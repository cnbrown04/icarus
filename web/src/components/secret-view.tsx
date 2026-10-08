import { CopyButton } from '@/components/copy-button'
import { hmacCurl, secretUrlCurl } from '@/lib/webhooks'
import type { Hook } from '@/lib/types'

// Shows a webhook's address and, for signature mode, its signing secret, plus a request example.
// Only mount this straight after create or rotate: the secret exists nowhere else in the app.
export function SecretView({ authMode, address, secret }: { authMode: Hook['auth_mode']; address: string; secret: string }) {
  const example = authMode === 'hmac' ? hmacCurl(address, secret) : secretUrlCurl(address)
  return (
    <div className="flex min-w-0 flex-col gap-4">
      {authMode === 'hmac' ? (
        <>
          <SecretField label="Endpoint" value={address} />
          <SecretField label="Signing secret" value={secret} />
        </>
      ) : (
        <SecretField label="Secret URL" value={address} />
      )}
      <div className="flex min-w-0 flex-col gap-2">
        <p className="text-xs text-muted-foreground">Example request</p>
        <pre tabIndex={0} role="region" aria-label="Example request" className="overflow-x-auto border bg-muted p-4 text-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring">
          <code>{example}</code>
        </pre>
        <CopyButton value={example} label="example request" />
      </div>
    </div>
  )
}

function SecretField({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <div className="flex min-w-0 flex-col items-start gap-2">
        <code className="block w-full break-all border p-2 text-xs">{value}</code>
        <CopyButton value={value} label={label.toLowerCase()} />
      </div>
    </div>
  )
}
