#!/usr/bin/env python3
"""Pin the production MLS core to its M1.4/M1.5-qualified source.

Usage: check-qualified-core.py QUALIFIED_SOURCES QUALIFIED_TESTS [--write]
  QUALIFIED_SOURCES  the M1.5 qualification swift/Sources directory
  QUALIFIED_TESTS    the M1.4 qualification swift/Tests/MLSQualificationTests directory

The unified diff between the qualified files and their production copies must
equal QUALIFIED_CORE.diff byte for byte. Any other change to the core fails
this check and needs a security review (and possibly requalification).
"""

import difflib
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
PINNED = HERE / "QUALIFIED_CORE.diff"
SOURCES = [
    ("ProtectedStateStore/ProtectedStateStore.swift", "Sources/ProtectedStateStore/ProtectedStateStore.swift"),
    ("MLSQualification/Model.swift", "Sources/WatchlinkMLS/Model.swift"),
    ("MLSQualification/Store.swift", "Sources/WatchlinkMLS/Store.swift"),
    ("MLSQualification/Device.swift", "Sources/WatchlinkMLS/Device.swift"),
]
TESTS = [(name, "Tests/QualifiedSuite/" + name) for name in ("Harness.swift", "LifecycleTests.swift", "TrustTests.swift")]


def diff(root: pathlib.Path, pairs, label: str) -> str:
    out = []
    for qualified, production in pairs:
        old = (root / qualified).read_text().splitlines(keepends=True)
        new = (HERE / production).read_text().splitlines(keepends=True)
        out += difflib.unified_diff(old, new, f"qualified/{label}/{qualified}", f"production/{production}")
    return "".join(out)


def main(argv) -> int:
    write = "--write" in argv
    args = [a for a in argv if a != "--write"]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    actual = diff(pathlib.Path(args[0]), SOURCES, "m15") + diff(pathlib.Path(args[1]), TESTS, "m14-tests")
    if write:
        PINNED.write_text(actual)
        print(f"wrote {PINNED.name}")
        return 0
    if actual != PINNED.read_text():
        sys.stdout.writelines(difflib.unified_diff(
            PINNED.read_text().splitlines(keepends=True), actual.splitlines(keepends=True),
            "pinned", "actual"))
        print("FAIL: production MLS core drifted from the qualified source", file=sys.stderr)
        return 1
    print(f"qualified core relationship: PASS ({len(SOURCES)} core + {len(TESTS)} test files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
