import type { Hook } from './types'

export const AUTH_LABEL: Record<Hook['auth_mode'], string> = {
  hmac: 'Signature',
  secret_url: 'Secret URL',
}

const HOOK_PATH = '/v1/hooks/'

// "https://host" from "https://host/v1/hooks/slug" (or "https://host/v1/hooks/slug/secret").
export function originOf(url: string): string {
  const at = url.indexOf(HOOK_PATH)
  return at >= 0 ? url.slice(0, at) : url
}

// What the list may show. A secret URL carries its secret in the path, so only the path up to the slug is shown.
export function hookAddress(hook: Hook): string {
  if (hook.auth_mode === 'hmac') return hook.url
  return `${originOf(hook.url)}${HOOK_PATH}${hook.slug}/[secret]`
}

export function secretUrl(origin: string, slug: string, secret: string): string {
  return `${origin}${HOOK_PATH}${slug}/${secret}`
}

// Single-quote a value for bash. Secrets are base64url, but the rule holds for any text.
export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

const SAMPLE_BODY = '{"message":"Front door opened"}'

// Signature header per PLAN.md §12.4: t=<unix>,v1=<hex(HMAC_SHA256(secret, t + "." + raw_body))>.
// TODO(PLAN §12.4): the spec does not say whether the HMAC key is the secret text or its decoded bytes.
// The example uses the text as shown. Check against the server before relying on it.
export function hmacCurl(url: string, secret: string): string {
  return [
    `SECRET=${shellQuote(secret)}`,
    `BODY=${shellQuote(SAMPLE_BODY)}`,
    'T=$(date +%s)',
    `SIG=$(printf '%s.%s' "$T" "$BODY" \\`,
    `  | openssl dgst -sha256 -hmac "$SECRET" \\`,
    `  | awk '{print $NF}')`,
    `curl -sS -X POST ${shellQuote(url)} \\`,
    `  -H 'Content-Type: application/json' \\`,
    `  -H "X-Icarus-Signature: t=$T,v1=$SIG" \\`,
    `  --data "$BODY"`,
  ].join('\n')
}

export function secretUrlCurl(url: string): string {
  return [`curl -sS -X POST \\`, `  ${shellQuote(url)} \\`, `  -H 'Content-Type: application/json' \\`, `  --data ${shellQuote(SAMPLE_BODY)}`].join('\n')
}

export function deliveryStatusLabel(status: 'accepted' | 'rejected' | 'rate_limited' | 'duplicate'): string {
  switch (status) {
    case 'accepted':
      return 'Accepted'
    case 'rejected':
      return 'Rejected'
    case 'rate_limited':
      return 'Rate limited'
    case 'duplicate':
      return 'Duplicate'
  }
}
