# Contributing

## Where code may come from

This engine is Apache-2.0 and everything in it has to be compatible with that.
One rule matters more than the rest:

**Do not read, copy, port, or consult `@rntp/player` v5 source while working on
this project.** That package is proprietary from v5 and its licence carries a
non-competition clause covering exactly this kind of software. Not a grey area,
and not something a rewrite launders.

`react-native-track-player` **v4 and earlier is Apache-2.0**, and that grant is
perpetual for the code published under it. Referencing or lifting from v4 is
legally clean. If you do, attribute it in `NOTICE` and say what changed.

Third-party code that is vendored — currently libogg, libvorbis, libopus and
libopusfile under `ios/Vendor` — goes in unmodified, with its licence file alongside it and an
entry in `NOTICE` naming the version and what was included.

## Verifying a change

The engine has been wrong in the same handful of ways often enough to be worth
listing, because each was found late and none of them threw.

**Say which copy you built.** `swift test` compiles `ios/Core` from the working
tree. An app build compiles whatever is in `node_modules`, which is the
*published* package. Those can differ — a bare `lib/` in `.gitignore` once kept
all of libvorbis out of every commit while both checks stayed green, because
the working tree had the files and the app build was being fed a copy of the
working tree. If a change adds files, check `git ls-files <path> | wc -l`
against what is on disk.

**Check the measurement before believing what it implies.** Four separate times
the instrument was the fault, not the code: a decoder count that could not
distinguish "one track played" from "two tracks shared a codec"; a state read
that returned `NONE` because nothing had been started; a command bitmask read
as a regression when it was a queue with genuinely nowhere to go; a position of
298265 against a duration estimated at 212741, which is not a slow track but a
wrong instrument.

**Ask what the code did, not whether it returned.** The characteristic failure
here is not a crash — it is succeeding at nothing. A guard that guards nothing,
a function with no callers, a stub that records its argument and discards it, a
curve inherited by a caller that wanted a different one, a command greyed out
before it can be sent, a state announcing an event that has not happened. Every
one of those passed a test suite.

`Tools/mutate.py` exists for the last of these: it breaks one real behaviour at
a time and reports whether any test notices. A test that survives its own
subject being broken is not a test. Run it when adding one that matters.

## Gates

```sh
npm run typecheck    # both tsconfigs — the second is what `prepare` uses
npm test
swift test
```

Android has no test target. Changes to `android/` are verified by building and
running them on a device or emulator, and a commit should say which.
