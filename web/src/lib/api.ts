import type { Problem } from './types'

// Same-origin API client for the cookie-authenticated website (contract: Auth, Conventions).

export class ApiError extends Error {
  readonly status: number
  readonly slug: string
  readonly detail: string | undefined
  readonly current: unknown

  constructor(problem: { status: number; slug: string; title: string; detail?: string; current?: unknown }) {
    super(problem.title)
    this.name = 'ApiError'
    this.status = problem.status
    this.slug = problem.slug
    this.detail = problem.detail
    this.current = problem.current
  }
}

const PROBLEM_PREFIX = 'urn:icarus:problem:'

let onUnauthorized: () => void = () => {
  window.location.assign('/login')
}

// Tests replace this; the app sends the browser to /login.
export function setUnauthorizedHandler(handler: () => void) {
  onUnauthorized = handler
}

type Query = Record<string, string | number | boolean | undefined | null>

type RequestOptions = {
  query?: Query
  body?: unknown
  ifMatch?: number
}

export function buildPath(path: string, query?: Query): string {
  if (!query) return path
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) continue
    params.set(key, String(value))
  }
  const search = params.toString()
  return search ? `${path}?${search}` : path
}

function slugFromType(type: string): string {
  return type.startsWith(PROBLEM_PREFIX) ? type.slice(PROBLEM_PREFIX.length) : type
}

async function problemFrom(response: Response): Promise<ApiError> {
  const fallback = { status: response.status, slug: 'internal', title: response.statusText || 'Request failed' }
  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.includes('json')) return new ApiError(fallback)
  try {
    const body = (await response.json()) as Partial<Problem>
    return new ApiError({
      status: body.status ?? response.status,
      slug: body.type ? slugFromType(body.type) : fallback.slug,
      title: body.title ?? fallback.title,
      detail: body.detail,
      current: body.current,
    })
  } catch {
    return new ApiError(fallback)
  }
}

export async function request<T>(method: string, path: string, options: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {}
  if (method !== 'GET') headers['X-Icarus-CSRF'] = '1'
  if (options.body !== undefined) headers['Content-Type'] = 'application/json'
  if (options.ifMatch !== undefined) headers['If-Match'] = String(options.ifMatch)

  const url = new URL(buildPath(path, options.query), window.location.origin)
  let response: Response
  try {
    response = await fetch(url, {
      method,
      credentials: 'include',
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    })
  } catch {
    throw new ApiError({ status: 0, slug: 'network', title: 'Network error. Check the connection and try again.' })
  }

  if (response.status === 401 && path !== '/v1/auth/login') {
    onUnauthorized()
  }
  if (!response.ok) throw await problemFrom(response)
  if (response.status === 204) return undefined as T
  return (await response.json()) as T
}

export const api = {
  get: <T>(path: string, query?: Query) => request<T>('GET', path, { query }),
  post: <T>(path: string, body?: unknown, options?: Omit<RequestOptions, 'body'>) =>
    request<T>('POST', path, { ...options, body }),
  patch: <T>(path: string, body: unknown, ifMatch?: number) => request<T>('PATCH', path, { body, ifMatch }),
  delete: <T = void>(path: string, body?: unknown, ifMatch?: number) => request<T>('DELETE', path, { body, ifMatch }),
}
