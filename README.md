# Watchlink — CI build snapshot

This repository is a generated, sanitised snapshot of an in-development iOS
application. It exists only to run CI on GitHub-hosted macOS runners: the
production unit tests, the unsigned `Vault-App` builds, and manually dispatched
signed builds. It is not the development repository. Do not edit it by hand;
changes are overwritten by the next sync.

The source here is identical to the development source except for one
documented rewrite: the local test-relay host is replaced with the loopback
placeholder `127.0.0.1`.

## Security status

- The relay transport in this code is a local development prototype.
- Relay traffic is plaintext and unauthenticated. It is not production-secure.
- Do not expose the relay to the public Internet.
- This repository is not evidence that end-to-end encryption is implemented.

## Build and test

Requires macOS, Xcode 26.3, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate --spec project.yml
xcodebuild test -project Vault.xcodeproj -scheme Vault-App \
  -destination 'platform=iOS Simulator,name=<an installed iPhone simulator>' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project Vault.xcodeproj -scheme Vault-App -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## CI

All workflows are manual-only (`workflow_dispatch`). None runs on push, pull
request, or schedule.

- `.github/workflows/production-ios-build.yml`: logging guard, unit tests on an
  iOS Simulator, unsigned Debug/Release iPhoneOS builds. No credentials.
- `.github/workflows/testflight.yml`: signed App Store Connect IPA; uploads
  only when the `upload` input is explicitly `true`. The IPA is never published
  as an artifact.

## License

No license is granted. All rights reserved. No permission to reuse, modify, or
redistribute this code is given beyond what applicable copyright law otherwise
permits.
