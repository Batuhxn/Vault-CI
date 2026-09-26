# MLS M1.3 Apple qualification scope

This branch exercises synthetic MLS identities and messages in an isolated
Swift Package. Its source and tests are separate from the application. It is
not a production integration or a release artifact.

The local anti-rollback design detects replacement of a current encrypted
state file with an older valid file **while the Keychain anchor remains
current**. AES.GCM authentication detects state file mutation and use of a
wrong local storage key. A missing Keychain key fails restore. A pending
Keychain marker fails restore, favoring safety over availability after a crash.

It does not protect against rollback of the entire physical device together
with its trusted Keychain state, or a permanently compromised unlocked
endpoint. The prototype does not establish durable power-loss ordering for
every iOS filesystem and Keychain failure mode. MLS lifecycle, identity trust,
KeyPackage persistence, and application security gates remain outside this
qualification.

The isolated test's identity material is sealed inside the protected payload
for restart testing. A production design must keep the private identity in a
separate device-only Keychain item and bind it to the claimed public identity.
No production MLS state, user identity, or real message content is used here.
