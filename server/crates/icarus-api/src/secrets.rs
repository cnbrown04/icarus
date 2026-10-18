//! AES-256-GCM for webhook secrets (PLAN.md §18). The key is `ICARUS_ENC_KEY`, base64 for 32 bytes.
//!
//! Sealed form: `nonce (12 bytes) || ciphertext || tag`. The row's id is bound as associated data,
//! so a ciphertext copied to another row fails to open.

use aes_gcm::{
    Aes256Gcm, Key, Nonce,
    aead::{Aead, KeyInit, Payload},
};
use base64::{Engine, engine::general_purpose::STANDARD};

use crate::auth::fill_random;

const NONCE_LEN: usize = 12;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SecretsError {
    #[error("ICARUS_ENC_KEY is not valid base64")]
    NotBase64,
    #[error("ICARUS_ENC_KEY must decode to 32 bytes")]
    WrongLength,
    #[error("sealed value is malformed or was not sealed under this key")]
    Open,
}

#[derive(Clone)]
pub struct Secrets {
    key: [u8; 32],
}

impl std::fmt::Debug for Secrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secrets(<redacted>)")
    }
}

impl Secrets {
    pub fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    /// Parses the `ICARUS_ENC_KEY` value. Whitespace around it is ignored.
    pub fn from_base64(raw: &str) -> Result<Self, SecretsError> {
        let bytes = STANDARD
            .decode(raw.trim())
            .map_err(|_| SecretsError::NotBase64)?;
        let key: [u8; 32] = bytes.try_into().map_err(|_| SecretsError::WrongLength)?;
        Ok(Self::new(key))
    }

    fn cipher(&self) -> Aes256Gcm {
        Aes256Gcm::new(&Key::<Aes256Gcm>::from(self.key))
    }

    pub fn seal(&self, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, SecretsError> {
        let mut nonce = [0u8; NONCE_LEN];
        fill_random(&mut nonce);
        let ciphertext = self
            .cipher()
            .encrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|_| SecretsError::Open)?;
        let mut sealed = Vec::with_capacity(NONCE_LEN + ciphertext.len());
        sealed.extend_from_slice(&nonce);
        sealed.extend_from_slice(&ciphertext);
        Ok(sealed)
    }

    pub fn open(&self, aad: &[u8], sealed: &[u8]) -> Result<Vec<u8>, SecretsError> {
        if sealed.len() < NONCE_LEN {
            return Err(SecretsError::Open);
        }
        let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
        let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| SecretsError::Open)?;
        self.cipher()
            .decrypt(
                &Nonce::from(nonce),
                Payload {
                    msg: ciphertext,
                    aad,
                },
            )
            .map_err(|_| SecretsError::Open)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_round_trips_and_binds_the_row() {
        let secrets = Secrets::new([7; 32]);
        let sealed = secrets.seal(b"row-a", b"s3cret").unwrap();
        assert!(
            !sealed.windows(6).any(|w| w == b"s3cret"),
            "plaintext absent"
        );
        assert_eq!(secrets.open(b"row-a", &sealed).unwrap(), b"s3cret");
        assert!(secrets.open(b"row-b", &sealed).is_err(), "other row id");
        assert!(
            Secrets::new([8; 32]).open(b"row-a", &sealed).is_err(),
            "other key"
        );
    }

    #[test]
    fn key_must_be_32_base64_bytes() {
        let good = STANDARD.encode([1u8; 32]);
        assert!(Secrets::from_base64(&good).is_ok());
        assert!(Secrets::from_base64(&format!(" {good}\n")).is_ok());
        assert_eq!(
            Secrets::from_base64(&STANDARD.encode([1u8; 31])).unwrap_err(),
            SecretsError::WrongLength
        );
        assert_eq!(
            Secrets::from_base64("not base64!").unwrap_err(),
            SecretsError::NotBase64
        );
    }
}
