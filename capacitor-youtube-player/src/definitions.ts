import type { PluginListenerHandle } from '@capacitor/core';

export interface YouTubeCapacitorPlugin {
  load(options: { videoId: string }): Promise<void>;
  /**
   * Native audio-stream playback (works in the background + on the lock screen).
   * Resolves { ok: false } when the stream could not be fetched, and the page should
   * fall back to `load()` (embedded web player).
   */
  loadStream(options: { videoId: string }): Promise<{ ok: boolean }>;
  /**
   * Point stream extraction at your own endpoint. The URL is called with the video id
   * (appended as `id=`, or substituted for a `{id}` placeholder) and must answer with
   * JSON containing the audio URL under `url`, `audio`, `stream.url` or `data.url`.
   * Pass an empty string to go back to the built-in extraction.
   */
  setStreamEndpoint(options: { url: string }): Promise<void>;
  play(): Promise<void>;
  pause(): Promise<void>;
  /** Play/pause decided by the native state; resolves with the new state. */
  toggle(): Promise<{ playing: boolean }>;
  /**
   * Playback state as the native player sees it. Used when the app returns to the
   * foreground, since the lock screen / Control Center may have changed it meanwhile.
   */
  getState(): Promise<{ playing: boolean; currentTime: number; duration: number; state: string }>;
  stop(): Promise<void>;
  seekTo(options: { seconds: number }): Promise<void>;
  setVolume(options: { volume: number }): Promise<void>;
  setUpNext(options: { items: Array<{ videoId: string; index: number; title: string; artist: string; duration: number; artworkUrl?: string }>; repeatOne: boolean }): Promise<void>;
  setTheme(options: { theme: 'dark' | 'light' | 'system' }): Promise<void>;
  setNowPlaying(options: { title: string; artist: string; duration: number; artworkUrl?: string; local?: boolean }): Promise<void>;

  addListener(
    eventName: 'youtubeStateChange',
    listenerFunc: (state: { state: string }) => void,
  ): Promise<PluginListenerHandle>;

  addListener(
    eventName: 'youtubeTimeUpdate',
    listenerFunc: (state: { currentTime: number, duration: number, videoId?: string }) => void,
  ): Promise<PluginListenerHandle>;
}
