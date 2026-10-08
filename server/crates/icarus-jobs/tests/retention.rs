use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use icarus_jobs::{partitions, retention};
use sqlx::PgPool;
use uuid::Uuid;

async fn partition_exists(pool: &PgPool, name: &str) -> bool {
    sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
        .bind(name)
        .fetch_one(pool)
        .await
        .unwrap()
}

fn month(y: i32, m: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, 1).unwrap()
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn drops_only_raw_partitions_wholly_older_than_400_days(pool: PgPool) {
    // Cutoff is 2025-09-04 (400 days before 2026-10-08). 2025-08 ends before it; 2025-09 does not.
    for (table, m) in [
        ("hr_samples", month(2024, 1)),
        ("rr_intervals", month(2024, 1)),
        ("hr_samples", month(2025, 8)),
        ("hr_samples", month(2025, 9)),
        ("hr_samples", month(2026, 9)),
    ] {
        partitions::ensure_month(&pool, table, m).await.unwrap();
    }
    let now = Utc.with_ymd_and_hms(2026, 10, 8, 12, 0, 0).unwrap();
    let report = retention::run(&pool, now).await.unwrap();

    let mut dropped = report.partitions_dropped.clone();
    dropped.sort();
    assert_eq!(
        dropped,
        vec![
            "hr_samples_y2024m01",
            "hr_samples_y2025m08",
            "rr_intervals_y2024m01"
        ]
    );
    assert!(!partition_exists(&pool, "hr_samples_y2024m01").await);
    assert!(!partition_exists(&pool, "rr_intervals_y2024m01").await);
    assert!(partition_exists(&pool, "hr_samples_y2025m09").await);
    assert!(partition_exists(&pool, "hr_samples_y2026m09").await);

    let again = retention::run(&pool, now).await.unwrap();
    assert!(
        again.partitions_dropped.is_empty(),
        "running twice is harmless"
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn deletes_webhook_deliveries_older_than_90_days(pool: PgPool) {
    let user = Uuid::now_v7();
    sqlx::query("INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'x')")
        .bind(user)
        .bind(format!("{user}@example.com"))
        .execute(&pool)
        .await
        .unwrap();
    let alarm = Uuid::now_v7();
    sqlx::query("INSERT INTO alarms (id, user_id, kind, label, rhythm, channels) VALUES ($1, $2, 'webhook', 'Door', '\"single\"', ARRAY['phone'])")
        .bind(alarm)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    let endpoint = Uuid::now_v7();
    sqlx::query("INSERT INTO webhook_endpoints (id, user_id, slug, label, alarm_id, auth_mode, secret_ciphertext) VALUES ($1, $2, 'slug-retention-test-0', 'Door', $3, 'hmac', '\\x00'::bytea)")
        .bind(endpoint)
        .bind(user)
        .bind(alarm)
        .execute(&pool)
        .await
        .unwrap();

    let now: DateTime<Utc> = Utc.with_ymd_and_hms(2026, 10, 8, 12, 0, 0).unwrap();
    for (days_ago, key) in [(100, "old"), (10, "recent")] {
        sqlx::query("INSERT INTO webhook_deliveries (id, endpoint_id, received_at, idempotency_key, signature_valid, status) VALUES ($1, $2, $3, $4, true, 'accepted')")
            .bind(Uuid::now_v7())
            .bind(endpoint)
            .bind(now - Duration::days(days_ago))
            .bind(key)
            .execute(&pool)
            .await
            .unwrap();
    }

    let report = retention::run(&pool, now).await.unwrap();
    assert_eq!(report.deliveries_deleted, 1);
    let left: Vec<String> = sqlx::query_scalar("SELECT idempotency_key FROM webhook_deliveries")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(left, vec!["recent".to_owned()]);
}
