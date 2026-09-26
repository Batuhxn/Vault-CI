# MLS M1.4 Apple qualification scope

This branch exercises the MLS lifecycle and peer-trust model with synthetic
identities and messages in an isolated Swift package, hosted by an empty
qualification app so the simulator grants real Keychain access. It is not a
production integration, a release artifact, or a production relay.

Pinned upstream `mls-rs` (see `UPSTREAM_REVISION`) with its existing OpenSSL
provider, plus three delegate-only UniFFI patches whose SHA-256 values are
verified before use (`PATCHES.sha256`): M1.2 wire/identity, P1 foreign
KeyPackage storage, P2 read-only identity/roster/epoch accessors.

Qualified locally: one staging transaction for group state, epoch records,
KeyPackages, outbound commit bytes, pins and lifecycle; fail-closed crash
windows; exact outbound resend; relay commit sequencing whose metadata is
checked, never trusted; current + one prior epoch retention; mutual QR pin
exchange (payload data only, no camera); roster enforcement and hard stops.

Out of scope: the production relay, QR/camera UI, the production
CryptoEngine, real-device Data Protection and device-lock behavior (M1.5),
rollback of the whole device together with its Keychain, a permanently
compromised unlocked endpoint, and zeroization of secret buffers crossing
UniFFI/Swift. The protected group envelope contains the MLS signing key
(pinned upstream snapshot) and is treated as identity-class secret.
