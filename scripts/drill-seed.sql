-- Sample data for scripts/restore-drill.sh. Not real data: the secrets are placeholders.
-- Run after the server has applied its migrations and created the user (docs/backup.md):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/drill-seed.sql
DO $seed$
DECLARE
  uid uuid;
  device uuid := gen_random_uuid();
  band uuid := gen_random_uuid();
  alarm uuid := gen_random_uuid();
  endpoint uuid := gen_random_uuid();
  delivery uuid := gen_random_uuid();
  dispatch uuid := gen_random_uuid();
  batch uuid := gen_random_uuid();
BEGIN
  SELECT id INTO STRICT uid FROM users ORDER BY created_at LIMIT 1;

  INSERT INTO devices (id, user_id, name, model, os_version, app_version, token_hash, last_seen_at)
  VALUES (device, uid, 'Drill phone', 'iPhone17,2', '26.0', '1.0.0',
          sha256(convert_to(gen_random_uuid()::text, 'UTF8')), now());

  INSERT INTO bands (id, user_id, name, firmware, last_seen_at)
  VALUES (band, uid, 'WHOOP 4.0', '4.0.0', now());

  INSERT INTO hr_samples (band_id, ts, bpm, source, contact, batch_id)
  SELECT band, now() - g * interval '1 second', 60 + (g % 20), 1, true, batch
  FROM generate_series(1, 2000) AS g;

  INSERT INTO rr_intervals (band_id, ts, seq, rr_ms, accepted, batch_id)
  SELECT band, now() - g * interval '1 second', 0, 800 + (g % 50), true, batch
  FROM generate_series(1, 500) AS g;

  INSERT INTO band_events (band_id, ts, kind, payload, batch_id)
  VALUES (band, now() - interval '1 hour', 'wrist_off', '{}', batch);

  INSERT INTO minute_metrics (user_id, minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms,
    baevsky_sqrt, stress, stress_state, kcal, active_kcal, kcal_estimated, algo_version, origin, sync_rev)
  SELECT uid, date_trunc('minute', now()) - g * interval '1 minute', 62.5, 58, 66, 60, 42.1, 50.3,
    9.1, 31, 'value', 1.4, 0.2, false, 1, 'device', 1
  FROM generate_series(1, 1440) AS g;

  INSERT INTO daily_summaries (user_id, day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg,
    stress_high_minutes, kcal_total, kcal_active, coverage, algo_version, computed_at)
  SELECT uid, current_date - g, 55, 70, 120, 45, 30, 60, 2200, 500, 0.9, 1, now()
  FROM generate_series(0, 6) AS g;

  INSERT INTO alarms (id, user_id, kind, label, schedule, rhythm, channels, enabled)
  VALUES (alarm, uid, 'webhook', 'Front door', NULL, '"double"', ARRAY['phone', 'band'], true);

  INSERT INTO webhook_endpoints (id, user_id, slug, label, alarm_id, auth_mode, secret_ciphertext,
    rate_limit_per_min)
  VALUES (endpoint, uid, 'drill-slug', 'Drill door', alarm, 'hmac', decode('00', 'hex'), 10);

  INSERT INTO webhook_deliveries (id, endpoint_id, idempotency_key, signature_valid, status, request_meta)
  VALUES (delivery, endpoint, 'drill-key', true, 'accepted', '{"content_length": 2}');

  INSERT INTO alarm_dispatches (id, alarm_id, delivery_id, status, phone_status, message, rhythm)
  VALUES (dispatch, alarm, delivery, 'sent', 'sent', 'Front door opened', '"double"');

  INSERT INTO sync_batches (id, device_id, payload_sha256, schema_version, counts, status)
  VALUES (batch, device, sha256(convert_to(batch::text, 'UTF8')), 1,
          '{"hr": {"inserted": 2000, "duplicate": 0}}', 'stored');

  INSERT INTO alarm_deliveries (id, user_id, batch_id, alarm_id, dispatch_id, ts, channel, status, detail)
  VALUES (gen_random_uuid(), uid, batch, alarm, dispatch, now(), 'phone', 'shown', NULL);
END
$seed$;
