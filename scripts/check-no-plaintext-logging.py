#!/usr/bin/env python3
"""Fail if production Swift source logs message content.

Flags any logging call (print, debugPrint, dump, NSLog, os_log, log(...),
Logger/logger.<level>(...)) whose arguments mention a message-content
identifier: text, rawText, draft, incoming, payload, body, content, or
<anything>.text.

This is a baseline regression guard, not a proof: it catches the obvious
`print(message.text)` shape. Transport/error logs that interpolate only
errors, states, or byte counts pass.

Usage:
  check-no-plaintext-logging.py [DIR ...]   (default: Sources/Vault)
  check-no-plaintext-logging.py --self-test
Exit 0 = clean, 1 = findings.
"""

import pathlib
import re
import sys

LOG_CALL = re.compile(
    r"\b(?:print|debugPrint|dump|NSLog|os_log|log|"
    r"[Ll]ogger\s*\.\s*(?:debug|info|notice|warning|error|fault|critical|trace|log))\s*\((.*)"
)
CONTENT = re.compile(
    r"\b(?:text|rawText|draft|incoming|payload|body|content)\b|\.\s*text\b"
)


def findings(source: str) -> "list[tuple[int, str]]":
    hits = []
    for number, line in enumerate(source.splitlines(), 1):
        code = line.split("//", 1)[0]
        match = LOG_CALL.search(code)
        if match and CONTENT.search(match.group(1)):
            hits.append((number, line.strip()))
    return hits


def self_test() -> None:
    bad = [
        "print(message.text)",
        'print("got \\(text)")',
        "debugPrint(payload)",
        'log("frame: \\(incoming.text)")',
        'NSLog("%@", draft)',
        'logger.info("body \\(body)")',
        "dump(rawText)",
    ]
    good = [
        'print("[relay] \\(message)")',
        'log("connection failed: \\(error)")',
        'log("ignored malformed frame (\\(byteCount) bytes)")',
        "// print(message.text)",
        "messageHandler?(text)",
    ]
    for line in bad:
        assert findings(line), f"self-test: missed {line!r}"
    for line in good:
        assert not findings(line), f"self-test: false positive {line!r}"
    print("self-test: PASS")


def main(argv: "list[str]") -> int:
    if argv == ["--self-test"]:
        self_test()
        return 0
    roots = [pathlib.Path(a) for a in argv] or [pathlib.Path("Sources/Vault")]
    files = sorted(f for root in roots for f in root.rglob("*.swift"))
    if not files:
        print("no Swift files found", file=sys.stderr)
        return 1
    failed = False
    for path in files:
        for number, line in findings(path.read_text(encoding="utf-8")):
            print(f"{path}:{number}: possible plaintext logging: {line}")
            failed = True
    if failed:
        return 1
    print(f"no plaintext message logging in {len(files)} Swift files: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
