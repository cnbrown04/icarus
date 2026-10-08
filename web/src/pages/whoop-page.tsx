import { ChartLineIcon, FlameIcon, HeartIcon, LightningIcon, LinkIcon, MoonIcon, PlugIcon, ShieldCheckIcon, WaveformIcon } from '@phosphor-icons/react'
import { useState, type ReactNode } from 'react'
import { toast } from 'sonner'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock, LoadingRows } from '@/components/loading'
import { PageAction } from '@/components/page-action'
import { SectionCard } from '@/components/section-card'
import { StatTile } from '@/components/stat-tile'
import { StatusBadge } from '@/components/status-badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { useNow } from '@/hooks/use-now'
import { ApiError } from '@/lib/api'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { useDisconnectWhoop, useMe, useWhoopStatus, useWhoopSummary } from '@/lib/queries'
import { dayInZone, formatDateTime } from '@/lib/time'

// Browser navigation, not fetch: the server answers with a redirect to WHOOP's consent page.
const CONNECT_URL = '/v1/integrations/whoop/connect'

export function WhoopPage() {
  const me = useMe()
  const now = useNow(60_000)
  const status = useWhoopStatus()
  const tz = me.data?.tz ?? 'UTC'
  const connected = status.data?.connected === true
  const summary = useWhoopSummary(dayInZone(now.getTime(), tz), connected)
  const disconnect = useDisconnectWhoop()
  const [confirming, setConfirming] = useState(false)

  // The server answers 404 when the integration has no WHOOP client credentials (contract: WHOOP).
  if (status.error instanceof ApiError && status.error.status === 404) {
    return <EmptyState icon={PlugIcon} message="WHOOP integration is not configured on the server." />
  }
  if (status.isError) return <ErrorLine message={describeError(status.error)} />
  if (status.isPending || me.isPending) return <LoadingRows rows={3} />

  return (
    <div className="flex flex-col gap-6">
      {!connected && (
        <PageAction>
          <Button render={<a href={CONNECT_URL} />}>Connect</Button>
        </PageAction>
      )}

      <SectionCard
        title="Connection"
        icon={LinkIcon}
        action={connected ? <StatusBadge variant="ok">Connected</StatusBadge> : <StatusBadge variant="neutral">Disconnected</StatusBadge>}
      >
        {connected ? (
          <div className="flex flex-col gap-4">
            <Field label="Scopes">{status.data.scopes.join(', ') || '—'}</Field>
            <Field label="Connected since">
              {status.data.connected_at ? formatDateTime(Date.parse(status.data.connected_at), tz) : '—'}
            </Field>
            <Field label="Last webhook">
              {status.data.last_webhook_at ? formatDateTime(Date.parse(status.data.last_webhook_at), tz) : 'Never'}
            </Field>
            <div>
              <Button variant="outline" onClick={() => setConfirming(true)}>
                Disconnect
              </Button>
            </div>
          </div>
        ) : (
          <EmptyState icon={PlugIcon} message="WHOOP is not connected." />
        )}
      </SectionCard>

      {/* Tiles sit on the page, not in a card: a card inside a card is not allowed (PLAN.md §15.2 rule 15). */}
      {connected && (
        <section aria-labelledby="whoop-today" className="flex flex-col gap-4">
          <h2 id="whoop-today" className="flex items-center gap-2 text-xs font-medium">
            <ChartLineIcon aria-hidden className="size-4 text-muted-foreground" />
            Today
          </h2>
          {summary.isPending ? (
            <LoadingBlock className="h-40" />
          ) : summary.isError ? (
            <ErrorLine message={describeError(summary.error)} />
          ) : (
            <div className="flex flex-col gap-6">
              <p className="text-xs text-muted-foreground">Values are fetched live from WHOOP and are not stored.</p>
              <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
                <StatTile icon={ShieldCheckIcon} label="Recovery" value={summary.data.recovery_score} unit="%" />
                <StatTile icon={WaveformIcon} label="HRV (RMSSD)" value={summary.data.hrv_rmssd_milli} unit="ms" tone="hrv" />
                <StatTile icon={HeartIcon} label="Resting heart rate" value={summary.data.resting_heart_rate} unit="bpm" tone="hr" />
                <StatTile icon={LightningIcon} label="Strain" value={summary.data.strain?.toFixed(1) ?? null} />
                <StatTile
                  icon={FlameIcon}
                  label="Energy"
                  value={summary.data.kilojoule === null ? null : formatInt(summary.data.kilojoule)}
                  unit="kJ"
                  tone="kcal-active"
                />
                <StatTile icon={MoonIcon} label="Sleep performance" value={summary.data.sleep_performance} unit="%" />
              </div>
            </div>
          )}
        </section>
      )}

      <Dialog open={confirming} onOpenChange={setConfirming}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Disconnect WHOOP?</DialogTitle>
            <DialogDescription>Icarus revokes its access and deletes the stored tokens. Today's values stop showing.</DialogDescription>
          </DialogHeader>
          {disconnect.isError && <ErrorLine message={describeError(disconnect.error)} />}
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
            <Button
              variant="destructive"
              disabled={disconnect.isPending}
              onClick={() =>
                disconnect.mutate(undefined, {
                  onSuccess: () => {
                    toast.success('WHOOP disconnected')
                    setConfirming(false)
                  },
                })
              }
            >
              Disconnect
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-xs break-words">{children}</p>
    </div>
  )
}
