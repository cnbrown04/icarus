import { DeviceMobileIcon, WarningIcon, WatchIcon } from '@phosphor-icons/react'
import { useState } from 'react'
import { PairingDialog } from '@/components/pairing-dialog'
import { RevokeDialog } from '@/components/revoke-dialog'
import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { PageAction } from '@/components/page-action'
import { SectionCard } from '@/components/section-card'
import { StatusBadge } from '@/components/status-badge'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { useDevices, useMe } from '@/lib/queries'
import { formatAgo, formatDateTime } from '@/lib/time'
import type { Band, Device } from '@/lib/types'

// A device not seen for longer than this is flagged (PLAN.md §11.2: the phone syncs every few minutes while open).
const STALE_MS = 24 * 3_600_000

export function DevicesPage() {
  const devices = useDevices()
  const me = useMe()
  const now = useNow(60_000)
  const [revoking, setRevoking] = useState<Device | null>(null)

  return (
    <>
      <PageAction>
        <PairingDialog />
      </PageAction>

      {devices.isError ? (
        <ErrorLine message={describeError(devices.error)} />
      ) : devices.isPending || me.isPending ? (
        <LoadingRows rows={4} />
      ) : (
        <DevicesContent
          phones={devices.data.devices}
          bands={devices.data.bands}
          tz={me.data?.tz ?? 'UTC'}
          now={now}
          onRevoke={setRevoking}
        />
      )}

      <RevokeDialog device={revoking} onClose={() => setRevoking(null)} />
    </>
  )
}

function DevicesContent({
  phones,
  bands,
  tz,
  now,
  onRevoke,
}: {
  phones: Device[]
  bands: Band[]
  tz: string
  now: Date
  onRevoke: (device: Device) => void
}) {
  return (
    <div className="flex flex-col gap-6">
      <SectionCard title="Phones" icon={DeviceMobileIcon}>
        {phones.length === 0 ? (
          <EmptyState icon={DeviceMobileIcon} message="No phones paired" />
        ) : (
          <div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead className="hidden md:table-cell">Model</TableHead>
                  <TableHead className="hidden md:table-cell">iOS</TableHead>
                  <TableHead className="hidden md:table-cell">App</TableHead>
                  <TableHead className="hidden md:table-cell">Last seen</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {phones.map((phone) => (
                  <TableRow key={phone.id}>
                    <TableCell className="font-medium">
                      {phone.name}
                      {/* Below md the last-seen time moves under the name, so the table fits a phone. */}
                      <span className="block text-muted-foreground font-normal md:hidden">
                        Last seen <LastSeen value={phone.last_seen_at} now={now} tz={tz} />
                      </span>
                    </TableCell>
                    <TableCell className="hidden md:table-cell">{phone.model}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{phone.os_version}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{phone.app_version}</TableCell>
                    <TableCell className="hidden md:table-cell">
                      <LastSeen value={phone.last_seen_at} now={now} tz={tz} />
                    </TableCell>
                    <TableCell>
                      {phone.revoked_at ? (
                        <StatusBadge variant="neutral">Revoked</StatusBadge>
                      ) : (
                        <StatusBadge variant="ok">Active</StatusBadge>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      {phone.revoked_at === null && (
                        <Button variant="ghost" size="sm" aria-label={`Revoke ${phone.name}`} onClick={() => onRevoke(phone)}>
                          Revoke
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </SectionCard>

      <SectionCard title="Bands" icon={WatchIcon}>
        {bands.length === 0 ? (
          <EmptyState icon={WatchIcon} message="No bands paired" />
        ) : (
          <div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead className="hidden md:table-cell">Firmware</TableHead>
                  <TableHead className="hidden md:table-cell">Last seen</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {bands.map((band) => (
                  <TableRow key={band.id}>
                    <TableCell className="font-medium">
                      {band.name}
                      <span className="block text-muted-foreground font-normal md:hidden">
                        Last seen <LastSeen value={band.last_seen_at} now={now} tz={tz} />
                      </span>
                    </TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{band.firmware}</TableCell>
                    <TableCell className="hidden md:table-cell">
                      <LastSeen value={band.last_seen_at} now={now} tz={tz} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </SectionCard>
    </div>
  )
}

// The time last seen. Older than a day, it turns amber, adds an icon and says how old it is, so colour is not the only cue.
function LastSeen({ value, now, tz }: { value: string | null; now: Date; tz: string }) {
  if (!value) return <span className="text-muted-foreground">Never</span>
  const seen = Date.parse(value)
  const age = now.getTime() - seen
  const time = formatDateTime(seen, tz)
  if (age <= STALE_MS) return <span className="tabular-nums">{time}</span>
  return (
    <span className="inline-flex flex-wrap items-center gap-1 text-status-warn tabular-nums">
      <WarningIcon aria-hidden className="size-3 shrink-0" />
      {time}
      <span className="text-muted-foreground">({formatAgo(age)})</span>
    </span>
  )
}
