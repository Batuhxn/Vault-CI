"""Identity restore checks through the pinned upstream OpenSSL provider."""

import os

from mls_rs_uniffi import (
    CipherSuite,
    Error,
    SignatureKeypair,
    SignatureSecretKey,
    generate_signature_keypair,
    validate_signature_keypair,
)


SUITE = CipherSuite.CURVE25519_AES128
correct = generate_signature_keypair(SUITE)
different = generate_signature_keypair(SUITE)
assert validate_signature_keypair(correct)


def invalid(public, secret):
    candidate = SignatureKeypair(
        cipher_suite=SUITE,
        public_key=public,
        secret_key=SignatureSecretKey(bytes=secret),
    )
    try:
        assert not validate_signature_keypair(candidate)
    except Error:
        pass


invalid(correct.public_key, different.secret_key.bytes)
invalid(different.public_key, correct.secret_key.bytes)
invalid(correct.public_key, correct.secret_key.bytes[:-1])
invalid(correct.public_key, os.urandom(64))
invalid(correct.public_key, b"malformed")
tail_corrupt = bytearray(correct.secret_key.bytes)
tail_corrupt[-1] ^= 1
invalid(correct.public_key, bytes(tail_corrupt))
print("upstream-derived identity validation and malformed material: PASS")
