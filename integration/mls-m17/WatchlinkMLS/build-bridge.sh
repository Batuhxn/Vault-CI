#!/usr/bin/env bash
# Builds the MLS bridge with the UNCHANGED M1.5 qualification recipe (same pin,
# SHA-256-verified patches, OpenSSL provider, Cargo.lock), then copies the
# generated bindings and XCFramework into this package.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
qualified="${1:?usage: build-bridge.sh <m15-device-qualification dir>}"
bash "$qualified/build-apple.sh"
rm -rf "$root/Sources/MLSBridge" "$root/Artifacts"
mkdir -p "$root/Sources/MLSBridge" "$root/Artifacts"
cp "$qualified/swift/Sources/MLSBridge/mls_rs_uniffi.swift" "$root/Sources/MLSBridge/"
cp -R "$qualified/swift/Artifacts/MLSBridgeFFI.xcframework" "$root/Artifacts/"
