# Architecture

Ten decisions, each with the reason it went that way. The later ones came out
of measurement rather than design, which is why they read differently. Anything that contradicts one of these is either a mistake or
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

### Not `AVAudioFile` — a random-access byte provider

The obvious reading of "plays files" is `AVAudioFile`, and that does not work
on a file still being written. Two blockers, both in its own header:

- `length` is computed once at open and never re-derived, so a partial file
  reports a partial length and `scheduleSegment` honours it and stops early.
- Reading past the current end is a **short read, not an error** — you get
  `frameLength == 0`, indistinguishable from real end-of-file. There is no
  "would block" signal, so the only recovery is closing and reopening on every
  underrun, re-paying the parse each time.

So the reader is the callback-based Core Audio file layer instead:

```
sparse disk cache + ranged URLSession
        ↓  AudioFile_ReadProc / AudioFile_GetSizeProc  (blocking, own thread)
AudioFileOpenWithCallbacks
        ↓  ExtAudioFileWrapAudioFileID
ExtAudioFileSeek / ExtAudioFileRead → AVAudioPCMBuffer
        ↓  scheduleBuffer
AVAudioPlayerNode → EQ → mixer → output
```

`AudioFile_ReadProc` is random-access — it is handed an offset, not a cursor —
and `GetSizeProc` answers with the full size from `Content-Length`. So the
parser believes the file is whole from the first frame, and **a seek past the
fetched region stops being a special case**: Core Audio asks for bytes at the
target, the read proc issues a ranged GET and blocks until they land. Identical
code path to a local file.

The read proc has no async form, so all reads run on a dedicated producer
thread keeping a few seconds of PCM queued ahead. A stalled network read then
costs buffer-ahead, not a dropout — provided seeking can abandon an in-flight
blocking read promptly, which is the part to get right.

What this genuinely costs:

- Range requests, so a seek past the fetched region doesn't wait for the whole
  file.
- A start threshold — begin playing at N seconds buffered, not at complete.
- Care with long content. A three-hour DJ set must not have to land entirely
  before it plays.
- **Non-faststart M4A**: when `moov` sits at the tail, the parser's first read
  is near the end of the file. Confirmed by the spike — with only the first 30%
  of an ALAC file present, **the open fails outright**, two of its first ten
  reads being past the fetched region. WAV and FLAC in the same test open
  cleanly and report the correct full duration.

  So the cache **fetches the tail before the head for MP4-family files** —
  roughly the last 64KB. Cheap, because the read proc is random-access already:
  a prefetch heuristic, not a redesign. But it must not be forgotten, or ALAC
  and AAC will refuse to start until the whole file has landed.

Android could have kept the simpler road here: Media3's `SimpleCache` and
`CacheDataSource` do this already and well. It uses the same fetch-to-cache path
anyway, because two caching models would mean two sets of behaviour to reason
about, and the offline-downloads store has to interoperate with exactly one.

Rejected on the way here: an `AVAssetResourceLoader` delegate (it feeds
`AVPlayer`, and there is no supported route from an `AVURLAsset` to a player
node), and a local HTTP proxy (adds a socket, a background-execution liability
and a port-collision surface, in exchange for nothing the read proc doesn't
give free).

Prior art worth reading before writing any of this: **SFBAudioEngine** (MIT,
so both readable and usable) drives an `AVAudioEngine` graph with its own
decoders and does gapless already.

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

**Correction to an earlier version of this document.** It claimed overlapping
sources must share a sample rate. That is wrong: Apple's own guidance is to
connect each player node to the mixer *at its own track's rate* and let
`AVAudioMixerNode` do the conversion — it sums once and converts once, which is
cheaper than converting per node. So crossfading 44.1kHz into 96kHz is fine.

The real collision is with the **hardware** rate. `setPreferredSampleRate` is
what bit-perfect output requires, and changing it fires
`AVAudioEngineConfigurationChangeNotification`, which stops the engine and
clears every scheduled buffer. Mid-fade that is a guaranteed audible break.

> **Matching the hardware rate to the source can only happen at a track start
> with nothing fading.** It is not compatible with a crossfade in progress.

So `match-source` still clears crossfade and says so, but for the accurate
reason. Two consequences for the graph:

- A connection's format cannot be changed while the engine runs, so the pool of
  player nodes is reconnected at the incoming track's rate during the *preload*
  window — never the node that is currently playing.
- The mixer's conversion quality is not adjustable. If mixer SRC disappoints on
  96→48, convert at decode time with `AVAudioConverter`, which does expose
  quality, algorithm and dither.

Register for the configuration-change notification regardless and rebuild from
the current decode position: it fires on every AirPods, CarPlay and dock
transition, not only on rate changes of our own making.

Also worth knowing before choosing it — iOS hardware commonly runs at 48kHz and
Bluetooth imposes its own rate regardless, so bit-perfect only means anything
over wired output or a USB DAC.

## 9. Core Audio does not cover the formats, and its FLAC seeking is broken

Two findings that change what has to be built, both from the research spike.

**Ogg has no Core Audio container.** FLAC and Opus decode natively from iOS 11
(`kAudioFormatFLAC`, `kAudioFormatOpus`), and raw `.flac` opens fine. But the
`AudioFileTypeID` list has no Ogg member, so **Opus-in-Ogg — which is what a
`.opus` file off a Subsonic server is — will not open at all**, and Ogg Vorbis
is unsupported at any version. Those need bundled decoders (libogg, libvorbis,
libopus) and a second, parallel code path. Budget for it rather than finding it
late.

> **Status: half built, and the prediction held exactly.** It was found late
> anyway — by a listener, as one album of a real library showing "Unable to
> play track" while everything around it played.
>
> `TrackReader` is the parallel path, and `VorbisFileReader` is the first
> thing on it: libogg and libvorbis are vendored under `ios/Vendor` and the
> factory picks a decoder by reading the codec name out of the first Ogg page.
> Not by extension — a stream URL has none — and not by container either,
> since Opus and FLAC also live in Ogg behind the same `OggS`.
>
> **Opus is still not decoded.** A `.opus` file is transcoded by the server
> instead, which works and is not what Original quality is for. libopus is the
> same shape of job as libvorbis was, now that the seam and the two-build-system
> vendoring both exist.

**Apple's FLAC and MP3 decoders ignore the seek structures in the file.** They
decode from byte zero instead of using FLAC's `SEEKTABLE` or MP3's Xing/LAME
TOC, so seek cost is linear in distance. Measured on a 75-minute file, seeking
to the midpoint:

| format | local | over network |
| --- | --- | --- |
| WAV | 0.0005 s | 0.007 s |
| ALAC | 0.0011 s | 0.015 s |
| MP3 | 0.196 s | 9.2 s |
| **FLAC** | **0.753 s** | **30.2 s** |

`FLAC__stream_decoder_seek_absolute()` does the same seek in ~0.015 s. For a
self-hosted FLAC library — which is exactly yuzic's audience — that is the
difference between a working scrubber and an unusable one, and it applies to
any design sitting on Apple's decoder.

The mitigation is the same bundled libFLAC that Ogg support already argues for,
leaving Core Audio to handle MP3, AAC/M4A, ALAC and WAV.

**Reproduced, and it is worse than slow seeking.** The spike in
[`spikes/ios-reader`](../spikes/ios-reader) measured this on macOS 26 with a
20-minute file. Seek cost is linear in distance, as reported — but the useful
measurement was not time, it was *which bytes the decoder asks for*:

| format | bytes requested to play from 90% in | range touched |
| --- | --- | --- |
| WAV | 16 KB | 186050–186066 KB |
| **FLAC** | **279,985 KB — 177% of the file** | **13–142,331 KB** |
| ALAC | 36 KB | 143151–143188 KB |

Apple's FLAC decoder reads from the start of the file to the seek point, some
regions more than once. **So random access buys nothing for FLAC.** Over a
network, seeking near the end of a track would fetch the whole track first.
This is not a performance footnote — it defeats the ranged-fetch design in §2
outright, for the format this app's audience mostly holds.

libFLAC is therefore **architectural, not an optimisation**. Core Audio keeps
MP3, AAC/M4A, ALAC and WAV, where seeking is targeted.

Still unconfirmed on an iOS device: the frameworks are shared and the original
report was also macOS, but nobody has run it on the phone yet.

## 10. Transcoded streams are a second transport, not a variation

Measured, not assumed — see `spikes/ios-reader`. Against a real Navidrome, a
direct stream answers `206` with `accept-ranges: bytes` and a full
`content-range`. The same track requested with `maxBitRate` and `format`
answers `200`, `accept-ranges: none`, **and no content-length at all**, because
the server is producing bytes as it sends them.

Everything in §2 rests on two things a transcoded stream refuses to provide: a
known total size, and random access. `GetSizeProc` has nothing truthful to
answer, and an offset does not address a stable resource.

Subsonic's own seek mechanism for this case is `timeOffset` — re-request the
stream starting *n* seconds in, confirmed working on the demo server. That is a
fresh byte stream per seek, not a window into one file.

So there are two transports:

| | direct | transcoded |
| --- | --- | --- |
| ranges | yes | no, explicitly refused |
| length up front | yes | no |
| seeking | byte range | re-request with `timeOffset` |

**And the app chooses between them without meaning to.** yuzic sends
`format`/`maxBitRate` for every quality except Original, and that setting is
per-network — so the same track is randomly accessible on WiFi at Original and
forward-only on cellular at 192kbps. Neither the reader nor the cache may
assume which one it has.

What this does not change: the callback reader, the cache, the range
bookkeeping, and everything the spike proved are all still right for the direct
path, which is the one that carries lossless playback and offline downloads.

What it adds, now built as `StreamingByteSource`:

- **Length-unknown, append-only.** Every byte that arrives is kept, so seeking
  backwards or anywhere already received is ordinary random access; only a read
  ahead of the write head waits, which is the normal case for a reader running
  slightly ahead of a download.
- **`GetSizeProc` answers an estimate** until the stream ends, then the true
  size. It has to answer *something* — the parser asks before any bytes arrive.
  `duration × bitrate` is what the host knows. Erring high is deliberate:
  reading past the real end returns nothing, which the parser treats as
  end-of-file, whereas under-reporting truncates the track.
- **A forward seek past the write head is a reconnection, not a read.**
  `streamURL(base:timeOffsetSeconds:)` builds the new request; the layer above
  replaces the source and reopens the reader, because the new stream's byte
  offsets have nothing to do with the old one's. Deliberately not smuggled into
  the source, which would make a seek look cheap when it costs a round trip and
  a rebuffer.

That last cost is accepted rather than hidden. Someone who set a bitrate cap
chose it, and a slower seek is the honest consequence — better than quietly
pulling the lossless original over cellular to make seeking feel nicer.

**Measured since: the cost is smaller than this paragraph assumes.** 333ms to
first sample on the transcoded path against 273ms on a ranged one — a
reconnection, a fresh stream and a rebuffer, for about sixty milliseconds. The
trade-off stands, but "slower seek" overstates what a user would notice; see
open question 3.

`AudioFileReader` takes a `ByteSource` rather than either concrete type, so it
does not know or care which transport it is reading.

The alternative — always source the cache from `/rest/download`, which is the
raw file and seekable — trades a user's deliberate bandwidth choice for
seekability, and on cellular that is not ours to make.

## 11. The car is served natively, from a tree pushed down in advance

CarPlay asks for its list at the worst possible moment. The phone connects as
someone starts driving; the app has been backgrounded for hours, and its
JavaScript is suspended. A browse tree that has to be fetched from JS is a tree
that is sometimes empty exactly then, and the failure looks to the driver like
an app with an empty library.

So the host pushes the tree down whenever it likes, and the native side answers
alone — including playing the selection, which never round-trips either. The
host learns what happened afterwards, through the ordinary track-change event.

**Everything that decides anything is kept out of CarPlay's types.**
`BrowseTree` and `CarPlayCoordinator` import Foundation and nothing else, so
`swift test` reaches them on any Mac with no car and no phone. The scene
delegate is left with drawing. This is the same split as `NowPlayingInfo` and
`NowPlayingCenter`, for the same reason: the interesting decisions here are not
about templates.

The decisions worth stating:

- **A track chosen inside an album queues the album and starts there**, rather
  than playing one track and stopping. The album is the context the driver
  believes they are in, and they cannot pick a follow-up while moving.
- **Over-long lists truncate rather than throw.** CarPlay refuses a list past
  its limit outright; a car showing the first hundred albums is usable, a car
  showing an error is not.
- **Orphaned nodes are dropped, not promoted.** A half-loaded library should
  show less, not show a flat pile of tracks where albums were expected.
- **Duplicate ids keep the first.** Selection resolves by id, so the
  alternative is a car playing something other than what it displayed.
- **A tree arriving after the car connects rebuilds the root template.**
  Otherwise the driver has to back out and re-enter to refresh an empty list.

**The tree crosses the bridge flat**, with parent references, because an Expo
`Record` cannot contain itself. Hosts never see that: the facade flattens, the
native side rebuilds, and both sides pin the same rules in tests, so a
disagreement cannot quietly become a car that displays one album and plays
another.

Two things outside the engine's reach. The `com.apple.developer.carplay-audio`
entitlement is granted by Apple per app; until it is, none of this appears in a
car and nothing logs to say why. And yuzic commits its `ios/` directory, so the
config plugin's Info.plist scene entry lands only on a prebuild.

## 12. How this engine fails

Not a design decision — a record. The serious defects here have kept arriving in
the same shape, and it is worth naming because it is not the shape most review
looks for. Nothing below threw. Nothing below failed a test suite. Seven of the
nine are code that ran, returned, and accomplished nothing. The other two are
the same idea one level up: one where what accomplished nothing was the
handover, one where it was the API boundary.

**A guard that guards nothing.** `remoteCommandsEnabled` re-registered the lock
screen's targets only when the value changed. Correct in isolation; the previous
library's teardown calls `removeTarget(nil)`, which clears every target while
leaving the flag alone, so the one call that would have restored them was the
one the guard skipped. The controls were greyed out on every device.

**A function with no callers.** `handleConfigurationChange` was written, was
correct, committed, shipped, and never invoked.

**A stub that accepts and discards.** `setCrossfade` on Android took its
argument, stored it, and no code read it. The API was complete and the feature
did not exist.

**A curve inherited by the wrong caller.** The sleep timer's fade-out went
through the crossfade's ramp and got its equal-power curve. Right for two
uncorrelated sources overlapping; wrong for one source going to silence alone,
where it holds loud and then drops. `FadeCurve` is now a required argument with
no default, so the question has to be answered at every call site.

**A command greyed out before it can be sent.** Overriding `seekToNext` is
useless if `getAvailableCommands` reports there is nowhere to go: the controller
never sends the command and the override never runs. The button was not being
ignored — it was disabled before it could be pressed.

**A control advertised from state the announcing object cannot see.** Since the
Android model port each voice holds exactly one track, so
`getAvailableCommands` answers `COMMAND_SEEK_TO_NEXT` from `queue.nextIndex`
rather than from the player's timeline — a timeline of one can never report
that a next exists. But `ForwardingPlayer` passes listener registration
straight through and keeps no record, so nothing could raise
`onAvailableCommandsChanged` on the session's behalf. ExoPlayer announces its
own commands when its timeline changes; ours can change when nothing about the
player does. Appending behind the last track turns "next" from impossible into
possible, and the player has no reason to mention it.

The distinguishing detail is that it was *intermittent*, and that is the
property that let it survive. During ordinary playback, unrelated player events
fire often enough that the set is usually re-read within seconds — so it reaches
a user as "sometimes the next button doesn't work", with no pattern they can
see. Measured on device, the same probe on the same build gave one run that
recovered at eleven seconds and one that was still greyed at thirty. A control
that is wrong every time gets reported; a control that is wrong sometimes gets
lived with.

It is worth distinguishing from *a command greyed out before it can be sent*
above, which looks identical from outside. There, the advertised value was
wrong. Here, the value is right and nothing announces that it changed. Both
produce a dead button and the fix is in a different place for each — which is
why the thing that settled it was decoding the session's `actions` bitmask
rather than looking at the button: bit 16 present and bit 32 absent said the
override was running and the queue genuinely had nowhere to go, which was the
correct answer to a question that had been asked of a one-track queue.

The same blindness produces the opposite fault, and review caught that where the
device run had not: `setQueue(emptyList())` takes the queue from n tracks to
none while calling no player method at all, because `loadActiveTrack` returns
early when there is no active track. Nothing is announced, and the session goes
on advertising a next that is no longer there — lit when it should be greyed,
where the original was greyed when it should be lit. One blindness, both signs.

**A state announcing an event that has not happened.** The engine went to
`.playing` when play was requested rather than when the first buffer was
scheduled, so a track that never buffered showed as playing at 0:00 forever.

**A change that is whole where it was tested and partial where it was sent.**
The Android crossfade was built, wired and verified on a device by one author,
then handed over as a set of hunks transcribed by hand and vouched for as
complete. The hunk calling `maybeBeginTransition` was not among them. The
receiving copy therefore had the entire overlap implementation and nothing that
would ever run it — and it would have compiled, reviewed clean, and never once
faded. Nothing was wrong with the code; the defect existed only in the copy, and
only between two machines.

**A feature complete on one side of an API that nothing on the other side
feeds.** The engine implements replay gain properly — per-track gain, a preamp
for untagged tracks, a clipping guard using `replayGainPeak`, a floor. It is
tested and it is correct. No host populates `replayGainDb` or `replayGainPeak`,
so every track takes the untagged branch and every track gets the same
multiplier. The feature cannot be observed to work or to fail, because nothing
exercises the part that varies.

This one was found by trying to test it: the check for whether an incoming
track's gain was applied correctly during a crossfade could not be constructed,
because no two tracks could be made to differ. A green result there would have
meant nothing at all. It is the same shape as a function with no callers, moved
out to the boundary between two codebases — where it is harder to see, because
each side is complete and only the join is empty.

The common thread is that all nine are invisible to "does it return, and is the
return value right". What catches them is asking what the code *did* — which
call ran, which caller reached it, what the user then heard. `Tools/mutate.py`
automates one slice of this: break a real behaviour, and see whether any test
notices.

### The instrument is part of the system

Four times the measurement was the fault and the code was fine, and each nearly
produced a "fix" for a bug that did not exist:

- A **decoder count** that could not distinguish "one track played" from "two
  tracks shared a codec" — it would have read the same either way, so it was
  evidence for neither.
- **`state=NONE(0)`** read as a fault, when nothing had been started yet. An
  absence is not a failure.
- **`actions=661`** read as a regression, when 661 was correct: a one-track
  queue genuinely had nowhere to go.
- A position of **298265 against a duration of 212741** — not a slow track, a
  wrong instrument. A number larger than the total it is measured against is a
  fact about the ruler.

A fifth is in CONTRIBUTING because it is about builds rather than readings: a
bare `lib/` in `.gitignore` kept all of libvorbis out of every commit while
`swift test` and the app build both stayed green, because both were being fed
the working tree. Before believing what a measurement implies, check that it
could have come out differently.

That test — could this have come out differently? — is also what caught the
seventh shape above, and it is worth being precise about how, because it was not
review and it was not a test suite. The hunks arrived with an assertion that
they were complete. An assertion cannot fail. What failed was a mechanical check
on the merged file: every helper named, and for each one, both a definition and
a caller. `maybeBeginTransition` came back defined once and called zero times.
The check took a minute to write, knew nothing about crossfades, and would have
caught the omission whichever hunk had gone missing.

The general form: when you receive work you did not do, verify a property of the
result rather than trusting a claim about the process. "That is every hunk" and
"the tests pass" are both claims about process. "Every function that exists is
reachable" is a property of the artefact in front of you.

## What is not decided yet

The architecture above is settled. What remains is empirical, and there is a
spike to run before the iOS reader is written. In order, the first two being
go/no-go:

1. ~~Does the FLAC slow-seek defect reproduce?~~ **Done — yes**, on macOS.
   Linear in distance, and it reads 177% of the file to play from 90% in. See
   §9 and `spikes/ios-reader`. Outstanding: confirm on an iOS device, and test
   MP3, which could not be encoded on macOS for lack of an encoder.
2. ~~Does the callback reader decode a partial file?~~ **Done — yes for WAV and
   FLAC**, opening from the head alone with the correct duration reported.
   **No for non-faststart M4A**, which needs its tail; the cache gets a
   tail-first prefetch for MP4-family files.
3. **Seek into an unfetched region**: time-to-first-sample end to end, and
   confirm an in-flight blocking read cancels in bounded time.
   **Half done — cancellation, yes**, once it was built: `cancel` reached only
   as far as a flag `ensure` read between fetches, so a seek waited out the
   request it had arrived during. `ByteFetcher.cancel` now abandons the task,
   and the bound is the cancel rather than the 30s timeout. `TrackPlayback.stop`
   calls through to it, so a discarded playback no longer leaves a thread and a
   request open until the timeout.

   Wiring it turned up a second thing. `PlaybackEngine.seek` builds a new
   `TrackPlayback` over the *same* reader, and `AudioFileReader` is documented
   not thread-safe — so the old producer, still parked in a read, was being
   raced by the new one seeking. That is `stopAndWait`: cancel, wait for the
   producer to unwind on its serial queue, then put the reads back to work.
   Used only at the seek site; everywhere else the reader is discarded and the
   wait would buy nothing.

   ~~Outstanding: time-to-first-sample.~~ **Done, and both transports were
   measured** — which turned out to matter, because the first run measured the
   wrong one and was written up as the other.

   On the simulator against a real Navidrome over the open internet, playing at
   4.4s with 11.1s buffered, seeking to 151.4s:

   | transport | first sample |
   | --- | --- |
   | direct, ranged (`format=raw`) | **273ms** |
   | transcoded, 320k (`timeOffset` reconnect) | **333ms** |

   So a seek far outside anything fetched costs about a round trip either way,
   not a rebuffer — and §10's second transport, which has to throw away its
   stream and reconnect, is only ~60ms worse than a ranged GET. That is a much
   better result for the transcoded path than the design assumed when it called
   the slower seek "the honest consequence" of a bitrate cap.

   **The trap worth recording**: yuzic sends `format`/`maxBitRate` for every
   quality *except* Original, so a probe written against the app's default
   quality silently measures the transcoded path. The engine cannot tell you
   which one you got — both are just a `ByteSource` by then. The smoke test now
   has one row per transport and prints which it is using.

   Measuring it also caught a divergence the tests could not: `bufferedSec` is
   **absolute** — on the same timeline as the position — because that is what a
   buffering bar is drawn against. iOS did that and said so; `src/types.ts`
   documented the opposite, and the Android port had followed the docs. Both
   corrected to match iOS.
4. **Two nodes at 44.1 and 96 crossfaded through the mixer**, on device and
   over Bluetooth. Decide mixer SRC versus `AVAudioConverter` by listening.

   The plain case now runs: two tracks overlapping, the transition started by
   the engine's own tick rather than by being told, with the track change
   landing at the fade's midpoint where §1 says it should. Driven from yuzic's
   smoke test, on the simulator. So the graph does what it was built for — but
   this question is not answered by that. What is still unmeasured is the part
   that motivated it: **differing sample rates**, a **real device**, and
   **Bluetooth**, none of which a simulator playing two 44.1kHz files exercises.
5. **Configuration-change survival**: pull the route mid-crossfade, confirm the
   rebuild resumes at the right frame with nothing repeated or dropped.
6. ~~Against real servers: does `/rest/stream` honour `Range` when
   transcoding?~~ **Done — no.** Direct streams are fully ranged; transcoded
   ones answer `accept-ranges: none` with no length, and seek via `timeOffset`.
   See §10; this needs a second transport, not a tweak.
7. **Thermal and battery** with two hi-res decoders live during a crossfade.

If (2) fails for a given format, that format falls back to fetch-to-complete —
a degradation, not a redesign.
