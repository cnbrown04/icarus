import { QueryClient } from '@tanstack/react-query'
import {
  createRootRoute,
  createRoute,
  createRouter,
  lazyRouteComponent,
  Outlet,
  type RouteComponent,
  type RouterHistory,
} from '@tanstack/react-router'
import { AppLayout } from '@/components/app-layout'
import { Toaster } from '@/components/ui/sonner'
import { ApiError } from '@/lib/api'
import { LoginPage } from '@/pages/login-page'
import { NotFoundPage } from '@/pages/not-found-page'

declare module '@tanstack/react-router' {
  interface StaticDataRouteOption {
    title?: string
  }
}

function RootLayout() {
  return (
    <div className="min-h-svh bg-background text-foreground">
      <Outlet />
      <Toaster />
    </div>
  )
}

const rootRoute = createRootRoute({ component: RootLayout })

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: LoginPage,
  staticData: { title: 'Sign in' },
})

// Pathless layout route: every page below renders inside AppLayout.
const appRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: 'app',
  component: AppLayout,
})

// Pages load on first visit, so the entry bundle carries only the shell (PLAN.md §13.1, bundle budget 500 kB).
const appPage = <TPath extends string>(path: TPath, title: string, component: RouteComponent) =>
  createRoute({
    getParentRoute: () => appRoute,
    path,
    component,
    staticData: { title },
  })

const routeTree = rootRoute.addChildren([
  loginRoute,
  appRoute.addChildren([
    appPage('/', 'Today', lazyRouteComponent(() => import('@/pages/today-page'), 'TodayPage')),
    appPage('/heart-rate', 'Heart rate', lazyRouteComponent(() => import('@/pages/heart-rate-page'), 'HeartRatePage')),
    appPage('/stress', 'Stress', lazyRouteComponent(() => import('@/pages/stress-page'), 'StressPage')),
    appPage('/calories', 'Calories', lazyRouteComponent(() => import('@/pages/calories-page'), 'CaloriesPage')),
    appPage('/history', 'History', lazyRouteComponent(() => import('@/pages/history-page'), 'HistoryPage')),
    // The title is the date; see AppLayout.
    createRoute({
      getParentRoute: () => appRoute,
      path: '/history/$day',
      component: lazyRouteComponent(() => import('@/pages/history-day-page'), 'HistoryDayPage'),
    }),
    appPage('/alarms', 'Alarms', lazyRouteComponent(() => import('@/pages/alarms-page'), 'AlarmsPage')),
    appPage('/webhooks', 'Webhooks', lazyRouteComponent(() => import('@/pages/webhooks-page'), 'WebhooksPage')),
    createRoute({
      getParentRoute: () => appRoute,
      path: '/webhooks/$hookId',
      component: lazyRouteComponent(() => import('@/pages/webhook-deliveries-page'), 'WebhookDeliveriesPage'),
      staticData: { title: 'Webhook deliveries' },
    }),
    appPage('/devices', 'Devices', lazyRouteComponent(() => import('@/pages/devices-page'), 'DevicesPage')),
    appPage('/sync', 'Sync', lazyRouteComponent(() => import('@/pages/sync-page'), 'SyncPage')),
    appPage('/settings', 'Settings', lazyRouteComponent(() => import('@/pages/settings-page'), 'SettingsPage')),
    appPage('/integrations/whoop', 'WHOOP', lazyRouteComponent(() => import('@/pages/whoop-page'), 'WhoopPage')),
    appPage('$', 'Not found', NotFoundPage),
  ]),
])

export function createAppRouter(history?: RouterHistory) {
  return createRouter({ routeTree, history })
}

// Client errors are not retried. Network failures and 5xx responses get two more attempts.
export function createAppQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: (failureCount, error) => {
          if (error instanceof ApiError && error.status >= 400 && error.status < 500) return false
          return failureCount < 2
        },
      },
    },
  })
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof createAppRouter>
  }
}
