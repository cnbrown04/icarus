import { HeartbeatIcon } from '@phosphor-icons/react'
import { useNavigate } from '@tanstack/react-router'
import { useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { ErrorLine } from '@/components/error-line'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { describeError } from '@/lib/errors'
import { useLogin } from '@/lib/queries'

export function LoginPage() {
  const login = useLogin()
  const navigate = useNavigate()
  const client = useQueryClient()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    login.mutate(
      { email, password },
      {
        onSuccess: () => {
          void client.invalidateQueries()
          void navigate({ to: '/' })
        },
      },
    )
  }

  return (
    <main className="mx-auto flex min-h-svh w-full max-w-sm flex-col justify-center gap-6 p-4 md:p-6">
      <p className="flex items-center justify-center gap-2 text-base font-medium">
        <HeartbeatIcon aria-hidden className="size-5 text-hr" />
        Icarus
      </p>
      <Card>
        <CardContent className="flex flex-col gap-6">
          <h1 className="text-base font-medium">Sign in</h1>
          <form className="flex flex-col gap-6" onSubmit={onSubmit} noValidate>
            <div className="flex flex-col gap-2">
              <Label htmlFor="email">Email</Label>
              <Input
                id="email"
                name="email"
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(event) => setEmail(event.target.value)}
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="password">Password</Label>
              <Input
                id="password"
                name="password"
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={(event) => setPassword(event.target.value)}
              />
            </div>
            {login.isError && <ErrorLine message={describeError(login.error, 'login')} />}
            <Button type="submit" className="self-start" disabled={login.isPending}>
              Sign in
            </Button>
          </form>
        </CardContent>
      </Card>
    </main>
  )
}
