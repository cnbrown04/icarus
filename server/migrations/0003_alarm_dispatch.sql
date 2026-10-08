-- Phase 4/5: what a dispatch carries and how the dispatcher tracks attempts (api-contract.md "Alarms",
-- PLAN.md §9.3, §12.4, §12.5). Deviations from §10.3 are the columns below and the status check.
ALTER TABLE alarm_dispatches
  ADD COLUMN message text,
  ADD COLUMN rhythm jsonb NOT NULL DEFAULT '"double"',
  ADD COLUMN channels text[] NOT NULL DEFAULT ARRAY['phone', 'band'],
  ADD COLUMN last_attempt_at timestamptz,
  ADD COLUMN ack_detail text;

ALTER TABLE alarm_dispatches
  ADD CONSTRAINT alarm_dispatches_status_check
  CHECK (status IN ('pending', 'sent', 'acked', 'unacked', 'failed'));

CREATE INDEX alarm_dispatches_delivery_idx ON alarm_dispatches (delivery_id);
CREATE INDEX alarm_dispatches_alarm_idx ON alarm_dispatches (alarm_id, created_at);
-- The dispatcher's sweep only looks at dispatches that still need work.
CREATE INDEX alarm_dispatches_open_idx ON alarm_dispatches (last_attempt_at)
  WHERE status IN ('pending', 'sent');
CREATE INDEX webhook_deliveries_endpoint_idx ON webhook_deliveries (endpoint_id, received_at DESC, id DESC);
