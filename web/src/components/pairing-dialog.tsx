import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { queryKeys, useCreatePairingCode } from '@/lib/queries'

// Mint a new code each time the dialog opens; codes are single use and expire after 10 minutes.
export function PairingDialog() {
  const create = useCreatePairingCode()
  const client = useQueryClient()
  const now = useNow(1_000)
  const code = create.data

  return (
    <Dialog
      onOpenChange={(open) => {
        if (open) create.mutate(undefined)
        else void client.invalidateQueries({ queryKey: queryKeys.devices })
      }}
    >
      <DialogTrigger render={<Button />}>Pair iPhone</DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Pair iPhone</DialogTitle>
          <DialogDescription>Scan the code in the Icarus app, or enter the code. It works once.</DialogDescription>
        </DialogHeader>

        {create.isError && <ErrorLine message={describeError(create.error)} />}
        {create.isPending && !code && <LoadingBlock className="h-56" />}

        {code && <PairingCode code={code.code} qrSvg={code.qr_svg} expiresAt={code.expires_at} now={now} />}

        {code && Date.parse(code.expires_at) <= now.getTime() && (
          <Button variant="outline" className="self-start" onClick={() => create.mutate(undefined)}>
            New code
          </Button>
        )}
      </DialogContent>
    </Dialog>
  )
}

function PairingCode({
  code,
  qrSvg,
  expiresAt,
  now,
}: {
  code: string
  qrSvg: string
  expiresAt: string
  now: Date
}) {
  const remaining = Date.parse(expiresAt) - now.getTime()
  const expired = remaining <= 0
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <p className="text-xs text-muted-foreground">Code</p>
        <p className="text-3xl font-medium tracking-widest" aria-label={`Pairing code ${code.split('').join(' ')}`}>
          {code}
        </p>
      </div>
      {/* The SVG travels as a data URL in an img, so it is never injected as markup. */}
      <img
        src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(qrSvg)}`}
        alt="QR code for pairing the iPhone"
        width={192}
        height={192}
        className="size-48 bg-background"
      />
      <p className="text-xs text-muted-foreground" aria-live="polite">
        {expired ? 'Code expired' : `Expires in ${formatCountdown(remaining)}`}
      </p>
    </div>
  )
}

export function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000))
  const minutes = Math.floor(total / 60)
  const seconds = total % 60
  return `${minutes}:${String(seconds).padStart(2, '0')}`
}
