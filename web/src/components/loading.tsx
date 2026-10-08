import { Skeleton } from '@/components/ui/skeleton'

// Skeletons match the final layout and appear only for loads that take longer than 300 ms (PLAN.md §15.4 rule 23).
export function LoadingBlock({ className }: { className: string }) {
  return (
    <div role="status" aria-label="Loading">
      <Skeleton className={className} />
    </div>
  )
}

export function LoadingRows({ rows = 3 }: { rows?: number }) {
  return (
    <div role="status" aria-label="Loading" className="flex flex-col gap-3">
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-8" />
      ))}
    </div>
  )
}
