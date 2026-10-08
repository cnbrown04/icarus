//! Alarms, rhythms and schedules (api-contract.md "Alarms", PLAN.md §9).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::time::rfc3339;
use crate::{ValidationError, invalid};

/// Built-in rhythm names. PLAN.md §9.2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NamedRhythm {
    Single,
    Double,
    Triple,
    Long,
    Ramp,
    Sos,
}

/// One rhythm step. A buzz loop counts as 1 s toward the 30 s limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Step {
    Buzz { preset: u8, loops: u8 },
    Pause { ms: u32 },
}

/// A built-in name, or an explicit list of steps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Rhythm {
    Named(NamedRhythm),
    Steps(Vec<Step>),
}

pub const MAX_RHYTHM_STEPS: usize = 10;
pub const MAX_RHYTHM_MS: u64 = 30_000;
const BUZZ_LOOP_MS: u64 = 1_000;

impl Rhythm {
    /// Checks the contract rules: 1 to 10 steps, loops >= 1, total time <= 30 s.
    pub fn validate(&self) -> Result<(), ValidationError> {
        let steps = match self {
            Rhythm::Named(_) => return Ok(()),
            Rhythm::Steps(steps) => steps,
        };
        if steps.is_empty() {
            return invalid("rhythm needs at least one step");
        }
        if steps.len() > MAX_RHYTHM_STEPS {
            return invalid(format!("rhythm has more than {MAX_RHYTHM_STEPS} steps"));
        }
        let mut total_ms: u64 = 0;
        for step in steps {
            match *step {
                Step::Buzz { loops, .. } => {
                    if loops == 0 {
                        return invalid("buzz loops must be at least 1");
                    }
                    total_ms += u64::from(loops) * BUZZ_LOOP_MS;
                }
                Step::Pause { ms } => total_ms += u64::from(ms),
            }
        }
        if total_ms > MAX_RHYTHM_MS {
            return invalid("rhythm is longer than 30 s");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AlarmKind {
    Scheduled,
    Webhook,
    Relay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    Phone,
    Band,
}

/// Scheduled alarms only. `weekdays` uses ISO numbering (1 = Monday). Empty means the next occurrence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Schedule {
    pub time: String,
    pub weekdays: Vec<u8>,
}

impl Schedule {
    pub fn validate(&self) -> Result<(), ValidationError> {
        let bytes = self.time.as_bytes();
        let well_formed = bytes.len() == 5
            && bytes[2] == b':'
            && bytes[..2].iter().all(u8::is_ascii_digit)
            && bytes[3..].iter().all(u8::is_ascii_digit);
        let in_range = well_formed && {
            let hh = (bytes[0] - b'0') * 10 + (bytes[1] - b'0');
            let mm = (bytes[3] - b'0') * 10 + (bytes[4] - b'0');
            hh < 24 && mm < 60
        };
        if !in_range {
            return invalid("schedule time must be HH:MM");
        }
        let mut seen = [false; 8];
        for &day in &self.weekdays {
            if !(1..=7).contains(&day) {
                return invalid("weekdays must be 1 (Monday) to 7 (Sunday)");
            }
            if std::mem::replace(&mut seen[usize::from(day)], true) {
                return invalid("weekdays must be unique");
            }
        }
        Ok(())
    }
}

/// `Alarm` in api-contract.md.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Alarm {
    pub id: Uuid,
    pub kind: AlarmKind,
    pub label: String,
    pub schedule: Option<Schedule>,
    pub rhythm: Rhythm,
    pub channels: Vec<Channel>,
    pub enabled: bool,
    pub version: i64,
    #[serde(with = "rfc3339")]
    pub updated_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    pub deleted_at: Option<DateTime<Utc>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buzz(loops: u8) -> Step {
        Step::Buzz { preset: 2, loops }
    }

    #[test]
    fn named_rhythms_parse_and_validate() {
        let r: Rhythm = serde_json::from_str(r#""sos""#).unwrap();
        assert_eq!(r, Rhythm::Named(NamedRhythm::Sos));
        assert!(r.validate().is_ok());
    }

    #[test]
    fn step_rhythm_round_trips_to_contract_shape() {
        let json = r#"[{"type":"buzz","preset":2,"loops":1},{"type":"pause","ms":300}]"#;
        let r: Rhythm = serde_json::from_str(json).unwrap();
        assert_eq!(r, Rhythm::Steps(vec![buzz(1), Step::Pause { ms: 300 }]));
        assert_eq!(serde_json::to_string(&r).unwrap(), json);
        assert!(r.validate().is_ok());
    }

    #[test]
    fn rejects_unknown_step_fields_and_names() {
        assert!(serde_json::from_str::<Rhythm>(r#""polka""#).is_err());
        assert!(serde_json::from_str::<Rhythm>(r#"[{"type":"pause","ms":1,"x":2}]"#).is_err());
    }

    #[test]
    fn rejects_empty_and_too_many_steps() {
        assert!(Rhythm::Steps(vec![]).validate().is_err());
        let eleven = vec![Step::Pause { ms: 1 }; 11];
        assert!(Rhythm::Steps(eleven).validate().is_err());
        let ten = vec![Step::Pause { ms: 1 }; 10];
        assert!(Rhythm::Steps(ten).validate().is_ok());
    }

    #[test]
    fn total_time_counts_each_buzz_loop_as_one_second() {
        // 20 loops (20 s) + 10 s of pauses = 30 s exactly: allowed.
        let ok = Rhythm::Steps(vec![buzz(20), Step::Pause { ms: 10_000 }]);
        assert!(ok.validate().is_ok());
        // One millisecond over.
        let over = Rhythm::Steps(vec![buzz(20), Step::Pause { ms: 10_001 }]);
        assert!(over.validate().is_err());
        // 31 loops alone is over the limit.
        assert!(Rhythm::Steps(vec![buzz(31)]).validate().is_err());
    }

    #[test]
    fn buzz_needs_at_least_one_loop() {
        assert!(Rhythm::Steps(vec![buzz(0)]).validate().is_err());
    }

    #[test]
    fn schedule_time_and_weekdays() {
        let ok = Schedule {
            time: "06:30".into(),
            weekdays: vec![1, 2, 3, 4, 5],
        };
        assert!(ok.validate().is_ok());
        assert!(
            Schedule {
                time: "00:00".into(),
                weekdays: vec![]
            }
            .validate()
            .is_ok()
        );
        assert!(
            Schedule {
                time: "24:00".into(),
                weekdays: vec![]
            }
            .validate()
            .is_err()
        );
        assert!(
            Schedule {
                time: "6:30".into(),
                weekdays: vec![]
            }
            .validate()
            .is_err()
        );
        assert!(
            Schedule {
                time: "06:60".into(),
                weekdays: vec![]
            }
            .validate()
            .is_err()
        );
        assert!(
            Schedule {
                time: "06:30".into(),
                weekdays: vec![0]
            }
            .validate()
            .is_err()
        );
        assert!(
            Schedule {
                time: "06:30".into(),
                weekdays: vec![8]
            }
            .validate()
            .is_err()
        );
        assert!(
            Schedule {
                time: "06:30".into(),
                weekdays: vec![1, 1]
            }
            .validate()
            .is_err()
        );
    }
}
