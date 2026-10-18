import { ApiError } from './api'

// What happened and what to do, in one short sentence (PLAN.md §15.1 rule 8).
export function describeError(error: unknown, context: 'login' | 'generic' = 'generic'): string {
  if (!(error instanceof ApiError)) return 'Something went wrong. Try again.'
  if (context === 'login') {
    if (error.status === 401) return 'Email or password is incorrect.'
    if (error.status === 429) return 'Too many attempts. Wait a minute and try again.'
  }
  switch (error.slug) {
    case 'network':
      return 'Network error. Check the connection and try again.'
    case 'rate-limited':
      return 'Too many requests. Wait a minute and try again.'
    case 'database-unavailable':
    case 'migrations-pending':
      return 'The server database is not ready. Try again shortly.'
    case 'validation':
      return error.detail ?? 'Check the highlighted fields and try again.'
    case 'forbidden':
      return 'This action is not allowed. Reload the page and try again.'
    case 'not-found':
      return 'Not found.'
    case 'conflict':
      return 'This changed somewhere else. Reload and try again.'
    default:
      return error.status >= 500 ? 'The server had a problem. Try again.' : 'Something went wrong. Try again.'
  }
}

// A 409 means the entity changed since it was loaded. Its body carries the current entity (contract: Conventions).
export function isConflict(error: unknown): error is ApiError {
  return error instanceof ApiError && error.status === 409
}
