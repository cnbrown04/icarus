const INT = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })

// Whole numbers with thousands separators: "1,482".
export function formatInt(value: number): string {
  return INT.format(Math.round(value))
}
