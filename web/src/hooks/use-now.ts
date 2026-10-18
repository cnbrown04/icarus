import { useEffect, useState } from 'react'

// Current time, refreshed every `intervalMs`. Query keys use it so ranges move forward without re-rendering every frame.
export function useNow(intervalMs: number): Date {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}
