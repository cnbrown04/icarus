const field = 'w-full border border-neutral-500 bg-white px-2 py-2 dark:border-neutral-400 dark:bg-neutral-950'
const focus = 'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-900 dark:focus-visible:outline-neutral-100'

export function LoginPage() {
  return (
    <main className="mx-auto flex min-h-svh max-w-sm flex-col justify-center gap-6 p-4 md:p-6">
      <h1 className="text-base font-medium">Sign in</h1>
      <form className="flex flex-col gap-6" onSubmit={(event) => event.preventDefault()}>
        <div className="flex flex-col items-start gap-2">
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="email" className={`${field} ${focus}`} />
        </div>
        <div className="flex flex-col items-start gap-2">
          <label htmlFor="password">Password</label>
          <input
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            className={`${field} ${focus}`}
          />
        </div>
        <button
          type="submit"
          className={`self-start bg-neutral-900 px-4 py-2 text-white hover:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-300 ${focus}`}
        >
          Sign in
        </button>
      </form>
    </main>
  )
}
