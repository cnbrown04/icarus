// The one error line on a page or form. Announced to screen readers when it appears.
export function ErrorLine({ message }: { message: string }) {
  return (
    <p role="alert" className="text-xs text-destructive">
      {message}
    </p>
  )
}
