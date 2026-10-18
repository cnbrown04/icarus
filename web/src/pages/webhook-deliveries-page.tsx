import { ArrowLeftIcon, WebhooksLogoIcon } from '@phosphor-icons/react'
import { Link, useParams } from '@tanstack/react-router'
import { DispatchBadge, DeliveryBadge } from '@/components/state-badges'
import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { SectionCard } from '@/components/section-card'
import { StatusBadge } from '@/components/status-badge'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeDeliveryStatus } from '@/lib/alarms'
import { describeError } from '@/lib/errors'
import { useHookDeliveries, useHooks, useMe } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'

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
      <Link to="/webhooks" className="flex items-center gap-2 self-start text-xs text-foreground underline underline-offset-4">
        <ArrowLeftIcon aria-hidden className="size-3" />
        Back to webhooks
      </Link>
      <SectionCard title={hook?.label ?? 'Deliveries'} icon={WebhooksLogoIcon}>
        {rows.length === 0 ? (
          <EmptyState icon={WebhooksLogoIcon} message="No deliveries yet" />
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
                    <TableCell className="whitespace-normal">
                      <DeliveryBadge status={delivery.status} />
                    </TableCell>
                    <TableCell className="whitespace-normal hidden md:table-cell">
                      {delivery.signature_valid ? (
                        <StatusBadge variant="ok">Valid</StatusBadge>
                      ) : (
                        <StatusBadge variant="danger">Invalid</StatusBadge>
                      )}
                    </TableCell>
                    <TableCell className="whitespace-normal">{describeDeliveryStatus(delivery.dispatch?.phone_status ?? null)}</TableCell>
                    <TableCell className="whitespace-normal">{describeDeliveryStatus(delivery.dispatch?.band_status ?? null)}</TableCell>
                    <TableCell className="hidden whitespace-normal text-right md:table-cell">
                      {delivery.dispatch ? <DispatchBadge status={delivery.dispatch.status} /> : '—'}
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
      </SectionCard>
    </div>
  )
}
