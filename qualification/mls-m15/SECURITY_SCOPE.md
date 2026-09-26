# MLS M1.5 real-device qualification scope

An isolated qualification app (App ID `com.batuhxn.watchlink.m15qual`) that
reuses the M1.4-qualified Swift components to observe, on a physical iPhone,
what the simulator cannot prove: Keychain `WhenUnlockedThisDeviceOnly`
behavior while locked, `NSFileProtectionComplete` on the protected state,
lock during a transaction, force-kill, reboot + first unlock, pending-commit
and KeyPackage recovery, persistent hard stops, wipe/re-pair, reinstall with
leftover Keychain items, and absence of plaintext in local files.

Synthetic identities and messages only. It is not Watchlink, is not part of
the Watchlink runtime, uses the qualification relay model (not the
production relay) and no QR camera. Results report labels, PASS/FAIL,
stateVersion, OSStatus and public fingerprints only. The signed IPA is
built only on manual dispatch and uploaded only encrypted, 1-day retention.

Pinned `mls-rs` (`UPSTREAM_REVISION`) with its OpenSSL provider plus the
SHA-256-verified M1.2, P1 and P2 patches (`PATCHES.sha256`). Additions over
M1.4: a persistable relay model (public wire bytes only) and non-secret
transaction stage events.

Out of scope: rollback of the whole device with its Keychain, a permanently
compromised unlocked endpoint, the production relay, QR camera UX, the
production CryptoEngine, TestFlight.
