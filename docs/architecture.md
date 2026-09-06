# Architecture

Eight decisions, taken before the native code went in, each with the reason it
went that way. Anything that contradicts one of these is either a mistake or
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

## 5. Expo Modules, not Nitro

The perf argument for Nitro does not apply here: **nothing high-frequency
crosses this bridge.** Audio never does — it goes disk → decoder → graph →
output, entirely native. Commands are user-initiated and rare. Progress is
emitted about once a second.

What *is* large is the integration surface: background audio mode, the CarPlay
entitlement and scene delegate, the Android foreground service, the
notification channel, the Android Auto declaration. That is config-plugin work,
and the Expo Modules API is markedly better at it. yuzic is an Expo app with a
dev client already.

The cost: consumers pull in `expo-modules-core`. Acceptable, because this is
for yuzic. If it were aimed at broad adoption the answer would flip to Nitro or
plain Turbo Modules — worth revisiting only if that goal changes.

## 6. Crossfade rules are the engine's, not the host's

Four behaviours are fixed in `PlaybackQueue.transitionDuration` rather than
exposed as settings, because each one is a bug and not a preference when it
goes the other way:

- **A `continuous` track never fades.** Live radio has no known finish line to
  start a fade before.
- **`followsPrevious` hard-cuts.** A track mastered to run out of the one
  before it — an album segue, a continuous mix — sounds worse crossfaded than
  joined, because the overlap doubles. The host supplies this flag; it already
  knows album and track numbers, which beats digging encoder delay and padding
  out of LAME tags or `iTunSMPB`.
- **A manual skip is immediate.** A fade is for a track that ended. Eight
  seconds of politeness after pressing next reads as lag.
- **The fade is clamped to half the shorter track.**

And one that is not about sound at all: **the faded-out portion counts toward
the outgoing track's listened time**, reported as `previousListenedSec` on
`trackChange`. Without it, position never approaches duration, and a host
scrobbling at "half the track or four minutes" silently stops scrobbling
anything once a long crossfade is switched on. `trackChange` fires at the
crossover midpoint so it lines up with what is actually being heard.

## 7. Replay gain comes from tags, and respects peak

Computing loudness on device means decoding a whole track before it can play:
bad on battery, impossible on first listen. Both of yuzic's backends already
carry the figures — Navidrome through the OpenSubsonic extension, Jellyfin as
normalization gain — so the engine reads tags and never measures.

Two details that get missed and make normalisation sound worse than none:

- **Peak-aware clamping.** Positive gain on a hot master clips. Total gain is
  held below full scale using `replayGainPeak`. Quieter than asked for beats
  distorted.
- **Untagged tracks are their own case.** `replayGainDb` absent means "no
  information", which is not 0 dB. A library where half the tracks are adjusted
  and half are not sounds *more* uneven than one where none are, so untagged
  material gets its own configurable pre-amp.

`auto` mode picks album for a queue that is one album — keeping the interlude
that is meant to be quiet quiet — and track otherwise. Most players make this
one global choice and are therefore wrong half the time.

## 8. Fixed sample rate by default, and it excludes crossfade

The graph runs at 48kHz and converts into it: that is what iOS hardware most
often runs natively, so the common case is a no-op rather than a resample.

`match-source` reconfigures the session per track for true bit-perfect output.
It is not a free upgrade, because of a structural collision worth stating
plainly:

> Overlapping sources must share a sample rate, and changing the session rate
> requires stopping the engine. **Matching the source and crossfading are
> mutually exclusive.**

The engine enforces that rather than letting two settings quietly contradict
each other: turning on `match-source` clears crossfade and emits an error event
saying so. Also worth knowing before choosing it — iOS hardware commonly runs
at 48kHz and Bluetooth imposes its own rate regardless, so bit-perfect only
means anything over wired output or a USB DAC.

## What is not decided yet

- **The iOS cache.** The one genuinely open question, and the biggest risk in
  the project: how remote audio gets to disk such that playback can start
  before the file is complete and a seek past the fetched region works.
  Candidates are an `AVAssetResourceLoader` delegate, a local HTTP proxy, or a
  plain ranged fetcher of our own feeding `AVAudioFile`. Under research; the
  graph work above does not depend on the answer.
- **Whether `AVAudioFile` tolerates a file still being appended to**, which
  decides whether the fetcher can be as simple as "write and read behind".
- **Native decoding coverage** — FLAC and Opus in particular — and whether a
  third-party decoder is needed for any format yuzic's users actually hold.
