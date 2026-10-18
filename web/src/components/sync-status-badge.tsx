import { StatusBadge } from '@/components/status-badge'
import { formatAgo } from '@/lib/time'

// A batch newer than this is current. The phone syncs every 5 minutes in the foreground (PLAN.md §11.2).
const CURRENT_MS = 15 * 60_000

// The age of the last batch, green while it is current and amber once it is not.
export function SyncStatusBadge({ lastBatchAt, now }: { lastBatchAt: string | null; now: Date }) {
  if (!lastBatchAt) return <StatusBadge variant="neutral">No batches yet</StatusBadge>
  const age = now.getTime() - Date.parse(lastBatchAt)
  return <StatusBadge variant={age <= CURRENT_MS ? 'ok' : 'warn'}>{formatAgo(age)}</StatusBadge>
}
