import { QueryClient } from '@tanstack/react-query'
import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  type RouterHistory,
} from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { AppLayout } from '@/components/app-layout'
import { Toaster } from '@/components/ui/sonner'
import { ApiError } from '@/lib/api'
import { AlarmsPage } from '@/pages/alarms-page'
import { CaloriesPage } from '@/pages/calories-page'
import { DevicesPage } from '@/pages/devices-page'
import { HeartRatePage } from '@/pages/heart-rate-page'
import { HistoryDayPage } from '@/pages/history-day-page'
import { HistoryPage } from '@/pages/history-page'
import { LoginPage } from '@/pages/login-page'
import { NotFoundPage } from '@/pages/not-found-page'
import { SettingsPage } from '@/pages/settings-page'
import { StressPage } from '@/pages/stress-page'
import { SyncPage } from '@/pages/sync-page'
import { TodayPage } from '@/pages/today-page'
import { WebhooksPage } from '@/pages/webhooks-page'

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

const appPage = <TPath extends string>(path: TPath, title: string, component: () => ReactNode) =>
  createRoute({
    getParentRoute: () => appRoute,
    path,
    component,
    staticData: { title },
  })

const routeTree = rootRoute.addChildren([
  loginRoute,
  appRoute.addChildren([
    appPage('/', 'Today', TodayPage),
    appPage('/heart-rate', 'Heart rate', HeartRatePage),
    appPage('/stress', 'Stress', StressPage),
    appPage('/calories', 'Calories', CaloriesPage),
    appPage('/history', 'History', HistoryPage),
    // The title is the date; see AppLayout.
    createRoute({ getParentRoute: () => appRoute, path: '/history/$day', component: HistoryDayPage }),
    appPage('/alarms', 'Alarms', AlarmsPage),
    appPage('/webhooks', 'Webhooks', WebhooksPage),
    appPage('/devices', 'Devices', DevicesPage),
    appPage('/sync', 'Sync', SyncPage),
    appPage('/settings', 'Settings', SettingsPage),
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
