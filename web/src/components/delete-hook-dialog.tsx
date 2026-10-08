import { toast } from 'sonner'
import { ErrorLine } from '@/components/error-line'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { describeError } from '@/lib/errors'
import { useDeleteHook } from '@/lib/queries'
import type { Hook } from '@/lib/types'

export function DeleteHookDialog({ hook, onClose }: { hook: Hook | null; onClose: () => void }) {
  const remove = useDeleteHook()

  return (
    <Dialog
      open={hook !== null}
      onOpenChange={(open) => {
        if (!open) {
          remove.reset()
          onClose()
        }
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Delete webhook "{hook?.label ?? ''}"?</DialogTitle>
          <DialogDescription>Calls to this endpoint stop working. This cannot be undone.</DialogDescription>
        </DialogHeader>
        {remove.isError && <ErrorLine message={describeError(remove.error)} />}
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
          <Button
            variant="destructive"
            disabled={remove.isPending || hook === null}
            onClick={() => {
              if (!hook) return
              remove.mutate(hook.id, {
                onSuccess: () => {
                  toast.success(`Deleted ${hook.label}`)
                  onClose()
                },
              })
            }}
          >
            Delete
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
