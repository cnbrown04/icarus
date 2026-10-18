// TODO(shadcn): replace with the switch component once CI adds it (scripts/shadcn-components.txt).
// A plain switch button until then. The label names the setting for screen readers.
export function Switch({
  checked,
  onCheckedChange,
  label,
  disabled = false,
}: {
  checked: boolean
  onCheckedChange: (checked: boolean) => void
  label: string
  disabled?: boolean
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onCheckedChange(!checked)}
      className={`relative inline-flex h-6 w-10 shrink-0 items-center border border-input transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring disabled:opacity-50 ${
        checked ? 'bg-primary' : 'bg-muted'
      }`}
    >
      <span
        aria-hidden
        className={`block size-4 transition-transform duration-150 ease-out motion-reduce:transition-none ${
          checked ? 'translate-x-5 bg-primary-foreground' : 'translate-x-1 bg-foreground'
        }`}
      />
    </button>
  )
}
