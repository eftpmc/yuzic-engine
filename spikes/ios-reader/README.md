# Spike: the iOS reader

Answers items 1 and 2 of the spike plan in [`docs/architecture.md`](../../docs/architecture.md) —
the two that were go/no-go for the fetch-to-cache design.

## Running it

Needs macOS with Xcode. No project, no dependencies; these are scripts.

```sh
swift gen.swift 20 tone.wav   # ~25s, writes a 202MB 20-minute reference
swift encode.swift            # re-encodes it to FLAC and ALAC
swift seek.swift              # item 1: seek cost by format and distance
swift readpattern.swift       # item 2: which bytes a decoder actually asks for
```

The generated audio is broadband — a swept tone plus noise — because silence or
a pure tone compresses to nearly nothing and would let a decoder skip work a
real track makes it do.

## Results, macOS 26.0 / Swift 6.3.3, Apple silicon, 20-minute 44.1kHz stereo

**Item 1 — seek + first read, cold open each time:**

| format | 10% | 50% | 90% |
| --- | --- | --- | --- |
| WAV | 0.0000s | 0.0000s | 0.0000s |
| **FLAC** | **0.0159s** | **0.0708s** | **0.1267s** |
| ALAC | 0.0004s | 0.0004s | 0.0004s |

FLAC's cost is linear in distance. That is decoding from byte zero: the
`SEEKTABLE` is being ignored. WAV and ALAC are flat, because both are seekable
by arithmetic.

**Item 2 — bytes actually requested to play from 90% in:**

| format | bytes fetched | range touched | time |
| --- | --- | --- | --- |
| WAV | 16 KB | 186050–186066 KB | 0.0012s |
| **FLAC** | **279,985 KB (177% of the file)** | **13–142,331 KB** | **1.2479s** |
| ALAC | 36 KB | 143151–143188 KB | 0.0006s |

This is the finding that matters, and it is worse than slow seeking. To play
from 90% in, Apple's FLAC decoder reads from the *start* of the file to the
seek point — 177% of the file's size in total requests, some regions more than
once. **Random access buys nothing for FLAC**: over a network, seeking to the
end of a track would require fetching the whole track first. It is not a
performance footnote, it defeats the ranged-fetch design outright.

**Item 2 — opening with only the first 30% present**, `GetSizeProc` reporting
the full size:

| format | result |
| --- | --- |
| WAV | opens, correct 20.0 min duration, plays, zero reads past the fetched region |
| FLAC | opens, correct 20.0 min duration, plays, zero reads past the fetched region |
| **ALAC (.m4a)** | **open fails** — 2 of its first 10 reads are past the fetched region |

So the core premise holds: **lie about the size, serve the head, and the parser
believes the file is whole.** Duration is reported correctly rather than
truncated, which is the thing `AVAudioFile` gets wrong.

The M4A failure is the documented non-faststart case, now confirmed: `moov` sits
at the tail of a file written by `AVAudioFile`, so opening needs the end.

## What this means for the design

Two different mitigations, because the two failures are opposites — FLAC starts
fine but cannot seek, M4A seeks perfectly but cannot start:

1. **Bundle libFLAC.** Not an optimisation. Without it the cache design does not
   work for the format yuzic's audience mostly holds.
2. **The cache fetches the tail first for MP4-family files.** Cheap — the read
   proc is random-access already, so it is a prefetch heuristic, not a
   redesign. Roughly the last 64KB before the head.

## Spike item 6: what a real server does with `Range`

Measured against `demo.navidrome.org`, September 2026, on an 18MB m4a track.

**Direct stream** — `/rest/stream.view?id=…` with no quality parameters:

```
HTTP/2 206
accept-ranges: bytes
content-range: bytes 0-0/18389560
```

Ranges fully supported, length known. Everything above works.

**Transcoded stream** — the same URL with `&maxBitRate=128&format=mp3`:

```
HTTP/2 200
accept-ranges: none
(no content-length at all)
```

Not merely "ranges ignored". The server says outright that it does not accept
them, and declines to state a length, because it is producing the bytes as it
sends them and does not know yet.

**Seeking in that mode is a different mechanism entirely.** Subsonic's answer is
`timeOffset`, and it works — re-requesting with `&timeOffset=60` returns a
different first 2KB, so the server restarts the encode sixty seconds in.

So there are two transports, not one:

| | direct | transcoded |
| --- | --- | --- |
| ranges | yes | no, explicitly |
| length up front | yes | no |
| seeking | byte range | re-request with `timeOffset` |
| random access | yes | no — a fresh stream per seek |

**Which one you get is decided by the app's own quality setting.** yuzic asks
for `format`/`maxBitRate` on everything except Original, and that choice is made
per network — so the same track is randomly-accessible on WiFi at Original and
a forward-only stream on cellular at 192kbps. The reader cannot assume either.

The consequence for this design is in `docs/architecture.md` §10.

## Caveats

- Measured on macOS, not on an iOS device. The frameworks are shared and the
  original report was also macOS, but iOS remains formally unconfirmed.
- One machine, one file length, Apple silicon. The *shape* — linear versus flat
  — is the robust result; absolute numbers are not.
- MP3 is missing because macOS has no MP3 encoder, so the reference file could
  not be produced. The same defect is reported for MP3 and is untested here.
