import { Link, useParams } from '@tanstack/react-router'
import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { Panel } from '@/components/stat'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeDeliveryStatus, describeDispatchStatus } from '@/lib/alarms'
import { describeError } from '@/lib/errors'
import { useHookDeliveries, useHooks, useMe } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'
import { deliveryStatusLabel } from '@/lib/webhooks'

export function WebhookDeliveriesPage() {
  const { hookId = '' } = useParams({ strict: false })
  const hooks = useHooks()
  const me = useMe()
  const deliveries = useHookDeliveries(hookId)

  if (deliveries.isError) return <ErrorLine message={describeError(deliveries.error)} />
  if (deliveries.isPending || hooks.isPending || me.isPending) return <LoadingRows rows={4} />

  const tz = me.data?.tz ?? 'UTC'
  const hook = (hooks.data ?? []).find((item) => item.id === hookId)
  const rows = deliveries.data.pages.flatMap((page) => page.deliveries)

  return (
    <div className="flex flex-col gap-6">
      <Link to="/webhooks" className="self-start text-xs text-foreground underline underline-offset-4">
        Back to webhooks
      </Link>
      <Panel title={hook?.label ?? 'Deliveries'}>
        {rows.length === 0 ? (
          <EmptyState message="No deliveries yet" />
        ) : (
          <div className="flex flex-col gap-4">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Received</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="hidden md:table-cell">Signature</TableHead>
                  <TableHead>Phone</TableHead>
                  <TableHead>Band</TableHead>
                  <TableHead className="hidden text-right md:table-cell">Dispatch</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((delivery) => (
                  <TableRow key={delivery.id}>
                    <TableCell className="whitespace-normal tabular-nums">{formatDateTime(Date.parse(delivery.received_at), tz)}</TableCell>
                    <TableCell className="whitespace-normal">{deliveryStatusLabel(delivery.status)}</TableCell>
                    <TableCell className="whitespace-normal hidden md:table-cell">{delivery.signature_valid ? 'Valid' : 'Invalid'}</TableCell>
                    <TableCell className="whitespace-normal">{describeDeliveryStatus(delivery.dispatch?.phone_status ?? null)}</TableCell>
                    <TableCell className="whitespace-normal">{describeDeliveryStatus(delivery.dispatch?.band_status ?? null)}</TableCell>
                    <TableCell className="hidden whitespace-normal text-right md:table-cell">
                      {delivery.dispatch ? describeDispatchStatus(delivery.dispatch.status) : '—'}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {deliveries.hasNextPage && (
              <div>
                <Button
                  variant="outline"
                  disabled={deliveries.isFetchingNextPage}
                  onClick={() => void deliveries.fetchNextPage()}
                >
                  Load more
                </Button>
              </div>
            )}
          </div>
        )}
      </Panel>
    </div>
  )
}
