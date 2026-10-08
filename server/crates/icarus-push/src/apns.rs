//! APNs over HTTP/2 with token auth (`a2`), and the log-only fallback used when APNs is not configured.
//!
//! TODO(PLAN.md §12.5, [Unverified]): nothing here has been sent to Apple's servers yet. The first
//! TestFlight alarm should confirm the alert and silent push, the sandbox/production split, and the
//! 410 path that deletes a token.

use a2::{
    Client, ClientConfig, Endpoint, Error as A2Error, ErrorReason, NotificationOptions, Priority,
    PushType, request::payload::PayloadLike,
};
use icarus_core::Rhythm;
use serde::{Serialize, Serializer};
use serde_json::{Value, json};
use tracing::{debug, info};

use crate::sender::{Alert, Background, Environment, Outcome, PushError, PushSender, Target};

/// `APNS_*` settings. `key_pem` is the `.p8` file's contents.
#[derive(Clone)]
pub struct ApnsSettings {
    pub key_pem: Vec<u8>,
    pub key_id: String,
    pub team_id: String,
    pub topic: String,
}

impl std::fmt::Debug for ApnsSettings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApnsSettings")
            .field("key_id", &self.key_id)
            .field("team_id", &self.team_id)
            .field("topic", &self.topic)
            .finish_non_exhaustive()
    }
}

/// Builds one client per APNs endpoint. A token is valid for both, and each device's
/// environment picks the endpoint.
pub struct ApnsSender {
    sandbox: Client,
    production: Client,
    topic: String,
}

impl ApnsSender {
    pub fn new(settings: &ApnsSettings) -> Result<Self, A2Error> {
        let build = |endpoint| {
            Client::token(
                settings.key_pem.as_slice(),
                settings.key_id.clone(),
                settings.team_id.clone(),
                ClientConfig::new(endpoint),
            )
        };
        Ok(Self {
            sandbox: build(Endpoint::Sandbox)?,
            production: build(Endpoint::Production)?,
            topic: settings.topic.clone(),
        })
    }

    fn client(&self, environment: Environment) -> &Client {
        match environment {
            Environment::Sandbox => &self.sandbox,
            Environment::Production => &self.production,
        }
    }

    async fn send(
        &self,
        target: &Target,
        body: Value,
        push_type: PushType,
        priority: Priority,
    ) -> Result<Outcome, PushError> {
        let payload = RawPayload {
            options: NotificationOptions {
                apns_topic: Some(&self.topic),
                apns_push_type: Some(push_type),
                apns_priority: Some(priority),
                ..Default::default()
            },
            device_token: &target.token,
            body,
        };
        match self.client(target.environment).send(payload).await {
            Ok(response) => Ok(Outcome::Accepted {
                apns_id: response.apns_id,
            }),
            Err(err) => Err(classify(&err)),
        }
    }
}

/// APNs refusals that retrying cannot fix are `Rejected`. Throttling, 5xx and transport errors
/// are `Retryable`.
fn classify(err: &A2Error) -> PushError {
    match err {
        A2Error::ResponseError(response) => {
            let unregistered = response.code == 410
                || response
                    .error
                    .as_ref()
                    .is_some_and(|e| e.reason == ErrorReason::Unregistered);
            if unregistered {
                PushError::Unregistered
            } else if response.code == 429 || response.code >= 500 {
                PushError::Retryable
            } else {
                PushError::Rejected
            }
        }
        _ => PushError::Retryable,
    }
}

fn alert_body(alert: &Alert) -> Result<Value, PushError> {
    Ok(json!({
        "aps": {
            "alert": { "title": alert.title, "body": alert.body },
            "sound": "default",
            "category": "ICARUS_ALARM",
            "interruption-level": "time-sensitive",
        },
        "dispatch_id": alert.dispatch_id,
        "rhythm": rhythm_json(&alert.rhythm)?,
    }))
}

fn background_body(push: &Background) -> Result<Value, PushError> {
    let mut body = json!({ "aps": { "content-available": 1 } });
    if let Some(dispatch_id) = push.dispatch_id {
        body["dispatch_id"] = json!(dispatch_id);
    }
    if let Some(rhythm) = &push.rhythm {
        body["rhythm"] = rhythm_json(rhythm)?;
    }
    if push.config_changed {
        body["config_changed"] = json!(true);
    }
    Ok(body)
}

fn rhythm_json(rhythm: &Rhythm) -> Result<Value, PushError> {
    serde_json::to_value(rhythm).map_err(|_| PushError::Rejected)
}

impl PushSender for ApnsSender {
    async fn alert(&self, target: &Target, alert: &Alert) -> Result<Outcome, PushError> {
        let body = alert_body(alert)?;
        self.send(target, body, PushType::Alert, Priority::High)
            .await
    }

    async fn background(&self, target: &Target, push: &Background) -> Result<Outcome, PushError> {
        let body = background_body(push)?;
        // Priority 5 is what Apple asks for silent pushes (PLAN.md §12.5).
        self.send(target, body, PushType::Background, Priority::Normal)
            .await
    }
}

/// Used when `APNS_*` is not set. Logs once at startup and reports `Outcome::Disabled`.
#[derive(Debug, Default, Clone, Copy)]
pub struct LogOnlySender;

impl LogOnlySender {
    pub fn announce() {
        info!("APNs disabled: alarms are queued but no push is sent");
    }
}

impl PushSender for LogOnlySender {
    async fn alert(&self, _target: &Target, _alert: &Alert) -> Result<Outcome, PushError> {
        debug!("APNs disabled; alert not sent");
        Ok(Outcome::Disabled)
    }

    async fn background(&self, _target: &Target, _push: &Background) -> Result<Outcome, PushError> {
        debug!("APNs disabled; background push not sent");
        Ok(Outcome::Disabled)
    }
}

/// The sender the server runs with. Chosen once at startup.
pub enum AnySender {
    Apns(Box<ApnsSender>),
    LogOnly(LogOnlySender),
}

impl PushSender for AnySender {
    async fn alert(&self, target: &Target, alert: &Alert) -> Result<Outcome, PushError> {
        match self {
            AnySender::Apns(sender) => sender.alert(target, alert).await,
            AnySender::LogOnly(sender) => sender.alert(target, alert).await,
        }
    }

    async fn background(&self, target: &Target, push: &Background) -> Result<Outcome, PushError> {
        match self {
            AnySender::Apns(sender) => sender.background(target, push).await,
            AnySender::LogOnly(sender) => sender.background(target, push).await,
        }
    }
}

/// The payload `a2` sends. Its built-in `aps` type has no `interruption-level`, so the JSON is ours.
#[derive(Debug)]
struct RawPayload<'a> {
    options: NotificationOptions<'a>,
    device_token: &'a str,
    body: Value,
}

impl Serialize for RawPayload<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.body.serialize(serializer)
    }
}

impl PayloadLike for RawPayload<'_> {
    fn get_device_token(&self) -> &str {
        self.device_token
    }

    fn get_options(&self) -> &NotificationOptions<'_> {
        &self.options
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alert_carries_time_sensitive_category_and_dispatch() {
        let alert = Alert {
            dispatch_id: uuid::Uuid::nil(),
            title: "Wake up".into(),
            body: "Front door opened".into(),
            rhythm: Rhythm::Named(icarus_core::NamedRhythm::Double),
        };
        let body = alert_body(&alert).unwrap();
        assert_eq!(body["aps"]["interruption-level"], "time-sensitive");
        assert_eq!(body["aps"]["category"], "ICARUS_ALARM");
        assert_eq!(body["aps"]["sound"], "default");
        assert_eq!(body["rhythm"], "double");
        assert_eq!(body["dispatch_id"], uuid::Uuid::nil().to_string());
    }

    #[test]
    fn background_is_silent() {
        let body = background_body(&Background {
            dispatch_id: None,
            rhythm: None,
            config_changed: true,
        })
        .unwrap();
        assert_eq!(
            body,
            json!({ "aps": { "content-available": 1 }, "config_changed": true })
        );
    }
}
