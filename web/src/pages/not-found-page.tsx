import { Link } from '@tanstack/react-router'

export function NotFoundPage() {
  return (
    <p className="text-muted-foreground">
      Nothing at this address.{' '}
      <Link to="/" className="text-foreground underline underline-offset-4">
        Go to Today
      </Link>
    </p>
  )
}
