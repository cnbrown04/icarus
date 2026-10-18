import { keepPreviousData, useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api } from './api'
import { toRfc3339 } from './time'
import type {
  Alarm,
  AlarmDispatchesResponse,
  AlarmInput,
  AlarmsResponse,
  AlarmTest,
  CreatedHook,
  DailyResponse,
  DevicesResponse,
  HookCreate,
  HookDeliveriesResponse,
  HookUpdate,
  HooksResponse,
  HrResolution,
  HrResponse,
  Hook,
  LiveHr,
  Me,
  MeUpdate,
  MinutesResponse,
  PairingCode,
  RotatedSecret,
  SyncState,
  WhoopStatus,
  WhoopSummary,
} from './types'

// Live values refresh on this cadence; the age label reads the timestamp, not the poll.
const LIVE_REFRESH_MS = 15_000

export const queryKeys = {
  me: ['me'] as const,
  live: ['metrics', 'live'] as const,
  hr: (from: string, to: string, res: HrResolution) => ['metrics', 'hr', from, to, res] as const,
  minutes: (from: string, to: string) => ['metrics', 'minutes', from, to] as const,
  daily: (from: string, to: string) => ['metrics', 'daily', from, to] as const,
  devices: ['devices'] as const,
  syncState: ['sync', 'state'] as const,
  alarms: ['alarms'] as const,
  alarmDispatches: ['alarm-dispatches'] as const,
  hooks: ['hooks'] as const,
  deliveries: (hookId: string) => ['hooks', hookId, 'deliveries'] as const,
  whoop: ['integrations', 'whoop'] as const,
  whoopSummary: (day: string) => ['integrations', 'whoop', 'summary', day] as const,
}

type Range = { from: Date; to: Date }

const meQuery = () => ({ queryKey: queryKeys.me, queryFn: () => api.get<Me>('/v1/me') })

export function useMe() {
  return useQuery(meQuery())
}

export function useUpdateMe() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ changes, version }: { changes: MeUpdate; version: number }) =>
      api.patch<Me>('/v1/me', changes, version),
    onSuccess: (me) => client.setQueryData(queryKeys.me, me),
  })
}

export function useLiveHr(enabled = true) {
  return useQuery({
    queryKey: queryKeys.live,
    queryFn: () => api.get<LiveHr>('/v1/metrics/live'),
    refetchInterval: LIVE_REFRESH_MS,
    enabled,
  })
}

export function useHr({ from, to }: Range, res: HrResolution, enabled = true) {
  const f = toRfc3339(from)
  const t = toRfc3339(to)
  return useQuery({
    queryKey: queryKeys.hr(f, t, res),
    queryFn: () => api.get<HrResponse>('/v1/metrics/hr', { from: f, to: t, res }),
    placeholderData: keepPreviousData,
    enabled,
  })
}

export function useMinutes({ from, to }: Range, enabled = true) {
  const f = toRfc3339(from)
  const t = toRfc3339(to)
  return useQuery({
    queryKey: queryKeys.minutes(f, t),
    queryFn: () => api.get<MinutesResponse>('/v1/metrics/minutes', { from: f, to: t }),
    placeholderData: keepPreviousData,
    enabled,
  })
}

// Daily summaries are keyed by local day, so the caller passes YYYY-MM-DD bounds (inclusive).
export function useDaily(fromDay: string, toDay: string, enabled = true) {
  return useQuery({
    queryKey: queryKeys.daily(fromDay, toDay),
    queryFn: () => api.get<DailyResponse>('/v1/metrics/daily', { from: fromDay, to: toDay }),
    placeholderData: keepPreviousData,
    enabled,
  })
}

export function useSyncState(enabled = true) {
  return useQuery({
    queryKey: queryKeys.syncState,
    queryFn: () => api.get<SyncState>('/v1/sync/state'),
    refetchInterval: 60_000,
    enabled,
  })
}

export function useDevices() {
  return useQuery({
    queryKey: queryKeys.devices,
    queryFn: () => api.get<DevicesResponse>('/v1/devices'),
  })
}

export function useCreatePairingCode() {
  return useMutation({
    mutationFn: () => api.post<PairingCode>('/v1/devices/pairing-codes'),
  })
}

export function useRevokeDevice() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (deviceId: string) => api.delete(`/v1/devices/${deviceId}`),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.devices }),
  })
}

export function useAlarms() {
  return useQuery({
    queryKey: queryKeys.alarms,
    queryFn: () => api.get<AlarmsResponse>('/v1/alarms'),
    select: (data): Alarm[] => data.alarms,
  })
}

export function useHooks() {
  return useQuery({
    queryKey: queryKeys.hooks,
    queryFn: () => api.get<HooksResponse>('/v1/hooks'),
    select: (data) => data.hooks,
  })
}

export function useLogin() {
  return useMutation({
    mutationFn: (credentials: { email: string; password: string }) => api.post<void>('/v1/auth/login', credentials),
  })
}

export function useLogout() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: () => api.post<void>('/v1/auth/logout'),
    onSettled: () => client.clear(),
  })
}

export function useDeleteAccount() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (confirm: string) => api.delete('/v1/me', { confirm }),
    onSuccess: () => client.clear(),
  })
}

// Alarm and webhook writes send If-Match with the version the editor loaded (contract: Conventions).
export function useCreateAlarm() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (input: AlarmInput) => api.post<Alarm>('/v1/alarms', input),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.alarms }),
  })
}

export function useUpdateAlarm() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ id, changes, version }: { id: string; changes: Partial<Omit<AlarmInput, 'id'>>; version: number }) =>
      api.patch<Alarm>(`/v1/alarms/${id}`, changes, version),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.alarms }),
  })
}

export function useDeleteAlarm() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ id, version }: { id: string; version: number }) => api.delete(`/v1/alarms/${id}`, undefined, version),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.alarms }),
  })
}

export function useTestAlarm() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => api.post<AlarmTest>(`/v1/alarms/${id}/test`),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.alarmDispatches }),
  })
}

export function useDispatches() {
  return useQuery({
    queryKey: queryKeys.alarmDispatches,
    queryFn: () => api.get<AlarmDispatchesResponse>('/v1/alarm-dispatches', { limit: 50 }),
    select: (data) => data.dispatches,
  })
}

export function useCreateHook() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (input: HookCreate) => api.post<CreatedHook>('/v1/hooks', input),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.hooks }),
  })
}

export function useUpdateHook() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ id, changes, version }: { id: string; changes: HookUpdate; version: number }) =>
      api.patch<Hook>(`/v1/hooks/${id}`, changes, version),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.hooks }),
  })
}

export function useDeleteHook() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => api.delete(`/v1/hooks/${id}`),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.hooks }),
  })
}

export function useRotateHook() {
  return useMutation({
    mutationFn: (id: string) => api.post<RotatedSecret>(`/v1/hooks/${id}/rotate-secret`),
  })
}

export function useHookDeliveries(hookId: string) {
  return useInfiniteQuery({
    queryKey: queryKeys.deliveries(hookId),
    queryFn: ({ pageParam }) =>
      api.get<HookDeliveriesResponse>(`/v1/hooks/${encodeURIComponent(hookId)}/deliveries`, { cursor: pageParam }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (page) => page.next_cursor ?? undefined,
  })
}

// Live-fetched WHOOP values are refetched on every visit; nothing is cached across sessions.
export function useWhoopStatus() {
  return useQuery({
    queryKey: queryKeys.whoop,
    queryFn: () => api.get<WhoopStatus>('/v1/integrations/whoop'),
  })
}

export function useWhoopSummary(day: string, enabled: boolean) {
  return useQuery({
    queryKey: queryKeys.whoopSummary(day),
    queryFn: () => api.get<WhoopSummary>('/v1/integrations/whoop/summary', { day }),
    enabled,
    staleTime: 0,
  })
}

export function useDisconnectWhoop() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: () => api.delete('/v1/integrations/whoop'),
    onSettled: () => client.invalidateQueries({ queryKey: queryKeys.whoop }),
  })
}
