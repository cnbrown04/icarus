//! WHOOP webhook signature and payload (PLAN.md §5.2 [S3]). Webhooks only say that something changed,
//! so the payload keeps three values: the WHOOP user, the object, and the trace id used for dedupe.

use axum::http::HeaderMap;
use base64::{Engine, engine::general_purpose::STANDARD};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use serde_json::Value;
use sha2::Sha256;

use crate::error::ApiError;

const TIMESTAMP_HEADER: &str = "x-whoop-signature-timestamp";
const SIGNATURE_HEADER: &str = "x-whoop-signature";
const EVENT_TYPES: [&str; 6] = [
    "workout.updated",
    "workout.deleted",
    "sleep.updated",
    "sleep.deleted",
    "recovery.updated",
    "recovery.deleted",
];

/// `X-WHOOP-Signature` is base64(HMAC-SHA256(timestamp + raw body, client secret)).
pub fn verify(client_secret: &str, headers: &HeaderMap, body: &[u8]) -> Result<(), ApiError> {
    let invalid = |reason: &str| ApiError::SignatureInvalid(reason.to_owned());
    let timestamp = headers
        .get(TIMESTAMP_HEADER)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| invalid("The X-WHOOP-Signature-Timestamp header is missing."))?;
    let signature = headers
        .get(SIGNATURE_HEADER)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| invalid("The X-WHOOP-Signature header is missing."))?;
    let signature = STANDARD
        .decode(signature.trim())
        .map_err(|_| invalid("The X-WHOOP-Signature header is not base64."))?;

    let mut mac = Hmac::<Sha256>::new_from_slice(client_secret.as_bytes())
        .expect("HMAC accepts keys of any length");
    mac.update(timestamp.as_bytes());
    mac.update(body);
    mac.verify_slice(&signature)
        .map_err(|_| invalid("The signature does not match."))
}

/// A verified event worth keeping. Only the row is stored, never the payload.
#[derive(Debug, PartialEq, Eq)]
pub struct Event {
    pub trace_id: String,
    pub whoop_user_id: i64,
    pub kind: String,
    pub object_id: String,
}

#[derive(Deserialize)]
struct Payload {
    user_id: Value,
    id: Value,
    #[serde(rename = "type")]
    kind: String,
    trace_id: String,
}

/// `Ok(None)` for event types Icarus does not use. They are acknowledged and dropped.
pub fn parse(body: &[u8]) -> Result<Option<Event>, ApiError> {
    let payload: Payload = serde_json::from_slice(body)
        .map_err(|_| ApiError::Validation("The webhook body is not a WHOOP event.".into()))?;
    if !EVENT_TYPES.contains(&payload.kind.as_str()) {
        return Ok(None);
    }
    let trace_id = payload.trace_id.trim().to_owned();
    if trace_id.is_empty() || trace_id.len() > 200 {
        return Err(ApiError::Validation(
            "The webhook has no usable trace_id.".into(),
        ));
    }
    let whoop_user_id = scalar(&payload.user_id)
        .and_then(|s| s.parse::<i64>().ok())
        .ok_or_else(|| ApiError::Validation("The webhook has no usable user_id.".into()))?;
    let object_id = scalar(&payload.id)
        .ok_or_else(|| ApiError::Validation("The webhook has no usable id.".into()))?;
    Ok(Some(Event {
        trace_id,
        whoop_user_id,
        kind: payload.kind,
        object_id,
    }))
}

fn scalar(value: &Value) -> Option<String> {
    match value {
        Value::Number(n) => Some(n.to_string()),
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use axum::http::HeaderValue;
    use base64::engine::general_purpose::STANDARD;

    use super::*;

    fn sign(secret: &str, timestamp: &str, body: &[u8]) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(timestamp.as_bytes());
        mac.update(body);
        STANDARD.encode(mac.finalize().into_bytes())
    }

    fn headers(timestamp: &str, signature: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(TIMESTAMP_HEADER, HeaderValue::from_str(timestamp).unwrap());
        h.insert(SIGNATURE_HEADER, HeaderValue::from_str(signature).unwrap());
        h
    }

    #[test]
    fn signature_is_base64_hmac_over_timestamp_and_body() {
        let body = br#"{"user_id":4242}"#;
        let good = headers("1700000000", &sign("client-secret", "1700000000", body));
        assert!(verify("client-secret", &good, body).is_ok());
        assert!(verify("other-secret", &good, body).is_err(), "wrong key");
        assert!(
            verify("client-secret", &good, b"{}").is_err(),
            "changed body"
        );
        let retimed = headers("1700000001", &sign("client-secret", "1700000000", body));
        assert!(
            verify("client-secret", &retimed, body).is_err(),
            "changed timestamp"
        );
        assert!(verify("client-secret", &headers("1", "not base64!"), body).is_err());
        assert!(verify("client-secret", &HeaderMap::new(), body).is_err());
    }

    #[test]
    fn parse_keeps_three_values_and_ignores_unknown_types() {
        let body = br#"{"user_id":4242,"id":"6b1e0c2a-0000-4000-8000-000000000001","type":"sleep.updated","trace_id":"trace-1"}"#;
        assert_eq!(
            parse(body).unwrap(),
            Some(Event {
                trace_id: "trace-1".into(),
                whoop_user_id: 4242,
                kind: "sleep.updated".into(),
                object_id: "6b1e0c2a-0000-4000-8000-000000000001".into(),
            })
        );
        let other = br#"{"user_id":4242,"id":"x","type":"cycle.updated","trace_id":"t"}"#;
        assert_eq!(parse(other).unwrap(), None);
        assert!(parse(br#"{"type":"sleep.updated"}"#).is_err());
        let no_trace = br#"{"user_id":1,"id":"x","type":"sleep.updated","trace_id":" "}"#;
        assert!(parse(no_trace).is_err());
    }
}
