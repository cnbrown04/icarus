import { createContext, useContext, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

// The top bar owns the one primary action slot; pages render into it so their dialogs keep their state.
const PageActionSlot = createContext<HTMLElement | null>(null)

export const PageActionSlotProvider = PageActionSlot.Provider

export function PageAction({ children }: { children: ReactNode }) {
  const slot = useContext(PageActionSlot)
  return slot ? createPortal(children, slot) : null
}
