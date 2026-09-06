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

## Decided

Reasoning for each is in [docs/architecture.md](docs/architecture.md).

- **Licence: Apache-2.0.** Permissive, patent grant, same as react-native-track-
  player v4. yuzic consumes it under GPL-3 without friction, and it does not
  impose on anyone else the kind of restriction this project exists to escape.
- **A graph, not a queue player.** Crossfade and a real equalizer are not
  expressible against a single-output player; that is the wall every existing
  RN player hits.
- **Remote audio is fetched to disk and played from there.** The graph plays
  files, and yuzic already caches everything to disk, so streaming and caching
  become one path instead of two.
- **The queue lives natively.** Backgrounded JS gets suspended; the lock screen
  and the car must keep working anyway.
- **`MPNowPlayingInfoCenter.playbackState` is set explicitly.** Taken straight
  from the bug that made CarPlay show "paused" while audio played.

## Still open

- **Bridge**: Nitro (already a yuzic dependency) vs the Expo Modules API
  (better config-plugin ergonomics, and the plugin work is needed either way).
  Leaning Nitro.
- **Gapless detection**: encoder delay/padding metadata, or the host's word.
- **Hi-res**: switch the graph's sample rate to match the source, or resample.
  Constrains the mixer, so it wants deciding before the mixer is built.
- **The iOS cache is the biggest unknown** and deserves a spike before the rest
  of the iOS work: `AVAssetResourceLoader` with manual range handling, a local
  proxy, or a plain ranged fetcher of our own. Android gets this close to free
  from Media3.
