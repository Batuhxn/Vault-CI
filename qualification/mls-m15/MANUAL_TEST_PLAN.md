# M1.5 real-device qualification: manual procedure

Run this on the physical iPhone with the Ad Hoc IPA of the isolated App ID
`com.batuhxn.watchlink.m15qual`. It is NOT Watchlink and cannot see Watchlink data.

Before you start:
- The iPhone has a passcode.
- Set Auto-Lock to 30 s or longer.
- Watch (Settings › Privacy › Analytics) is off for this session, or you
  don't share its crash data.

Only synthetic data is used. The app shows labels, PASS/FAIL, stateVersion,
OSStatus, and public fingerprints. Paste the report from **Copy Sanitized
Report** back for review after each block. **M1.5 is not PASS until every
required block below has real-device results.**

## Identity policy (explicit)

| Event | Local identity | Conversation | Required action |
|---|---|---|---|
| Unpair / explicit security reset | Deleted: anchor first, then identity, then state (with KeyPackages). The next pairing creates a **fresh identity**. | Retired. A fresh random `conversation_id` and fresh QR nonces are used. | Mutual QR re-pair |
| Reinstall, Keychain survives but state is gone | Not reused and not reconstructed | None | **Fail closed**. Explicit wipe, then mutual QR re-pair. |
| Reinstall, Keychain also removed by iOS | None | None | Mutual QR pairing as new |
| Kill / relaunch / reboot | Same identity | Same conversation | None |

## Block 0: setup (unlocked)

1. Install the IPA and open **M15 Qualification**.
2. Tap **Run Setup**, then **Create Protected State**.
3. Expected results:
   - PASS for Create Protected State.
   - Keychain accessibility = `WhenUnlockedThisDeviceOnly` for anchor and
     identity (both simulated devices).
   - Data Protection class `NSFileProtectionComplete` on both `state.aead`
     files after atomic replacement.
4. Note the conversation id, fingerprints, and stateVersion from the report.

## Block 1: Keychain + Data Protection while locked

1. Tap **Lock Test**, and within 5 s press the side button to lock.
2. Leave the phone locked for **25 s**. Protected data typically becomes
   unavailable about 10 s after the lock.
3. Unlock, return to the app, and tap **Lock Test: Verify After Unlock**.
4. Expected results:
   - While `protectedData=false`: anchor and identity `OSStatus=-25308`
     (`errSecInteractionNotAllowed`).
   - The class-C control item (`AfterFirstUnlockThisDeviceOnly`) is still `0`.
   - The protected state file is unreadable, and restore reports `Closed`.
   - After unlock: the same fingerprints and the same stateVersion. No
     regeneration, reset, or new session.
5. If "protected data never became unavailable" appears, repeat and lock
   sooner.

## Block 2: lock during a state-changing operation

1. Tap **Lock During Operation**, and within 5 s lock the phone. Leave it
   locked for 25 s.
2. Unlock and tap **Lock During Operation: Verify**.
3. Accept either result per device:
   - **Outcome A**: consistent restore.
   - **Outcome B**: fail closed on the pending marker; the committed state is
     untouched.

   `Lock During Operation (ordering)` must be PASS, meaning no outbound bytes
   were released before a durable commit.
4. If outcome B occurred, tap **Run Setup** and **Create Protected State**
   before continuing.

## Block 3: force-kill cases (app switcher swipe-up = force-kill)

| Case | Start | Kill | Relaunch, then tap | Expected |
|---|---|---|---|---|
| A: clean state | (Block 0 state) | yes | **Relaunch Test** | Same fingerprints, conversation, and stateVersion; messaging works |
| B: pending commit | **Pending Commit Test** | yes | **Pending Commit: Finish** | Same outbound sha256; send blocked while pending; byte-identical resend accepted; peer follows |
| C: KeyPackage | **KeyPackage Test** | yes | **KeyPackage: Finish** | KeyPackage survived; Welcome joins once; second join rejected |
| D: hard stop | **Hard Stop Test** | yes | **Hard Stop: Finish** | `identityChanged` persists; operations blocked; no re-pin |

## Block 4: reboot + first unlock (two explicit steps)

1. Tap **Reboot Test: Prepare**. It records only the boot identity, the
   fingerprints, the conversation, and the stateVersion, and marks the reboot
   test pending. It shows `REBOOT_PENDING` and claims **nothing**.
2. Optionally tap **KeyPackage Test** too (outstanding KeyPackage across the
   reboot).
3. Power off and power on the phone. **Do not unlock yet.** Before the first
   unlock, iOS does not run the app, so the app cannot observe this window.
   It is covered by Block 1 (class A / WhenUnlocked unavailable while locked).
4. Unlock for the first time, open the app, and tap **Reboot Test: Verify**.
   If you did step 2, also tap **KeyPackage: Finish**.
5. Expected results:
   - `REBOOT_OBSERVED`, then PASS for the same identity, the same
     conversation, the expected stateVersion, and restored messaging.
   - A reboot counts only if the current boot started after Prepare
     (`kern.boottime` later than the Prepare moment) and the boot session
     changed, where iOS reports one.
   - Without a real reboot, the result is `REBOOT_NOT_OBSERVED` with no PASS,
     and the test stays pending. Relaunch-only restores are Block 3A
     evidence, not reboot evidence.

## Block 5: wipe / re-pair

1. Tap **Wipe Test**.
2. Expected results:
   - Restore unavailable, and anchor `OSStatus=-25300` (not found).
   - The protected state is gone.
   - Fresh identities.
   - A fresh `conversation_id` and QR nonce.
   - The retired `conversation_id` is rejected by the device and the relay.

## Block 6: reinstall (may be PARTIAL)

1. Tap **Run Setup** and **Create Protected State**.
2. Delete the app (long-press › Remove App › Delete App).
3. Reinstall the same IPA, open it, and tap **Reinstall Check**.
4. Expected results:
   - If the Keychain survived: PASS "leftover Keychain … FAIL CLOSED;
     explicit wipe required".
   - If iOS removed the Keychain items: INFO "no leftover qualification
     Keychain marker". Report this as PARTIAL, not PASS.
5. Tap **Explicit Wipe** to clean up.

## Block 7: plaintext / local storage

1. Tap **Plaintext Scan**. It scans every readable file in the app
   container for the synthetic marker strings and their base64 form, and for
   leftover temporary files.
2. Expected result: PASS, with 0 hits and 0 temporary files.
3. Crash reports: the app never writes protected content to logs. Confirming
   that no crash report exists is manual (Settings › Privacy › Analytics
   Data). Do not share unrelated entries.

## Required for `MLS_REAL_DEVICE_SECURITY_PASS`

Real-device PASS lines for all of the following:
- Block 1 (locked OSStatus and verify)
- Block 3 A–D
- Block 4
- Block 5
- Block 7
- Block 0 accessibility and protection class
- Block 2 ordering + outcome A or B

Block 6 may be PARTIAL if iOS removes the Keychain items or the reinstall
cannot be reproduced.
