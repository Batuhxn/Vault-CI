#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
test "$(xcodebuild -version | sed -n '1s/^Xcode //p')" = 26.3
build="${RUNNER_TEMP:?}/mls-m13"
mkdir -p "$build"
"$root/prepare-upstream.sh" "$build/mls-rs"
cd "$build/mls-rs"
cargo +1.98.1 fmt --all -- --check
cargo +1.98.1 test --locked -p mls-rs-uniffi --lib
cargo +1.98.1 test --locked -p mls-rs-uniffi --test scenarios
cargo +1.98.1 clippy --locked -p mls-rs-uniffi --lib -- -D warnings
cargo +1.98.1 build --release --locked -p mls-rs-uniffi
mkdir -p "$root/swift/Sources/MLSBridge"
cargo +1.98.1 run --release --locked -p uniffi-bindgen -- generate \
  --library target/release/libmls_rs_uniffi.dylib --language swift \
  --out-dir "$build/bindings" --no-format
cp "$build/bindings/mls_rs_uniffi.swift" "$root/swift/Sources/MLSBridge/"

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo +1.98.1 build --release --locked -p mls-rs-uniffi --target "$target"
  library="target/$target/release/libmls_rs_uniffi.a"
  test -s "$library"
  file "$library"
  xcrun lipo -info "$library"
  test "$(xcrun lipo -archs "$library")" = arm64
done

mkdir -p "$build/headers"
cp "$build/bindings/mls_rs_uniffiFFI.h" "$build/headers/"
cp "$build/bindings/mls_rs_uniffiFFI.modulemap" "$build/headers/module.modulemap"
artifact="$root/swift/Artifacts/MLSBridgeFFI.xcframework"
mkdir -p "$(dirname "$artifact")"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libmls_rs_uniffi.a -headers "$build/headers" \
  -library target/aarch64-apple-ios-sim/release/libmls_rs_uniffi.a -headers "$build/headers" \
  -output "$artifact"
python3 - "$artifact" <<'PY'
import pathlib, plistlib, sys
artifact = pathlib.Path(sys.argv[1])
with (artifact / 'Info.plist').open('rb') as source:
    slices = plistlib.load(source)['AvailableLibraries']
assert len(slices) == 2
assert {(s['SupportedPlatform'], s.get('SupportedPlatformVariant', '')) for s in slices} == {('ios', ''), ('ios', 'simulator')}
assert all(s['SupportedArchitectures'] == ['arm64'] for s in slices)
for s in slices:
    archive = artifact / s['LibraryIdentifier'] / s['LibraryPath']
    assert archive.is_file()
    print('XCFramework:', s['LibraryIdentifier'], s['SupportedArchitectures'])
PY
