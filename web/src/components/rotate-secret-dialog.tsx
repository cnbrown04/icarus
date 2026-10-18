import { useState } from 'react'
import { ErrorLine } from '@/components/error-line'
import { SecretView } from '@/components/secret-view'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { describeError } from '@/lib/errors'
import { useRotateHook } from '@/lib/queries'
import { originOf, secretUrl } from '@/lib/webhooks'
import type { Hook } from '@/lib/types'

// Two steps: confirm, then show the new secret once. The old one is not shown again either way.
export function RotateSecretDialog({ hook, onClose }: { hook: Hook | null; onClose: () => void }) {
  const rotate = useRotateHook()
  const [secret, setSecret] = useState<string | null>(null)

  function close() {
    setSecret(null)
    rotate.reset()
    onClose()
  }

  return (
    <Dialog open={hook !== null} onOpenChange={(open) => !open && close()}>
      <DialogContent className={secret !== null ? 'sm:max-w-lg' : undefined}>
        {hook && secret === null && (
          <>
            <DialogHeader>
              <DialogTitle>Rotate secret for "{hook.label}"?</DialogTitle>
              <DialogDescription>Senders that still use the old secret must be updated with the new one.</DialogDescription>
            </DialogHeader>
            {rotate.isError && <ErrorLine message={describeError(rotate.error)} />}
            <DialogFooter>
              <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
              <Button
                disabled={rotate.isPending}
                onClick={() =>
                  rotate.mutate(hook.id, {
                    onSuccess: (result) => setSecret(result.secret),
                  })
                }
              >
                Rotate secret
              </Button>
            </DialogFooter>
          </>
        )}
        {hook && secret !== null && (
          <>
            <DialogHeader>
              <DialogTitle>New secret for "{hook.label}"</DialogTitle>
              <DialogDescription>The new secret is shown once. Copy it now. It cannot be viewed again.</DialogDescription>
            </DialogHeader>
            <SecretView
              authMode={hook.auth_mode}
              address={hook.auth_mode === 'hmac' ? hook.url : secretUrl(originOf(hook.url), hook.slug, secret)}
              secret={secret}
            />
            <DialogFooter>
              <Button onClick={close}>Done</Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
