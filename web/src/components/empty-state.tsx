type EmptyStateProps = {
  message: string
  action?: string
}

export function EmptyState({ message, action }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-neutral-600 dark:text-neutral-400">{message}</p>
      {action && (
        <button
          type="button"
          className="border border-neutral-900 px-4 py-2 hover:bg-neutral-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-900 dark:border-neutral-100 dark:hover:bg-neutral-900 dark:focus-visible:outline-neutral-100"
        >
          {action}
        </button>
      )}
    </div>
  )
}
