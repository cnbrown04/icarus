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
import {
  AlarmsPage,
  CaloriesPage,
  DevicesPage,
  HeartRatePage,
  HistoryPage,
  NotFoundPage,
  SettingsPage,
  StressPage,
  SyncPage,
  TodayPage,
  WebhooksPage,
} from '@/pages/app-pages'
import { LoginPage } from '@/pages/login-page'

declare module '@tanstack/react-router' {
  interface StaticDataRouteOption {
    title?: string
    action?: ReactNode
  }
}

function RootLayout() {
  return (
    <div
      className="min-h-svh bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100"
      style={{ fontFamily: "'JetBrains Mono Variable', ui-monospace, monospace" }}
    >
      <Outlet />
    </div>
  )
}

const rootRoute = createRootRoute({ component: RootLayout })

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: LoginPage,
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

export function createAppQueryClient() {
  return new QueryClient()
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof createAppRouter>
  }
}
