# Architecture

Four decisions, taken before any native code was written, each with the reason
it went that way. Anything that contradicts one of these is either a mistake or
a decision to revisit here first.

## 1. A graph, not a queue player

Every React Native audio library wraps a queue player — `AVQueuePlayer` on iOS,
ExoPlayer used as a whole on Android. You get URL playback, buffering and
platform integration nearly free, and you get exactly one output with nowhere
to insert anything. That is a fine trade until you want two of the things yuzic
wants:

- **Crossfade** is two sources overlapping with volume ramps. One output cannot
  overlap with itself.
- **A working equalizer** needs a processing stage between decode and output.
  yuzic has shipped an equalizer *interface* for a while with nothing behind it,
  because there was nowhere to put it.

So: `AVAudioEngine` on iOS, with `AVAudioPlayerNode`s into an `AVAudioMixerNode`
and `AVAudioUnitEQ` in the chain. Media3 on Android, with custom
`AudioProcessor`s and a second player instance for the overlap.

The cost is real and lands almost entirely on iOS — see §2.

## 2. The graph plays files, so remote audio is fetched to disk first

`AVAudioEngine` plays buffers and files. It does not play URLs. That is the bill
for §1, and the obvious response — "then we need a whole streaming stack" —
overstates it, because **yuzic already caches everything to disk**: a 1GB LRU
with a two-track preload window.

Once audio is landing on disk anyway, "stream it" and "cache it" stop being two
problems. The engine fetches to the cache and plays from the cache, for local
and remote alike. One path, and the buffering policy is ours: how much before
we start, how far ahead we read, what a seek past the buffer does.

What this genuinely costs:

- Range requests, so a seek past the fetched region doesn't wait for the whole
  file.
- A start threshold — begin playing at N seconds buffered, not at complete.
- Care with long content. A three-hour DJ set must not have to land entirely
  before it plays.

Android could have kept the simpler road here: Media3's `SimpleCache` and
`CacheDataSource` do this already and well. It uses the same fetch-to-cache path
anyway, because two caching models would mean two sets of behaviour to reason
about, and the offline-downloads store has to interoperate with exactly one.

**This is the biggest unknown in the project.** It deserves a spike before the
rest of the iOS work.

## 3. The queue lives natively

The host hands over a whole queue and issues commands against it. It never
drives playback track by track.

This is not a style preference. Backgrounded apps have their JavaScript
suspended, and the things that must keep working while it is suspended are
exactly the ones users notice: advancing to the next track, updating the lock
screen, answering a steering-wheel button, keeping the now-playing info honest
for CarPlay. Anything that needs JS awake will eventually not happen, usually in
a car.

The same reasoning applies to the browse tree (§`setBrowseTree`) and the sleep
timer: the car can ask, and the timer can fire, while nothing of ours is running
in JS.

## 4. Explicit now-playing state

`MPNowPlayingInfoCenter.playbackState` is set explicitly on every transition,
not inferred and not left to the framework.

This is the one decision taken directly from a bug. yuzic's current player left
it implicit, and CarPlay showed "paused" while audio was playing on the first
track of a session — fixed downstream by patching the library. An engine that
owns the session should never need that patch to exist.

## What is not decided yet

- **Bridge**: Nitro (already a yuzic dependency, cleaner JSI path for progress)
  versus the Expo Modules API (better ergonomics for the config-plugin work
  that background modes, entitlements and the Android service need regardless).
  Leaning Nitro; the config plugin is separate work either way.
- **Gapless**: whether to detect mastered-to-run-together tracks from encoder
  delay/padding metadata, or to take the host's word for it via a flag.
- **Hi-res**: whether the graph switches sample rate to match the source or
  resamples to a fixed rate. Matters to exactly the audience that self-hosts
  FLAC, and it constrains the graph, so it wants deciding before the mixer is
  built rather than after.
