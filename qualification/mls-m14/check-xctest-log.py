#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail on absent XCTest execution or obvious secret material in CI output."""
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
for label, pattern in {
    "PEM private key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "age secret key": "AGE" + "-SECRET-KEY-1",
    "sensitive key assignment": r"(?im)\b(?:private[_ -]?key|session[_ -]?key|pickle[_ -]?key)\s*[:=]\s*[^\s,]+",
}.items():
    if re.search(pattern, log):
        sys.exit(f"CI log rejected: {label}")
summaries = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
if not summaries:
    sys.exit("CI log rejected: XCTest execution summary missing")
executed, failures = map(int, summaries[-1])
if executed < 20 or failures:
    sys.exit(f"CI log rejected: {executed} tests, {failures} failures; expected >=20 and 0")
print(f"MLS Apple XCTest: PASS ({executed} executed, 0 failures); log guard: PASS")
