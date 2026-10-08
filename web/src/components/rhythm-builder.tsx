import { TrashIcon } from '@phosphor-icons/react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { canAddStep, defaultStep, formatSeconds, RHYTHM_LIMITS, totalMs } from '@/lib/rhythm'
import type { RhythmStep } from '@/lib/types'

// TODO(shadcn): swap the native selects for the select component once CI adds it (scripts/shadcn-components.txt).
const field = 'h-8 border border-input bg-background px-2 text-xs'

const numberText = (value: number) => (Number.isFinite(value) ? String(value) : '')
const parseNumber = (text: string) => (text === '' ? Number.NaN : Number(text))

// Custom step list with a live total. Limits: 10 steps, 30 s, buzz loops count 1 s each (PLAN.md §9.2).
export function RhythmBuilder({
  steps,
  onChange,
  errors,
}: {
  steps: RhythmStep[]
  onChange: (steps: RhythmStep[]) => void
  errors: string[]
}) {
  const total = totalMs(steps)
  const over = Number.isFinite(total) && total > RHYTHM_LIMITS.maxTotalMs
  const full = !canAddStep(steps)

  const replace = (index: number, next: RhythmStep) => onChange(steps.map((step, i) => (i === index ? next : step)))

  return (
    <div className="flex flex-col gap-4">
      {steps.length > 0 && (
        <ol className="flex flex-col gap-2">
          {steps.map((step, index) => (
            <StepRow
              key={index}
              index={index}
              step={step}
              onChange={(next) => replace(index, next)}
              onRemove={() => onChange(steps.filter((_, i) => i !== index))}
            />
          ))}
        </ol>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="outline" size="sm" disabled={full} onClick={() => onChange([...steps, defaultStep('buzz')])}>
          Add buzz
        </Button>
        <Button variant="outline" size="sm" disabled={full} onClick={() => onChange([...steps, defaultStep('pause')])}>
          Add pause
        </Button>
        {full && <span className="text-xs text-muted-foreground">Maximum {RHYTHM_LIMITS.maxSteps} steps.</span>}
      </div>
      <p
        aria-live="polite"
        className={`text-xs tabular-nums ${over ? 'text-destructive' : 'text-muted-foreground'}`}
      >
        Total {Number.isFinite(total) ? formatSeconds(total) : '—'} of {RHYTHM_LIMITS.maxTotalMs / 1000} s
      </p>
      {errors.map((message) => (
        <p key={message} role="alert" className="text-xs text-destructive">
          {message}
        </p>
      ))}
    </div>
  )
}

function StepRow({
  index,
  step,
  onChange,
  onRemove,
}: {
  index: number
  step: RhythmStep
  onChange: (step: RhythmStep) => void
  onRemove: () => void
}) {
  const n = index + 1
  return (
    <li className="flex flex-wrap items-center gap-2">
      <span className="w-4 text-xs tabular-nums text-muted-foreground">{n}</span>
      <select
        aria-label={`Step ${n} type`}
        className={field}
        value={step.type}
        onChange={(event) => onChange(defaultStep(event.target.value as RhythmStep['type']))}
      >
        <option value="buzz">Buzz</option>
        <option value="pause">Pause</option>
      </select>
      {step.type === 'buzz' ? (
        <>
          <select
            aria-label={`Step ${n} preset`}
            className={field}
            value={step.preset}
            onChange={(event) => onChange({ ...step, preset: Number(event.target.value) })}
          >
            {Array.from({ length: RHYTHM_LIMITS.preset.max }, (_, offset) => offset + 1).map((preset) => (
              <option key={preset} value={preset}>
                Preset {preset}
              </option>
            ))}
          </select>
          <Input
            aria-label={`Step ${n} loops`}
            type="number"
            inputMode="numeric"
            min={RHYTHM_LIMITS.loops.min}
            max={RHYTHM_LIMITS.loops.max}
            step={1}
            className="h-8 w-16"
            value={numberText(step.loops)}
            onChange={(event) => onChange({ ...step, loops: parseNumber(event.target.value) })}
          />
          <span className="text-xs text-muted-foreground">loops</span>
        </>
      ) : (
        <>
          <Input
            aria-label={`Step ${n} pause`}
            type="number"
            inputMode="numeric"
            min={RHYTHM_LIMITS.pauseMs.min}
            max={RHYTHM_LIMITS.pauseMs.max}
            step={100}
            className="h-8 w-24"
            value={numberText(step.ms)}
            onChange={(event) => onChange({ ...step, ms: parseNumber(event.target.value) })}
          />
          <span className="text-xs text-muted-foreground">ms</span>
        </>
      )}
      <Button variant="ghost" size="icon-sm" aria-label={`Remove step ${n}`} onClick={onRemove}>
        <TrashIcon />
      </Button>
    </li>
  )
}
