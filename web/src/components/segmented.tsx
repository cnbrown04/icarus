// TODO(shadcn): replace with the toggle-group component once CI adds it (scripts/shadcn-components.txt).
// Plain buttons with aria-pressed until then.
export function Segmented<T extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string
  options: readonly { value: T; label: string }[]
  value: T
  onChange: (value: T) => void
}) {
  return (
    <div role="group" aria-label={label} className="inline-flex flex-wrap border border-border">
      {options.map((option) => {
        const pressed = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={pressed}
            onClick={() => onChange(option.value)}
            className={`h-8 px-3 text-xs whitespace-nowrap hover:bg-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring ${
              pressed ? 'bg-foreground text-background' : 'bg-background text-foreground'
            }`}
          >
            {option.label}
          </button>
        )
      })}
    </div>
  )
}
