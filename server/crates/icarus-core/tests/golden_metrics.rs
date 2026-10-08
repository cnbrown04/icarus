//! Golden parity for the metrics port (PLAN.md 8, 17.4).
//!
//! Reads `shared/golden/metrics_v1.json` and checks every case of every section. The Swift
//! `Metrics` package reads the same file. Floats use the file's tolerance. Integers, booleans and
//! strings compare exactly. Every mismatch is collected and reported together.

use std::collections::BTreeMap;
use std::fmt::Debug;
use std::path::PathBuf;

use chrono_tz::Tz;
use icarus_core::metrics::algo_version::AlgoVersion;
use icarus_core::metrics::baevsky;
use icarus_core::metrics::calories::{self, FormulaSex, UserProfile};
use icarus_core::metrics::five_minute_windows::{self, FiveMinuteWindow};
use icarus_core::metrics::heart_rate_zones::{self, HeartRateZone};
use icarus_core::metrics::hrv;
use icarus_core::metrics::local_time::LocalDay;
use icarus_core::metrics::minute_aggregation::{self, MinuteAggregate};
use icarus_core::metrics::minute_metrics::{MinuteMetricsCalculator, MinuteMetricsContext};
use icarus_core::metrics::resting_hr;
use icarus_core::metrics::rr_cleaner;
use icarus_core::metrics::samples::{HeartRateSample, RRSample, SensorContact};
use icarus_core::metrics::stress::{self, StressBaseline};
use serde_json::Value;

const SECTIONS: [&str; 10] = [
    "rr_cases",
    "kcal_cases",
    "minute_cases",
    "rhr_cases",
    "hrmax_cases",
    "hrr_cases",
    "window_cases",
    "baevsky_cases",
    "stress_cases",
    "minute_metric_cases",
];

#[derive(Default)]
struct Checks {
    tolerance: f64,
    section: &'static str,
    case: String,
    cases: BTreeMap<&'static str, usize>,
    failures: Vec<String>,
}

impl Checks {
    fn case(&mut self, section: &'static str, name: &str) {
        self.section = section;
        self.case = name.to_owned();
        *self.cases.entry(section).or_insert(0) += 1;
    }

    fn fail(&mut self, field: &str, detail: String) {
        self.failures.push(format!(
            "{} / {} / {field}: {detail}",
            self.section, self.case
        ));
    }

    /// Exact comparison for integers, booleans and strings.
    fn exact<T: PartialEq + Debug>(&mut self, field: &str, actual: T, expected: T) {
        if actual != expected {
            self.fail(field, format!("actual {actual:?}, expected {expected:?}"));
        }
    }

    /// Tolerance comparison for floats. `null` in the golden file means absent.
    fn float(&mut self, field: &str, actual: Option<f64>, expected: &Value) {
        match (actual, opt_f64(expected)) {
            (None, None) => {}
            (Some(a), Some(e)) => {
                let diff = (a - e).abs();
                if diff.is_nan() || diff > self.tolerance {
                    self.fail(field, format!("actual {a}, expected {e}, diff {diff}"));
                }
            }
            (a, e) => self.fail(field, format!("actual {a:?}, expected {e:?}")),
        }
    }
}

fn golden_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/golden/metrics_v1.json")
}

fn cases<'a>(doc: &'a Value, key: &str) -> &'a [Value] {
    doc[key]
        .as_array()
        .unwrap_or_else(|| panic!("golden section {key} missing"))
}

fn name_of(case: &Value) -> &str {
    case["name"].as_str().expect("case name")
}

fn array<'a>(v: &'a Value, what: &str) -> &'a [Value] {
    v.as_array()
        .unwrap_or_else(|| panic!("golden {what} is not an array"))
}

fn int_of(v: &Value) -> i64 {
    if let Some(i) = v.as_i64() {
        return i;
    }
    let f = v
        .as_f64()
        .unwrap_or_else(|| panic!("golden {v} is not a number"));
    assert_eq!(f.fract(), 0.0, "golden {f} is not integral");
    f as i64
}

fn f64_of(v: &Value) -> f64 {
    v.as_f64()
        .unwrap_or_else(|| panic!("golden {v} is not a number"))
}

fn opt_f64(v: &Value) -> Option<f64> {
    if v.is_null() { None } else { Some(f64_of(v)) }
}

fn opt_i64(v: &Value) -> Option<i64> {
    if v.is_null() { None } else { Some(int_of(v)) }
}

fn opt_text(v: &Value) -> Option<&str> {
    if v.is_null() {
        None
    } else {
        Some(v.as_str().expect("golden text"))
    }
}

fn bool_of(v: &Value) -> bool {
    v.as_bool()
        .unwrap_or_else(|| panic!("golden {v} is not a bool"))
}

fn contact_of(v: &Value) -> Option<SensorContact> {
    match v.as_str() {
        Some("detected") => Some(SensorContact::Detected),
        Some("not_detected") => Some(SensorContact::NotDetected),
        None if v.is_null() => None,
        other => panic!("unknown contact {other:?}"),
    }
}

/// `[ts_ms, bpm, contact]`
fn heart_rate_samples(v: &Value) -> Vec<HeartRateSample> {
    array(v, "samples")
        .iter()
        .map(|row| HeartRateSample {
            ts_ms: int_of(&row[0]),
            bpm: int_of(&row[1]),
            contact: contact_of(&row[2]),
        })
        .collect()
}

/// `[ts_ms, rr_ms]`
fn rr_samples(v: &Value) -> Vec<RRSample> {
    array(v, "rr")
        .iter()
        .map(|row| RRSample {
            ts_ms: int_of(&row[0]),
            rr_ms: f64_of(&row[1]),
        })
        .collect()
}

/// `[minute_ms, hr_avg, hr_n]`. RestingHR reads only `hr_avg` and `hr_n`, so the min and max
/// fields are filled from the average and are not used.
fn minutes_of(v: &Value) -> Vec<MinuteAggregate> {
    array(v, "minutes")
        .iter()
        .map(|row| {
            let avg = f64_of(&row[1]);
            MinuteAggregate {
                minute_ms: int_of(&row[0]),
                hr_avg: avg,
                hr_min: avg.round() as i64,
                hr_max: avg.round() as i64,
                hr_n: int_of(&row[2]) as usize,
            }
        })
        .collect()
}

/// `[start_ms, hr_mean, valid, ln_rmssd]`. The stress baseline reads only these fields.
fn window_row(row: &Value) -> FiveMinuteWindow {
    FiveMinuteWindow {
        start_ms: int_of(&row[0]),
        hr_mean: opt_f64(&row[1]),
        rr_count: 0,
        rr_sum_ms: 0.0,
        valid: bool_of(&row[2]),
        rmssd: None,
        sdnn: None,
        ln_rmssd: opt_f64(&row[3]),
        baevsky_sqrt: None,
    }
}

fn history_of(v: &Value) -> Vec<FiveMinuteWindow> {
    array(v, "history").iter().map(window_row).collect()
}

fn profile_of(v: &Value) -> UserProfile {
    let sex = match v["sex"].as_str() {
        Some("male") => FormulaSex::Male,
        Some("female") => FormulaSex::Female,
        other => panic!("unknown sex {other:?}"),
    };
    UserProfile {
        sex,
        age_years: int_of(&v["age_years"]),
        height_cm: f64_of(&v["height_cm"]),
        weight_kg: f64_of(&v["weight_kg"]),
    }
}

fn tz_of(v: &Value) -> Tz {
    v.as_str()
        .expect("golden tz")
        .parse()
        .unwrap_or_else(|e| panic!("unknown IANA zone {v}: {e}"))
}

fn day_of(v: &Value) -> LocalDay {
    LocalDay {
        year: int_of(&v["year"]) as i32,
        month: int_of(&v["month"]) as u32,
        day: int_of(&v["day"]) as u32,
    }
}

fn zone_name(zone: HeartRateZone) -> &'static str {
    match zone {
        HeartRateZone::Below => "below",
        HeartRateZone::Zone1 => "zone1",
        HeartRateZone::Zone2 => "zone2",
        HeartRateZone::Zone3 => "zone3",
        HeartRateZone::Zone4 => "zone4",
        HeartRateZone::Zone5 => "zone5",
    }
}

fn check_rr(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("rr_cases", name_of(case));
        let exp = &case["expected"];
        let rr: Vec<f64> = array(&case["rr_ms"], "rr_ms").iter().map(f64_of).collect();
        let flags = rr_cleaner::accepted_flags(&rr);
        let expected_flags: Vec<bool> = array(&exp["rr_accepted"], "rr_accepted")
            .iter()
            .map(bool_of)
            .collect();
        c.exact("rr_accepted", flags.clone(), expected_flags);

        let intervals: Vec<RRSample> = rr
            .iter()
            .enumerate()
            .map(|(i, &rr_ms)| RRSample {
                ts_ms: i as i64,
                rr_ms,
            })
            .collect();
        let kept = rr_cleaner::accepted(&intervals);
        c.exact(
            "accepted count",
            kept.len(),
            flags.iter().filter(|f| **f).count(),
        );

        let accepted: Vec<f64> = kept.iter().map(|s| s.rr_ms).collect();
        c.float("rmssd", hrv::rmssd(&accepted), &exp["rmssd"]);
        c.float("sdnn", hrv::sdnn(&accepted), &exp["sdnn"]);
        c.float("ln_rmssd", hrv::ln_rmssd(&accepted), &exp["ln_rmssd"]);
    }
}

fn check_kcal(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("kcal_cases", name_of(case));
        let exp = &case["expected"];
        let profile = profile_of(&case["profile"]);
        let resting = f64_of(&case["resting_hr"]);
        let max = f64_of(&case["max_hr"]);
        let hrs = array(&case["hr_bpm"], "hr_bpm");
        let kcal = array(&exp["kcal_min"], "kcal_min");
        let active = array(&exp["active_kcal_min"], "active_kcal_min");
        let estimated = array(&exp["estimated"], "estimated");

        c.float(
            "hr_flex",
            Some(calories::heart_rate_flex(resting, max)),
            &exp["hr_flex"],
        );
        c.float(
            "bmr_kcal_min",
            Some(calories::mifflin_bmr_per_minute(&profile)),
            &exp["bmr_kcal_min"],
        );
        c.exact("minute count", hrs.len(), kcal.len());
        c.exact("minute count", hrs.len(), active.len());
        c.exact("minute count", hrs.len(), estimated.len());

        for (i, hr) in hrs.iter().enumerate() {
            let energy = calories::minute_energy(opt_f64(hr), &profile, resting, max);
            c.float(&format!("kcal_min[{i}]"), Some(energy.kcal), &kcal[i]);
            c.float(
                &format!("active_kcal_min[{i}]"),
                Some(energy.active_kcal),
                &active[i],
            );
            c.exact(
                &format!("estimated[{i}]"),
                energy.estimated,
                bool_of(&estimated[i]),
            );
        }
    }
}

fn check_minutes(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("minute_cases", name_of(case));
        let minutes = minute_aggregation::aggregate(&heart_rate_samples(&case["samples"]));
        let expected = array(&case["expected"]["minutes"], "minutes");
        c.exact("minute count", minutes.len(), expected.len());
        for (m, e) in minutes.iter().zip(expected) {
            c.exact("minute_ms", m.minute_ms, int_of(&e["minute_ms"]));
            c.float("hr_avg", Some(m.hr_avg), &e["hr_avg"]);
            c.exact("hr_min", m.hr_min, int_of(&e["hr_min"]));
            c.exact("hr_max", m.hr_max, int_of(&e["hr_max"]));
            c.exact("hr_n", m.hr_n as i64, int_of(&e["hr_n"]));
            c.float("coverage", Some(m.coverage()), &e["coverage"]);
        }
    }
}

fn check_rhr(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("rhr_cases", name_of(case));
        let day = day_of(&case["local_day"]);
        let tz = tz_of(&case["tz"]);
        let minutes = minutes_of(&case["minutes"]);
        c.float(
            "rhr",
            resting_hr::for_night(day, &minutes, tz),
            &case["expected"]["rhr"],
        );
    }
}

fn check_hrmax(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("hrmax_cases", name_of(case));
        let got =
            heart_rate_zones::max_hr(opt_i64(&case["user_hr_max"]), int_of(&case["age_years"]));
        c.float("hr_max", Some(got), &case["expected"]["hr_max"]);
    }
}

fn check_hrr(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("hrr_cases", name_of(case));
        let exp = &case["expected"];
        let hr = f64_of(&case["hr"]);
        let resting = f64_of(&case["resting_hr"]);
        let max = f64_of(&case["max_hr"]);
        let fraction = heart_rate_zones::hrr_fraction(hr, resting, max);
        c.float("hrr_fraction", fraction, &exp["hrr_fraction"]);
        let zone = fraction.map(|f| zone_name(HeartRateZone::of_hrr_fraction(f)));
        c.exact("zone", zone, opt_text(&exp["zone"]));
        c.exact(
            "exertion",
            heart_rate_zones::is_exertion(Some(hr), Some(resting), max),
            bool_of(&exp["exertion"]),
        );
    }
}

fn check_windows(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("window_cases", name_of(case));
        let samples = heart_rate_samples(&case["samples"]);
        let rr = rr_samples(&case["rr"]);
        let range = int_of(&case["range_start_ms"])..int_of(&case["range_end_ms"]);
        let windows = five_minute_windows::build(&samples, &rr, range);
        let expected = array(&case["expected"]["windows"], "windows");
        c.exact("window count", windows.len(), expected.len());
        for (w, e) in windows.iter().zip(expected) {
            c.exact("start_ms", w.start_ms, int_of(&e["start_ms"]));
            c.float("hr_mean", w.hr_mean, &e["hr_mean"]);
            c.exact("rr_count", w.rr_count as i64, int_of(&e["rr_count"]));
            c.float("rr_sum_ms", Some(w.rr_sum_ms), &e["rr_sum_ms"]);
            c.exact("valid", Some(w.valid), e["valid"].as_bool());
            c.float("rmssd", w.rmssd, &e["rmssd"]);
            c.float("sdnn", w.sdnn, &e["sdnn"]);
            c.float("ln_rmssd", w.ln_rmssd, &e["ln_rmssd"]);
            c.float("baevsky_sqrt", w.baevsky_sqrt, &e["baevsky_sqrt"]);
        }
    }
}

fn check_baevsky(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("baevsky_cases", name_of(case));
        let rr: Vec<f64> = array(&case["rr_ms"], "rr_ms").iter().map(f64_of).collect();
        let exp = &case["expected"];
        c.float("si", baevsky::stress_index(&rr), &exp["si"]);
        c.float("sqrt_si", baevsky::sqrt_stress_index(&rr), &exp["sqrt_si"]);
    }
}

fn check_stress(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("stress_cases", name_of(case));
        let exp = &case["expected"];
        let day = day_of(&case["day"]);
        let tz = tz_of(&case["tz"]);
        let resting = opt_f64(&case["resting_hr"]);
        let max = f64_of(&case["max_hr"]);
        let baseline = StressBaseline::build(&history_of(&case["history"]), day, tz, resting, max);
        let result = stress::score(&window_row(&case["current"]), resting, max, &baseline);

        c.exact(
            "valid_days",
            baseline.valid_days as i64,
            int_of(&exp["valid_days"]),
        );
        c.exact(
            "hr_only_days",
            baseline.hr_only_days as i64,
            int_of(&exp["hr_only_days"]),
        );
        c.float("hr_median", baseline.hr_median, &exp["hr_median"]);
        c.float("hr_mad", baseline.hr_mad, &exp["hr_mad"]);
        c.float(
            "ln_rmssd_median",
            baseline.ln_rmssd_median,
            &exp["ln_rmssd_median"],
        );
        c.float("ln_rmssd_mad", baseline.ln_rmssd_mad, &exp["ln_rmssd_mad"]);
        c.float(
            "hr_only_median",
            baseline.hr_only_median,
            &exp["hr_only_median"],
        );
        c.float("hr_only_mad", baseline.hr_only_mad, &exp["hr_only_mad"]);
        c.exact("stress", result.stress, opt_i64(&exp["stress"]));
        c.exact("state", Some(result.state.as_str()), exp["state"].as_str());
    }
}

fn check_minute_metrics(c: &mut Checks, all: &[Value]) {
    for case in all {
        c.case("minute_metric_cases", name_of(case));
        let tz = tz_of(&case["tz"]);
        let day = day_of(&case["day"]);
        let resting = opt_f64(&case["resting_hr"]);
        let max = f64_of(&case["max_hr"]);
        let context = MinuteMetricsContext {
            profile: profile_of(&case["profile"]),
            resting_hr: resting,
            max_hr: max,
            baseline: StressBaseline::build(&history_of(&case["history"]), day, tz, resting, max),
        };
        let range = int_of(&case["range_start_ms"])..int_of(&case["range_end_ms"]);
        let rows = MinuteMetricsCalculator::rows(
            range,
            &heart_rate_samples(&case["samples"]),
            &rr_samples(&case["rr"]),
            &context,
        );
        let expected = array(&case["expected"]["rows"], "rows");
        c.exact("row count", rows.len(), expected.len());
        for (row, e) in rows.iter().zip(expected) {
            c.exact("minute_ms", row.minute_ms, int_of(&e["minute_ms"]));
            c.float("hr_avg", row.hr_avg, &e["hr_avg"]);
            c.exact("hr_min", row.hr_min, opt_i64(&e["hr_min"]));
            c.exact("hr_max", row.hr_max, opt_i64(&e["hr_max"]));
            c.exact("hr_n", row.hr_n as i64, int_of(&e["hr_n"]));
            c.float("rmssd_ms", row.rmssd_ms, &e["rmssd_ms"]);
            c.float("sdnn_ms", row.sdnn_ms, &e["sdnn_ms"]);
            c.float("baevsky_sqrt", row.baevsky_sqrt, &e["baevsky_sqrt"]);
            c.exact("stress", row.stress, opt_i64(&e["stress"]));
            c.exact(
                "stress_state",
                Some(row.stress_state.as_str()),
                e["stress_state"].as_str(),
            );
            c.float("kcal", Some(row.kcal), &e["kcal"]);
            c.float("active_kcal", Some(row.active_kcal), &e["active_kcal"]);
            c.exact(
                "kcal_estimated",
                Some(row.kcal_estimated),
                e["kcal_estimated"].as_bool(),
            );
            c.exact("algo_version", row.algo_version, AlgoVersion::CURRENT);
        }
    }
}

#[test]
fn golden_metrics_v1_matches_the_rust_port() {
    let path = golden_path();
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let doc: Value = serde_json::from_str(&raw).expect("golden file is valid JSON");

    assert_eq!(doc["format"], "icarus-golden-metrics");
    assert_eq!(doc["format_version"], 1);
    let algo = AlgoVersion::CURRENT;
    assert_eq!(doc["algo_version"]["hr"], algo.hr);
    assert_eq!(doc["algo_version"]["hrv"], algo.hrv);
    assert_eq!(doc["algo_version"]["stress"], algo.stress);
    assert_eq!(doc["algo_version"]["kcal"], algo.kcal);

    let mut c = Checks {
        tolerance: f64_of(&doc["tolerance"]),
        ..Checks::default()
    };
    check_rr(&mut c, cases(&doc, "rr_cases"));
    check_kcal(&mut c, cases(&doc, "kcal_cases"));
    check_minutes(&mut c, cases(&doc, "minute_cases"));
    check_rhr(&mut c, cases(&doc, "rhr_cases"));
    check_hrmax(&mut c, cases(&doc, "hrmax_cases"));
    check_hrr(&mut c, cases(&doc, "hrr_cases"));
    check_windows(&mut c, cases(&doc, "window_cases"));
    check_baevsky(&mut c, cases(&doc, "baevsky_cases"));
    check_stress(&mut c, cases(&doc, "stress_cases"));
    check_minute_metrics(&mut c, cases(&doc, "minute_metric_cases"));

    for section in SECTIONS {
        let checked = c.cases.get(section).copied().unwrap_or(0);
        assert_eq!(
            checked,
            cases(&doc, section).len(),
            "{section}: every golden case must be checked"
        );
        eprintln!("golden {section}: {checked} cases checked");
    }
    assert!(
        c.failures.is_empty(),
        "{} golden mismatches:\n{}",
        c.failures.len(),
        c.failures.join("\n")
    );
}
