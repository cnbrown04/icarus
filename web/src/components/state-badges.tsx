import { StatusBadge, type StatusVariant } from '@/components/status-badge'
import { describeDispatchStatus } from '@/lib/alarms'
import type { DispatchStatus, HookDelivery } from '@/lib/types'
import { deliveryStatusLabel } from '@/lib/webhooks'

const DISPATCH_VARIANT: Record<DispatchStatus, StatusVariant> = {
  pending: 'neutral',
  sent: 'info',
  acked: 'ok',
  unacked: 'danger',
  failed: 'danger',
}

export function DispatchBadge({ status }: { status: DispatchStatus }) {
  return <StatusBadge variant={DISPATCH_VARIANT[status]}>{describeDispatchStatus(status)}</StatusBadge>
}

const DELIVERY_VARIANT: Record<HookDelivery['status'], StatusVariant> = {
  accepted: 'ok',
  duplicate: 'neutral',
  rate_limited: 'warn',
  rejected: 'danger',
}

export function DeliveryBadge({ status }: { status: HookDelivery['status'] }) {
  return <StatusBadge variant={DELIVERY_VARIANT[status]}>{deliveryStatusLabel(status)}</StatusBadge>
}

// Sync batches: "ok" is the server's acknowledgement of the rows (PLAN.md §11.3).
const BATCH: Record<string, { variant: StatusVariant; label: string }> = {
  ok: { variant: 'ok', label: 'Acknowledged' },
  pending: { variant: 'info', label: 'Pending' },
  rejected: { variant: 'danger', label: 'Rejected' },
  duplicate: { variant: 'neutral', label: 'Duplicate' },
}

export function BatchBadge({ status }: { status: string }) {
  const entry = BATCH[status] ?? { variant: 'neutral' as const, label: status.charAt(0).toUpperCase() + status.slice(1) }
  return <StatusBadge variant={entry.variant}>{entry.label}</StatusBadge>
}
