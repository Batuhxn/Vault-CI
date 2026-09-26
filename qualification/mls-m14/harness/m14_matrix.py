"""M1.4A/M1.4B Linux qualification matrix. Prints one label per check only.

usage: m14_matrix.py WORK_DIR            run everything
       m14_matrix.py child OP CASE_DIR   crash-injection child (M14_CRASH=point)
The key-changing adversary binary path comes from M14_ADVERSARY.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from mls_rs_uniffi import (Client, ClientConfig, Error as MlsError, Message, SignatureKeypair,
                           SignaturePublicKey, SignatureSecretKey, generate_signature_keypair)

from m12_secure_persistence import ClosedError, MemoryGroupStorage, b64, canonical, unb64
from m14_lifecycle import (
    DOMAIN, KEY_PACKAGE_TTL, PIN_DOMAIN, QR_TTL, SUITE, Device, IdentityChanged, Rejected,
    Relay, RelayViolation, Store, Violation, identity_pin, make_qr, member_pin,
)

RESULTS = []


def check(label, condition=True):
    if not condition:
        raise AssertionError(label)
    RESULTS.append(label)
    print(f"{label}: PASS")


def raises(kind, action):
    try:
        action()
    except kind as exc:
        return exc
    raise AssertionError(f"expected {kind.__name__}")


class Clock:
    def __init__(self):
        self.now = 1_900_000_000

    def __call__(self):
        return self.now


def peek(root):
    """Decrypt the on-disk document even when a pending marker is present.

    The anchor stores the reserved version too, so an un-anchored replaced
    file (crash after replace) can be inspected; restore still refuses it.
    """
    anchor = json.loads((Path(root) / "anchor.json").read_bytes())
    envelope = json.loads((Path(root) / "state.aead").read_bytes())
    version = envelope["stateVersion"]
    assert version in (anchor["committedVersion"], anchor["pendingVersion"])
    inner = AESGCM(unb64(anchor["storageKey"])).decrypt(
        unb64(envelope["nonce"]), unb64(envelope["ciphertext"]), DOMAIN + version.to_bytes(8, "big"))
    return json.loads(inner)["document"], anchor


def durable_snapshot(root):
    return (Path(root) / "anchor.json").read_bytes(), (Path(root) / "state.aead").read_bytes()


def welcome_for(device):
    conversation = unb64(device.document["conversation"])
    return [e for e in device.relay.fetch(conversation, device.name, 0) if e["kind"] == "welcome"]


def pair(base, clock, relay=None):
    base.mkdir(parents=True, exist_ok=True)
    relay = relay or Relay(base / "relay.json")
    a = Device.setup(base / "a", "alice", relay, clock)
    b = Device.setup(base / "b", "bob", relay, clock)
    b_qr = b.scan_initiator(a.start_pairing())
    a.scan_responder(b_qr)
    check_status = a.add_peer()
    b.accept_welcome(welcome_for(b)[0])
    assert check_status == "ACCEPTED"
    return a, b, relay


def reopen(device, relay=None):
    return Device(device.root, device.name, relay or device.relay, device.clock).open()


def clone(base, name, *devices):
    """Copy devices plus their relay into an isolated case directory."""
    case = base / name
    case.mkdir(parents=True)
    shutil.copy2(devices[0].relay.path, case / "relay.json")
    relay = Relay(case / "relay.json")
    copies = []
    for device in devices:
        shutil.copytree(device.root, case / device.root.name)
        copies.append(Device(case / device.root.name, device.name, relay, device.clock).open())
    return (*copies, relay)


# ---------------------------------------------------------------- pin + QR --

def pin_and_qr(base):
    expected = hashlib.sha256(PIN_DOMAIN + b"\0\0\0\x02ab" + b"\0\0\0\x01c").digest()
    check("PIN canonical u32be length encoding", identity_pin(b"ab", b"c") == expected)
    check("PIN no concatenation ambiguity", identity_pin(b"ab", b"c") != identity_pin(b"a", b"bc"))

    clock = Clock()
    relay = Relay(base / "qr-relay.json")
    a = Device.setup(base / "qr-a", "alice", relay, clock)
    b = Device.setup(base / "qr-b", "bob", relay, clock)
    item = json.loads((b.root / "identity.json").read_bytes())
    same = Client(b"bob", SignatureKeypair(cipher_suite=SUITE,
                                           public_key=SignaturePublicKey(bytes=unb64(item["public"])),
                                           secret_key=SignatureSecretKey(bytes=unb64(item["secret"]))),
                  ClientConfig(group_state_storage=MemoryGroupStorage(), use_ratchet_tree_extension=True))
    check("PIN own pin equals pin of own KeyPackage identity",
          member_pin(Message.from_bytes(same.generate_key_package_message().to_bytes())
                     .key_package_signing_identity()) == b.own_pin)
    qr_a = a.start_pairing()
    check("T8 QR holds exactly version, conversation, nonce, pin, expiry",
          set(json.loads(qr_a)) == {"v", "cid", "nonce", "pin", "exp"})
    check("T8 QR carries no signing key bytes",
          unb64(json.loads((a.root / "identity.json").read_bytes())["secret"]) not in qr_a)

    clock.now += QR_TTL
    raises(Rejected, lambda: b.scan_initiator(qr_a))
    check("T8 stale (expired) QR rejected", peek(b.root)[0]["lifecycle"] == "unpaired")
    clock.now -= QR_TTL
    qr_b = b.scan_initiator(qr_a)
    b.abort_pairing()
    check("L3 aborted pairing deletes the outstanding KeyPackage", peek(b.root)[0]["keyPackages"] == {})
    raises(Rejected, lambda: b.scan_initiator(qr_a))
    check("T8 duplicate QR nonce rejected after abort")

    document = json.loads(qr_b)
    raises(Rejected, lambda: a.scan_responder(make_qr(os.urandom(16), unb64(document["nonce"]),
                                                      unb64(document["pin"]), document["exp"])))
    check("T8 responder QR for another conversation rejected")
    raises(Rejected, lambda: a.scan_responder(make_qr(unb64(document["cid"]), unb64(json.loads(qr_a)["nonce"]),
                                                      unb64(document["pin"]), document["exp"])))
    check("T8 responder QR reusing the initiator nonce rejected")
    raises(Rejected, lambda: a.scan_responder(b'{"v":2}'))
    check("T8 malformed/unsupported QR rejected")


# ------------------------------------------------- establishment + trust --

def establishment(base):
    clock = Clock()
    a, b, relay = pair(base / "est", clock)
    conversation = unb64(a.document["conversation"])
    check("T1 mutual QR pins, KeyPackage matches pin, conversation established",
          a.document["lifecycle"] == b.document["lifecycle"] == "established"
          and a.group.current_epoch() == b.group.current_epoch() == 1)
    check("KP consumed KeyPackage deleted on join", b.document["keyPackages"] == {})

    solo = a.client.create_group(os.urandom(16))
    a.check_roster(solo, established=False)
    raises(IdentityChanged, lambda: a.check_roster(solo, established=True))
    raises(IdentityChanged, lambda: a.check_roster(a.group, established=False))
    a.check_roster(a.group, established=True)
    check("ROSTER cardinality: exactly {own} before join, exactly {own, peer} after")

    a.send(b"m14 probe one")
    sender_ok = b.sync() == [b"m14 probe one"]
    check("T5 application sender resolves to the pinned peer", sender_ok)
    b.send(b"m14 probe two")
    check("L-msg bidirectional after establishment", a.sync() == [b"m14 probe two"])
    return a, b, relay, conversation


def l1_restart_control(base):
    # Upstream default (no P1 storage): KeyPackage secrets die with the process.
    key = generate_signature_keypair(SUITE)
    before = Client(b"bob", key, ClientConfig(group_state_storage=MemoryGroupStorage(), use_ratchet_tree_extension=True))
    kp = before.generate_key_package_message().to_bytes()
    alice = Client(b"alice", generate_signature_keypair(SUITE),
                   ClientConfig(group_state_storage=MemoryGroupStorage(), use_ratchet_tree_extension=True))
    welcome = alice.create_group(None).add_members([Message.from_bytes(kp)]).welcome_message
    after = Client(b"bob", key, ClientConfig(group_state_storage=MemoryGroupStorage(), use_ratchet_tree_extension=True))
    raises(MlsError, lambda: after.join_group(None, welcome))
    check("L1 control: without P1 a restarted client cannot join (proves the gap)")

    clock = Clock()
    relay = Relay(base / "l1-relay.json")
    a = Device.setup(base / "l1-a", "alice", relay, clock)
    b = Device.setup(base / "l1-b", "bob", relay, clock)
    a.scan_responder(b.scan_initiator(a.start_pairing()))
    b = reopen(b)  # process restart between KeyPackage publish and Welcome
    a.add_peer()
    b.accept_welcome(welcome_for(b)[0])
    check("L1 restart between KeyPackage publish and Welcome: join succeeds",
          b.document["lifecycle"] == "established")


def keypackage_rules(base):
    clock = Clock()
    relay = Relay(base / "kp-relay.json")
    a = Device.setup(base / "kp-a", "alice", relay, clock)
    b = Device.setup(base / "kp-b", "bob", relay, clock)
    a.scan_responder(b.scan_initiator(a.start_pairing()))
    a.add_peer()
    welcome = welcome_for(b)[0]

    b_copy, relay_copy = clone(base, "kp-one", b)
    b_copy.store.begin()
    raises(MlsError, lambda: b_copy.client.generate_key_package_message())
    check("KP exactly one outstanding KeyPackage enforced", b_copy.store.callback_failed)

    before = durable_snapshot(b.root)
    clock.now += KEY_PACKAGE_TTL + 1
    raises(Rejected, lambda: b.accept_welcome(welcome))
    check("L3 expired outstanding KeyPackage: Welcome rejected, durable state unchanged",
          durable_snapshot(b.root) == before and b.document["lifecycle"] == "joinPending")
    b.abort_pairing()
    check("L3 expired package removed by explicit abort", b.document["keyPackages"] == {})

    # Unknown package: a Welcome for this conversation that targets another KeyPackage.
    clock.now = Clock().now
    b2 = Device.setup(base / "kp-b2", "bob", relay, clock)
    a2 = Device.setup(base / "kp-a2", "alice", relay, clock)
    b2.scan_initiator(a2.start_pairing())
    other = Client(b"bob", generate_signature_keypair(SUITE),
                   ClientConfig(group_state_storage=MemoryGroupStorage(),
                                use_ratchet_tree_extension=True))
    group = Client(b"alice", generate_signature_keypair(SUITE),
                   ClientConfig(group_state_storage=MemoryGroupStorage(),
                                use_ratchet_tree_extension=True)).create_group(unb64(b2.document["conversation"]))
    foreign = group.add_members([Message.from_bytes(other.generate_key_package_message().to_bytes())])
    before = durable_snapshot(b2.root)
    raises(Rejected, lambda: b2.accept_welcome({"cid": unb64(b2.document["conversation"]), "seq": 99,
                                                "kind": "welcome", "base": None,
                                                "data": foreign.welcome_message.to_bytes()}))
    check("L2 Welcome for unknown KeyPackage rejected before any durable change",
          durable_snapshot(b2.root) == before)


def welcome_state_machine(base, a, b):
    welcome = welcome_for(b)[0]
    before = durable_snapshot(b.root)
    raises(Rejected, lambda: b.accept_welcome(welcome))
    check("L5 Welcome for an established conversation rejected; durable unchanged",
          durable_snapshot(b.root) == before)
    raises(MlsError, lambda: b.client.join_group(None, Message.from_bytes(welcome["data"])))
    check("L2/L5 consumed KeyPackage deleted: same Welcome cannot join even bypassing policy")


def join_failure_windows(base):
    clock = Clock()
    relay = Relay(base / "jf-relay.json")
    a = Device.setup(base / "jf-a", "alice", relay, clock)
    b = Device.setup(base / "jf-b", "bob", relay, clock)
    a.scan_responder(b.scan_initiator(a.start_pairing()))
    a.add_peer()
    b_copy, _ = clone(base, "jf-delete-error", b)
    b_copy.store.fail_at = "kp-delete"
    raises(ClosedError, lambda: b_copy.accept_welcome(welcome_for(b_copy)[0]))
    document, anchor = peek(b_copy.root)
    raises(ClosedError, lambda: reopen(b_copy))
    check("L4b group write ok + KeyPackage delete error: no durable partial state, fail closed",
          anchor["pendingVersion"] is not None and document["lifecycle"] == "joinPending"
          and document["groups"] == {} and b_copy.client is None)
    return a, b


# ------------------------------------------------ rejected input (release) --

def versions(device):
    anchor = json.loads((device.root / "anchor.json").read_bytes())
    return anchor["committedVersion"], anchor["pendingVersion"]


def rejected_input(base, a, b):
    a1, b1, relay1 = clone(base, "rejected", a, b)
    conversation = unb64(a1.document["conversation"])
    wire = a1.send(b"real after garbage")
    start = versions(b1)

    def envelope(data, seq=10**6):
        return {"cid": conversation, "seq": seq, "kind": "application", "base": None, "data": data}

    raises(Rejected, lambda: b1.receive(envelope(b"\x00 not mls")))
    check("RJ malformed MLS bytes rejected before any transaction", versions(b1) == start)
    corrupt = bytearray(wire)
    corrupt[-1] ^= 1
    raises(Rejected, lambda: b1.receive(envelope(bytes(corrupt))))
    check("RJ well-formed but invalid MLS input: reservation released, version unchanged",
          versions(b1) == start)
    check("RJ restart afterwards succeeds from unchanged durable state", reopen(b1).group is not None)
    for i in range(100):
        raises(Rejected, lambda: b1.receive(envelope(bytes(corrupt), 10**6 + i)))
    check("RJ 100 repeated invalid inputs do not brick the conversation",
          versions(b1) == start and b1.sync() == [b"real after garbage"])

    start = versions(b1)
    x, _, _ = pair(base / "rejected-other", Clock())
    raises(Rejected, lambda: b1.receive(envelope(x.send(b"other group"), 2 * 10**6)))
    check("RJ rejected wrong-group message does not alter stateVersion", versions(b1) == start)
    check("RJ stale relay envelope (seq <= lastSeq) ignored without a transaction",
          b1.receive(dict(envelope(wire), seq=1)) is None and versions(b1) == start)

    def mutate_then_fail(document):
        b1.group.write_to_storage()  # a mutation callback fires
        raise Rejected("policy refusal after a mutation")
    raises(ClosedError, lambda: b1.transact(mutate_then_fail))
    committed, pending = versions(b1)
    raises(ClosedError, lambda: reopen(b1))
    check("RJ mutation callback before an error: reservation NOT released, fails closed",
          committed == start[0] and pending == committed + 1)


# ------------------------------------------------------- crash matrix (L4) --

def child(op, case):
    relay = Relay(case / "relay.json")
    a = Device(case / "a", "alice", relay).open()
    b = Device(case / "b", "bob", relay).open()
    if op == "keypackage":
        b.scan_initiator((case / "qr-a").read_bytes())
    elif op == "join":
        b.accept_welcome(welcome_for(b)[0])
    elif op == "commit":
        a.update()
    elif op == "process":
        b.sync()
    os._exit(0)


def crash_matrix(base):
    stages = {}
    relay = Relay(base / "crash-stage-kp" / "relay.json")
    a = Device.setup(base / "crash-stage-kp" / "a", "alice", relay)
    b = Device.setup(base / "crash-stage-kp" / "b", "bob", relay)
    (base / "crash-stage-kp" / "qr-a").write_bytes(a.start_pairing())
    relay.save()
    stages["keypackage"] = base / "crash-stage-kp"

    shutil.copytree(stages["keypackage"], base / "crash-stage-join")
    relay = Relay(base / "crash-stage-join" / "relay.json")
    a = Device(base / "crash-stage-join" / "a", "alice", relay).open()
    b = Device(base / "crash-stage-join" / "b", "bob", relay).open()
    a.scan_responder(b.scan_initiator((base / "crash-stage-join" / "qr-a").read_bytes()))
    a.add_peer()
    stages["join"] = base / "crash-stage-join"

    shutil.copytree(stages["join"], base / "crash-stage-est")
    relay = Relay(base / "crash-stage-est" / "relay.json")
    b = Device(base / "crash-stage-est" / "b", "bob", relay).open()
    b.accept_welcome(welcome_for(b)[0])
    stages["commit"] = base / "crash-stage-est"

    shutil.copytree(stages["commit"], base / "crash-stage-proc")
    relay = Relay(base / "crash-stage-proc" / "relay.json")
    Device(base / "crash-stage-proc" / "a", "alice", relay).open().update()
    stages["process"] = base / "crash-stage-proc"

    matrix = {
        "keypackage": ["reserved", "written", "replaced", "anchored"],
        "join": ["reserved", "group-written", "kp-delete", "written", "replaced", "anchored"],
        "commit": ["reserved", "group-written", "written", "replaced", "anchored"],
        "process": ["reserved", "group-written", "written", "replaced", "anchored"],
    }
    target = {"keypackage": "b", "join": "b", "commit": "a", "process": "b"}
    for op, points in matrix.items():
        for point in points:
            case = base / f"crash-{op}-{point}"
            shutil.copytree(stages[op], case)
            relay_before = (case / "relay.json").read_bytes()
            result = subprocess.run([sys.executable, __file__, "child", op, str(case)],
                                    env={**os.environ, "M14_CRASH": point}, capture_output=True)
            assert result.returncode == 90, (op, point, result.returncode)
            relay = Relay(case / "relay.json")
            name = {"a": "alice", "b": "bob"}[target[op]]
            released = (case / "relay.json").read_bytes() != relay_before
            if point == "anchored":
                device = Device(case / target[op], name, relay).open()
                document = device.document
                if op == "keypackage":
                    ok = document["lifecycle"] == "joinPending" and len(document["keyPackages"]) == 1 \
                        and any(o["kind"] == "keypackage" for o in document["outbound"])
                elif op == "join":
                    ok = document["lifecycle"] == "established" and document["keyPackages"] == {}
                elif op == "commit":
                    ok = document["pendingCommit"] is not None and device.send_pending() == "ACCEPTED"
                else:
                    ok = device.group.current_epoch() == 2
            else:
                raises(ClosedError, lambda: Device(case / target[op], name, relay).open())
                document, _ = peek(case / target[op])
                _, anchor = peek(case / target[op])
                unanchored = json.loads((case / target[op] / "state.aead").read_bytes())["stateVersion"] \
                    != anchor["committedVersion"]
                ok = op != "join" or unanchored or (document["groups"] == {} and len(document["keyPackages"]) == 1)
            ok = ok and not released
            check(f"L4 crash {op}@{point}: {'new state restores' if point == 'anchored' else 'fails closed, nothing released'}", ok)
            if op == "join" and point == "kp-delete":
                check("L4a group state written, process dies before KeyPackage delete: no partial state", ok)


# ---------------------------------------------------- commits + relay (L6/7) --

class OfflineRelay:
    def __init__(self, relay):
        self.relay = relay

    def post(self, *args):
        raise ConnectionError("relay unreachable")

    def __getattr__(self, name):
        return getattr(self.relay, name)


def pending_commits(base, a, b, relay):
    a1, b1, relay1 = clone(base, "pending", a, b)
    a1.relay = OfflineRelay(relay1)
    raises(ConnectionError, a1.update)
    persisted = unb64(a1.document["outbound"][0]["data"])
    raises(Rejected, lambda: a1.send(b"blocked while pending"))
    check("L6 no application messages while a commit is unresolved")
    a1 = reopen(a1, relay1)
    check("L6 restart keeps pending commit and its exact outbound bytes",
          unb64(a1.document["outbound"][0]["data"]) == persisted)
    status = a1.send_pending()
    conversation = unb64(a1.document["conversation"])
    accepted = [e for e in relay1.fetch(conversation, "bob", 0) if e["kind"] == "commit"][-1]
    check("L6 resend is byte-identical and accepted", status == "ACCEPTED" and accepted["data"] == persisted)
    again = relay1.post(conversation, "commit", accepted["base"], persisted, "alice")
    check("L6 relay idempotent retransmission acknowledgement", again == ("ACCEPTED", accepted["seq"]))
    b1.sync()
    check("L6 peer follows the resent commit", b1.group.current_epoch() == a1.group.current_epoch())

    a2, relay2 = clone(base, "pending-missing", a)
    a2.relay = OfflineRelay(relay2)
    raises(ConnectionError, a2.update)
    a2.store.begin()
    a2.store.staging["outbound"] = []  # models a bug losing the queue, validly re-sealed
    a2.store.commit()
    raises(RelayViolation, lambda: reopen(a2, relay2))
    check("L6a pending commit with missing outbound bytes: HARD STOP persisted",
          peek(a2.root)[0]["security"] == "halted")


def concurrent_commits(base, a, b):
    a1, b1, relay1 = clone(base, "concurrent", a, b)
    epoch = a1.group.current_epoch()
    check("L7 first commit from epoch N accepted", a1.update() == "ACCEPTED")
    b_log = len(relay1.fetch(unb64(a1.document["conversation"]), "alice", 0))
    check("L7 competing commit from the same epoch is STALE", b1.update() == "STALE")
    check("L7 loser processed the winner; mls-rs cleared its pending commit; no fork",
          b1.group.current_epoch() == epoch + 1 and b1.document["pendingCommit"] is None
          and len(relay1.fetch(unb64(a1.document["conversation"]), "alice", 0)) == b_log)
    check("L7 loser retries a NEW update from the new epoch", b1.update() == "ACCEPTED")
    a1.sync()
    a1.send(b"after concurrency")
    check("L7 both converge and keep messaging",
          a1.group.current_epoch() == b1.group.current_epoch() == epoch + 2
          and b1.sync() == [b"after concurrency"])


def relay_model(base, a, b):
    relay = Relay(base / "relay-rules.json")
    conversation = os.urandom(16)
    first = relay.post(conversation, "commit", 0, b"commit-x", "alice")
    check("L7a relay: base == current accepted once", first == ("ACCEPTED", 1))
    check("L7a relay: same bytes again = idempotent ack", relay.post(conversation, "commit", 0, b"commit-x", "alice") == first)
    check("L7a relay: different bytes for accepted base = STALE",
          relay.post(conversation, "commit", 0, b"commit-y", "bob") == ("STALE", 1))
    check("L7a relay: future base rejected", relay.post(conversation, "commit", 5, b"z", "bob")[0] == "REJECT")
    relay.retire(conversation)
    check("L7a relay: retired conversation rejected", relay.post(conversation, "commit", 1, b"z", "bob")[0] == "REJECT")

    a1, b1, relay1 = clone(base, "relay-lie", a, b)
    a1.update()
    conversation = unb64(a1.document["conversation"])
    real = [e for e in relay1.fetch(conversation, "bob", b1.document["lastSeq"]) if e["kind"] == "commit"][0]
    lie = dict(real, base=real["base"] + 1)
    raises(RelayViolation, lambda: b1.receive(lie))
    check("L7a relay lying about base_epoch: HARD STOP", peek(b1.root)[0]["security"] == "halted")

    a2, b2, relay2 = clone(base, "relay-replay", a, b)
    a2.update()
    b2.sync()
    old = [e for e in relay2.fetch(unb64(a2.document["conversation"]), "bob", 0) if e["kind"] == "commit"][-1]
    replay = dict(old, base=b2.group.current_epoch(), seq=old["seq"] + 100)
    raises(RelayViolation, lambda: b2.receive(replay))
    check("L7a relay replaying an accepted commit with wrong metadata: HARD STOP",
          peek(b2.root)[0]["security"] == "halted")


# ------------------------------------------------------------ epochs (L8) --

def epoch_retention(base, a, b):
    a1, b1, relay1 = clone(base, "epochs", a, b)
    conversation = unb64(a1.document["conversation"])

    def held(device, plaintext):
        """Encrypt durably but let the relay 'delay' delivery (not posted)."""
        def operation(document):
            wire = device.group.encrypt_application_message(plaintext).to_bytes()
            device.group.write_to_storage()
            return wire
        return device.transact(operation)

    def deliver(device, wire, seq):
        return device.receive({"cid": conversation, "seq": seq, "kind": "application",
                               "base": None, "data": wire})

    delayed_n1 = held(a1, b"from n-1")
    b1.update()  # B: n-1 -> n; A has not seen it yet
    n = b1.group.current_epoch()
    before = dict(b1.document["groups"][b64(conversation)]["epochs"])
    check("L8 delayed message from n-1 decrypts at n", deliver(b1, delayed_n1, 10_000) == b"from n-1")
    after = dict(b1.document["groups"][b64(conversation)]["epochs"])
    check("L8 prior-epoch secret update persisted transactionally",
          set(after) == {str(n - 1)} and after != before and peek(b1.root)[0]["groups"][b64(conversation)]["epochs"] == after)
    raises(Rejected, lambda: deliver(reopen(b1), delayed_n1, 10_001))
    check("L9 replay of the delayed message after restart rejected (update was durable)")

    delayed_n2 = held(a1, b"from n-2")  # A still at n-1
    b1 = reopen(b1)
    b1.update()  # B: n -> n+1, A's epoch is now two behind
    raises(Rejected, lambda: deliver(b1, delayed_n2, 10_002))
    check("L8 message from n-2 rejected outside retention")
    b1 = reopen(b1)
    raises(Rejected, lambda: deliver(b1, delayed_n2, 10_003))
    check("L8 restart preserves the n-2 rejection")
    document, _ = peek(b1.root)
    epochs = document["groups"][b64(conversation)]["epochs"]
    check("L8 persisted state holds no epoch below n-1", set(epochs) == {str(b1.group.current_epoch() - 1)})
    check("L8 trimmed epoch secrets are absent from the persisted document",
          after[str(n - 1)] not in json.dumps(document))

    a1 = reopen(a1)
    a1.sync()
    fresh = held(a1, b"n-1 again")
    b1.update()
    check("L8 after restart, n-1 still decrypts at n", deliver(reopen(b1), fresh, 10_004) == b"n-1 again")


# -------------------------------------------------- identity / trust (M1.4B) --

def impostor_keypackage(base):
    clock = Clock()
    relay = Relay(base / "t2-relay.json")
    a = Device.setup(base / "t2-a", "alice", relay, clock)
    b = Device.setup(base / "t2-b", "bob", relay, clock)
    a.scan_responder(b.scan_initiator(a.start_pairing()))
    impostor = Client(b"bob", generate_signature_keypair(SUITE),
                      ClientConfig(group_state_storage=MemoryGroupStorage(),
                                   use_ratchet_tree_extension=True))
    entry = relay.conversations[a.document["conversation"]]["log"][0]
    entry["data"] = b64(impostor.generate_key_package_message().to_bytes())  # malicious relay swap
    relay.save()
    raises(IdentityChanged, a.add_peer)
    check("T2 KeyPackage not matching the QR pin: hard stop before any group state",
          peek(a.root)[0]["security"] == "identityChanged" and peek(a.root)[0]["groups"] == {})
    return a


def key_change_same_credential(base, a, b):
    a1, b1, relay1 = clone(base, "t3", a, b)
    conversation = unb64(a1.document["conversation"])
    document, _ = peek(b1.root)
    group = document["groups"][b64(conversation)]
    lines = [conversation.hex(), b"bob".hex(), unb64(group["state"]).hex()]
    lines += [f"{k} {unb64(v).hex()}" for k, v in group["epochs"].items()]
    out = subprocess.run([os.environ["M14_ADVERSARY"]], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, check=True).stdout.strip()
    commit = bytes.fromhex(out)
    base_epoch = b1.group.current_epoch()

    probe_a, probe_relay = clone(base, "t3-probe", a1)
    probe_a.group.process_incoming_message(Message.from_bytes(commit))
    bob = [m for m in probe_a.group.roster() if m.basic_identifier() == b"bob"][0]
    check("T3 control: pinned mls-rs accepts a new key under the same BasicCredential (F2)",
          member_pin(bob) != unb64(probe_a.document["peerPin"]))

    state_before = peek(a1.root)[0]["groups"]
    status, seq = relay1.post(conversation, "commit", base_epoch, commit, "bob")
    raises(IdentityChanged, a1.sync)
    document, _ = peek(a1.root)
    check("T3 peer key change under identical BasicCredential: HARD STOP, group state not committed",
          status == "ACCEPTED" and document["security"] == "identityChanged" and document["groups"] == state_before)
    return a1


def third_member(base, a, b):
    a1, b1, relay1 = clone(base, "t4", a, b)
    carol = Client(b"carol", generate_signature_keypair(SUITE),
                   ClientConfig(group_state_storage=MemoryGroupStorage(),
                                use_ratchet_tree_extension=True))
    base_epoch = b1.group.current_epoch()
    injected = b1.group.add_members([Message.from_bytes(carol.generate_key_package_message().to_bytes())])
    relay1.post(unb64(a1.document["conversation"]), "commit", base_epoch,
                injected.commit_message.to_bytes(), "bob")
    raises(IdentityChanged, a1.sync)
    check("T4 third member injection: HARD STOP", peek(a1.root)[0]["security"] == "identityChanged")


def blocked_after_stop(base, halted):
    for action in (lambda: halted.send(b"x"), halted.update, halted.sync, halted.start_pairing):
        raises(Violation, action)
    again = reopen(halted)
    raises(Violation, lambda: again.send(b"x"))
    check("T7 after identityChanged: send/receive/update/pair blocked, also after restart",
          again.group is None and again.document["security"] == "identityChanged")


def identity_item(base, a, b):
    a1, _ = clone(base, "l10-swap", a)
    item = json.loads((a1.root / "identity.json").read_bytes())
    other = generate_signature_keypair(SUITE)
    item.update(public=b64(other.public_key.bytes), secret=b64(other.secret_key.bytes))
    (a1.root / "identity.json").write_bytes(canonical(item))
    raises(Violation, lambda: reopen(a1))
    check("L10 swapped Keychain identity != restored group's own leaf (F1): HARD STOP",
          peek(a1.root)[0]["security"] == "halted")
    a2, _ = clone(base, "l10-missing", a)
    (a2.root / "identity.json").unlink()
    raises(ClosedError, lambda: reopen(a2))
    check("L10 missing Keychain identity: fail closed, nothing regenerated", not (a2.root / "identity.json").exists())


def tamper_and_rollback(base, a):
    a1, _ = clone(base, "t6", a)
    old = (a1.root / "state.aead").read_bytes()
    a1.send(b"advance")
    envelope = json.loads((a1.root / "state.aead").read_bytes())
    data = bytearray(unb64(envelope["ciphertext"]))
    data[-1] ^= 1
    envelope["ciphertext"] = b64(data)
    (a1.root / "state.aead").write_bytes(canonical(envelope))
    raises(ClosedError, lambda: reopen(a1))
    (a1.root / "state.aead").write_bytes(old)
    raises(ClosedError, lambda: reopen(a1))
    check("T6 tampered or rolled-back pin/state rejected (AES-GCM + anchor)")


def wipe_and_repair(base, a, b):
    clock = a.clock
    a1, b1, relay1 = clone(base, "wipe", a, b)
    old_conversation = unb64(a1.document["conversation"])
    old_welcome = welcome_for(b1)[0]
    old_app = a1.send(b"old conversation")

    b_crash = base / "wipe-crash"
    shutil.copytree(b1.root, b_crash)
    (b_crash / "anchor.json").unlink()  # crash after anchor deletion, before the rest
    raises(ClosedError, lambda: Device(b_crash, "bob", relay1, clock).open())
    check("L11 wipe interrupted after anchor deletion: state file is unreadable")

    b_left = base / "leftover-anchor"
    shutil.copytree(b1.root, b_left)
    (b_left / "state.aead").unlink()
    raises(ClosedError, lambda: Device(b_left, "bob", relay1, clock).open())
    check("L12 leftover Keychain material without state: fail closed, no silent recovery",
          (b_left / "anchor.json").exists() and (b_left / "identity.json").exists())

    for device in (a1, b1):
        device.wipe()
    raises(ClosedError, lambda: reopen(b1))
    check("L11 explicit wipe then restore: unavailable")
    a2 = Device.setup(a1.root, "alice", relay1, clock)
    b2 = Device.setup(b1.root, "bob", relay1, clock)
    a2.scan_responder(b2.scan_initiator(a2.start_pairing()))
    a2.add_peer()
    b2.accept_welcome(welcome_for(b2)[0])
    new_conversation = unb64(a2.document["conversation"])
    check("RE-PAIR creates a fresh random conversation_id",
          new_conversation != old_conversation and a2.document["lifecycle"] == "established")
    relay1.retire(old_conversation)
    raises(Rejected, lambda: b2.accept_welcome(old_welcome))
    raises(Rejected, lambda: b2.receive({"cid": old_conversation, "seq": 10**6, "kind": "application",
                                         "base": 1, "data": old_app}))
    check("RE-PAIR old conversation_id rejected by device; relay retired it",
          relay1.post(old_conversation, "application", 1, b"x", "alice")[0] == "REJECT")
    return a2, b2


def abandoned_marker(base):
    case = base / "crash-join-kp-delete"
    relay = Relay(case / "relay.json")
    raises(ClosedError, lambda: Device(case / "b", "bob", relay).open())
    b = Device(case / "b", "bob", relay)
    b.wipe()
    a = Device(case / "a", "alice", relay).open()
    a.wipe()
    a = Device.setup(case / "a", "alice", relay)
    b = Device.setup(case / "b", "bob", relay)
    a.scan_responder(b.scan_initiator(a.start_pairing()))
    a.add_peer()
    b.accept_welcome(welcome_for(b)[0])
    check("L13 abandoned pending marker: explicit wipe + new mutual QR recovers, no old epoch resumed",
          b.document["lifecycle"] == "established" and b.group.current_epoch() == 1)


def wrong_group(base, a, b):
    a1, b1, relay1 = clone(base, "l14", a, b)
    clock = Clock()
    x, y, _ = pair(base / "l14-other", clock)
    foreign = x.send(b"other group")
    raises(Rejected, lambda: b1.receive({"cid": unb64(b1.document["conversation"]), "seq": 10**6,
                                         "kind": "application", "base": 1, "data": foreign}))
    check("L14 message from another group rejected by MLS")


def privacy(base, a, b):
    leaked = []
    for root in [p for p in base.rglob("*") if p.is_file()]:
        data = root.read_bytes()
        for probe in (b"m14 probe one", b"m14 probe two", b"after concurrency", b"from n-1"):
            if probe in data or b64(probe).encode() in data:
                leaked.append(root.name)
    check("L15 no message plaintext in any state or relay file", not leaked)


def main(base):
    base.mkdir(parents=True, exist_ok=True)
    pin_and_qr(base)
    a, b, relay, _ = establishment(base)
    l1_restart_control(base)
    keypackage_rules(base)
    welcome_state_machine(base, a, b)
    join_failure_windows(base)
    rejected_input(base, a, b)
    crash_matrix(base)
    pending_commits(base, a, b, relay)
    concurrent_commits(base, a, b)
    relay_model(base, a, b)
    epoch_retention(base, a, b)
    halted = impostor_keypackage(base)
    blocked_after_stop(base, halted)
    blocked_after_stop(base, key_change_same_credential(base, a, b))
    third_member(base, a, b)
    identity_item(base, a, b)
    tamper_and_rollback(base, a)
    wipe_and_repair(base, a, b)
    abandoned_marker(base)
    wrong_group(base, a, b)
    privacy(base, a, b)
    print(f"M1.4 Linux matrix: {len(RESULTS)} checks PASS")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "child":
        child(sys.argv[2], Path(sys.argv[3]))
    elif len(sys.argv) == 2:
        main(Path(sys.argv[1]))
    else:
        raise SystemExit(__doc__)
