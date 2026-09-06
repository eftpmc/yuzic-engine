# yuzic-engine

Audio playback engine for [yuzic](https://github.com/eftpmc/yuzic). React Native,
written from scratch.

## Why this exists

Not primarily a licensing exercise. Two reasons, in order:

1. **Control.** yuzic already carries a ~389-line patch against its current
   player — deleting an Android Cast integration it doesn't want, fixing an iOS
   now-playing state bug that made CarPlay show "paused" on first play. That is
   maintaining a fork without any of the benefits of owning one.
2. **Features the existing React Native players don't expose.** Crossfade needs
   two players overlapping with volume ramps; every RN track player presents a
   single player with no seam to reach through. Same story for real DSP — an
   equalizer that actually processes audio needs an audio graph, not a
   play-this-URL API.

Licence independence is a consequence, not the goal: yuzic is GPL-3.0 and its
current player went proprietary at v5, which is a real problem, but it isn't
what this is for.

## Hard rule: no v5

`@rntp/player` v5 is proprietary and its licence carries a non-competition
clause — it may not be used, in whole or in part, to build something that
competes directly with react-native-track-player. An RN audio engine competes
directly.

- **Do not** read, copy, port, or consult `@rntp/player` v5 source while working
  on this.
- react-native-track-player **v4 and earlier is Apache-2.0**, and that grant is
  perpetual for the code published under it. Referencing or lifting from v4 is
  legally clean, with attribution and a NOTICE. We are choosing not to fork it
  because it is old — but it stays available as a legitimate reference for
  platform edge cases.
- Anything lifted from v4 gets attributed in NOTICE, and the change stated.

## What it has to do

Taken from what yuzic actually calls today, not from a wishlist.

**Queue** — set a whole queue; add, insert, remove, move items; skip to index /
next; read the queue, the active item and its index.

**Transport** — play, pause, stop, seek, volume, playback speed, repeat mode
(off / one / all).

**Progress** — position, duration and buffered, read both by subscription
(~1Hz) and imperatively.

**Events** — track transition, playback state change, playback error.

**Platform integration**
- Background playback with lock-screen / notification controls and artwork.
- `MPNowPlayingInfoCenter.playbackState` settable explicitly. The current
  player's failure to do this is the CarPlay "paused on first play" bug.
- CarPlay: a browsable tree and a configurable command set.
- Android Auto equivalent.
- Audio focus, interruptions, route changes, becoming-noisy.

**Sources**
- Local files (`file://`) for offline downloads.
- HTTP streaming where the URL carries auth in query params or headers.
- An on-device LRU cache, currently 1GB with a 2-item preload window, that can
  be cleared on demand.

**Sleep timer** — stop after a duration, cancellable.

## What it should do that today's players can't

- **Crossfade** between tracks.
- **DSP**: a working equalizer, replay gain / normalisation.
- Whatever the audio-graph architecture makes cheap once it exists.

## Open decisions

- **Licence for this repo.** Not yet chosen. Permissive (Apache-2.0, matching
  RNTP v4, patent grant included) keeps it usable by yuzic under GPL-3 and by
  anyone else; copyleft would restrict adoption. Deliberately left unset until
  decided — an unlicensed repo is all-rights-reserved, which is fine while
  private.
- **Architecture**: queue-player wrapper vs full audio graph. If crossfade and
  DSP are both in scope, it's a graph — AVAudioEngine on iOS, ExoPlayer audio
  processors on Android — and that decision wants making before any code.
- **Native module layer**: yuzic already depends on `react-native-nitro-modules`.
- **The iOS cache** is the biggest unknown. Android gets it close to free from
  Media3's `SimpleCache`/`CacheDataSource`; iOS has no equivalent and means
  either `AVAssetResourceLoader` with manual range handling or a local proxy.
  Worth a spike before committing to a design.
