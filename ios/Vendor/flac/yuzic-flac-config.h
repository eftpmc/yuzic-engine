#ifndef YUZIC_FLAC_CONFIG_H
#define YUZIC_FLAC_CONFIG_H

/*
 * libFLAC's build configuration, written out rather than generated.
 *
 * Upstream expects autotools or CMake to produce a `config.h` and to define
 * HAVE_CONFIG_H so every source picks it up. That flag is generic autotools
 * vocabulary, and in the pod it applies to *every* file in the target —
 * including React Native's C++, where a stray HAVE_CONFIG_H made unrelated
 * headers take a different branch. libopus in this repo is vendored with its
 * defines spelled out for exactly that reason (see Package.swift), and this
 * follows the same rule: no HAVE_CONFIG_H anywhere, one header force-included
 * into this target only.
 *
 * Decoder only. No encoder source is vendored, so nothing here describes
 * encoding, and libFLAC's Ogg aspect is left out with it — a `.oga`/Ogg-FLAC
 * stream is deliberately not claimed, matching `HTTPTrackReaderFactory`'s
 * sniff, which answers nil for FLAC-in-Ogg.
 */

/* Apple platforms: all of these are true on both iOS and macOS, arm64 and
 * x86_64. Hardcoded because the platform set is known, where autotools has to
 * probe an arbitrary host. */
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_LROUND 1
#define HAVE_FSEEKO 1
#define HAVE_INTTYPES_H 1

/* Darwin has no <sys/auxv.h>; that is a Linux/glibc interface for reading
 * hardware capabilities. cpu.c guards on it. */
/* #undef HAVE_SYS_AUXV_H */

/* Not a CD-quality-only build: 24-bit files are exactly the case that matters
 * here — the track that prompted this work is 24-bit — and the integer-only
 * library drops the float LPC path used to decode them well. */
/* #undef FLAC__INTEGER_ONLY_LIBRARY */

/* No assertions or overflow tracing in a shipped decoder; both are debugging
 * aids that cost work on every frame. */
#define NDEBUG 1

/*
 * Ogg-FLAC support, off.
 *
 * Defined as 0 rather than left undefined: `stream_decoder.c` tests it in
 * ordinary C expressions (`if(FLAC__HAS_OGG && decoder->private_->is_ogg)`),
 * not with `#ifdef`, so an undefined symbol is a compile error rather than a
 * disabled feature. At 0 the compiler folds those branches away and the Ogg
 * aspect is never reached — which is why no `ogg_decoder_aspect.c` is
 * vendored.
 *
 * This matches the engine's existing position: `HTTPTrackReaderFactory.oggCodec`
 * deliberately does not claim FLAC-in-Ogg, and says so.
 */
#define FLAC__HAS_OGG 0

/*
 * SIMD.
 *
 * The x86 intrinsic sources are vendored so the file list is identical on
 * every architecture — a target whose sources change per-arch is a target that
 * breaks the first time someone builds for the other one. They compile to
 * nothing on arm64 because FLAC__CPU_X86_64 is never defined here.
 *
 * NEON is what actually runs on the phone. libFLAC picks it up from the
 * compiler's own __ARM_NEON, so there is no symbol to set — but the decision
 * is worth stating, because it is the difference between a hi-res FLAC
 * decoding comfortably on an iPhone and not.
 */
#if defined(__x86_64__)
#define FLAC__CPU_X86_64 1
#define FLAC__ALIGN_MALLOC_DATA 1
#endif

/* Version string, normally substituted by the build system. Reported through
 * FLAC__VERSION_STRING and worth keeping accurate: it is what a NOTICE audit
 * or a bug report would quote. */
#define PACKAGE_VERSION "1.5.0"

#endif /* YUZIC_FLAC_CONFIG_H */
