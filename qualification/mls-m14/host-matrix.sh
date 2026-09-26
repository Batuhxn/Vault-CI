#!/usr/bin/env bash
# The pinned M1.4 Python harness, host-side on macOS: real child-process crash
# matrix, T3 native adversary, and every Linux qualification check.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
build="${RUNNER_TEMP:?}/mls-m14"
python3 -m venv "$build/venv"
"$build/venv/bin/pip" install --quiet --disable-pip-version-check -r "$root/harness/requirements-m12.txt"
umask 077
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$build/python:$root/harness"
export M14_ADVERSARY="$build/mls-rs/target/debug/examples/m14_adversary"
"$build/venv/bin/python" "$root/harness/m12_identity_cases.py"
"$build/venv/bin/python" "$root/harness/m14_matrix.py" "$build/state" | tee "$build/host-matrix.log"
grep -qx 'M1.4 Linux matrix: 96 checks PASS' "$build/host-matrix.log"
test "$(grep -c ': PASS$' "$build/host-matrix.log")" -eq 96
