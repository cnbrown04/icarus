use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use icarus_jobs::{partitions, rollup};
use sqlx::PgPool;
use uuid::Uuid;

async fn partition_exists(pool: &PgPool, name: &str) -> bool {
    sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
        .bind(name)
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn insert_user(pool: &PgPool, tz: &str) -> Uuid {
    let id = Uuid::now_v7();
    sqlx::query("INSERT INTO users (id, email, password_hash, tz) VALUES ($1, $2, 'x', $3)")
        .bind(id)
        .bind(format!("{id}@example.com"))
        .bind(tz)
        .execute(pool)
        .await
        .unwrap();
    id
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn creates_current_and_next_month_partitions(pool: PgPool) {
    let now = Utc.with_ymd_and_hms(2026, 10, 8, 12, 0, 0).unwrap();
    partitions::ensure_current_and_next(&pool, now)
        .await
        .unwrap();
    // Running again is a no-op.
    partitions::ensure_current_and_next(&pool, now)
        .await
        .unwrap();

    for table in ["hr_samples", "rr_intervals"] {
        assert!(partition_exists(&pool, &format!("{table}_y2026m10")).await);
        assert!(partition_exists(&pool, &format!("{table}_y2026m11")).await);
        assert!(!partition_exists(&pool, &format!("{table}_y2026m12")).await);
        assert!(partition_exists(&pool, &format!("{table}_default")).await);
    }
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn partition_creation_moves_rows_out_of_default(pool: PgPool) {
    let user = insert_user(&pool, "America/Chicago").await;
    let band = Uuid::now_v7();
    sqlx::query("INSERT INTO bands (id, user_id) VALUES ($1, $2)")
        .bind(band)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();

    // December has no partition yet, so this row lands in the default partition.
    sqlx::query(
        "INSERT INTO hr_samples (band_id, ts, bpm, source, batch_id) VALUES ($1, '2026-12-15 10:00+00', 60, 1, $2)",
    )
    .bind(band)
    .bind(Uuid::now_v7())
    .execute(&pool)
    .await
    .unwrap();

    partitions::ensure_month(
        &pool,
        "hr_samples",
        NaiveDate::from_ymd_opt(2026, 12, 1).unwrap(),
    )
    .await
    .unwrap();

    let in_partition: i64 = sqlx::query_scalar("SELECT count(*) FROM hr_samples_y2026m12")
        .fetch_one(&pool)
        .await
        .unwrap();
    let in_default: i64 = sqlx::query_scalar("SELECT count(*) FROM hr_samples_default")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(in_partition, 1);
    assert_eq!(in_default, 0);
}

fn utc(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

/// Inserts one minute row for `user`. Only the columns the rollup reads are set.
#[allow(clippy::too_many_arguments)]
async fn insert_minute(
    pool: &PgPool,
    user: Uuid,
    minute: DateTime<Utc>,
    hr_avg: Option<f32>,
    hr_max: i16,
    hr_n: i16,
    rmssd: Option<f32>,
    stress: Option<(i16, &str)>,
    kcal: (f32, f32),
) {
    sqlx::query(
        "INSERT INTO minute_metrics (user_id, minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, stress, stress_state,
           kcal, active_kcal, algo_version, sync_rev)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 1, 1)",
    )
    .bind(user)
    .bind(minute)
    .bind(hr_avg)
    .bind(hr_avg.map(|v| v as i16 - 2))
    .bind(hr_max)
    .bind(hr_n)
    .bind(rmssd)
    .bind(stress.map(|s| s.0))
    .bind(stress.map(|s| s.1))
    .bind(kcal.0)
    .bind(kcal.1)
    .execute(pool)
    .await
    .unwrap();
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn daily_rollup_matches_hand_computed_values(pool: PgPool) {
    // America/Chicago is UTC-5 on 2026-10-07, so local 00:00 is 05:00Z.
    let user = insert_user(&pool, "America/Chicago").await;
    let local_midnight = utc("2026-10-07T05:00:00Z");
    let night_hr = [60.0, 62.0, 64.0, 66.0, 68.0, 70.0, 72.0, 74.0, 76.0, 78.0];
    for (i, hr) in night_hr.iter().enumerate() {
        let minute = local_midnight + chrono::Duration::minutes(i as i64);
        // Minute 9 has only 10 HR samples, so it does not qualify for RHR.
        let hr_n = if i == 9 { 10 } else { 60 };
        let stress = if i == 0 { (80, "value") } else { (30, "value") };
        insert_minute(
            &pool,
            user,
            minute,
            Some(*hr),
            *hr as i16 + 5,
            hr_n,
            Some(40.0 + i as f32),
            Some(stress),
            (1.0, 0.5),
        )
        .await;
    }
    // Noon local (17:00Z): outside the night window, so it stays out of RHR and RMSSD.
    insert_minute(
        &pool,
        user,
        utc("2026-10-07T17:00:00Z"),
        Some(100.0),
        120,
        60,
        Some(200.0),
        Some((70, "value")),
        (2.0, 1.0),
    )
    .await;

    let day = NaiveDate::from_ymd_opt(2026, 10, 7).unwrap();
    let days = rollup::recompute_days(&pool, user, "America/Chicago", &[day, day])
        .await
        .unwrap();
    assert_eq!(days, 1, "duplicate days are processed once");

    type SummaryRow = (
        Option<i16>,
        Option<f32>,
        Option<i16>,
        Option<f32>,
        Option<f32>,
        i32,
        Option<f32>,
        Option<f32>,
        f32,
        i16,
    );
    let row: SummaryRow =
        sqlx::query_as(
            "SELECT rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg, stress_high_minutes, kcal_total, kcal_active, coverage, algo_version
             FROM daily_summaries WHERE user_id = $1 AND day = $2",
        )
        .bind(user)
        .bind(day)
        .fetch_one(&pool)
        .await
        .unwrap();

    // Rolling 5-minute means over qualifying minutes: 64, 66, 68, 70, 72. The minimum is 64.
    assert_eq!(row.0, Some(64), "rhr");
    // Weighted by hr_n: 43500 / 610.
    assert!(
        (row.1.unwrap() - 71.311_47).abs() < 0.001,
        "hr_avg {:?}",
        row.1
    );
    assert_eq!(row.2, Some(120), "hr_max");
    // Night RMSSD is 40..=49, mean 44.5. The noon value of 200 is excluded.
    assert!(
        (row.3.unwrap() - 44.5).abs() < 0.001,
        "rmssd_night_ms {:?}",
        row.3
    );
    // 420 / 11 minutes with stress.
    assert!(
        (row.4.unwrap() - 38.181_82).abs() < 0.001,
        "stress_avg {:?}",
        row.4
    );
    assert_eq!(row.5, 2, "stress_high_minutes");
    assert!((row.6.unwrap() - 12.0).abs() < 0.001, "kcal_total");
    assert!((row.7.unwrap() - 6.0).abs() < 0.001, "kcal_active");
    assert!((row.8 - 11.0 / 1440.0).abs() < 1e-6, "coverage");
    assert_eq!(row.9, 1);

    // A day with no minutes has no row, and a second run gives the same result.
    let empty_day = NaiveDate::from_ymd_opt(2026, 10, 6).unwrap();
    rollup::recompute_days(&pool, user, "America/Chicago", &[day, empty_day])
        .await
        .unwrap();
    let again: Option<f32> =
        sqlx::query_scalar("SELECT hr_avg FROM daily_summaries WHERE user_id = $1 AND day = $2")
            .bind(user)
            .bind(day)
            .fetch_optional(&pool)
            .await
            .unwrap()
            .flatten();
    assert_eq!(again.map(|v| (v * 1000.0).round()), Some(71_311.0));
    let none: i64 =
        sqlx::query_scalar("SELECT count(*) FROM daily_summaries WHERE user_id = $1 AND day = $2")
            .bind(user)
            .bind(empty_day)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(none, 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn rhr_is_null_without_five_qualifying_minutes_in_a_row(pool: PgPool) {
    let user = insert_user(&pool, "America/Chicago").await;
    // Minutes at 00:00, 00:01, 00:02, then a gap, then 00:10. No run of five qualifies.
    for offset in [0, 1, 2, 10] {
        insert_minute(
            &pool,
            user,
            utc("2026-10-07T05:00:00Z") + chrono::Duration::minutes(offset),
            Some(55.0),
            60,
            60,
            None,
            None,
            (0.0, 0.0),
        )
        .await;
    }
    let day = NaiveDate::from_ymd_opt(2026, 10, 7).unwrap();
    rollup::recompute_days(&pool, user, "America/Chicago", &[day])
        .await
        .unwrap();
    let rhr: Option<i16> =
        sqlx::query_scalar("SELECT rhr FROM daily_summaries WHERE user_id = $1 AND day = $2")
            .bind(user)
            .bind(day)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(rhr, None);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn prune_removes_only_expired_sessions_and_old_pairing_codes(pool: PgPool) {
    let user = insert_user(&pool, "America/Chicago").await;
    let session = |id: u8, expires: &str| {
        sqlx::query(
            "INSERT INTO sessions (id, user_id, expires_at) VALUES ($1, $2, $3::timestamptz)",
        )
        .bind(vec![id])
        .bind(user)
        .bind(expires.to_owned())
        .execute(&pool)
    };
    session(1, "2000-01-01T00:00:00Z").await.unwrap();
    session(2, "2999-01-01T00:00:00Z").await.unwrap();
    for (code, expires) in [(1u8, "2000-01-01T00:00:00Z"), (2, "2999-01-01T00:00:00Z")] {
        sqlx::query("INSERT INTO pairing_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3::timestamptz)")
            .bind(vec![code])
            .bind(user)
            .bind(expires)
            .execute(&pool)
            .await
            .unwrap();
    }

    let removed = icarus_jobs::prune_expired(&pool).await.unwrap();
    assert_eq!(removed, 2);
    let left: i64 = sqlx::query_scalar(
        "SELECT (SELECT count(*) FROM sessions) + (SELECT count(*) FROM pairing_codes)",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(left, 2);
}
