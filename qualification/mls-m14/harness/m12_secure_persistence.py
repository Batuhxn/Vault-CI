"""Disposable Linux qualification of a local MLS persistence boundary.

The only MLS bytes are opaque callbacks from the pinned upstream UniFFI API.
AES-GCM comes from cryptography, never from handwritten cryptography. The
separate JSON anchor models Keychain semantics for tests; it is not a Keychain
or a production secret store. No message body or private value is printed.
"""

import base64
import json
import os
from pathlib import Path
import shutil
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from mls_rs_uniffi import (
    CipherSuite,
    Client,
    ClientConfig,
    Error as MlsError,
    GroupStateStorage,
    Message,
    ReceivedMessage,
    SignatureKeypair,
    SignaturePublicKey,
    SignatureSecretKey,
    generate_signature_keypair,
    validate_signature_keypair,
)


GROUP_ID = b"watchlink-m12-test-group"
SUITE = CipherSuite.CURVE25519_AES128
DOMAIN = b"Watchlink M1.2 local state envelope v1"
FORMAT_VERSION = 1


class ClosedError(Exception):
    pass


def b64(data):
    return base64.b64encode(data).decode("ascii")


def unb64(value):
    if not isinstance(value, str):
        raise ClosedError("invalid local encoding")
    try:
        return base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise ClosedError("invalid local encoding") from exc


def canonical(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def parse_json(data):
    try:
        return json.loads(data)
    except (ValueError, UnicodeError, TypeError) as exc:
        raise ClosedError("invalid local document") from exc


def durable_replace(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".pending")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        raise
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


class TestAnchor:
    """Separate-file stand-in for a non-migrating Keychain item."""

    def __init__(self, root):
        self.path = root / "test-keychain.json"

    def create(self, keypair):
        if self.path.exists():
            raise ClosedError("identity already exists")
        item = {
            "storageKey": b64(os.urandom(32)),
            "identityPublic": b64(keypair.public_key.bytes),
            "identitySecret": b64(keypair.secret_key.bytes),
            "committedVersion": 0,
            "pendingVersion": None,
        }
        durable_replace(self.path, canonical(item))

    def read(self):
        try:
            item = parse_json(self.path.read_bytes())
            if not isinstance(item, dict):
                raise ClosedError("invalid anchor")
            key = unb64(item["storageKey"])
            public = unb64(item["identityPublic"])
            secret = unb64(item["identitySecret"])
            committed = item["committedVersion"]
            pending = item["pendingVersion"]
            if len(key) != 32 or type(committed) is not int or not 0 <= committed < 2**64:
                raise ClosedError("invalid anchor")
            if pending is not None and (type(pending) is not int or pending <= committed):
                raise ClosedError("invalid anchor")
            return item, key, public, secret, committed, pending
        except (OSError, KeyError, TypeError) as exc:
            raise ClosedError("missing or invalid anchor") from exc

    def write(self, item):
        durable_replace(self.path, canonical(item))

    def begin(self):
        item, _, _, _, committed, pending = self.read()
        if pending is not None:
            raise ClosedError("unfinished local state transaction")
        item["pendingVersion"] = committed + 1
        self.write(item)
        return committed + 1

    def finish(self, version):
        item, _, _, _, committed, pending = self.read()
        if pending != version or version != committed + 1:
            raise ClosedError("invalid local state transition")
        item["committedVersion"] = version
        item["pendingVersion"] = None
        self.write(item)


class MemoryGroupStorage(GroupStateStorage):
    def __init__(self):
        self.groups = {}

    def state(self, group_id):
        value = self.groups.get(group_id)
        return None if value is None else value["state"]

    def epoch(self, group_id, epoch_id):
        value = self.groups.get(group_id)
        return None if value is None else value["epochs"].get(epoch_id)

    def write(self, group_id, group_state, epoch_inserts, epoch_updates):
        prior = self.groups.get(group_id, {"state": b"", "epochs": {}})
        epochs = dict(prior["epochs"])
        for record in epoch_inserts:
            if record.id in epochs:
                raise ClosedError("duplicate epoch insert")
            epochs[record.id] = record.data
        for record in epoch_updates:
            if record.id not in epochs:
                raise ClosedError("missing epoch update")
            epochs[record.id] = record.data
        self.groups[group_id] = {"state": group_state, "epochs": epochs}

    def max_epoch_id(self, group_id):
        value = self.groups.get(group_id)
        return max(value["epochs"]) if value and value["epochs"] else None

    def encode(self):
        if len(self.groups) != 1 or GROUP_ID not in self.groups:
            raise ClosedError("group state incomplete")
        value = self.groups[GROUP_ID]
        if not value["state"]:
            raise ClosedError("group state empty")
        return canonical(
            {
                "groupId": b64(GROUP_ID),
                "state": b64(value["state"]),
                "epochs": [
                    {"id": epoch_id, "data": b64(data)}
                    for epoch_id, data in sorted(value["epochs"].items())
                ],
            }
        )

    @classmethod
    def decode(cls, data):
        document = parse_json(data)
        try:
            if set(document) != {"groupId", "state", "epochs"}:
                raise ClosedError("unexpected group document")
            group_id = unb64(document["groupId"])
            state = unb64(document["state"])
            if group_id != GROUP_ID or not state or not isinstance(document["epochs"], list):
                raise ClosedError("invalid group document")
            epochs = {}
            for row in document["epochs"]:
                if set(row) != {"id", "data"} or type(row["id"]) is not int:
                    raise ClosedError("invalid epoch row")
                if row["id"] in epochs:
                    raise ClosedError("duplicate epoch row")
                epochs[row["id"]] = unb64(row["data"])
        except (KeyError, TypeError) as exc:
            raise ClosedError("invalid group document") from exc
        storage = cls()
        storage.groups[group_id] = {"state": state, "epochs": epochs}
        return storage


class Store:
    def __init__(self, root):
        self.root = root
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.anchor = TestAnchor(root)
        self.file = root / "mls-state.aead"

    def create_identity(self, keypair):
        self.anchor.create(keypair)

    def begin(self):
        return self.anchor.begin()

    def commit(self, storage, version, crash_at=None):
        item, key, _, _, _, pending = self.anchor.read()
        if pending != version:
            raise ClosedError("missing pending state reservation")
        payload = canonical({"stateVersion": version, "opaqueGroup": b64(storage.encode())})
        nonce = os.urandom(12)
        aad = DOMAIN + version.to_bytes(8, "big")
        sealed = AESGCM(key).encrypt(nonce, payload, aad)
        envelope = canonical(
            {
                "formatVersion": FORMAT_VERSION,
                "stateVersion": version,
                "nonce": b64(nonce),
                "ciphertext": b64(sealed),
            }
        )
        temporary = self.file.with_name(self.file.name + ".pending")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(envelope)
            output.flush()
            os.fsync(output.fileno())
        if crash_at == "written":
            os._exit(82)
        os.replace(temporary, self.file)
        directory = os.open(self.root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        if crash_at == "replaced":
            os._exit(83)
        self.anchor.finish(version)
        if crash_at == "anchored":
            os._exit(84)

    def restore(self, peer):
        _, key, public, secret, committed, pending = self.anchor.read()
        if pending is not None or committed == 0:
            raise ClosedError("uncommitted or absent local state")
        keypair = SignatureKeypair(
            cipher_suite=SUITE,
            public_key=SignaturePublicKey(bytes=public),
            secret_key=SignatureSecretKey(bytes=secret),
        )
        try:
            if not validate_signature_keypair(keypair):
                raise ClosedError("identity key mismatch")
        except MlsError as exc:
            raise ClosedError("invalid identity key") from exc
        try:
            envelope = parse_json(self.file.read_bytes())
            if set(envelope) != {"formatVersion", "stateVersion", "nonce", "ciphertext"}:
                raise ClosedError("invalid state envelope")
            version = envelope["stateVersion"]
            if (
                type(version) is not int
                or version != committed
                or type(envelope["formatVersion"]) is not int
                or envelope["formatVersion"] != FORMAT_VERSION
            ):
                raise ClosedError("state version mismatch")
            nonce = unb64(envelope["nonce"])
            sealed = unb64(envelope["ciphertext"])
            if len(nonce) != 12:
                raise ClosedError("invalid nonce")
            payload = AESGCM(key).decrypt(
                nonce, sealed, DOMAIN + version.to_bytes(8, "big")
            )
            inner = parse_json(payload)
            if (
                set(inner) != {"stateVersion", "opaqueGroup"}
                or type(inner["stateVersion"]) is not int
                or inner["stateVersion"] != version
            ):
                raise ClosedError("invalid authenticated state")
            storage = MemoryGroupStorage.decode(unb64(inner["opaqueGroup"]))
            peer_client = Client(
                peer.encode(),
                keypair,
                ClientConfig(group_state_storage=storage, use_ratchet_tree_extension=True),
            )
            return peer_client, peer_client.load_group(GROUP_ID), storage
        except (OSError, KeyError, TypeError, ValueError, InvalidTag, MlsError) as exc:
            raise ClosedError("local state unavailable or invalid") from exc


def fresh_client(peer, keypair, storage):
    return Client(
        peer.encode(),
        keypair,
        ClientConfig(group_state_storage=storage, use_ratchet_tree_extension=True),
    )


def application(group, wire):
    result = group.process_incoming_message(Message.from_bytes(wire))
    if not isinstance(result, ReceivedMessage.APPLICATION_MESSAGE):
        raise ClosedError("unexpected MLS message type")
    return result.data


def send(sender_store, sender_group, sender_storage, receiver_store, receiver_group, receiver_storage, plaintext):
    outgoing_version = sender_store.begin()
    wire = sender_group.encrypt_application_message(plaintext).to_bytes()
    sender_group.write_to_storage()
    sender_store.commit(sender_storage, outgoing_version)
    incoming_version = receiver_store.begin()
    if application(receiver_group, wire) != plaintext:
        raise ClosedError("application mismatch")
    receiver_group.write_to_storage()
    receiver_store.commit(receiver_storage, incoming_version)
    return wire


def setup(base):
    alice_store, bob_store = Store(base / "alice"), Store(base / "bob")
    alice_key, bob_key = generate_signature_keypair(SUITE), generate_signature_keypair(SUITE)
    alice_store.create_identity(alice_key)
    bob_store.create_identity(bob_key)
    alice_storage, bob_storage = MemoryGroupStorage(), MemoryGroupStorage()
    alice = fresh_client("alice", alice_key, alice_storage)
    bob = fresh_client("bob", bob_key, bob_storage)
    key_package_wire = bob.generate_key_package_message().to_bytes()

    version = alice_store.begin()
    alice_group = alice.create_group(GROUP_ID)
    added = alice_group.add_members([Message.from_bytes(key_package_wire)])
    welcome_wire = added.welcome_message.to_bytes()
    alice_group.process_incoming_message(Message.from_bytes(added.commit_message.to_bytes()))
    alice_group.write_to_storage()
    alice_store.commit(alice_storage, version)
    shutil.copy2(alice_store.file, base / "old-valid-state.aead")

    version = bob_store.begin()
    bob_group = bob.join_group(None, Message.from_bytes(welcome_wire)).group
    bob_group.write_to_storage()
    bob_store.commit(bob_storage, version)

    replay_wire = send(
        alice_store, alice_group, alice_storage,
        bob_store, bob_group, bob_storage, b"M1.2 test message",
    )
    send(
        bob_store, bob_group, bob_storage,
        alice_store, alice_group, alice_storage, b"M1.2 test reply",
    )
    if b"M1.2 test message" in alice_store.file.read_bytes():
        raise ClosedError("plaintext appeared in protected state file")
    (base / "replay-wire.bin").write_bytes(replay_wire)
    print("secure-envelope session setup: PASS")


def resume(base):
    alice_store, bob_store = Store(base / "alice"), Store(base / "bob")
    _, alice_group, alice_storage = alice_store.restore("alice")
    _, bob_group, bob_storage = bob_store.restore("bob")
    try:
        application(bob_group, (base / "replay-wire.bin").read_bytes())
    except MlsError:
        pass
    else:
        raise ClosedError("pre-restart replay was accepted")
    send(
        alice_store, alice_group, alice_storage,
        bob_store, bob_group, bob_storage, b"M1.2 resumed message",
    )
    send(
        bob_store, bob_group, bob_storage,
        alice_store, alice_group, alice_storage, b"M1.2 resumed reply",
    )
    print("secure-envelope separate-process restart: PASS")


def copy_alice(base, name):
    destination = base / "cases" / name
    shutil.copytree(base / "alice", destination)
    return destination


def rejected_restore(root):
    try:
        Store(root).restore("alice")
    except ClosedError:
        return
    raise AssertionError("tampered local state restored")


def adversarial(base):
    def mutate_file(name, operation):
        path = copy_alice(base, name)
        operation(path / "mls-state.aead")
        rejected_restore(path)

    def mutate_anchor(name, operation):
        path = copy_alice(base, name)
        anchor = TestAnchor(path)
        item = parse_json(anchor.path.read_bytes())
        operation(item)
        anchor.write(item)
        rejected_restore(path)

    def bitflip(path):
        item = parse_json(path.read_bytes())
        data = bytearray(unb64(item["ciphertext"]))
        data[-1] ^= 1
        item["ciphertext"] = b64(data)
        durable_replace(path, canonical(item))

    mutate_file("bitflip", bitflip)
    mutate_file("truncated", lambda p: durable_replace(p, p.read_bytes()[:-8]))
    mutate_file("random", lambda p: durable_replace(p, os.urandom(99)))
    mutate_file("rollback", lambda p: shutil.copy2(base / "old-valid-state.aead", p))

    def change_file_version(path, missing):
        item = parse_json(path.read_bytes())
        if missing:
            item.pop("stateVersion")
        else:
            item["stateVersion"] += 1
        durable_replace(path, canonical(item))

    mutate_file("file-version", lambda p: change_file_version(p, False))
    mutate_file("file-missing-version", lambda p: change_file_version(p, True))
    mutate_anchor("wrong-key", lambda i: i.__setitem__("storageKey", b64(os.urandom(32))))
    mutate_anchor("missing-key", lambda i: i.pop("storageKey"))
    wrong = generate_signature_keypair(SUITE)
    mutate_anchor("wrong-private", lambda i: i.__setitem__("identitySecret", b64(wrong.secret_key.bytes)))
    mutate_anchor("wrong-public", lambda i: i.__setitem__("identityPublic", b64(wrong.public_key.bytes)))
    mutate_anchor("truncated-private", lambda i: i.__setitem__("identitySecret", b64(unb64(i["identitySecret"])[:-1])))
    mutate_anchor("malformed-private", lambda i: i.__setitem__("identitySecret", b64(os.urandom(64))))
    mutate_anchor("mismatched-version", lambda i: i.__setitem__("committedVersion", i["committedVersion"] + 1))
    mutate_anchor("missing-version", lambda i: i.pop("committedVersion"))
    mutate_anchor("pending-version", lambda i: i.__setitem__("pendingVersion", i["committedVersion"] + 1))
    absent_anchor = copy_alice(base, "absent-anchor")
    (absent_anchor / "test-keychain.json").unlink()
    rejected_restore(absent_anchor)
    absent_file = copy_alice(base, "absent-file")
    (absent_file / "mls-state.aead").unlink()
    rejected_restore(absent_file)
    print("authenticated-state, rollback, key, and version tampering: PASS")


def crash_child(root, point):
    if point == "before-reservation":
        os._exit(80)
    store = Store(root)
    _, group, storage = store.restore("alice")
    version = store.begin()
    if point == "reserved":
        os._exit(81)
    group.encrypt_application_message(b"unsent crash probe")
    if point == "produced":
        os._exit(82)
    group.write_to_storage()
    if point in ("written", "replaced", "anchored"):
        store.commit(storage, version, crash_at=point)
    raise ClosedError("unknown crash point")


def usage():
    raise SystemExit("usage: m12_secure_persistence.py setup|resume|adversarial|crash PATH [POINT]")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        usage()
    mode, root = sys.argv[1], Path(sys.argv[2])
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if mode == "setup" and len(sys.argv) == 3:
        setup(root)
    elif mode == "resume" and len(sys.argv) == 3:
        resume(root)
    elif mode == "adversarial" and len(sys.argv) == 3:
        adversarial(root)
    elif mode == "crash" and len(sys.argv) == 4:
        crash_child(root, sys.argv[3])
    else:
        usage()
