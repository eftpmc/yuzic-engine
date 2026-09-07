import type {
  BrowseNode,
  CacheOptions,
  CacheStats,
  CrossfadeOptions,
  EngineEvent,
  EqBand,
  MediaId,
  PlaybackState,
  Progress,
  RepeatMode,
  ReplayGainOptions,
  SampleRateMode,
  Track,
} from './types';

/**
 * The whole surface.
 *
 * Two rules shaped this, and both are worth stating before the methods:
 *
 * **The queue lives natively.** Not here. When the app is backgrounded, its
 * JavaScript is suspended — but the lock screen still has to advance to the
 * next track, the car still has to answer a steering-wheel button, and the
 * now-playing info still has to update. Anything that needs JS awake to happen
 * will eventually not happen. So the host hands over a whole queue and issues
 * commands against it; it never drives track-by-track.
 *
 * **Playback is a graph, not a player.** Crossfade is two source nodes
 * overlapping into a mixer, and an equalizer is a node in the chain. Neither is
 * expressible against a single-output queue player, which is the wall every
 * existing React Native player runs into. That choice is what `setCrossfade`
 * and `setEqualizer` below rest on, and it is why remote audio is fetched to
 * disk first — see docs/architecture.md.
 */
export interface AudioEngine {
  // ── lifecycle ────────────────────────────────────────────────────────────

  /**
   * Claim the audio session and start the playback service. Idempotent; a
   * second call with different options reconfigures rather than restarting,
   * because tearing the session down mid-playback is audible.
   */
  setup(options?: EngineSetupOptions): Promise<void>;

  /** Release the session and stop the service. */
  teardown(): Promise<void>;

  // ── queue ────────────────────────────────────────────────────────────────

  /** Replace the queue. `startIndex` becomes current; playback does not start. */
  setQueue(tracks: Track[], startIndex?: number): Promise<void>;
  append(tracks: Track[]): Promise<void>;
  /** Insert before `index`. */
  insertAt(index: number, tracks: Track[]): Promise<void>;
  removeAt(index: number): Promise<void>;
  move(fromIndex: number, toIndex: number): Promise<void>;
  clearQueue(): Promise<void>;

  getQueue(): Promise<Track[]>;
  getActiveIndex(): Promise<number>;

  // ── transport ────────────────────────────────────────────────────────────

  play(): Promise<void>;
  pause(): Promise<void>;
  /** Stops and releases the current source; the queue survives. */
  stop(): Promise<void>;
  seekTo(positionSec: number): Promise<void>;
  skipToNext(): Promise<void>;
  skipToPrevious(): Promise<void>;
  skipToIndex(index: number): Promise<void>;

  setVolume(volume: number): Promise<void>;
  setSpeed(speed: number): Promise<void>;
  setRepeatMode(mode: RepeatMode): Promise<void>;

  getState(): Promise<PlaybackState>;
  getProgress(): Promise<Progress>;

  // ── the reasons this exists ──────────────────────────────────────────────

  /** Pass `null` to turn crossfade off. */
  setCrossfade(options: CrossfadeOptions | null): Promise<void>;

  /**
   * Replace the equalizer curve. An empty array is flat — which is not the
   * same as bypassed, and the engine bypasses the node entirely when flat so
   * an untouched EQ costs nothing.
   */
  setEqualizer(bands: EqBand[]): Promise<void>;

  /**
   * Needs `replayGainDb` on the tracks — the engine reads tags and never
   * computes loudness itself, because computing it means decoding a whole
   * track before it can play.
   */
  setReplayGain(options: ReplayGainOptions): Promise<void>;

  /**
   * Turning this to `match-source` disables crossfade, because overlapping
   * sources have to share a sample rate. The engine reports the change rather
   * than letting the two settings silently contradict each other.
   */
  setSampleRateMode(mode: SampleRateMode): Promise<void>;

  // ── cache ────────────────────────────────────────────────────────────────
  //
  // Implemented on iOS. Audio is kept on disk between tracks and between
  // launches, keyed by `MediaId` rather than by URL — stream URLs carry tokens
  // that rotate, so a URL key would miss every session and fill the cache with
  // duplicates of one album.
  //
  // Entries are sparse: a track played halfway is kept halfway, and a later
  // play resumes from whatever arrived rather than starting again. Eviction is
  // least-recently-used and takes whole entries, because a track with its
  // middle dropped still costs a request per gap.
  //
  // Only directly-streamed audio is cached. A transcoded stream is generated
  // per request and its bytes are not the file, so two plays at different
  // bitrates would be different audio under one id.
  //
  // NOT IMPLEMENTED on Android, where Media3 keeps its own cache — these four
  // are no-ops there until that is joined up.

  configureCache(options: CacheOptions): Promise<void>;
  clearCache(): Promise<void>;
  cacheStats(): Promise<CacheStats>;
  /** Drop one track's cached audio — used when a download is deleted. */
  evict(id: MediaId): Promise<void>;

  // ── platform surfaces ────────────────────────────────────────────────────

  /**
   * The tree CarPlay and Android Auto browse. Handed over whole for the same
   * reason as the queue: the car may ask while JS is asleep.
   */
  setBrowseTree(root: BrowseNode): Promise<void>;
  /** Which remote controls to advertise on the lock screen and in the car. */
  setCommands(commands: RemoteCommand[]): Promise<void>;

  // ── sleep timer ──────────────────────────────────────────────────────────

  /** Fades out and pauses after `seconds`. Native so it survives suspension. */
  sleepAfter(seconds: number): Promise<void>;
  cancelSleep(): Promise<void>;

  // ── events ───────────────────────────────────────────────────────────────

  addListener(listener: (event: EngineEvent) => void): () => void;
}

export interface EngineSetupOptions {
  cache?: CacheOptions;
  /**
   * How often to emit `progress`. The host usually wants ~1Hz for a progress
   * bar; scrubbing wants more. Emitting is cheap, re-rendering is not, so the
   * rate is the host's call.
   */
  progressIntervalMs?: number;
  /** Pause when headphones are unplugged, rather than playing out loud. */
  pauseOnBecomingNoisy?: boolean;
  android?: {
    notificationChannelId: string;
    notificationChannelName: string;
    smallIconResourceName?: string;
  };
}

export type RemoteCommand =
  | 'playPause'
  | 'next'
  | 'previous'
  | 'seek'
  | 'skipForward'
  | 'skipBackward'
  | 'stop';
