import { Link, Outlet, useMatches } from '@tanstack/react-router'

// The only place page padding is applied.
const navItems = [
  { to: '/', label: 'Today' },
  { to: '/heart-rate', label: 'Heart rate' },
  { to: '/stress', label: 'Stress' },
  { to: '/calories', label: 'Calories' },
  { to: '/history', label: 'History' },
  { to: '/alarms', label: 'Alarms' },
  { to: '/webhooks', label: 'Webhooks' },
  { to: '/devices', label: 'Devices' },
  { to: '/sync', label: 'Sync' },
  { to: '/settings', label: 'Settings' },
] as const

const rule = 'border-neutral-200 dark:border-neutral-800'

export function AppLayout() {
  const current = useMatches({ select: (matches) => matches.at(-1)?.staticData })

  return (
    <div className="flex min-h-svh flex-col md:flex-row">
      <nav aria-label="Primary" className={`border-b md:w-48 md:shrink-0 md:border-r md:border-b-0 ${rule}`}>
        <ul className="flex gap-4 overflow-x-auto p-2 md:flex-col md:gap-0 md:p-4">
          {navItems.map((item) => (
            <li key={item.to}>
              <Link
                to={item.to}
                activeOptions={{ exact: true }}
                activeProps={{ className: 'font-medium underline underline-offset-4' }}
                className="block px-2 py-1 whitespace-nowrap hover:underline underline-offset-4 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-900 dark:focus-visible:outline-neutral-100"
              >
                {item.label}
              </Link>
            </li>
          ))}
        </ul>
      </nav>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className={`flex h-12 items-center justify-between gap-4 border-b px-4 md:px-6 ${rule}`}>
          <h1 className="truncate text-base font-medium">{current?.title}</h1>
          <div>{current?.action}</div>
        </header>
        <main className="flex-1 p-4 md:p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
