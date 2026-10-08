import { useState } from 'react'
import { PairingDialog } from '@/components/pairing-dialog'
import { RevokeDialog } from '@/components/revoke-dialog'
import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { PageAction } from '@/components/page-action'
import { Panel } from '@/components/stat'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeError } from '@/lib/errors'
import { useDevices, useMe } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'
import type { Band, Device } from '@/lib/types'

export function DevicesPage() {
  const devices = useDevices()
  const me = useMe()
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
  onRevoke,
}: {
  phones: Device[]
  bands: Band[]
  tz: string
  onRevoke: (device: Device) => void
}) {
  const when = (value: string | null) => (value ? formatDateTime(Date.parse(value), tz) : 'Never')

  return (
    <div className="flex flex-col gap-6">
      <Panel title="Phones">
        {phones.length === 0 ? (
          <EmptyState message="No phones paired" />
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
                        Last seen {when(phone.last_seen_at)}
                      </span>
                    </TableCell>
                    <TableCell className="hidden md:table-cell">{phone.model}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{phone.os_version}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{phone.app_version}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{when(phone.last_seen_at)}</TableCell>
                    <TableCell>{phone.revoked_at ? 'Revoked' : 'Active'}</TableCell>
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
      </Panel>

      <Panel title="Bands">
        {bands.length === 0 ? (
          <EmptyState message="No bands paired" />
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
                        Last seen {when(band.last_seen_at)}
                      </span>
                    </TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{band.firmware}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{when(band.last_seen_at)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Panel>
    </div>
  )
}
