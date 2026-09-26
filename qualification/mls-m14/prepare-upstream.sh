#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
checkout="${1:?usage: prepare-upstream.sh <empty-checkout-path>}"
test ! -e "$checkout"
revision="$(cat "$root/UPSTREAM_REVISION")"
(cd "$root" && shasum -a 256 -c PATCHES.sha256)  # verify before anything is applied
git clone --filter=blob:none --no-checkout https://github.com/awslabs/mls-rs.git "$checkout"
git -C "$checkout" checkout --detach "$revision"
test "$(git -C "$checkout" rev-parse HEAD)" = "$revision"
for patch in uniffi-m12-wire-identity.patch uniffi-m14-p1-keypackage-storage.patch \
             uniffi-m14-p2-readonly-accessors.patch; do
  git -C "$checkout" apply --check "$root/$patch"
  git -C "$checkout" apply "$root/$patch"
done

# Packaging only: expose a static archive and build the SAME OpenSSL provider
# for iOS. No MLS or crypto-provider implementation is changed.
python3 - "$checkout" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1])
manifest = base / 'mls-rs-uniffi/Cargo.toml'
text = manifest.read_text()
old = 'crate-type = ["lib", "cdylib"]'
assert text.count(old) == 1
manifest.write_text(text.replace(old, 'crate-type = ["lib", "cdylib", "staticlib"]'))
provider = base / 'mls-rs-crypto-openssl/Cargo.toml'
text = provider.read_text()
old = 'openssl = { version = "0.10.40" }'
assert text.count(old) == 1
provider.write_text(text.replace(old, 'openssl = { version = "0.10.40", features = ["vendored"] }'))
PY

cp "$root/Cargo.lock" "$checkout/Cargo.lock"
# Test-only T3 adversary for the host-side matrix; not part of any patch.
mkdir -p "$checkout/mls-rs-uniffi/examples"
cp "$root/harness/m14_adversary.rs" "$checkout/mls-rs-uniffi/examples/"
