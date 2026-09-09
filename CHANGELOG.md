# Changelog

All notable changes to yuzic-engine are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

Semver here is a promise about the **JavaScript API** — the methods on
`YuzicEngine`, the event vocabulary, and the exported types. Native
implementation detail may change in a patch release when the observable
behaviour does not.

## [Unreleased]

## [1.0.0]

First published release. The engine has been in production use in
[yuzic](https://github.com/yuzicapp/yuzic) across iOS and Android before this
point; 1.0.0 marks the API being committed to rather than the code being new.

### Added

- **Two-voice audio graph** with crossfade (`gapless-aware` and `always`
  modes), where a gapless join is the same machinery with a zero-length fade.
- **Native queue** — set, append, insert, remove, move, clear, and skip to
  next/previous/index. It lives in native code because backgrounded JavaScript
  is suspended while the lock screen, notification and car still have to work.
- **Transport** — play, pause, stop, seek, volume, speed (0.25×–4×), and
  repeat (off / one / all).
- **DSP** — a ten-band equalizer, bypassed entirely when flat, and replay gain
  with album/track/auto modes and clipping protection.
- **Sources** — local files and HTTP streaming, with auth by query parameter
  or header, and an on-device LRU cache keyed by media id rather than URL
  (Subsonic and Jellyfin rotate tokens through the URL, so keying on it
  re-downloads the same audio every session).
- **Vorbis and Opus decoding** on iOS, which Core Audio cannot open at all,
  via vendored libogg/libvorbis/libopus.
- **Mutual TLS** on both platforms — import a PKCS#12 identity in memory and
  present it for both ordinary API requests and audio streaming. Both halves
  are required: a certificate on only the audio transport is unreachable,
  because the login that precedes every track is the request an mTLS server
  refuses first.
- **Platform integration** — background playback, lock-screen and notification
  controls with artwork, CarPlay and Android Auto browse trees, audio focus,
  interruptions, route changes, becoming-noisy, and a sleep timer that fades
  rather than cuts.
- **Events** — state changes, track changes carrying the time actually
  listened, progress, queue changes, and errors.

### Known gaps

- `configureCache` is **absent on Android**, deliberately rather than stubbed,
  so it rejects by name at the bridge. Media3's evictor takes its cache limit
  as a constructor argument, so honouring a new one means either a second
  `SimpleCache` over one directory (which corrupts the index) or releasing the
  live one mid-track. `Tools/parity.py` declares it; every other method agrees
  across the two platforms by signature and event vocabulary.

[Unreleased]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yuzicapp/yuzic-engine/releases/tag/v1.0.0
