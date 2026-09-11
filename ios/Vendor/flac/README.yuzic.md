libFLAC 1.5.0, vendored for yuzic-engine
========================================

Upstream: https://github.com/xiph/flac  (flac-1.5.0.tar.xz)
SHA-256 of the release tarball:
  f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920

Licence: BSD-3-Clause (Xiph.Org). See COPYING.


Why this is here
----------------

Not because iOS lacks a FLAC decoder — Core Audio has one, and it decodes
correctly. It cannot *stream* one. Its parser seeks backwards, which a
transcoded (forward-only) stream cannot serve at all, and it reads from the
start of the file to any seek point, which defeats the ranged cache. Measured
numbers and the bug it caused are in `docs/architecture.md` §10; the reader is
`ios/Core/FLACFileReader.swift`.


What was taken
--------------

Decoder only. Everything here is unmodified upstream source.

  src/           the decoder's translation units, from src/libFLAC/
  src/private/   from src/libFLAC/include/private/
  src/protected/ from src/libFLAC/include/protected/
  src/share/     from include/share/  (alloc.h, compat.h, endswap.h — the
                 three the decoder actually reaches for)
  src/deduplication/
                 fragments that lpc.c, fixed.c and bitreader.c `#include`
                 *inside function bodies*. They are not translation units and
                 must not be compiled on their own; both Package.swift and the
                 podspec exclude them from compilation while still shipping
                 them.
  include/FLAC/  the public headers

Deliberately NOT taken:

  - the encoder (`stream_encoder.c` and friends) — yuzic never writes FLAC.
    `include/FLAC/stream_encoder.h` is kept anyway because `all.h` includes it
    and would not parse without it; no encoder *code* is compiled.
  - `ogg_decoder_aspect.c` and the Ogg glue — FLAC-in-Ogg is not claimed, which
    matches `HTTPTrackReaderFactory.oggCodec` answering nil for it. The config
    header sets `FLAC__HAS_OGG` to 0 so those branches fold away.
  - libFLAC++, the tools, the tests, the docs.


The one addition
----------------

`yuzic-flac-config.h` supplies what autotools or CMake would normally generate.
It is force-included into this target only (`-include`), never via
`HAVE_CONFIG_H` — that flag would apply to every file in the pod target,
React Native's C++ included, which is the same trap libopus is vendored around.
See the comments in that file.


Updating
--------

Take the same file set from the new release, keep `yuzic-flac-config.h`, and
re-run the engine's test suite — `FLACFileReaderTests` asserts the two
properties that matter (a forward-only source decodes to completion, and a seek
does not read the whole file), so a regression in either shows up there rather
than on a phone.
