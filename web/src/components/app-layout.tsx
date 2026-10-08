import { Link, Outlet, useMatchRoute, useMatches, useNavigate } from '@tanstack/react-router'
import {
  ArrowsClockwiseIcon,
  BellIcon,
  CalendarIcon,
  ClockIcon,
  DeviceMobileIcon,
  FlameIcon,
  GaugeIcon,
  GearIcon,
  HeartIcon,
  HeartbeatIcon,
  SignOutIcon,
  WebhooksLogoIcon,
  type Icon,
} from '@phosphor-icons/react'
import { useState } from 'react'
import { PageActionSlotProvider } from '@/components/page-action'
import { StatusBadge } from '@/components/status-badge'
import { SyncStatusBadge } from '@/components/sync-status-badge'
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
import { useNow } from '@/hooks/use-now'
import { useLogout, useSyncState } from '@/lib/queries'
import { formatDayTitle } from '@/lib/time'

const navItems: { to: string; label: string; icon: Icon }[] = [
  { to: '/', label: 'Today', icon: ClockIcon },
  { to: '/heart-rate', label: 'Heart rate', icon: HeartIcon },
  { to: '/stress', label: 'Stress', icon: GaugeIcon },
  { to: '/calories', label: 'Calories', icon: FlameIcon },
  { to: '/history', label: 'History', icon: CalendarIcon },
  { to: '/alarms', label: 'Alarms', icon: BellIcon },
  { to: '/webhooks', label: 'Webhooks', icon: WebhooksLogoIcon },
  { to: '/devices', label: 'Devices', icon: DeviceMobileIcon },
  { to: '/sync', label: 'Sync', icon: ArrowsClockwiseIcon },
  { to: '/settings', label: 'Settings', icon: GearIcon },
  { to: '/integrations/whoop', label: 'WHOOP', icon: HeartbeatIcon },
]

function AppSidebar() {
  const matchRoute = useMatchRoute()
  const { setOpenMobile } = useSidebar()
  const navigate = useNavigate()
  const logout = useLogout()

  return (
    <Sidebar>
      <SidebarHeader>
        <p className="flex items-center gap-2 px-2 py-1 text-base font-medium">
          <HeartbeatIcon aria-hidden className="size-4 text-hr" />
          Icarus
        </p>
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
                  className="border-l-2 border-transparent data-active:border-sidebar-primary"
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
        <SyncFooter />
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

// Connection state at a glance: how old the last phone batch is (PLAN.md §11.2).
function SyncFooter() {
  const sync = useSyncState()
  const now = useNow(60_000)
  if (sync.isPending) return null
  return (
    <div className="flex flex-col items-start gap-2 px-2 py-1 text-xs">
      <p className="text-muted-foreground">Sync</p>
      {sync.isError ? (
        <StatusBadge variant="danger">Sync unavailable</StatusBadge>
      ) : (
        <SyncStatusBadge lastBatchAt={sync.data.last_batch_at} now={now} />
      )}
    </div>
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
