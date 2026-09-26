//! Test-only adversary for M1.4 T3. Not part of any patch or product.
//!
//! Models a modified peer that loads its own group state and commits a NEW
//! signature key under the SAME BasicCredential, which the pinned
//! BasicIdentityProvider accepts as a valid successor. Reads hex lines on
//! stdin: group id, credential id, group state, then "epoch_id hex" rows.
//! Prints the commit bytes as hex. Copied into mls-rs-uniffi/examples/ by
//! run-m14-linux.sh.

use std::collections::HashMap;
use std::convert::Infallible;
use std::io::BufRead;

use mls_rs::identity::basic::{BasicCredential, BasicIdentityProvider};
use mls_rs::identity::SigningIdentity;
use mls_rs::{CipherSuite, CipherSuiteProvider, CryptoProvider};
use mls_rs_core::group::{EpochRecord, GroupState, GroupStateStorage};
use mls_rs_crypto_openssl::OpensslCryptoProvider;
use zeroize::Zeroizing;

#[derive(Clone, Default)]
struct Snapshot {
    state: HashMap<Vec<u8>, Vec<u8>>,
    epochs: HashMap<u64, Vec<u8>>,
}

impl GroupStateStorage for Snapshot {
    type Error = Infallible;

    fn state(&self, group_id: &[u8]) -> Result<Option<Zeroizing<Vec<u8>>>, Infallible> {
        Ok(self.state.get(group_id).cloned().map(Zeroizing::new))
    }

    fn epoch(&self, _: &[u8], epoch_id: u64) -> Result<Option<Zeroizing<Vec<u8>>>, Infallible> {
        Ok(self.epochs.get(&epoch_id).cloned().map(Zeroizing::new))
    }

    fn write(
        &mut self,
        _: GroupState,
        _: Vec<EpochRecord>,
        _: Vec<EpochRecord>,
    ) -> Result<(), Infallible> {
        Ok(())
    }

    fn max_epoch_id(&self, _: &[u8]) -> Result<Option<u64>, Infallible> {
        Ok(self.epochs.keys().max().copied())
    }
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn main() {
    let lines: Vec<String> = std::io::stdin()
        .lock()
        .lines()
        .map(Result::unwrap)
        .collect();
    let group_id = unhex(&lines[0]);
    let credential = unhex(&lines[1]);
    let mut storage = Snapshot::default();
    storage.state.insert(group_id.clone(), unhex(&lines[2]));
    for row in &lines[3..] {
        let (id, data) = row.split_once(' ').expect("epoch row");
        storage
            .epochs
            .insert(id.parse().expect("epoch id"), unhex(data));
    }

    let crypto = OpensslCryptoProvider::default();
    let suite = crypto
        .cipher_suite_provider(CipherSuite::CURVE25519_AES128)
        .expect("suite");
    let (secret, public) = suite.signature_key_generate().expect("keygen");
    let same_credential = BasicCredential::new(credential).into_credential();

    let client = mls_rs::Client::builder()
        .crypto_provider(crypto)
        .identity_provider(BasicIdentityProvider::new())
        .group_state_storage(storage)
        .build();
    let mut group = client.load_group(&group_id).expect("load group");
    let output = group
        .commit_builder()
        .set_new_signing_identity(secret, SigningIdentity::new(same_credential, public))
        .build()
        .expect("key-changing commit");
    let bytes = output.commit_message.to_bytes().expect("encode");
    println!(
        "{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    );
}
