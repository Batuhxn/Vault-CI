#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
test "$(xcodebuild -version | sed -n '1s/^Xcode //p')" = 26.3
build="${RUNNER_TEMP:?}/mls-m14"
mkdir -p "$build"
bash "$root/prepare-upstream.sh" "$build/mls-rs"
python3 "$root/check-p2-readonly.py" "$root/uniffi-m14-p2-readonly-accessors.patch"
cd "$build/mls-rs"
cargo +1.98.1 fmt --all -- --check
cargo +1.98.1 test --locked -p mls-rs-uniffi --lib
cargo +1.98.1 test --locked -p mls-rs-uniffi --test scenarios
cargo +1.98.1 clippy --locked -p mls-rs-uniffi --lib -- -D warnings
cargo +1.98.1 build --locked -p mls-rs-uniffi --example m14_adversary
cargo +1.98.1 build --release --locked -p mls-rs-uniffi
mkdir -p "$root/swift/Sources/MLSBridge" "$build/python"
cargo +1.98.1 run --release --locked -p uniffi-bindgen -- generate \
  --library target/release/libmls_rs_uniffi.dylib --language swift \
  --out-dir "$build/bindings" --no-format
cp "$build/bindings/mls_rs_uniffi.swift" "$root/swift/Sources/MLSBridge/"
target/release/uniffi-bindgen generate --library target/release/libmls_rs_uniffi.dylib \
  --language python --out-dir "$build/python"
cp target/release/libmls_rs_uniffi.dylib "$build/python/"

# Align Rust and vendored OpenSSL C objects to the package's iOS 17 floor.
# Without this, Clang chooses the Xcode SDK version while rustc links for 10.0.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo +1.98.1 build --release --locked -p mls-rs-uniffi --target "$target"
  library="target/$target/release/libmls_rs_uniffi.a"
  test -s "$library"
  file "$library"
  xcrun lipo -info "$library"
  case "$target" in
    x86_64-apple-ios) test "$(xcrun lipo -archs "$library")" = x86_64 ;;
    *) test "$(xcrun lipo -archs "$library")" = arm64 ;;
  esac
done

mkdir -p "$build/simulator"
xcrun lipo -create \
  target/aarch64-apple-ios-sim/release/libmls_rs_uniffi.a \
  target/x86_64-apple-ios/release/libmls_rs_uniffi.a \
  -output "$build/simulator/libmls_rs_uniffi.a"
xcrun lipo -info "$build/simulator/libmls_rs_uniffi.a"

mkdir -p "$build/headers"
cp "$build/bindings/mls_rs_uniffiFFI.h" "$build/headers/"
cp "$build/bindings/mls_rs_uniffiFFI.modulemap" "$build/headers/module.modulemap"
artifact="$root/swift/Artifacts/MLSBridgeFFI.xcframework"
mkdir -p "$(dirname "$artifact")"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libmls_rs_uniffi.a -headers "$build/headers" \
  -library "$build/simulator/libmls_rs_uniffi.a" -headers "$build/headers" \
  -output "$artifact"
python3 - "$artifact" <<'PY'
import pathlib, plistlib, sys
artifact = pathlib.Path(sys.argv[1])
with (artifact / 'Info.plist').open('rb') as source:
    slices = plistlib.load(source)['AvailableLibraries']
assert {(s['SupportedPlatform'], s.get('SupportedPlatformVariant', '')):
        set(s['SupportedArchitectures']) for s in slices} == {
    ('ios', ''): {'arm64'}, ('ios', 'simulator'): {'arm64', 'x86_64'}}
for s in slices:
    assert (artifact / s['LibraryIdentifier'] / s['LibraryPath']).is_file()
    print('XCFramework:', s['LibraryIdentifier'], s['SupportedArchitectures'])
PY
