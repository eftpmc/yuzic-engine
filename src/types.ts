/**
 * The vocabulary the engine and its host agree on.
 *
 * Deliberately not modelled on any existing React Native player: those all
 * describe a queue player, and this is a graph. The differences that matter
 * show up here — `continuous`, `replayGainDb`, and the fact that a track
 * carries its own request headers.
 */

/** Stable identity for a track, chosen by the host. Opaque to the engine. */
export type MediaId = string;

export interface Track {
  id: MediaId;
  /**
   * `file://` for something already on disk, `http(s)://` for anything else.
   * A remote URI is fetched into the cache and played from there — see
   * docs/architecture.md; the graph plays files, never sockets.
   */
  uri: string;
  title: string;
  artist?: string;
  album?: string;
  /** Shown on the lock screen and in the car. Remote or local. */
  artworkUri?: string;
  /**
   * Seconds, when the host already knows it. The engine will discover the real
   * duration on decode; this is what the lock screen shows before then, and
   * what a progress bar can size itself against without waiting.
   */
  durationSec?: number;
  /**
   * Sent with the fetch. Some servers authenticate a stream by header rather
   * than by signing the URL, and a player that can only take a URL forces
   * those into query strings, where they end up in logs.
   */
  headers?: Record<string, string>;
  /**
   * Track loudness in dB relative to reference, from the server's tags. Applied
   * as gain when replay gain is on. Absent means "no information" — which is
   * not the same as 0, and the engine treats it as such.
   */
  replayGainDb?: number;
  /**
   * A stream with no meaningful end: live radio, and anything else where the
   * next track is not a thing that exists. Suppresses crossfade, gapless
   * preparation and end-of-track prediction — all three assume a finish line.
   */
  continuous?: boolean;
}

export type RepeatMode = 'off' | 'one' | 'all';

/**
 * What the engine is doing. `buffering` is distinct from `paused` because the
 * UI should say different things: one is waiting on the network, the other is
 * waiting on the user.
 */
export type PlaybackState =
  | 'idle'
  | 'buffering'
  | 'playing'
  | 'paused'
  | 'ended'
  | 'error';

export interface Progress {
  positionSec: number;
  /** 0 until the decoder knows, and for anything `continuous`. */
  durationSec: number;
  /** How far ahead the cache holds contiguous audio from the current position. */
  bufferedSec: number;
}

/**
 * Crossfade is off by default, and off for `continuous` tracks whatever this
 * says. `gapless` means: overlap only where the tracks were mastered to run
 * together, and hard-cut otherwise — a crossfade across a deliberate album
 * segue sounds worse than the seam it is hiding.
 */
export interface CrossfadeOptions {
  durationSec: number;
  mode: 'always' | 'gapless-aware';
  /**
   * Skip the fade when the user skipped manually. A crossfade is for a track
   * that ended; a skip should feel immediate.
   */
  skipIsImmediate?: boolean;
}

/** One band of the equalizer. Frequencies in Hz, gain in dB. */
export interface EqBand {
  frequencyHz: number;
  gainDb: number;
  /** Bandwidth in octaves. Defaults to a sensible value per band. */
  q?: number;
}

export type ReplayGainMode = 'off' | 'track' | 'album';

export interface CacheOptions {
  maxBytes: number;
  /**
   * How many upcoming tracks to fetch ahead. Preloading is what makes gapless
   * and crossfade possible at all — you cannot overlap into a track you have
   * not started fetching.
   */
  preloadCount: number;
}

export interface CacheStats {
  usedBytes: number;
  maxBytes: number;
  entryCount: number;
}

/** A node in the CarPlay / Android Auto browse tree. */
export interface BrowseNode {
  id: string;
  title: string;
  subtitle?: string;
  artworkUri?: string;
  /** Present for a branch; absent or empty for a leaf that plays. */
  children?: BrowseNode[];
  /** For a leaf: what to play. */
  playable?: Track;
}

export type EngineEvent =
  | { type: 'stateChange'; state: PlaybackState }
  | { type: 'trackChange'; index: number; id: MediaId | null }
  | { type: 'progress'; progress: Progress }
  | { type: 'queueChange' }
  | { type: 'error'; code: string; message: string; id?: MediaId }
  /**
   * A remote command the engine could not handle alone — the car asked for
   * something from the browse tree, say. The host answers by driving the
   * ordinary API.
   */
  | { type: 'remoteCommand'; command: string; payload?: unknown };
