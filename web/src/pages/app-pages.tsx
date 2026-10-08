import { Link } from '@tanstack/react-router'
import { EmptyState } from '@/components/empty-state'

export function TodayPage() {
  return <EmptyState message="No data yet" action="Pair iPhone" />
}

export function HeartRatePage() {
  return <EmptyState message="No data yet" action="Pair iPhone" />
}

export function StressPage() {
  return <EmptyState message="No data yet" action="Pair iPhone" />
}

export function CaloriesPage() {
  return <EmptyState message="No data yet" action="Pair iPhone" />
}

export function HistoryPage() {
  return <EmptyState message="No data yet" action="Pair iPhone" />
}

export function AlarmsPage() {
  return <EmptyState message="No alarms" action="New alarm" />
}

export function WebhooksPage() {
  return <EmptyState message="No webhooks" action="New webhook" />
}

export function DevicesPage() {
  return <EmptyState message="No devices paired" action="Pair iPhone" />
}

export function SyncPage() {
  return <EmptyState message="No sync batches yet" action="Pair iPhone" />
}

export function SettingsPage() {
  return <EmptyState message="No profile set" action="Edit profile" />
}

export function NotFoundPage() {
  return (
    <p>
      Nothing at this address. <Link to="/" className="underline underline-offset-4">Go to Today</Link>
    </p>
  )
}
