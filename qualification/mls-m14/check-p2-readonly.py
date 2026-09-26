#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail if the P2 accessor patch exposes any setter or mutating API."""
import re
import sys

added = [line[1:] for line in open(sys.argv[1]).read().splitlines()
         if line.startswith("+") and not line.startswith("+++")]
functions = [line for line in added if re.search(r"\bfn\s+\w+", line)]
assert functions, "no accessors found"
for line in functions:
    name = re.search(r"\bfn\s+(\w+)", line).group(1)
    assert "&self" in line and "&mut" not in line, f"accessor {name} must take &self"
    assert not name.startswith(("set", "with_", "insert", "delete", "remove", "clear")), name
touched = re.findall(r"^\+\+\+ b/(\S+)", open(sys.argv[1]).read(), re.M)
assert touched == ["mls-rs-uniffi/src/lib.rs"], touched
print(f"P2 read-only: PASS ({len(functions)} accessors, no setters or &mut self)")
