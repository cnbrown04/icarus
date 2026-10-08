import { Link, Outlet, useMatchRoute, useMatches, useNavigate } from '@tanstack/react-router'
import {
  ArrowsClockwiseIcon,
  BellIcon,
  CalendarIcon,
  ClockIcon,
  DeviceMobileIcon,
  FireIcon,
  GearIcon,
  HeartIcon,
  SignOutIcon,
  WaveformIcon,
  WebhooksLogoIcon,
  type Icon,
} from '@phosphor-icons/react'
import { useState } from 'react'
import { PageActionSlotProvider } from '@/components/page-action'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
  useSidebar,
} from '@/components/ui/sidebar'
import { useLogout } from '@/lib/queries'
import { formatDayTitle } from '@/lib/time'

const navItems: { to: string; label: string; icon: Icon }[] = [
  { to: '/', label: 'Today', icon: ClockIcon },
  { to: '/heart-rate', label: 'Heart rate', icon: HeartIcon },
  { to: '/stress', label: 'Stress', icon: WaveformIcon },
  { to: '/calories', label: 'Calories', icon: FireIcon },
  { to: '/history', label: 'History', icon: CalendarIcon },
  { to: '/alarms', label: 'Alarms', icon: BellIcon },
  { to: '/webhooks', label: 'Webhooks', icon: WebhooksLogoIcon },
  { to: '/devices', label: 'Devices', icon: DeviceMobileIcon },
  { to: '/sync', label: 'Sync', icon: ArrowsClockwiseIcon },
  { to: '/settings', label: 'Settings', icon: GearIcon },
]

function AppSidebar() {
  const matchRoute = useMatchRoute()
  const { setOpenMobile } = useSidebar()
  const navigate = useNavigate()
  const logout = useLogout()

  return (
    <Sidebar>
      <SidebarHeader>
        <p className="px-2 py-1 text-base font-medium">Icarus</p>
      </SidebarHeader>
      <SidebarContent>
        <nav aria-label="Primary">
          <SidebarMenu>
            {navItems.map((item) => (
              <SidebarMenuItem key={item.to}>
                <SidebarMenuButton
                  isActive={Boolean(matchRoute({ to: item.to }))}
                  onClick={() => setOpenMobile(false)}
                  render={<Link to={item.to} />}
                >
                  <item.icon aria-hidden />
                  <span>{item.label}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            ))}
          </SidebarMenu>
        </nav>
      </SidebarContent>
      <SidebarFooter>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton
              disabled={logout.isPending}
              onClick={() => logout.mutate(undefined, { onSettled: () => void navigate({ to: '/login' }) })}
            >
              <SignOutIcon aria-hidden />
              <span>Sign out</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  )
}

type CurrentMatch = { routeId: string; params: Record<string, string>; staticData: { title?: string } }

// The day route titles itself with the date; every other route uses its staticData title.
function titleOf(match: CurrentMatch | undefined): string {
  if (!match) return ''
  if (match.routeId.endsWith('/history/$day')) return formatDayTitle(match.params.day ?? '')
  return match.staticData.title ?? ''
}

// Layout shell. The content padding below is the only page padding in the app (PLAN.md §15.2 rule 11).
export function AppLayout() {
  const title = useMatches({ select: (matches) => titleOf(matches.at(-1) as CurrentMatch | undefined) })
  const [actionSlot, setActionSlot] = useState<HTMLDivElement | null>(null)

  return (
    <SidebarProvider>
      <AppSidebar />
      <SidebarInset>
        <header className="flex h-12 shrink-0 items-center gap-4 border-b px-4 md:px-6">
          <SidebarTrigger />
          <h1 className="min-w-0 flex-1 truncate text-base font-medium">{title}</h1>
          <div ref={setActionSlot} className="flex shrink-0 items-center gap-2" />
        </header>
        <div className="flex flex-1 flex-col gap-6 p-4 md:p-6">
          <PageActionSlotProvider value={actionSlot}>
            <Outlet />
          </PageActionSlotProvider>
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}
