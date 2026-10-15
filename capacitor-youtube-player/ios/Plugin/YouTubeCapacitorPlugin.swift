import Foundation
import Capacitor
import AVFoundation
import MediaPlayer
import UIKit
import Combine
// YouTubePlayerKit sources are compiled into THIS module (see ios/Plugin/YouTubePlayerKit),
// so no separate `import YouTubePlayerKit` is needed (it would fail: no such module).

@MainActor
@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {

    private var player: YouTubePlayer?
    private var timer: Timer?
    private var intendedPlaybackState = "paused"
    private let silentPlayer = SilentAudioPlayer()
    private var didNotifyErrorForCurrentLoad = false
    private var lastNotifiedState = ""
    private var cachedDuration: Double = 0
    private var lastDurationFetch = Date.distantPast

    private var isInterrupted = false
    private var lastResumeAttempt = Date.distantPast
    private var lastNowPlayingUpdate = Date.distantPast
    private var loadStartedAt = Date.distantPast

    private var localMode = false
    // Play/pause taps are de-bounced: only the final intent is applied to the player.
    private var pendingApply: DispatchWorkItem?

    private var silenceStopWork: DispatchWorkItem?

    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?
    private var npArtKey = ""
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artDataCache: [String: String] = [:]
    private var npArtDataUrl: String?

    private var resumeGeneration = 0
    private var lastToggleAt = Date.distantPast
    private var remoteGateTimes: [String: Date] = [:]
    private var stateQueryInFlight = false
    private var npDuration: Double = 0
    private var npElapsed: Double = 0
    private var remoteCommandsConfigured = false

    private struct UpNextItem {
        let videoId: String; let index: Int
        let title: String; let artist: String
        let duration: Double; let artworkUrl: String?
    }
    private var upNext: [UpNextItem] = []
    private var repeatOne = false
    private var didHandleEndForCurrentLoad = false
    private var lastAdvanced: (index: Int, videoId: String)?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // Direct stream playback (the way apps like YouTify do it): the audio URL is fetched
    // from YouTube's own player endpoint and played with AVPlayer. That is ordinary app
    // audio, so background playback, the lock screen and Control Center work like in any
    // other music app. If the URL cannot be fetched, the embedded web player is used.
    private let streamEnabled = true
    private var streamMode = false
    // Optional user-supplied extraction endpoint (Settings -> "Audio source").
    private var customStreamEndpoint: String?
    private var streamPlayer: AVPlayer?
    private var streamItem: AVPlayerItem?
    private var streamDuration: Double = 0
    private var streamEndedObserver: NSObjectProtocol?
    private var streamFailedObserver: NSObjectProtocol?
    private var streamStatusObservation: NSKeyValueObservation?

    private var cancellables = Set<AnyCancellable>()

    // Every load bumps this. Async work (progress polling, delayed loads) captures it and
    // is dropped if it changed, so values from the PREVIOUS song never leak into the new one.
    private var loadGeneration = 0
    private var loadConfirmed = false
    private var currentVideoId = ""

    private func startLoading(videoId: String) {
        loadGeneration &+= 1
        let gen = loadGeneration
        loadConfirmed = false
        loadStartedAt = Date()
        currentVideoId = videoId
        cachedDuration = 0
        lastDurationFetch = Date.distantPast
        player?.source = .video(id: videoId)
        Task { [weak self] in
            // Wait until the embedded player is ready (first load), but give up if a newer load started.
            while let self = self, gen == self.loadGeneration, self.player?.state == .idle {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self = self, gen == self.loadGeneration, let player = self.player else { return }
            try? await player.load(source: .video(id: videoId))
            if gen == self.loadGeneration { try? await player.play() }
        }
    }

    public override func load() {
        super.load()
        DispatchQueue.main.async {
            self.activateAudioSession(force: true)
            self.silentPlayer.play()
            UIApplication.shared.beginReceivingRemoteControlEvents()

            self.player = YouTubePlayer(
                parameters: .init(
                    autoPlay: true,
                    showControls: false,
                    showFullscreenButton: false
                ),
                configuration: .init(
                    allowsInlineMediaPlayback: true
                )
            )

            self.player?.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.handlePlayerState(state)
                }
                .store(in: &self.cancellables)

            self.player?.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] playbackState in
                    self?.handlePlaybackState(playbackState)
                }
                .store(in: &self.cancellables)

            self.attachPlayerWebViewIfNeeded()
            self.setupRemoteCommands()

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: nil)
            nc.addObserver(self, selector: #selector(self.routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)

            self.startStateObserver()
        }
    }

    private func handlePlayerState(_ state: YouTubePlayer.State) {
        if case .error(let error) = state {
            if !didNotifyErrorForCurrentLoad {
                didNotifyErrorForCurrentLoad = true
                notifyListeners("youtubeError", data: ["error": String(describing: error)])
            }
        }
    }

    private func handlePlaybackState(_ state: YouTubePlayer.PlaybackState) {
        let stateStr: String
        switch state {
        case .unstarted: stateStr = "unstarted"
        case .ended: stateStr = "ended"
        case .playing: stateStr = "playing"
        case .paused: stateStr = "paused"
        case .buffering: stateStr = "buffering"
        case .cued: stateStr = "cued"
        default: stateStr = "unknown"
        }

        if stateStr == "playing" || stateStr == "buffering" { loadConfirmed = true }

        if stateStr == "playing" && intendedPlaybackState == "paused" {
            Task { try? await self.player?.pause() }
            return
        }

        let stalled = stateStr == "paused" || stateStr == "cued"
            || (stateStr == "unstarted" && Date().timeIntervalSince(loadStartedAt) > 3)
        if stalled && intendedPlaybackState == "playing" && !isInterrupted {
            if Date().timeIntervalSince(lastResumeAttempt) > 0.12 {
                lastResumeAttempt = Date()
                activateAudioSession()
                silentPlayer.play()
                Task { try? await self.player?.play() }
            }
            return
        }

        if stateStr == "ended" && handleTrackEnded() { return }

        if stateStr != lastNotifiedState {
            lastNotifiedState = stateStr
            notifyListeners("youtubeStateChange", data: ["state": stateStr])
            if stateStr == "playing" { broadcastWebSession() }
        }
    }

    private var sessionNeedsActivation = true

    private func activateAudioSession(force: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            if force || session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
                sessionNeedsActivation = true
            }
            if force || sessionNeedsActivation {
                try session.setActive(true)
                sessionNeedsActivation = false
            }
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func attachPlayerWebViewIfNeeded() {
        guard let wv = player?.webView else { return }
        /* The lock screen / Control Center play button and the automatic switch to the
           next track (both happen without a fresh touch on the page) count as playback
           with no user gesture. WebKit blocks audible media in that case unless the
           player is allowed to start on its own. Applied on every call - it must be in
           place before the player page loads. */
        wv.configuration.mediaTypesRequiringUserActionForPlayback = []
        guard wv.superview == nil else { return }
        wv.isHidden = false
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        wv.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        if let main = bridge?.webView, let parent = main.superview {
            parent.insertSubview(wv, belowSubview: main)
        } else if let root = bridge?.viewController?.view {
            root.addSubview(wv)
        }
    }

    private func keepSessionAliveWhilePaused() {
        silenceStopWork?.cancel()
        activateAudioSession()
        silentPlayer.play()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.intendedPlaybackState != "playing" else { return }
            self.silentPlayer.pause()
        }
        silenceStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60, execute: work)
    }

    private func cancelSilenceStop() {
        silenceStopWork?.cancel()
        silenceStopWork = nil
    }

    private func performPlay() {
        isInterrupted = false
        intendedPlaybackState = "playing"
        cancelSilenceStop()
        pushNowPlaying()
        resumeIfIntended()
    }

    private func performPause() {
        intendedPlaybackState = "paused"
        resumeGeneration &+= 1
        if streamMode {
            streamPlayer?.pause()
            notifyState("paused")
            keepSessionAliveWhilePaused()
            pushNowPlaying()
            return
        }
        Task { try? await player?.pause() }
        keepSessionAliveWhilePaused()
        pushNowPlaying()
    }

    private func resumeIfIntended() {
        guard intendedPlaybackState == "playing", !isInterrupted else { return }
        activateAudioSession()
        silentPlayer.play()
        if streamMode {
            if streamPlayer?.timeControlStatus != .playing { streamPlayer?.play() }
            notifyState("playing")
            resumeGeneration &+= 1
            return
        }
        Task { try? await player?.play() }
        resumeGeneration &+= 1
        let gen = resumeGeneration
        for delay in [0.05, 0.15, 0.35, 0.7, 1.3, 2.5, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, gen == self.resumeGeneration,
                      self.intendedPlaybackState == "playing", !self.isInterrupted else { return }

                let state = self.player?.playbackStateSubject.value
                if state != .playing && state != .buffering {
                    self.activateAudioSession()
                    self.silentPlayer.play()
                    Task { try? await self.player?.play() }
                }
            }
        }
    }

    private func beginResumeTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "music-resume") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
        }
    }

    @objc func appWillResignActive() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
            self.pushNowPlaying()
        }
    }

    @objc func appDidEnterBackground() {
        DispatchQueue.main.async {
            self.beginResumeTask()
            self.resumeIfIntended()
            self.pushNowPlaying()
            if self.intendedPlaybackState == "playing" {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
        }
    }

    @objc func appDidBecomeActive() {
        DispatchQueue.main.async {
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            self.lastNotifiedState = ""
            self.resumeIfIntended()
            self.pushNowPlaying()
            self.broadcastWebSession()
            if let a = self.lastAdvanced {
                self.notifyListeners("youtubeAdvanced", data: ["index": a.index, "videoId": a.videoId])
            }
        }
    }

    @objc func engineConfigChanged() {
        DispatchQueue.main.async { if self.intendedPlaybackState == "playing" { self.silentPlayer.recoverIfNeeded() } }
    }

    @objc func mediaServicesReset() {
        DispatchQueue.main.async {
            self.sessionNeedsActivation = true
            self.activateAudioSession(force: true)
            self.silentPlayer.restart()
            self.resumeIfIntended()
        }
    }

    @objc func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        guard reason == .oldDeviceUnavailable else { return }

        let headsetPorts: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        let previous = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let hadHeadset = previous?.outputs.contains(where: { output in
            headsetPorts.contains(output.portType)
        }) ?? false
        guard hadHeadset else { return }

        DispatchQueue.main.async {
            let stillHeadset = AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { output in
                headsetPorts.contains(output.portType)
            })
            if !stillHeadset && !self.localMode { self.performPause() }
        }
    }

    @objc func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.isInterrupted = true
                self.resumeGeneration &+= 1
            } else {
                self.isInterrupted = false
                self.sessionNeedsActivation = true
                let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resumeIfIntended()
                } else {
                    self.intendedPlaybackState = "paused"
                }
            }
        }
    }

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remotePlay(); return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remotePause(); return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.localMode { return .success }
            if self.intendedPlaybackState == "playing" { self.remotePause() } else { self.remotePlay() }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteTrack("next"); return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remoteTrack("previous"); return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, !self.localMode else { return .success }
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            if self.streamMode {
                self.streamPlayer?.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                Task { try? await self.player?.seek(to: Measurement(value: e.positionTime, unit: .seconds), allowSeekAhead: true) }
            }
            self.npElapsed = e.positionTime
            self.pushNowPlaying()
            return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            guard let self = self, !self.localMode else { return .success }
            self.remotePause(); return .success
        }
        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self, !self.localMode else { return .success }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self.seekBy(interval)
            return .success
        }
        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self, !self.localMode else { return .success }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self.seekBy(-interval)
            return .success
        }
        applyLockScreenMode()
    }

    private func seekBy(_ seconds: Double) {
        if streamMode {
            guard let p = streamPlayer else { return }
            let current = p.currentTime().seconds
            let target = max(0, current + seconds)
            p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            npElapsed = target
            pushNowPlaying()
            notifyListeners("youtubeTimeUpdate", data: [
                "currentTime": target,
                "duration": cachedDuration > 0 ? cachedDuration : npDuration,
                "videoId": currentVideoId
            ])
        } else {
            Task { [weak self] in
                guard let self = self else { return }
                let current = (try? await self.player?.getCurrentTime().value) ?? self.npElapsed
                let target = max(0, current + seconds)
                try? await self.player?.seek(to: Measurement(value: target, unit: .seconds), allowSeekAhead: true)
                self.npElapsed = target
                self.pushNowPlaying()
                self.notifyListeners("youtubeTimeUpdate", data: [
                    "currentTime": target,
                    "duration": self.cachedDuration > 0 ? self.cachedDuration : self.npDuration,
                    "videoId": self.currentVideoId
                ])
            }
        }
    }

    private func applyLockScreenMode() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.stopCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [10]
    }

    private func remoteGate(_ key: String, window: TimeInterval = 0.2) -> Bool {
        let now = Date()
        if let t = remoteGateTimes[key], now.timeIntervalSince(t) < window { return false }
        remoteGateTimes[key] = now
        return true
    }

    private func remoteTrack(_ name: String) {
        DispatchQueue.main.async {
            guard self.remoteGate("track-" + name) else { return }
            self.notifyListeners("youtubeRemoteCommand", data: ["command": name])
        }
    }

    private func broadcastWebSession() {
        // Nothing needed here since we don't sync with WebSession anymore
    }

    private func remotePlay() {
        DispatchQueue.main.async {
            guard self.remoteGate("play") else { return }
            self.performPlay()
        }
    }

    private func remotePause() {
        DispatchQueue.main.async {
            guard self.remoteGate("pause") else { return }
            self.performPause()
        }
    }

    private func pushNowPlaying() {
        guard !localMode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: npElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: intendedPlaybackState == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if npDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = npDuration }
        if let art = npArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = intendedPlaybackState == "playing" ? .playing : .paused
    }

    @objc func setNowPlaying(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let duration = call.getDouble("duration") ?? 0
        let artworkUrl = call.getString("artworkUrl")
        let isLocal = call.getBool("local") ?? false
        if isLocal {
            DispatchQueue.main.async { self.localMode = true; call.resolve() }
            return
        }
        DispatchQueue.main.async {
            self.localMode = false
            self.npTitle = title
            self.npArtist = artist
            self.npDuration = duration
            self.npElapsed = 0
            self.applyArtwork(urlString: artworkUrl)
            self.pushNowPlaying()
            self.broadcastWebSession()
            call.resolve()
        }
    }

    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    nonisolated private static func squareCrop(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return img }
        let letterboxed = abs(h / w - 0.75) < 0.02
        let side = letterboxed ? h * 0.75 : min(w, h)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: cropped, scale: 1, orientation: img.imageOrientation)
    }

    nonisolated private static func smallJpegDataUrl(_ img: UIImage) -> String? {
        let side: CGFloat = 400
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        let jpg = small.image { _ in img.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let data = jpg.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    nonisolated private static func artworkCandidates(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s = "https://" + String(s.dropFirst(7)) }
        var out: [String] = []
        if let r = s.range(of: "i.ytimg.com/vi/") {
            let rest = s[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let vid = String(rest[rest.startIndex..<slash])
                for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault", "default"] {
                    out.append("https://i.ytimg.com/vi/\(vid)/\(name).jpg")
                }
                if !out.contains(s) { out.insert(s, at: 0) }
                return out
            }
        }
        return [s]
    }

    private func applyArtwork(urlString: String?) {
        guard let raw = urlString, !raw.isEmpty else { npArtwork = nil; npArtKey = ""; npArtDataUrl = nil; return }
        let key = raw
        npArtKey = key
        if let cached = artworkCache[key] { npArtwork = cached; npArtDataUrl = artDataCache[key]; return }
        npArtwork = nil
        npArtDataUrl = nil
        let candidates = YouTubeCapacitorPlugin.artworkCandidates(raw)
        func attempt(_ i: Int) {
            guard i < candidates.count, let url = URL(string: candidates[i]) else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                guard ok, let data = data, data.count > 1500, let img = UIImage(data: data), img.size.width >= 100 else {
                    attempt(i + 1); return
                }
                let square = YouTubeCapacitorPlugin.squareCrop(img)
                let art = YouTubeCapacitorPlugin.makeArtwork(square)
                let dataUrl = YouTubeCapacitorPlugin.smallJpegDataUrl(square)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.artworkCache[key] = art
                    if let d = dataUrl { self.artDataCache[key] = d }
                    if self.artworkCache.count > 40, let k = self.artworkCache.keys.first(where: { $0 != key }) { self.artworkCache.removeValue(forKey: k) }
                    if self.npArtKey == key { self.npArtwork = art; self.npArtDataUrl = dataUrl; self.pushNowPlaying(); self.broadcastWebSession() }
                }
            }.resume()
        }
        attempt(0)
    }

    @objc func load(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        DispatchQueue.main.async {
            self.lastAdvanced = nil
            self.didNotifyErrorForCurrentLoad = false
            self.didHandleEndForCurrentLoad = false
            self.lastNotifiedState = ""
            self.cachedDuration = 0
            self.isInterrupted = false
            self.localMode = false
            self.loadStartedAt = Date()
            self.cancelSilenceStop()
            self.intendedPlaybackState = "playing"
            self.activateAudioSession()
            self.silentPlayer.play()
            self.attachPlayerWebViewIfNeeded()
            self.npElapsed = 0
            self.startLoading(videoId: videoId)
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.cancelPendingApply()
            self.performPlay()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.cancelPendingApply()
            self.performPause()
            call.resolve()
        }
    }

    /* Every tap used to be forwarded to the YouTube player straight away. Spamming the
       play/pause button therefore queued several pause/play round-trips (each one is a
       JavaScript evaluation inside the player's web view) and playback froze for a few
       seconds while they drained. Taps are de-bounced now: only the last intent is
       applied, and the answer to the web view is immediate so the UI never blocks. */
    private func schedulePlaybackApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingApply = nil
            if self.intendedPlaybackState == "playing" { self.performPlay() } else { self.performPause() }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func cancelPendingApply() {
        pendingApply?.cancel()
        pendingApply = nil
    }

    @objc func toggle(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if Date().timeIntervalSince(self.lastToggleAt) > 0.18 {
                self.lastToggleAt = Date()
                self.intendedPlaybackState = self.intendedPlaybackState == "playing" ? "paused" : "playing"
            }
            self.schedulePlaybackApply()
            call.resolve(["playing": self.intendedPlaybackState == "playing"])
        }
    }

    /* Current native state. The web view asks for it when the app comes back to the
       foreground, because the lock screen / Control Center may have changed playback
       while the page was frozen. */
    @objc func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let playing = self.intendedPlaybackState == "playing" && (!self.streamMode || self.streamPlayer?.timeControlStatus == .playing)
            var currentTime = self.npElapsed
            if self.streamMode, let t = self.streamPlayer?.currentTime(), t.isValid && !t.isIndefinite { currentTime = max(0, t.seconds) }
            call.resolve([
                "playing": playing,
                "currentTime": currentTime,
                "duration": self.cachedDuration > 0 ? self.cachedDuration : self.npDuration,
                "state": self.lastNotifiedState
            ])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.stopStream()
            Task { try? await self.player?.stop() }
            self.cancelSilenceStop()
            self.silentPlayer.pause()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getDouble("seconds") ?? 0
        DispatchQueue.main.async {
            if self.streamMode {
                self.streamPlayer?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                Task { try? await self.player?.seek(to: Measurement(value: seconds, unit: .seconds), allowSeekAhead: true) }
            }
            call.resolve()
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func setUpNext(_ call: CAPPluginCall) {
        let raw = call.getArray("items", JSObject.self) ?? []
        let rep = call.getBool("repeatOne") ?? false
        DispatchQueue.main.async {
            self.repeatOne = rep
            self.upNext = raw.compactMap { o in
                guard let vid = o["videoId"] as? String, !vid.isEmpty,
                      let idx = o["index"] as? Int else { return nil }
                return UpNextItem(videoId: vid, index: idx,
                                  title: o["title"] as? String ?? "",
                                  artist: o["artist"] as? String ?? "",
                                  duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
                                  artworkUrl: o["artworkUrl"] as? String)
            }
            call.resolve()
        }
    }

    @objc func setTheme(_ call: CAPPluginCall) {
        let theme = call.getString("theme") ?? "system"
        DispatchQueue.main.async {
            let style: UIUserInterfaceStyle = theme == "light" ? .light : (theme == "dark" ? .dark : .unspecified)
            self.bridge?.viewController?.overrideUserInterfaceStyle = style
            call.resolve()
        }
    }

    private func handleTrackEnded() -> Bool {
        if didHandleEndForCurrentLoad { return true }
        if repeatOne {
            didHandleEndForCurrentLoad = true
            intendedPlaybackState = "playing"
            if streamMode {
                streamPlayer?.seek(to: .zero)
                streamPlayer?.play()
                notifyState("playing")
            } else {
                Task {
                    try? await self.player?.seek(to: Measurement(value: 0, unit: .seconds), allowSeekAhead: true)
                    try? await self.player?.play()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.didHandleEndForCurrentLoad = false }
            return true
        }
        guard !upNext.isEmpty else { return false }
        didHandleEndForCurrentLoad = true
        let item = upNext.removeFirst()
        didNotifyErrorForCurrentLoad = false
        lastNotifiedState = ""
        cachedDuration = 0
        loadStartedAt = Date()
        intendedPlaybackState = "playing"
        activateAudioSession()
        silentPlayer.play()
        loadNextTrack(videoId: item.videoId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.didHandleEndForCurrentLoad = false }
        npTitle = item.title; npArtist = item.artist; npDuration = item.duration; npElapsed = 0
        applyArtwork(urlString: item.artworkUrl)
        pushNowPlaying()
        broadcastWebSession()
        lastAdvanced = (item.index, item.videoId)
        notifyListeners("youtubeAdvanced", data: ["index": item.index, "videoId": item.videoId])
        return true
    }

    private func startStateObserver() {
        stopStateObserver()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollProgress() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopStateObserver() {
        timer?.invalidate()
        timer = nil
    }

    private func pollProgress() {
        if streamMode { pollStreamProgress(); return }
        if stateQueryInFlight { return }
        let gen = loadGeneration
        let needDuration = cachedDuration <= 0 || Date().timeIntervalSince(lastDurationFetch) > 3
        let knownDuration = cachedDuration
        stateQueryInFlight = true
        Task { @MainActor in
            defer { self.stateQueryInFlight = false }
            var duration = knownDuration
            if needDuration, let fetched = try? await self.player?.getDuration() {
                guard gen == self.loadGeneration else { return }
                duration = fetched.value
                self.cachedDuration = duration
                self.lastDurationFetch = Date()
            }
            guard let currentTime = try? await self.player?.getCurrentTime() else { return }
            // Song changed while we were waiting -> this answer belongs to the old song.
            guard gen == self.loadGeneration else { return }
            // Until the NEW video reports playing/buffering, the web view may still answer with the
            // old video's time (this made the bar jump from "where you skipped" back to 0).
            if !self.loadConfirmed && Date().timeIntervalSince(self.loadStartedAt) < 6 { return }

            self.notifyListeners("youtubeTimeUpdate", data: [
                "currentTime": currentTime.value,
                "duration": duration,
                "videoId": self.currentVideoId
            ])
            if Date().timeIntervalSince(self.lastNowPlayingUpdate) > 1.0 {
                self.lastNowPlayingUpdate = Date()
                self.npElapsed = currentTime.value
                if duration > 0 { self.npDuration = duration }
                self.pushNowPlaying()
            }
        }
    }

    // MARK: - Direct audio stream (native playback that survives the background)

    /* Asked by the web page before every track. Resolves {ok:true} when the audio
       stream was fetched and native AVPlayer playback started, {ok:false} when it was
       not - the page then falls back to the embedded web player as before. */
    @objc func loadStream(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        DispatchQueue.main.async {
            self.lastAdvanced = nil
            self.didNotifyErrorForCurrentLoad = false
            self.didHandleEndForCurrentLoad = false
            self.lastNotifiedState = ""
            self.isInterrupted = false
            self.localMode = false
            self.npElapsed = 0
            guard self.streamEnabled, !videoId.isEmpty else { call.resolve(["ok": false]); return }
            self.loadStartedAt = Date()
            self.loadGeneration &+= 1
            self.fetchStreamURL(videoId: videoId) { [weak self] source in
                guard let self = self else { return }
                guard let source = source else {
                    self.stopStream()
                    call.resolve(["ok": false])
                    return
                }
                self.playStream(source: source, videoId: videoId)
                call.resolve(["ok": true])
            }
        }
    }

    /* Next track of a queue that is already playing natively - keep the same mode
       (native stream) instead of dropping back to the web view. */
    private func loadNextTrack(videoId: String) {
        guard streamEnabled, streamMode || streamItem != nil else {
            stopStream()
            startLoading(videoId: videoId)
            return
        }
        loadStartedAt = Date()
        fetchStreamURL(videoId: videoId) { [weak self] source in
            guard let self = self else { return }
            guard let source = source else {
                self.stopStream()
                self.startLoading(videoId: videoId)
                return
            }
            self.playStream(source: source, videoId: videoId)
        }
    }

    // MARK: - YouTube stream extraction (InnerTube)

    /* One resolved playable stream: the direct audio URL plus the metadata and the
       User-Agent the URL was minted for (the CDN is happiest when the request carries
       the same identity). */
    struct StreamSource {
        let url: URL
        let duration: Double
        let title: String
        let artist: String
        let userAgent: String
    }

    /* An InnerTube client profile. YouTube only hands out direct stream URLs to
       specific clients; the ones below were the ones answering with playable URLs when
       this was written, in the order they are tried. */
    private struct StreamClient {
        let name: String, nameID: String, version: String, userAgent: String
    }

    /* These three are tried one after another; the first one that answers with a direct
       audio URL wins. ANDROID_VR is first because it is the client that needs no
       proof-of-origin token for unauthenticated playback. */
    private static let streamClients: [StreamClient] = [
        StreamClient(
            name: "ANDROID_VR", nameID: "28", version: "1.65.10",
            userAgent:
                "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        ),
        StreamClient(
            name: "IOS", nameID: "5", version: "21.02.3",
            userAgent:
                "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        ),
        StreamClient(
            name: "ANDROID", nameID: "3", version: "21.02.35",
            userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip"
        ),
    ]

    // Public InnerTube key published in YouTube's own web client JavaScript.
    // The player endpoint must be asked on www.youtube.com - the same clients asked on
    // youtubei.googleapis.com or music.youtube.com answer with SABR-only responses that
    // contain no direct URL at all (that is what used to break playback here).
    private static let innertubeKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let innertubePlayerURL = "https://www.youtube.com/youtubei/v1/player"
    private static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static func contextFields(for client: StreamClient) -> [String: Any] {
        var c: [String: Any] = ["hl": "en", "clientName": client.name,
                                "clientVersion": client.version, "userAgent": client.userAgent]
        switch client.name {
        case "ANDROID_VR":
            c["deviceMake"] = "Oculus"
            c["deviceModel"] = "Quest 3"
            c["androidSdkVersion"] = 32
            c["osName"] = "Android"
            c["osVersion"] = "12L"
        case "IOS":
            c["deviceMake"] = "Apple"
            c["deviceModel"] = "iPhone16,2"
            c["osName"] = "iPhone"
            c["osVersion"] = "18.3.2.22D82"
        case "ANDROID":
            c["androidSdkVersion"] = 30
            c["osName"] = "Android"
            c["osVersion"] = "11"
        default:
            break
        }
        return c
    }

    /* visitorData is the session identity YouTube ties the answer to. Without it the
       player endpoint replies LOGIN_REQUIRED ("Sign in to confirm you're not a bot") and
       no stream URL is ever returned. It is lifted from the watch page and reused for
       half an hour, the same way yt-dlp keeps one visitor id per session. */
    private var visitorDataCache: (value: String, at: Date)?

    private func loadVisitorData(videoId: String, completion: @escaping (String?) -> Void) {
        if let cached = visitorDataCache, Date().timeIntervalSince(cached.at) < 1800 {
            completion(cached.value)
            return
        }
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&hl=en") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(YouTubeCapacitorPlugin.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            var found: String?
            if let data = data, let html = String(data: data, encoding: .utf8) {
                let pattern = "\"visitorData\"\\s*:\\s*\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html) {
                    found = String(html[range])
                }
            }
            DispatchQueue.main.async {
                if let found = found { self?.visitorDataCache = (found, Date()) }
                completion(found)
            }
        }.resume()
    }

    private func fetchFromPiped(videoId: String, completion: @escaping (StreamSource?) -> Void) {
        let instances = [
            "https://api.piped.privacydev.net/streams/",
            "https://pipedapi.kavin.rocks/streams/",
            "https://pipedapi.tokhmi.xyz/streams/"
        ]
        func tryInstance(_ idx: Int) {
            guard idx < instances.count, let url = URL(string: instances[idx] + videoId) else {
                completion(nil)
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                if ok, let data = data,
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let streams = json["audioStreams"] as? [[String: Any]] {
                    let m4a = streams.filter { ($0["mimeType"] as? String)?.contains("audio/mp4") == true || ($0["format"] as? String) == "M4A" }
                    let pick = m4a.sorted { (($0["bitrate"] as? NSNumber)?.intValue ?? 0) > (($1["bitrate"] as? NSNumber)?.intValue ?? 0) }.first ?? streams.first
                    if let pick = pick, let rawUrl = pick["url"] as? String, let streamUrl = URL(string: rawUrl) {
                        let dur = (json["duration"] as? NSNumber)?.doubleValue ?? 0
                        let title = (json["title"] as? String) ?? ""
                        let artist = (json["uploader"] as? String) ?? ""
                        let src = StreamSource(url: streamUrl, duration: dur, title: title, artist: artist, userAgent: "Mozilla/5.0")
                        DispatchQueue.main.async { completion(src) }
                        return
                    }
                }
                tryInstance(idx + 1)
            }.resume()
        }
        tryInstance(0)
    }

    private func fetchStreamURL(videoId: String, completion: @escaping (StreamSource?) -> Void) {
        // A user-supplied endpoint (Settings -> audio source) is tried first
        if let endpoint = customStreamEndpoint, !endpoint.isEmpty {
            fetchFromCustomEndpoint(endpoint, videoId: videoId) { [weak self] source in
                guard let self = self else { return }
                if let source = source { completion(source); return }
                self.fetchFromPiped(videoId: videoId) { pipedSource in
                    if let pipedSource = pipedSource { completion(pipedSource); return }
                    self.loadVisitorData(videoId: videoId) { vd in
                        self.tryStreamClients(YouTubeCapacitorPlugin.streamClients,
                                              videoId: videoId, visitorData: vd, completion: completion)
                    }
                }
            }
            return
        }
        self.fetchFromPiped(videoId: videoId) { [weak self] pipedSource in
            guard let self = self else { return }
            if let pipedSource = pipedSource { completion(pipedSource); return }
            self.loadVisitorData(videoId: videoId) { vd in
                self.tryStreamClients(YouTubeCapacitorPlugin.streamClients,
                                      videoId: videoId, visitorData: vd, completion: completion)
            }
        }
    }

    private func tryStreamClients(_ clients: [StreamClient], videoId: String,
                                  visitorData: String?, completion: @escaping (StreamSource?) -> Void) {
        guard let client = clients.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        requestStream(client: client, videoId: videoId, visitorData: visitorData) { [weak self] source in
            guard let self = self else { return }
            if let source = source { completion(source); return }
            self.tryStreamClients(Array(clients.dropFirst()), videoId: videoId,
                                  visitorData: visitorData, completion: completion)
        }
    }

    private func requestStream(client: StreamClient, videoId: String, visitorData: String?,
                               completion: @escaping (StreamSource?) -> Void) {
        var fields = YouTubeCapacitorPlugin.contextFields(for: client)
        if let vd = visitorData, !vd.isEmpty { fields["visitorData"] = vd }
        let body: [String: Any] = [
            "context": ["client": fields],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            // yt-dlp sends this for every client; without it some clients answer with a
            // SABR-only response that has no playable URL in it.
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
        ]
        guard var comps = URLComponents(string: YouTubeCapacitorPlugin.innertubePlayerURL) else {
            completion(nil); return
        }
        comps.queryItems = [
            URLQueryItem(name: "key", value: YouTubeCapacitorPlugin.innertubeKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = comps.url else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(client.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/watch?v=\(videoId)", forHTTPHeaderField: "Referer")
        req.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        if let vd = visitorData, !vd.isEmpty { req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var source: StreamSource?
            if code == 200, let data = data {
                source = YouTubeCapacitorPlugin.parseStream(data: data, client: client)
            }
            DispatchQueue.main.async { completion(source) }
        }.resume()
    }

    /* Own-endpoint support: the configured URL is called with the video id appended (or
       substituted for a {id} placeholder) and is expected to answer with JSON that has a
       stream URL under one of the usual keys. Any failure simply falls back to the
       built-in extraction. */
    private func fetchFromCustomEndpoint(_ endpoint: String, videoId: String,
                                        completion: @escaping (StreamSource?) -> Void) {
        let target = endpoint.contains("{id}")
            ? endpoint.replacingOccurrences(of: "{id}", with: videoId)
            : endpoint + (endpoint.contains("?") ? "&" : "?") + "id=" + videoId
        guard let url = URL(string: target) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(YouTubeCapacitorPlugin.browserUserAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var source: StreamSource?
            if code == 200, let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let raw = (json["url"] as? String)
                    ?? (json["audio"] as? String)
                    ?? ((json["stream"] as? [String: Any])?["url"] as? String)
                    ?? ((json["data"] as? [String: Any])?["url"] as? String)
                if let raw = raw, let streamURL = URL(string: raw) {
                    source = StreamSource(
                        url: streamURL,
                        duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
                        title: json["title"] as? String ?? "",
                        artist: json["artist"] as? String ?? "",
                        userAgent: YouTubeCapacitorPlugin.browserUserAgent
                    )
                }
            }
            DispatchQueue.main.async { completion(source) }
        }.resume()
    }

    @objc func setStreamEndpoint(_ call: CAPPluginCall) {
        let endpoint = (call.getString("url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            self.customStreamEndpoint = endpoint.isEmpty ? nil : endpoint
            call.resolve()
        }
    }

    /* Picks the format to hand to AVPlayer. audio/mp4 (AAC) comes first because that is
       what AVPlayer plays natively; the webm/opus formats YouTube also offers are not
       playable there, so when only those are present the caller falls back to the
       embedded player instead of starting playback that would stay silent. */
    private static func parseStream(data: Data, client: StreamClient) -> StreamSource? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let streaming = json["streamingData"] as? [String: Any] else { return nil }

        let details = json["videoDetails"] as? [String: Any]
        let duration = Double((details?["lengthSeconds"] as? String) ?? "") ?? 0
        let title = details?["title"] as? String ?? ""
        let artist = details?["author"] as? String ?? ""

        let formats = (streaming["adaptiveFormats"] as? [[String: Any]]) ?? []
        var best: (url: URL, rank: Int, bitrate: Double)?
        for f in formats {
            guard let mime = f["mimeType"] as? String, mime.hasPrefix("audio/mp4") else { continue }
            guard let raw = f["url"] as? String, let url = URL(string: raw) else { continue }
            let quality = (f["audioQuality"] as? String) ?? ""
            let rank: Int
            switch quality {
            case "AUDIO_QUALITY_HIGH": rank = 4
            case "AUDIO_QUALITY_MEDIUM": rank = 3
            case "AUDIO_QUALITY_LOW": rank = 2
            case "AUDIO_QUALITY_ULTRALOW": rank = 1
            default: rank = 0
            }
            let bitrate = (f["bitrate"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || rank > best!.rank || (rank == best!.rank && bitrate > best!.bitrate) {
                best = (url, rank, bitrate)
            }
        }
        if let best = best {
            return StreamSource(url: best.url, duration: duration, title: title,
                                artist: artist, userAgent: client.userAgent)
        }

        // No AAC track: an HLS manifest is still playable by AVPlayer, but only if the
        // client actually returned one.
        if let raw = streaming["hlsManifestUrl"] as? String, let url = URL(string: raw) {
            return StreamSource(url: url, duration: duration, title: title,
                                artist: artist, userAgent: client.userAgent)
        }
        return nil
    }

    private func playStream(source: StreamSource, videoId: String) {
        stopStream()
        loadConfirmed = true
        currentVideoId = videoId
        streamDuration = source.duration
        cachedDuration = source.duration
        lastDurationFetch = Date()
        loadStartedAt = Date()
        intendedPlaybackState = "playing"
        streamMode = true
        activateAudioSession()
        silentPlayer.play()
        beginReceivingRemote()

        /* The CDN URL was minted for a specific client identity, so the request for the
           media itself carries that same User-Agent. */
        let asset = AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": source.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        streamItem = item
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        streamPlayer = p
        streamEndedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.notifyState("ended")
            _ = self.handleTrackEnded()
        }
        streamFailedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.stopStream()
            self.startLoading(videoId: videoId)
        }
        streamStatusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self = self else { return }
            if it.status == .failed {
                DispatchQueue.main.async {
                    self.stopStream()
                    self.startLoading(videoId: videoId)
                }
            }
        }
        p.play()
        notifyState("playing")
        pushNowPlaying()
    }

    private func stopStream() {
        streamStatusObservation?.invalidate()
        streamStatusObservation = nil
        if let obs = streamEndedObserver { NotificationCenter.default.removeObserver(obs); streamEndedObserver = nil }
        if let obs = streamFailedObserver { NotificationCenter.default.removeObserver(obs); streamFailedObserver = nil }
        streamPlayer?.pause()
        streamPlayer = nil
        streamItem = nil
        streamMode = false
    }

    private func beginReceivingRemote() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func notifyState(_ state: String) {
        loadConfirmed = true
        guard state != lastNotifiedState else { return }
        lastNotifiedState = state
        notifyListeners("youtubeStateChange", data: ["state": state])
    }

    private func pollStreamProgress() {
        guard let p = streamPlayer, let item = streamItem else { return }
        let t = p.currentTime()
        guard t.isValid && !t.isIndefinite else { return }
        let c = max(0, t.seconds)
        var d = streamDuration
        if d <= 0, item.duration.isValid && !item.duration.isIndefinite { d = item.duration.seconds }
        if d > 0 { cachedDuration = d; npDuration = d }
        notifyListeners("youtubeTimeUpdate", data: [
            "currentTime": c,
            "duration": d,
            "videoId": currentVideoId
        ])
        if Date().timeIntervalSince(lastNowPlayingUpdate) > 1.0 {
            lastNowPlayingUpdate = Date()
            npElapsed = c
            pushNowPlaying()
        }
    }
}

class SilentAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?

    init() {
        engine.attach(playerNode)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(44100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData?[ch]
            for i in 0..<Int(frames) { data?[i] = 0.0 }
        }
        silentBuffer = buffer
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    func recoverIfNeeded() {
        if engine.isRunning && playerNode.isPlaying { return }
        restart()
    }

    func play() {
        do {
            if !engine.isRunning { try engine.start() }
            if !playerNode.isPlaying { playerNode.play() }
        } catch {
            print("Failed to start silent audio engine")
        }
    }

    func pause() {
        playerNode.pause()
        engine.pause()
    }

    func restart() {
        playerNode.stop()
        engine.stop()
        if let b = silentBuffer { playerNode.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }
        play()
    }
}
