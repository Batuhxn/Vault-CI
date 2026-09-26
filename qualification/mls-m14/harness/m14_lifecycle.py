"""Disposable Linux model of the M1.4 MLS lifecycle and peer-trust boundary.

Per device (test stand-ins, not production stores):
  identity.json  local signing identity (models the Keychain identity item)
  anchor.json    storage key + committed/pending version (Keychain anchor)
  state.aead     AES-GCM envelope of the complete local state document

Every MLS callback mutation lands in one transaction staging document. Only
seal -> atomic file replace -> anchor commit makes it durable, and only then
are outbound bytes released. MLS bytes stay opaque. Nothing secret or any
message content is printed.
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from mls_rs_uniffi import (
    CipherSuite,
    Client,
    ClientConfig,
    Error as MlsError,
    GroupStateStorage,
    KeyPackageStorage,
    Message,
    ReceivedMessage,
    SignatureKeypair,
    SignaturePublicKey,
    SignatureSecretKey,
    generate_signature_keypair,
    validate_signature_keypair,
)

from m12_secure_persistence import ClosedError, b64, canonical, durable_replace, parse_json, unb64

SUITE = CipherSuite.CURVE25519_AES128
DOMAIN = b"Watchlink M1.4 local state envelope v1"
PIN_DOMAIN = b"watchlink-identity-pin-v1"
QR_VERSION = 1
QR_TTL = 300
KEY_PACKAGE_TTL = 600
ID_BYTES = 16


class Rejected(Exception):
    """Input refused; durable state unchanged, session continues."""


class Violation(Exception):
    """Security hard stop, persisted before raising."""

    security = "halted"


class IdentityChanged(Violation):
    security = "identityChanged"


class RelayViolation(Violation):
    security = "halted"


def identity_pin(credential_id, signature_public_key):
    """SHA-256(domain || u32be len || credential_id || u32be len || key)."""
    digest = hashlib.sha256(PIN_DOMAIN)
    for part in (credential_id, signature_public_key):
        digest.update(struct.pack(">I", len(part)))
        digest.update(part)
    return digest.digest()


def member_pin(signing_identity):
    identifier = signing_identity.basic_identifier()
    if identifier is None:
        raise IdentityChanged("non-basic credential")
    return identity_pin(identifier, signing_identity.signature_public_key())


def make_qr(conversation, nonce, pin, expires):
    return canonical({"v": QR_VERSION, "cid": b64(conversation), "nonce": b64(nonce),
                      "pin": b64(pin), "exp": expires})


def parse_qr(data, now, consumed):
    try:
        document = parse_json(data)
        if not isinstance(document, dict) or set(document) != {"v", "cid", "nonce", "pin", "exp"}:
            raise Rejected("malformed pairing code")
        conversation, nonce, pin = (unb64(document[k]) for k in ("cid", "nonce", "pin"))
        expires = document["exp"]
    except ClosedError as exc:
        raise Rejected("malformed pairing code") from exc
    if document["v"] != QR_VERSION or type(expires) is not int:
        raise Rejected("unsupported pairing code")
    if len(conversation) != ID_BYTES or len(nonce) != ID_BYTES or len(pin) != 32:
        raise Rejected("malformed pairing code")
    if not now < expires <= now + QR_TTL:
        raise Rejected("expired pairing code")
    if b64(nonce) in consumed:
        raise Rejected("reused pairing nonce")
    return conversation, nonce, pin


class Relay:
    """Opaque sequencer. Epoch metadata orders commits; it grants no authority."""

    def __init__(self, path):
        self.path = Path(path)
        self.conversations = {}
        if self.path.exists():
            for key, value in json.loads(self.path.read_bytes()).items():
                value["accepted"] = {int(k): v for k, v in value["accepted"].items()}
                self.conversations[key] = value

    def save(self):
        durable_replace(self.path, canonical(self.conversations))

    def post(self, conversation, kind, base, data, sender):
        c = self.conversations.setdefault(
            b64(conversation), {"current": 0, "accepted": {}, "log": [], "retired": False})
        if c["retired"]:
            return "REJECT", None
        if kind == "commit":
            commit_id = b64(hashlib.sha256(data).digest())
            if base == c["current"]:
                c["accepted"][base] = commit_id
                c["current"] += 1
            elif base < c["current"]:
                accepted = next(e["seq"] for e in c["log"]
                                if e["kind"] == "commit" and e["base"] == base
                                and e["commitId"] == c["accepted"][base])
                return ("ACCEPTED" if c["accepted"][base] == commit_id else "STALE"), accepted
            else:
                return "REJECT", None
        else:
            commit_id = None
        seq = len(c["log"]) + 1
        c["log"].append({"seq": seq, "kind": kind, "base": base, "data": b64(data),
                         "sender": sender, "commitId": commit_id})
        self.save()  # durable before acknowledging or fanning out
        return ("ACCEPTED" if kind == "commit" else "OK"), seq

    def entry(self, conversation, seq):
        e = self.conversations[b64(conversation)]["log"][seq - 1]
        return {"cid": conversation, "seq": e["seq"], "kind": e["kind"], "base": e["base"],
                "data": unb64(e["data"]), "sender": e["sender"]}

    def fetch(self, conversation, recipient, after):
        c = self.conversations.get(b64(conversation))
        if c is None:
            return []
        return [self.entry(conversation, e["seq"]) for e in c["log"]
                if e["seq"] > after and e["sender"] != recipient]

    def retire(self, conversation):
        self.conversations[b64(conversation)]["retired"] = True
        self.save()


def empty_document():
    return {"lifecycle": "unpaired", "security": "ok", "conversation": None, "role": None,
            "ownNonce": None, "qrExpires": None, "peerPin": None, "consumedNonces": [],
            "groups": {}, "keyPackages": {}, "pendingCommit": None, "outbound": [],
            "lastSeq": 0}


class Store:
    """Anchor + sealed document with a single staging transaction."""

    def __init__(self, root):
        self.root = Path(root)
        self.anchor_path = self.root / "anchor.json"
        self.file = self.root / "state.aead"
        self.committed = None
        self.staging = None
        self.version = None
        self.callback_failed = self.mutated = self.replaced = False
        self.crash_at = os.environ.get("M14_CRASH")
        self.fail_at = None

    def point(self, name):
        if self.crash_at == name:
            os._exit(90)
        if self.fail_at == name:
            self.callback_failed = True
            raise ClosedError("injected storage failure")

    def anchor(self):
        try:
            item = parse_json(self.anchor_path.read_bytes())
            key = unb64(item["storageKey"])
            committed, pending = item["committedVersion"], item["pendingVersion"]
        except (OSError, KeyError, TypeError) as exc:
            raise ClosedError("missing or invalid anchor") from exc
        if len(key) != 32 or type(committed) is not int or (pending is not None and pending != committed + 1):
            raise ClosedError("invalid anchor")
        return item, key, committed, pending

    def create(self):
        if self.anchor_path.exists() or self.file.exists():
            raise ClosedError("local state already exists")
        durable_replace(self.anchor_path, canonical(
            {"storageKey": b64(os.urandom(32)), "committedVersion": 0, "pendingVersion": None}))
        self.committed = empty_document()
        self.begin()
        self.commit()

    def load(self):
        _, key, committed, pending = self.anchor()
        if pending is not None or committed == 0:
            raise ClosedError("unfinished or absent local state")
        try:
            envelope = parse_json(self.file.read_bytes())
            if set(envelope) != {"stateVersion", "nonce", "ciphertext"} or envelope["stateVersion"] != committed:
                raise ClosedError("state version mismatch")
            inner = parse_json(AESGCM(key).decrypt(
                unb64(envelope["nonce"]), unb64(envelope["ciphertext"]),
                DOMAIN + committed.to_bytes(8, "big")))
            if inner.get("stateVersion") != committed:
                raise ClosedError("invalid authenticated state")
        except (OSError, InvalidTag, AttributeError, ValueError) as exc:
            raise ClosedError("local state unavailable or invalid") from exc
        self.committed = inner["document"]
        return self.committed

    def view(self):
        return self.staging if self.staging is not None else self.committed

    def writable(self):
        self.mutated = True  # any mutation callback, even a no-op delete
        if self.staging is None:
            self.callback_failed = True
            raise ClosedError("storage write outside a transaction")
        return self.staging

    def begin(self):
        if self.staging is not None:
            raise ClosedError("nested transaction")
        item, _, committed, pending = self.anchor()
        if pending is not None:
            raise ClosedError("unfinished local state transaction")
        item["pendingVersion"] = committed + 1
        durable_replace(self.anchor_path, canonical(item))
        self.version = committed + 1
        self.begun_at = committed
        self.staging = copy.deepcopy(self.committed)
        self.callback_failed = self.mutated = self.replaced = False
        self.point("reserved")

    def commit(self):
        item, key, committed, pending = self.anchor()
        if pending != self.version:
            raise ClosedError("missing reservation")
        nonce = os.urandom(12)
        payload = canonical({"stateVersion": self.version, "document": self.staging})
        sealed = AESGCM(key).encrypt(nonce, payload, DOMAIN + self.version.to_bytes(8, "big"))
        envelope = canonical({"stateVersion": self.version, "nonce": b64(nonce), "ciphertext": b64(sealed)})
        temporary = self.file.with_name(self.file.name + ".pending")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(envelope)
            output.flush()
            os.fsync(output.fileno())
        self.point("written")
        self.replaced = True
        os.replace(temporary, self.file)
        directory = os.open(self.root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        self.point("replaced")
        item["committedVersion"], item["pendingVersion"] = self.version, None
        durable_replace(self.anchor_path, canonical(item))
        self.committed, self.staging = self.staging, None
        self.point("anchored")

    def releasable(self):
        """True only if the operation provably stayed read-only."""
        if self.staging is None or self.callback_failed or self.mutated or self.replaced:
            return False
        if self.staging != self.committed:
            return False
        _, _, committed, pending = self.anchor()
        return committed == self.begun_at and pending == self.version

    def release(self):
        """Refused input: clear only the reservation; committed version unchanged."""
        if not self.releasable():
            raise ClosedError("cannot prove the operation was read-only")
        item, _, _, _ = self.anchor()
        item["pendingVersion"] = None
        durable_replace(self.anchor_path, canonical(item))
        self.staging = None

    def abandon(self):
        """Callback or persistence failure: keep the fail-closed marker."""
        self.staging = None


class GroupCallbacks(GroupStateStorage):
    def __init__(self, store):
        self.store = store

    def state(self, group_id):
        group = self.store.view()["groups"].get(b64(group_id))
        return None if group is None else unb64(group["state"])

    def epoch(self, group_id, epoch_id):
        group = self.store.view()["groups"].get(b64(group_id))
        record = None if group is None else group["epochs"].get(str(epoch_id))
        return None if record is None else unb64(record)

    def write(self, group_id, group_state, epoch_inserts, epoch_updates):
        try:
            document = self.store.writable()
            group = document["groups"].setdefault(b64(group_id), {"state": "", "epochs": {}})
            epochs = group["epochs"]
            for record in epoch_inserts:
                if str(record.id) in epochs:
                    raise ClosedError("duplicate epoch insert")
                epochs[str(record.id)] = b64(record.data)
            for record in epoch_updates:
                if str(record.id) not in epochs:
                    raise ClosedError("update to absent epoch")
                epochs[str(record.id)] = b64(record.data)
            group["state"] = b64(group_state)
            # Retention: current epoch (group state) + exactly one prior epoch record.
            if epochs:
                newest = max(map(int, epochs))
                for epoch_id in [k for k in epochs if int(k) < newest]:
                    del epochs[epoch_id]
            self.store.point("group-written")
        except ClosedError:
            self.store.callback_failed = True
            raise

    def max_epoch_id(self, group_id):
        group = self.store.view()["groups"].get(b64(group_id))
        return max(map(int, group["epochs"])) if group and group["epochs"] else None


class KeyPackageCallbacks(KeyPackageStorage):
    def __init__(self, store, clock):
        self.store, self.clock = store, clock

    def insert(self, id, data):
        try:
            packages = self.store.writable()["keyPackages"]
            if packages:
                raise ClosedError("a key package is already outstanding")
            packages[b64(id)] = {"data": b64(data), "expires": int(self.clock()) + KEY_PACKAGE_TTL}
        except ClosedError:
            self.store.callback_failed = True
            raise

    def get(self, id):
        record = self.store.view()["keyPackages"].get(b64(id))
        if record is None or record["expires"] <= self.clock():
            return None  # unknown, deleted, or expired: unusable
        return unb64(record["data"])

    def delete(self, id):
        try:
            self.store.point("kp-delete")
            self.store.writable()["keyPackages"].pop(b64(id), None)  # idempotent
        except ClosedError:
            self.store.callback_failed = True
            raise


class Device:
    def __init__(self, root, name, relay, clock=time.time):
        self.root, self.name, self.relay, self.clock = Path(root), name, relay, clock
        self.store = Store(self.root)
        self.identity_path = self.root / "identity.json"
        self.group = None

    # ---- setup, open, wipe -------------------------------------------------

    @classmethod
    def setup(cls, root, name, relay, clock=time.time):
        device = cls(root, name, relay, clock)
        device.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if device.identity_path.exists():
            raise ClosedError("identity already exists")
        keypair = generate_signature_keypair(SUITE)
        durable_replace(device.identity_path, canonical({
            "credentialId": b64(name.encode()), "public": b64(keypair.public_key.bytes),
            "secret": b64(keypair.secret_key.bytes)}))
        device.store.create()
        device.open()
        return device

    def open(self):
        self.group = None
        try:
            item = parse_json(self.identity_path.read_bytes())
            self.credential_id = unb64(item["credentialId"])
            keypair = SignatureKeypair(cipher_suite=SUITE,
                                       public_key=SignaturePublicKey(bytes=unb64(item["public"])),
                                       secret_key=SignatureSecretKey(bytes=unb64(item["secret"])))
            if not validate_signature_keypair(keypair):
                raise ClosedError("identity key mismatch")
        except (OSError, KeyError, TypeError, MlsError) as exc:
            raise ClosedError("local identity unavailable") from exc
        self.own_pin = identity_pin(self.credential_id, keypair.public_key.bytes)
        document = self.store.load()
        self.client = Client(self.credential_id, keypair, ClientConfig(
            group_state_storage=GroupCallbacks(self.store), use_ratchet_tree_extension=True,
            key_package_storage=KeyPackageCallbacks(self.store, self.clock)))
        if document["security"] != "ok":
            return self
        if document["pendingCommit"] and not any(o["kind"] == "commit" for o in document["outbound"]):
            self.halt(RelayViolation("pending commit without its outbound bytes"))
        if document["conversation"] and document["groups"]:
            self.group = self.client.load_group(unb64(document["conversation"]))
            if document["lifecycle"] == "established":
                try:  # F1: the Keychain identity must be the restored group's own leaf
                    self.check_roster(self.group, established=True, halt_as=Violation)
                except Violation as violation:
                    self.halt(violation)
        return self

    def wipe(self):
        """Explicit wipe: anchor first (crypto-shred), then identity and state."""
        for path in (self.store.anchor_path, self.identity_path, self.store.file):
            path.unlink(missing_ok=True)
        self.group = None

    # ---- transactions ------------------------------------------------------

    @property
    def document(self):
        return self.store.view()

    def require(self, *lifecycles):
        document = self.store.committed
        if document["security"] != "ok":
            raise Violation(f"blocked: {document['security']}")
        if lifecycles and document["lifecycle"] not in lifecycles:
            raise Rejected("operation not allowed in this lifecycle state")

    def reload(self):
        self.group = None
        document = self.store.committed
        if document["conversation"] and document["groups"]:
            self.group = self.client.load_group(unb64(document["conversation"]))

    def transact(self, operation):
        self.store.begin()
        try:
            result = operation(self.store.staging)
        except (Violation, MlsError, Rejected, ClosedError) as exc:
            if isinstance(exc, ClosedError) or not self.store.releasable():
                self.store.abandon()  # keep the fail-closed marker
                self.group = self.client = None  # do not continue the session
                raise ClosedError("operation not provably read-only; session closed") from exc
            self.store.release()
            self.reload()  # rebuild MLS objects from unchanged durable state
            if isinstance(exc, Violation):
                self.halt(exc)
            raise Rejected(str(exc)) from exc
        try:
            self.store.commit()
        except BaseException:
            self.store.abandon()
            self.group = self.client = None
            raise
        return result

    def halt(self, violation):
        """Persist the security state on the last committed document, then stop."""
        self.group = None
        self.store.begin()
        self.store.staging["security"] = violation.security
        self.store.commit()
        raise violation

    def check_roster(self, group, established, halt_as=IdentityChanged):
        pins = [member_pin(member) for member in group.roster()]
        peer = self.document["peerPin"]
        if established:
            expected = sorted([self.own_pin, unb64(peer)]) if peer else None
            if expected is None or expected[0] == expected[1] or sorted(pins) != expected:
                raise halt_as("roster is not exactly {own, pinned peer}")
        elif pins != [self.own_pin]:
            raise halt_as("roster before peer join is not exactly {own}")

    # ---- pairing -----------------------------------------------------------

    def start_pairing(self):
        self.require("unpaired")
        conversation, nonce = os.urandom(ID_BYTES), os.urandom(ID_BYTES)
        expires = int(self.clock()) + QR_TTL

        def operation(document):
            document.update(lifecycle="offered", role="initiator", conversation=b64(conversation),
                            ownNonce=b64(nonce), qrExpires=expires)
            document["consumedNonces"].append(b64(nonce))
        self.transact(operation)
        return make_qr(conversation, nonce, self.own_pin, expires)

    def scan_initiator(self, qr):
        self.require("unpaired")
        conversation, nonce, peer_pin = parse_qr(qr, self.clock(), self.document["consumedNonces"])
        own_nonce, expires = os.urandom(ID_BYTES), int(self.clock()) + QR_TTL

        def operation(document):
            document.update(lifecycle="joinPending", role="responder", conversation=b64(conversation),
                            peerPin=b64(peer_pin), ownNonce=b64(own_nonce), qrExpires=expires)
            document["consumedNonces"] += [b64(nonce), b64(own_nonce)]
            key_package = self.client.generate_key_package_message().to_bytes()
            if len(document["keyPackages"]) != 1:
                raise ClosedError("key package was not persisted")
            document["outbound"] = [{"kind": "keypackage", "base": None, "data": b64(key_package)}]
            return key_package
        key_package = self.transact(operation)
        self.release_outbound()  # published only after it is durable
        return make_qr(conversation, own_nonce, self.own_pin, expires)

    def scan_responder(self, qr):
        self.require("offered")
        document = self.document
        conversation, nonce, peer_pin = parse_qr(qr, self.clock(), document["consumedNonces"])
        if b64(conversation) != document["conversation"] or document["qrExpires"] <= self.clock():
            raise Rejected("pairing code is for another or expired conversation")

        def operation(staged):
            staged.update(lifecycle="pinned", peerPin=b64(peer_pin), qrExpires=None)
            staged["consumedNonces"].append(b64(nonce))
        self.transact(operation)

    def abort_pairing(self):
        self.require("offered", "joinPending", "pinned")

        def operation(document):
            document.update(lifecycle="unpaired", role=None, conversation=None, peerPin=None,
                            ownNonce=None, qrExpires=None, outbound=[], keyPackages={})
        self.transact(operation)

    # ---- group establishment -----------------------------------------------

    def add_peer(self):
        self.require("pinned")
        conversation = unb64(self.document["conversation"])
        packages = [e for e in self.relay.fetch(conversation, self.name, 0) if e["kind"] == "keypackage"]
        if len(packages) != 1:
            raise Rejected("expected exactly one peer key package")
        key_package = Message.from_bytes(packages[0]["data"])
        identity = key_package.key_package_signing_identity()
        if identity is None:
            raise Rejected("not a key package")
        if member_pin(identity) != unb64(self.document["peerPin"]):
            self.halt(IdentityChanged("key package does not match the pinned peer"))

        def operation(document):
            group = self.client.create_group(conversation)
            self.check_roster(group, established=False)
            output = group.add_members([key_package])
            group.write_to_storage()
            commit = output.commit_message.to_bytes()
            document.update(lifecycle="creating", lastSeq=packages[0]["seq"],
                            pendingCommit={"base": 0, "commitId": b64(hashlib.sha256(commit).digest())})
            document["outbound"] = [{"kind": "commit", "base": 0, "data": b64(commit)},
                                    {"kind": "welcome", "base": None,
                                     "data": b64(output.welcome_message.to_bytes())}]
            self.group = group
        self.transact(operation)
        return self.send_pending()

    def accept_welcome(self, envelope):
        self.require("joinPending")
        if envelope["kind"] != "welcome" or b64(envelope["cid"]) != self.document["conversation"]:
            raise Rejected("welcome for another conversation")
        try:
            welcome = Message.from_bytes(envelope["data"])
        except MlsError as exc:
            raise Rejected("malformed welcome") from exc

        def operation(document):
            group = self.client.join_group(None, welcome).group
            self.check_roster(group, established=True)
            group.write_to_storage()  # also deletes the consumed key package
            if document["keyPackages"] or group.current_epoch() < 1:
                raise ClosedError("consumed key package still present")
            document.update(lifecycle="established", outbound=[], lastSeq=envelope["seq"])
            self.group = group
        self.transact(operation)

    # ---- commits -----------------------------------------------------------

    def update(self):
        self.require("established")
        if self.document["pendingCommit"]:
            raise Rejected("a commit is already unresolved")

        def operation(document):
            base = self.group.current_epoch()
            commit = self.group.commit().commit_message.to_bytes()
            self.group.write_to_storage()
            document["pendingCommit"] = {"base": base, "commitId": b64(hashlib.sha256(commit).digest())}
            document["outbound"] = [{"kind": "commit", "base": base, "data": b64(commit)}]
        self.transact(operation)
        return self.send_pending()

    def send_pending(self):
        """(Re)send the exact persisted commit bytes and resolve the relay decision."""
        document = self.document
        commit = next(o for o in document["outbound"] if o["kind"] == "commit")
        conversation = unb64(document["conversation"])
        data = unb64(commit["data"])
        if b64(hashlib.sha256(data).digest()) != document["pendingCommit"]["commitId"]:
            self.halt(RelayViolation("outbound bytes do not match the pending commit"))
        status, seq = self.relay.post(conversation, "commit", commit["base"], data, self.name)
        if status == "ACCEPTED":
            self.apply_commit({"cid": conversation, "seq": seq, "kind": "commit",
                               "base": commit["base"], "data": data}, own=True)
            self.release_outbound()
        elif status == "STALE":
            self.apply_commit(self.relay.entry(conversation, seq), own=False)
        else:
            raise Rejected("relay rejected the commit")
        return status

    def apply_commit(self, envelope, own):
        """Process a relay-accepted commit. Metadata is checked, never trusted."""
        self.require("creating", "established")
        base = envelope["base"]
        if self.group.current_epoch() != base:  # cheap check before any transaction
            self.halt(RelayViolation("accepted commit base does not match local epoch"))
        try:
            message = Message.from_bytes(envelope["data"])
        except MlsError:
            self.halt(RelayViolation("accepted commit is malformed"))

        def operation(document):
            try:
                result = self.group.process_incoming_message(message)
            except MlsError as exc:
                if self.store.callback_failed:
                    raise
                raise RelayViolation("accepted commit failed MLS processing") from exc
            if not isinstance(result, ReceivedMessage.COMMIT) or self.group.current_epoch() != base + 1:
                raise RelayViolation("accepted commit did not advance exactly one epoch")
            self.check_roster(self.group, established=True)
            self.group.write_to_storage()
            document.update(lifecycle="established", pendingCommit=None,
                            lastSeq=max(document["lastSeq"], envelope["seq"]))
            document["outbound"] = [o for o in document["outbound"] if o["kind"] != "commit"]
        self.transact(operation)

    def release_outbound(self):
        """Publish persisted non-commit outbound bytes, then drop them."""
        document = self.document
        pending = [o for o in document["outbound"] if o["kind"] != "commit"]
        if not pending:
            return
        conversation = unb64(document["conversation"])
        for item in pending:
            self.relay.post(conversation, item["kind"], item["base"], unb64(item["data"]), self.name)

        def operation(staged):
            staged["outbound"] = [o for o in staged["outbound"] if o["kind"] == "commit"]
        self.transact(operation)

    # ---- application messages ---------------------------------------------

    def send(self, plaintext):
        self.require("established")
        if self.document["pendingCommit"]:
            raise Rejected("no application messages while a commit is unresolved")

        def operation(document):
            wire = self.group.encrypt_application_message(plaintext).to_bytes()
            self.group.write_to_storage()
            return wire
        wire = self.transact(operation)
        self.relay.post(unb64(self.document["conversation"]), "application",
                        self.group.current_epoch(), wire, self.name)
        return wire

    def receive(self, envelope):
        self.require("established")
        if b64(envelope["cid"]) != self.document["conversation"]:
            raise Rejected("envelope for another conversation")
        if envelope["seq"] <= self.document["lastSeq"]:
            return None  # already processed delivery
        if envelope["kind"] == "commit":
            if self.document["pendingCommit"]:
                raise Rejected("resolve the local pending commit through the relay first")
            return self.apply_commit(envelope, own=False)
        if envelope["kind"] != "application":
            raise Rejected("unexpected envelope kind")
        try:
            message = Message.from_bytes(envelope["data"])  # parse before any transaction
        except MlsError as exc:
            raise Rejected("malformed MLS message") from exc

        def operation(document):
            result = self.group.process_incoming_message(message)
            if not isinstance(result, ReceivedMessage.APPLICATION_MESSAGE):
                raise Rejected("not an application message")
            if member_pin(result.sender) != unb64(document["peerPin"]):
                raise IdentityChanged("application sender is not the pinned peer")
            self.group.write_to_storage()  # persists prior-epoch secret updates too
            document["lastSeq"] = envelope["seq"]
            return result.data
        return self.transact(operation)

    def sync(self):
        """Deliver everything new from the relay, in relay order."""
        self.require("established")
        conversation = unb64(self.document["conversation"])
        delivered = []
        for envelope in self.relay.fetch(conversation, self.name, self.document["lastSeq"]):
            if envelope["kind"] in ("keypackage", "welcome"):
                continue
            delivered.append(self.receive(envelope))
        return delivered


def copy_device(device, destination, relay=None):
    shutil.copytree(device.root, destination)
    return Device(destination, device.name, relay or device.relay, device.clock).open()
