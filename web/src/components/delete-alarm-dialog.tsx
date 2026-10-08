import { toast } from 'sonner'
import { ErrorLine } from '@/components/error-line'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { describeError, isConflict } from '@/lib/errors'
import { useDeleteAlarm } from '@/lib/queries'
import type { Alarm } from '@/lib/types'

// Names the alarm in the title so the confirmation cannot be answered for the wrong one (PLAN.md §15.4 rule 25).
export function DeleteAlarmDialog({ alarm, onClose }: { alarm: Alarm | null; onClose: () => void }) {
  const remove = useDeleteAlarm()

  return (
    <Dialog
      open={alarm !== null}
      onOpenChange={(open) => {
        if (!open) {
          remove.reset()
          onClose()
        }
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Delete alarm "{alarm?.label ?? ''}"?</DialogTitle>
          <DialogDescription>The alarm stops firing. This cannot be undone.</DialogDescription>
        </DialogHeader>
        {remove.isError && (
          <ErrorLine message={isConflict(remove.error) ? 'This alarm changed somewhere else. Reload and try again.' : describeError(remove.error)} />
        )}
        <DialogFooter>
          <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
          <Button
            variant="destructive"
            disabled={remove.isPending || alarm === null}
            onClick={() => {
              if (!alarm) return
              remove.mutate(
                { id: alarm.id, version: alarm.version },
                {
                  onSuccess: () => {
                    toast.success(`Deleted ${alarm.label}`)
                    onClose()
                  },
                },
              )
            }}
          >
            Delete
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
