import { useState } from 'react'
import { Button } from '@/components/ui/button'

// Copies text to the clipboard. If the browser refuses, the user is told to copy by hand.
export function CopyButton({ value, label }: { value: string; label: string }) {
  const [status, setStatus] = useState<'idle' | 'copied' | 'failed'>('idle')

  async function copy() {
    try {
      await navigator.clipboard.writeText(value)
      setStatus('copied')
    } catch {
      setStatus('failed')
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Button variant="outline" size="sm" aria-label={`Copy ${label}`} onClick={() => void copy()}>
        {status === 'copied' ? 'Copied' : 'Copy'}
      </Button>
      {status === 'failed' && <span className="text-xs text-destructive">Copy failed. Select the text and copy it.</span>}
    </div>
  )
}
