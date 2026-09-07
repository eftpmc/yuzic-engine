#!/usr/bin/env python3
"""Compare the two native modules by signature, not just by name.

The check this replaces compared names only:

    grep -o 'AsyncFunction("[a-z]*"' <each module> | sort | comm -23 ios android

That is half the surface. A `setBrowseTree` once shipped whose name matched on
both platforms and whose arity did not, and a name-only diff is silent about
exactly that — the method is present on both sides, so nothing is reported,
and the failure arrives at a call site as a type error somewhere unrelated.

Exit status is 0 when the two modules agree and 1 when they do not, so this
can gate a change rather than be read and forgotten.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios" / "YuzicEngineModule.swift"
ANDROID = ROOT / "android/src/main/java/dev/yuzic/engine/YuzicEngineModule.kt"

# Differences that are deliberate. Listing one here is a claim that the gap is
# known and documented — not a way to quieten the check. Anything absent from
# this list fails, which is the point: an undocumented divergence should be
# loud, and a documented one should not cost you a red run forever.
KNOWN_GAPS = {
    # Media3's evictor takes its cache limit as a constructor argument, so
    # changing it needs either a second SimpleCache over one directory (which
    # corrupts the index) or releasing the live one mid-track. Deliberately
    # absent rather than stubbed, so it rejects by name at the bridge.
    "configureCache": "android",
}

# Swift and Kotlin spell the same wire types differently. Normalise both onto a
# single vocabulary so that `[TrackRecord]` and `List<TrackRecord>` compare
# equal — they are the same thing to the bridge, and a diff that reported them
# as a mismatch would be noise that trains you to ignore it.
CANON = [
    (re.compile(r"\bBoolean\b"), "Bool"),
    (re.compile(r"\bList<([^>]+)>"), r"[\1]"),
    (re.compile(r"\bMap<\s*([^,]+),\s*([^>]+)>"), r"[\1:\2]"),
    (re.compile(r"\bMutableList<([^>]+)>"), r"[\1]"),
]


def canonical(t: str) -> str:
    t = t.strip()
    # Swift writes `[String: Any]`; Kotlin `Map<String, Any>`. Drop the spaces
    # so the two land on the same string after the rewrites below.
    t = re.sub(r"\s+", "", t)
    for pattern, repl in CANON:
        prev = None
        while prev != t:  # nested generics need more than one pass
            prev = t
            t = pattern.sub(repl, t)
    return t


def split_params(raw: str) -> list[str]:
    """Split a parameter list on commas that are not inside brackets."""
    out, depth, current = [], 0, ""
    for ch in raw:
        if ch in "[<(":
            depth += 1
        elif ch in "]>)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        out.append(current)
    # Each entry is `label: Type`; the label is a local name and differs freely
    # between platforms (`fromIndex` vs `from`), so only the type is compared.
    types = []
    for p in out:
        p = p.strip()
        types.append(canonical(p.split(":", 1)[1]) if ":" in p else canonical(p))
    return types


PARAM_LIKE = re.compile(r"^\s*\w+\s*:\s*[\w\[\]<>,.:?\s]+$")

# `@Field var id: String = ""` on both platforms.
FIELD = re.compile(r"@Field\s+var\s+(\w+)\s*:\s*([\w\[\]<>,.:?\s]+?)\s*(?:=|$)", re.M)
# Swift `struct X: Record {`, Kotlin `class X : Record {`.
RECORD = re.compile(r"(?:struct|class)\s+(\w+)\s*:\s*Record\s*\{")


def parse_records(text: str) -> dict[str, tuple[tuple[str, str], ...]]:
    """Map each Record type to its field shape.

    The two platforms are free to name the same wire shape differently —
    `BrowseNodeRecord` on iOS is `FlatBrowseNodeRecord` on Android — and
    comparing the names would report that as a mismatch. What crosses the
    bridge is the fields, so that is what gets compared.
    """
    records = {}
    for m in RECORD.finditer(text):
        name, start = m.group(1), m.end()
        depth, i = 1, start
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[start : i - 1]
        records[name] = tuple(
            sorted((f, canonical(t)) for f, t in FIELD.findall(body))
        )
    return records


def resolve(types: list[str], records: dict) -> list[str]:
    """Replace a Record type name with its field shape, so that two platforms
    naming the same shape differently compare equal."""
    out = []
    for t in types:
        inner = t[1:-1] if t.startswith("[") and t.endswith("]") else t
        bare = inner.rstrip("?")
        if bare in records:
            shape = "{" + ",".join(f"{f}:{ty}" for f, ty in records[bare]) + "}"
            out.append(t.replace(bare, shape))
        else:
            out.append(t)
    return out


def parse_ios(text: str) -> dict[str, list[str]]:
    """`AsyncFunction("name") { (a: T, b: U?) in` — parens, or none for no args."""
    found = {}
    for m in re.finditer(r'AsyncFunction\("(\w+)"\)\s*\{([^\n]*)', text):
        name, rest = m.group(1), m.group(2)
        paren = re.match(r"\s*\(([^)]*)\)", rest)
        if paren:
            inner = paren.group(1).strip()
            # `() -> Int in` is a no-argument function with a return type.
            found[name] = [] if not inner else split_params(inner)
        else:
            found[name] = []
    return found


def parse_android(text: str) -> dict[str, list[str]]:
    """`AsyncFunction("name") { a: T, b: U? ->` — arrow ends the list.

    A no-argument function may carry its whole body inline
    (`{ onPlayer { it.play() } }`) and has no arrow at all, so the absence of
    one means zero parameters rather than an unparsed signature.
    """
    found = {}
    for m in re.finditer(r'AsyncFunction\("(\w+)"\)\s*\{([^\n]*)', text):
        name, rest = m.group(1), m.group(2)
        if "->" not in rest:
            found[name] = []
            continue
        head = rest.split("->", 1)[0]
        # A nested lambda's arrow is not this function's parameter list. Real
        # parameter lists are `label: Type` pairs and contain no braces.
        if "{" in head or not all(
            PARAM_LIKE.match(p) for p in head.split(",") if p.strip()
        ):
            found[name] = []
            continue
        found[name] = split_params(head)
    return found


def main() -> int:
    ios_text, android_text = IOS.read_text(), ANDROID.read_text()
    ios_records = parse_records(ios_text)
    android_records = parse_records(android_text)

    ios = {n: resolve(p, ios_records) for n, p in parse_ios(ios_text).items()}
    android = {
        n: resolve(p, android_records) for n, p in parse_android(android_text).items()
    }

    ios_only = sorted(
        n for n in set(ios) - set(android) if KNOWN_GAPS.get(n) != "android"
    )
    android_only = sorted(
        n for n in set(android) - set(ios) if KNOWN_GAPS.get(n) != "ios"
    )
    mismatched = sorted(
        n for n in set(ios) & set(android) if ios[n] != android[n]
    )
    known = sorted(
        n
        for n, side in KNOWN_GAPS.items()
        if (side == "android" and n in ios and n not in android)
        or (side == "ios" and n in android and n not in ios)
    )
    # A gap that has been closed should stop being listed as known, or the list
    # slowly becomes a record of what used to be true.
    stale = sorted(set(KNOWN_GAPS) - set(known))

    print(f"iOS: {len(ios)} methods   Android: {len(android)} methods\n")

    if known:
        print("Known gaps (declared in KNOWN_GAPS):")
        for n in known:
            print(f"  {n} — absent on {KNOWN_GAPS[n]}")
        print()
    if stale:
        print("KNOWN_GAPS lists differences that no longer exist — remove them:")
        for n in stale:
            print(f"  {n}")
        print()

    if ios_only:
        print("Only on iOS:")
        for n in ios_only:
            print(f"  {n}({', '.join(ios[n])})")
        print()
    if android_only:
        print("Only on Android:")
        for n in android_only:
            print(f"  {n}({', '.join(android[n])})")
        print()
    if mismatched:
        print("Signature mismatch — the name matches and the arguments do not:")
        for n in mismatched:
            print(f"  {n}")
            print(f"    ios     ({', '.join(ios[n])})")
            print(f"    android ({', '.join(android[n])})")
        print()

    if not (ios_only or android_only or mismatched or stale):
        print("Signatures agree, apart from the declared gaps above.")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
