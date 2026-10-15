import Foundation
import Capacitor
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
@objc(YouTubeCapacitorPlugin)
public class YouTubeCapacitorPlugin: CAPPlugin {

    // MARK: - Native Playback Properties
    private var avPlayer: AVPlayer?
    private var currentItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemEndedObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?

    private var intendedPlaybackState = "paused"
    private var currentVideoId = ""
    private var cachedDuration: Double = 0
    private var loadGeneration = 0

    // Metadata for Lock Screen & Dynamic Island
    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?
    private var npArtKey = ""
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var npDuration: Double = 0
    private var npElapsed: Double = 0
    private var lastNowPlayingPush = Date.distantPast

    private var remoteCommandsConfigured = false
    private var customStreamEndpoint: String?

    // Native Queue for Background Playback
    private struct UpNextItem {
        let videoId: String
        let index: Int
        let title: String
        let artist: String
        let duration: Double
        let artworkUrl: String?
    }
    private var upNext: [UpNextItem] = []
    private var repeatOne = false
    private var lastAdvanced: (index: Int, videoId: String)?

    // MARK: - Plugin Lifecycle
    public override func load() {
        super.load()
        DispatchQueue.main.async {
            self.configureAudioSession()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            self.setupRemoteCommands()

            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Audio session setup error: \(error)")
        }
    }

    // MARK: - Lock Screen & Control Center (MPRemoteCommandCenter)
    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.performPlay()
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.performPause()
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.intendedPlaybackState == "playing" {
                self.performPause()
            } else {
                self.performPlay()
            }
            return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.advanceToNextTrack()
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.npElapsed > 3.0 {
                self.seekTo(seconds: 0)
            } else {
                self.notifyListeners("youtubeRemoteCommand", data: ["command": "previous"])
            }
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seekTo(seconds: e.positionTime)
            return .success
        }

        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self.seekBy(interval)
            return .success
        }

        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self.seekBy(-interval)
            return .success
        }

        cc.stopCommand.isEnabled = true
        cc.stopCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.performPause()
            return .success
        }
    }

    // MARK: - Now Playing Info Center (Dynamic Island & Lock Screen)
    private func pushNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: npElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: intendedPlaybackState == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if npDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = npDuration
        }
        if let art = npArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = intendedPlaybackState == "playing" ? .playing : .paused
        lastNowPlayingPush = Date()
    }

    private func applyArtwork(urlString: String?) {
        guard let raw = urlString, !raw.isEmpty else {
            npArtwork = nil
            npArtKey = ""
            return
        }
        let key = raw
        npArtKey = key
        if let cached = artworkCache[key] {
            npArtwork = cached
            pushNowPlaying()
            return
        }
        guard let url = URL(string: raw) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self = self, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let data = data, let img = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            DispatchQueue.main.async {
                self.artworkCache[key] = art
                if self.npArtKey == key {
                    self.npArtwork = art
                    self.pushNowPlaying()
                }
            }
        }.resume()
    }

    // MARK: - Direct Audio Stream Playback
    struct StreamSource {
        let url: URL
        let duration: Double
        let title: String
        let artist: String
        let userAgent: String
    }

    private func playDirectAudio(source: StreamSource, videoId: String) {
        stopCurrentPlayback()
        loadGeneration &+= 1
        currentVideoId = videoId
        intendedPlaybackState = "playing"

        if source.duration > 0 {
            cachedDuration = source.duration
            npDuration = source.duration
        }
        if !source.title.isEmpty && npTitle.isEmpty { npTitle = source.title }
        if !source.artist.isEmpty && npArtist.isEmpty { npArtist = source.artist }

        configureAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let asset = AVURLAsset(url: source.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": source.userAgent]
        ])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        currentItem = item

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        avPlayer = player

        // Observe Item Completion (Advance queue even when screen is locked!)
        itemEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.repeatOne {
                self.seekTo(seconds: 0)
                self.performPlay()
            } else {
                self.advanceToNextTrack()
            }
        }

        // Observe Item Failure
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("Playback failed for \(videoId), advancing to next")
            self.notifyListeners("youtubeError", data: ["videoId": videoId])
            self.advanceToNextTrack()
        }

        // KVO on Status
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self = self else { return }
            if it.status == .failed {
                print("AVPlayerItem status failed: \(String(describing: it.error))")
                DispatchQueue.main.async {
                    self.notifyListeners("youtubeError", data: ["videoId": videoId])
                    self.advanceToNextTrack()
                }
            } else if it.status == .readyToPlay {
                let d = it.duration.seconds
                if d > 0 && !d.isNaN && !d.isInfinite {
                    self.cachedDuration = d
                    self.npDuration = d
                    self.pushNowPlaying()
                }
            }
        }

        // Periodic Time Observer for Lock Screen progress and UI sync
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let c = max(0, time.seconds)
            guard !c.isNaN && !c.isInfinite else { return }
            self.npElapsed = c

            var d = self.cachedDuration
            if d <= 0, let cur = self.currentItem {
                let itemDur = cur.duration.seconds
                if itemDur > 0 && !itemDur.isNaN && !itemDur.isInfinite {
                    d = itemDur
                    self.cachedDuration = d
                    self.npDuration = d
                }
            }

            self.notifyListeners("youtubeTimeUpdate", data: [
                "currentTime": c,
                "duration": d > 0 ? d : self.npDuration,
                "videoId": self.currentVideoId
            ])

            if Date().timeIntervalSince(self.lastNowPlayingPush) >= 1.0 {
                self.pushNowPlaying()
            }
        }

        player.play()
        pushNowPlaying()
        notifyListeners("youtubeStateChange", data: ["state": "playing"])
    }

    private func stopCurrentPlayback() {
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if let obs = itemEndedObserver {
            NotificationCenter.default.removeObserver(obs)
            itemEndedObserver = nil
        }
        if let obs = itemFailedObserver {
            NotificationCenter.default.removeObserver(obs)
            itemFailedObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        currentItem = nil
    }

    // MARK: - Stream Extraction (InnerTube ANDROID_VR)
    private static let innertubeKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let vrUserAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    private func fetchStreamURL(videoId: String, completion: @escaping (StreamSource?) -> Void) {
        if let endpoint = customStreamEndpoint, !endpoint.isEmpty {
            fetchFromCustomEndpoint(endpoint, videoId: videoId) { [weak self] source in
                if let source = source { completion(source); return }
                self?.requestInnerTubeStream(videoId: videoId, completion: completion)
            }
            return
        }
        requestInnerTubeStream(videoId: videoId, completion: completion)
    }

    private func requestInnerTubeStream(videoId: String, completion: @escaping (StreamSource?) -> Void) {
        let body: [String: Any] = [
            "context": [
                "client": [
                    "hl": "en",
                    "clientName": "ANDROID_VR",
                    "clientVersion": "1.65.10",
                    "userAgent": YouTubeCapacitorPlugin.vrUserAgent,
                    "deviceMake": "Oculus",
                    "deviceModel": "Quest 3",
                    "androidSdkVersion": 32,
                    "osName": "Android",
                    "osVersion": "12L"
                ]
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(YouTubeCapacitorPlugin.innertubeKey)&prettyPrint=false") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YouTubeCapacitorPlugin.vrUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("28", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue("1.65.10", forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            guard ok, let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let streaming = json["streamingData"] as? [String: Any] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let details = json["videoDetails"] as? [String: Any]
            let duration = Double((details?["lengthSeconds"] as? String) ?? "") ?? 0
            let title = (details?["title"] as? String) ?? ""
            let artist = (details?["author"] as? String) ?? ""

            let formats = (streaming["adaptiveFormats"] as? [[String: Any]]) ?? []
            var best: (url: URL, bitrate: Double)?
            for f in formats {
                guard let mime = f["mimeType"] as? String, mime.contains("audio/mp4") else { continue }
                guard let raw = f["url"] as? String, let url = URL(string: raw) else { continue }
                let bitrate = (f["bitrate"] as? NSNumber)?.doubleValue ?? 0
                if best == nil || bitrate > best!.bitrate {
                    best = (url, bitrate)
                }
            }

            if let best = best {
                let src = StreamSource(url: best.url, duration: duration, title: title, artist: artist, userAgent: YouTubeCapacitorPlugin.vrUserAgent)
                DispatchQueue.main.async { completion(src) }
                return
            }

            DispatchQueue.main.async { completion(nil) }
        }.resume()
    }

    private func fetchFromCustomEndpoint(_ endpoint: String, videoId: String, completion: @escaping (StreamSource?) -> Void) {
        let target = endpoint.contains("{id}")
            ? endpoint.replacingOccurrences(of: "{id}", with: videoId)
            : endpoint + (endpoint.contains("?") ? "&" : "?") + "id=" + videoId
        guard let url = URL(string: target) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok, let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let raw = (json["url"] as? String) ?? (json["audio"] as? String)
                if let raw = raw, let streamUrl = URL(string: raw) {
                    let dur = (json["duration"] as? NSNumber)?.doubleValue ?? 0
                    let title = (json["title"] as? String) ?? ""
                    let artist = (json["artist"] as? String) ?? ""
                    let src = StreamSource(url: streamUrl, duration: dur, title: title, artist: artist, userAgent: "Mozilla/5.0")
                    DispatchQueue.main.async { completion(src) }
                    return
                }
            }
            DispatchQueue.main.async { completion(nil) }
        }.resume()
    }

    // MARK: - Native Playback Controls & Queue Navigation
    private func performPlay() {
        configureAudioSession()
        intendedPlaybackState = "playing"
        avPlayer?.play()
        pushNowPlaying()
        notifyListeners("youtubeStateChange", data: ["state": "playing"])
    }

    private func performPause() {
        intendedPlaybackState = "paused"
        avPlayer?.pause()
        pushNowPlaying()
        notifyListeners("youtubeStateChange", data: ["state": "paused"])
    }

    private func seekTo(seconds: Double) {
        guard let p = avPlayer else { return }
        let target = max(0, seconds)
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        npElapsed = target
        pushNowPlaying()
        notifyListeners("youtubeTimeUpdate", data: [
            "currentTime": target,
            "duration": cachedDuration > 0 ? cachedDuration : npDuration,
            "videoId": currentVideoId
        ])
    }

    private func seekBy(_ seconds: Double) {
        guard let p = avPlayer else { return }
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
    }

    private func advanceToNextTrack() {
        guard !upNext.isEmpty else {
            notifyListeners("youtubeRemoteCommand", data: ["command": "next"])
            return
        }
        let next = upNext.removeFirst()
        lastAdvanced = (next.index, next.videoId)
        currentVideoId = next.videoId
        npTitle = next.title
        npArtist = next.artist
        npDuration = next.duration
        npElapsed = 0
        applyArtwork(urlString: next.artworkUrl)
        pushNowPlaying()

        fetchStreamURL(videoId: next.videoId) { [weak self] source in
            guard let self = self, let source = source else { return }
            self.playDirectAudio(source: source, videoId: next.videoId)
            self.notifyListeners("youtubeAdvanced", data: ["index": next.index, "videoId": next.videoId])
        }
    }

    // MARK: - Capacitor Plugin Exported Methods
    @objc func loadStream(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        guard !videoId.isEmpty else { call.resolve(["ok": false]); return }
        fetchStreamURL(videoId: videoId) { [weak self] source in
            guard let self = self, let source = source else {
                call.resolve(["ok": false])
                return
            }
            self.playDirectAudio(source: source, videoId: videoId)
            call.resolve(["ok": true])
        }
    }

    @objc func load(_ call: CAPPluginCall) {
        let videoId = call.getString("videoId") ?? ""
        guard !videoId.isEmpty else { call.resolve(); return }
        fetchStreamURL(videoId: videoId) { [weak self] source in
            guard let self = self, let source = source else {
                call.resolve()
                return
            }
            self.playDirectAudio(source: source, videoId: videoId)
            call.resolve()
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.performPlay()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.performPause()
            call.resolve()
        }
    }

    @objc func toggle(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.intendedPlaybackState == "playing" {
                self.performPause()
            } else {
                self.performPlay()
            }
            call.resolve(["playing": self.intendedPlaybackState == "playing"])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intendedPlaybackState = "paused"
            self.stopCurrentPlayback()
            self.pushNowPlaying()
            call.resolve()
        }
    }

    @objc func seekTo(_ call: CAPPluginCall) {
        let seconds = call.getDouble("seconds") ?? 0
        DispatchQueue.main.async {
            self.seekTo(seconds: seconds)
            call.resolve()
        }
    }

    @objc func setNowPlaying(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        let artist = call.getString("artist") ?? ""
        let duration = call.getDouble("duration") ?? 0
        let artworkUrl = call.getString("artworkUrl")

        DispatchQueue.main.async {
            self.npTitle = title
            self.npArtist = artist
            if duration > 0 {
                self.npDuration = duration
                self.cachedDuration = duration
            }
            self.applyArtwork(urlString: artworkUrl)
            self.pushNowPlaying()
            call.resolve()
        }
    }

    @objc func setUpNext(_ call: CAPPluginCall) {
        let raw = call.getArray("items", JSObject.self) ?? []
        let rep = call.getBool("repeatOne") ?? false
        DispatchQueue.main.async {
            self.repeatOne = rep
            self.upNext = raw.compactMap { o in
                guard let vid = o["videoId"] as? String, !vid.isEmpty,
                      let idx = o["index"] as? Int else { return nil }
                return UpNextItem(
                    videoId: vid,
                    index: idx,
                    title: o["title"] as? String ?? "",
                    artist: o["artist"] as? String ?? "",
                    duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
                    artworkUrl: o["artworkUrl"] as? String
                )
            }
            call.resolve()
        }
    }

    @objc func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let isPlaying = self.intendedPlaybackState == "playing" && (self.avPlayer?.timeControlStatus == .playing || self.avPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            call.resolve([
                "playing": isPlaying,
                "currentTime": self.npElapsed,
                "duration": self.cachedDuration > 0 ? self.cachedDuration : self.npDuration,
                "state": self.intendedPlaybackState
            ])
        }
    }

    @objc func setStreamEndpoint(_ call: CAPPluginCall) {
        let endpoint = (call.getString("url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            self.customStreamEndpoint = endpoint.isEmpty ? nil : endpoint
            call.resolve()
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        let vol = Float(call.getDouble("volume") ?? 1.0)
        DispatchQueue.main.async {
            self.avPlayer?.volume = max(0, min(1, vol))
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

    // MARK: - Notifications & Session Interruptions
    @objc func appDidEnterBackground() {
        // AVPlayer continues seamlessly in the background without any timer or JS hacks!
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    @objc func appDidBecomeActive() {
        // Sync UI upon returning to the foreground
        pushNowPlaying()
        if let a = lastAdvanced {
            notifyListeners("youtubeAdvanced", data: ["index": a.index, "videoId": a.videoId])
        }
        notifyListeners("youtubeStateChange", data: ["state": intendedPlaybackState])
    }

    @objc func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.avPlayer?.pause()
            } else if type == .ended {
                let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) && self.intendedPlaybackState == "playing" {
                    self.performPlay()
                }
            }
        }
    }

    @objc func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                // Pause when headphones are unplugged
                self.performPause()
            }
        }
    }
}
