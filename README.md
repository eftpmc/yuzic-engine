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

- **Gapless detection**: encoder delay/padding metadata, or the host's word.
- **Android has never run.** It compiles — it did not before, and the three
  errors were the kind only a compiler finds. Both platforms now declare the
  same twenty-four functions, checked by comparing the two modules rather than
  by reading them, because the module's own header calls a divergence here the
  worst kind of bug to find.

  Compiling is the whole of the evidence. There is no Kotlin test target and
  nothing has been on a device or an emulator, so every behaviour below the
  type checker is unverified — including three things that were wrong on
  inspection and may have company: every player call was being made from Expo's
  background dispatcher, which ExoPlayer rejects outright; the queue's active
  index did not follow the player's; and replay gain had no channel to be
  applied through.

  The next real gate is not more surface, it is **events**. `onProgress`,
  `onStateChange` and `onTrackChange` are declared and nothing emits them —
  only `onRemoteCommand` is wired. A host on Android can ask where it is but
  will never be told.
- ~~**Seek cost, measured.**~~ Answered: **333ms** to first sample seeking from
  4.4s to 151.4s with only 11.1s buffered, against a real Navidrome over the
  open internet. A seek far outside the fetched region costs about a round trip,
  not a rebuffer. See §2 and open question 3.

## Settled by building

These were open questions in the first draft of this file. Each was answered by
writing the thing and running it, not by deciding harder — the reasoning is in
[docs/architecture.md](docs/architecture.md).

- **Bridge: Expo Modules.** The config-plugin ergonomics turned out to be the
  whole argument; see `app.plugin.js`, which is doing more than expected.
- **The cache: a ranged fetcher of our own.** `AVAssetResourceLoader` was the
  obvious candidate and the spike killed it. `spikes/ios-reader/` has the
  measurements, including the one that mattered: a 90% seek into a FLAC pulls
  177% of the file, because libFLAC's seek is architecturally a scan.
- **Hi-res: the host chooses, and the engine enforces.** `setSampleRateMode`
  turns crossfade off when set to `match-source` and says so, because
  overlapping sources have to share a hardware rate. Two settings that silently
  contradict each other would have been the worse answer.

## CarPlay

The engine draws the car's screen from a tree the host pushes down in advance,
because the car asks while the app's JavaScript is asleep. `setBrowseTree` takes
an ordinary nested tree; selection is resolved and played natively, and the host
finds out through the usual track-change event.

Two things the config plugin cannot do for you:

1. **The `com.apple.developer.carplay-audio` entitlement is granted by Apple,
   per app**, on request. Until it is, none of this appears in a car — and
   nothing logs to say why. The plugin deliberately does not fabricate the
   entitlement, because that trades a clear message for a signing failure.
2. **yuzic commits its `ios/` directory**, so the plugin's Info.plist changes
   only land on a prebuild.

To try it without a car: Xcode's Simulator has **I/O → External Displays →
CarPlay**, which needs the entitlement the same way a real head unit does.
