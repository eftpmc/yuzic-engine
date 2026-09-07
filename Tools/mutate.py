"""
Mutation testing for the yuzic-engine Swift suite.

Each entry breaks one real behaviour the way a plausible bug would, runs the
suite, and records whether anything failed. A mutation that survives is a
behaviour nothing checks — which is the interesting result, not the reassuring
one.
"""
import io, subprocess, sys, os

ROOT = '/Users/zack/Documents/GitHub/yuzic-engine'

# (label, relative path, exact text to find, replacement)
MUTATIONS = [
    ("transition fires one sample late",
     "ios/Core/PlaybackEngine.swift",
     "return positionSec >= durationSec - transitionSec",
     "return positionSec > durationSec - transitionSec + 0.5"),

    ("insert at the playhead displaces the playing track",
     "ios/Core/PlaybackQueue.swift",
     "if at <= activeIndex { activeIndex += more.count }",
     "if at < activeIndex { activeIndex += more.count }"),

    ("removing a track above the playhead does not shift the index",
     "ios/Core/PlaybackQueue.swift",
     "if index < activeIndex {\n      activeIndex -= 1\n    }",
     "if false {\n      activeIndex -= 1\n    }"),

    ("replay gain always returns unity",
     "ios/Core/ReplayGain.swift",
     "guard settings.mode != .off else { return 1.0 }",
     "guard settings.mode != .off else { return 1.0 }\n    if true { return 1.0 }"),

    ("fade-out curve inverted (the bug that shipped)",
     "ios/Core/AudioGraph.swift",
     ": target + (start - target) * sqrt(1 - p)",
     ": start + (target - start) * (1 - sqrt(p))"),

    ("crossfade never bypasses the EQ when flat",
     "ios/Core/AudioGraph.swift",
     "    guard !bands.isEmpty, bands.contains(where: { $0.gainDb != 0 }) else {\n      eq.bypass = true\n      return\n    }\n    eq.bypass = false",
     "    eq.bypass = false"),

    ("artwork is kept when a track has none",
     "ios/Core/NowPlaying.swift",
     "guard let uri, !uri.isEmpty else { return .clear }",
     "guard let uri, !uri.isEmpty else { return .keep }"),

    ("paused time counts as listened again",
     "ios/Core/PlaybackEngine.swift",
     "    closeListeningStretch()\n    state = .paused",
     "    state = .paused"),
    ("clipping protection can raise a quiet track",
     "ios/Core/ReplayGain.swift",
     "gain = min(gain, 1.0 / peak)",
     "gain = max(gain, 1.0 / peak)"),
]


def run_tests():
    proc = subprocess.run(
        ['swift', 'test'], cwd=ROOT, capture_output=True, text=True, timeout=1800
    )
    out = proc.stdout + proc.stderr
    if 'Executed' not in out:
        return 'DID NOT COMPILE', []
    failures = sorted({
        line.split(']')[0].split('[')[-1]
        for line in out.splitlines()
        if 'error:' in line and 'XCTAssert' in line
    })
    # The exit code, not a substring. `with 0 failures` appears once per
    # sub-suite, so searching the whole output reports success whenever *any*
    # sub-suite is clean — which made every mutation look like a survivor,
    # including one already proven to be caught.
    return ('passed' if proc.returncode == 0 else 'failed'), failures


results = []
for label, rel, old, new in MUTATIONS:
    path = os.path.join(ROOT, rel)
    original = io.open(path, encoding='utf-8').read()
    if original.count(old) != 1:
        results.append((label, 'ANCHOR MISS (%d)' % original.count(old), []))
        continue
    io.open(path, 'w', encoding='utf-8').write(original.replace(old, new))
    try:
        status, failures = run_tests()
    finally:
        io.open(path, 'w', encoding='utf-8').write(original)
    results.append((label, status, failures))
    print('%-52s %s' % (label[:52], status))
    sys.stdout.flush()

print('\n=== SURVIVORS (nothing noticed) ===')
for label, status, _ in results:
    if status == 'passed':
        print(' -', label)
print('\n=== CAUGHT ===')
for label, status, failures in results:
    if status not in ('passed', 'ANCHOR MISS'):
        print(' -', label, '->', status, (failures[:3] if failures else ''))
