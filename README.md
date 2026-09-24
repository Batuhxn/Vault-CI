# VAULT — CI build snapshot

This repository is a build snapshot of an in-development iOS application. It
exists only to prove that the `Vault-App` target builds unsigned for
`iphoneos` (Debug and Release) on GitHub-hosted macOS runners. It is not the
development repository.

## Security status

- The relay transport in this code is a local development prototype.
- Relay traffic is plaintext and unauthenticated. It is not production-secure.
- Do not expose the relay to the public Internet.
- This repository is not evidence that end-to-end encryption is implemented.

## Build

Requires macOS, Xcode 26.3, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate --spec project.yml
xcodebuild -project Vault.xcodeproj -scheme Vault-App -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

CI: `.github/workflows/production-ios-build.yml` (manual `workflow_dispatch`).

## License

No license is granted. All rights reserved. No permission to reuse, modify, or
redistribute this code is given beyond what applicable copyright law otherwise
permits.
