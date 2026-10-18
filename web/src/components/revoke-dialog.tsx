import { toast } from 'sonner'
import { ErrorLine } from '@/components/error-line'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { describeError } from '@/lib/errors'
import { useRevokeDevice } from '@/lib/queries'
import type { Device } from '@/lib/types'

// Names the phone in the title so the confirmation cannot be answered for the wrong device (PLAN.md §15.4 rule 25).
export function RevokeDialog({ device, onClose }: { device: Device | null; onClose: () => void }) {
  const revoke = useRevokeDevice()
  const name = device?.name ?? ''

  return (
    <Dialog
      open={device !== null}
      onOpenChange={(open) => {
        if (!open) {
          revoke.reset()
          onClose()
        }
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Revoke {name}?</DialogTitle>
          <DialogDescription>
            The app on this phone stops syncing and its token stops working. Pair the phone again to resume.
          </DialogDescription>
        </DialogHeader>
        {revoke.isError && <ErrorLine message={describeError(revoke.error)} />}
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
          <Button
            variant="destructive"
            disabled={revoke.isPending || device === null}
            onClick={() => {
              if (!device) return
              revoke.mutate(device.id, {
                onSuccess: () => {
                  toast.success(`Revoked ${device.name}`)
                  onClose()
                },
              })
            }}
          >
            Revoke
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
