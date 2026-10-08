# 0004. Use Vite, React and shadcn Lyra for the website

Status: Proposed (PLAN.md draft, 2026-10-07)

## Context

The website shows the same data as the app and includes alarms, webhooks and device pages (PLAN.md §13.3). The backend is Rust, so a second Node server would add a runtime to operate. The UI needs a consistent, boxy visual style that matches the iOS app's square corners (PLAN.md §4.3, §15.2).

## Decision

Build a Vite and React single-page app in TypeScript (strict), with TanStack Router and TanStack Query. Axum serves the built `web/dist` at `/` with SPA fallback, and the API lives under `/v1` on the same origin (PLAN.md §13.1). Initialise shadcn/ui with `npx shadcn@latest init --preset lyra`: neutral base colour, Phosphor icons, JetBrains Mono, radius `none` (PLAN.md §4.3, §13.1).

Lyra's generated theme CSS and `components/ui/*` are not edited by hand. CI compares a SHA-256 of the generated CSS with `web/.lyra-lock`, and an intentional change goes through `shadcn apply` to regenerate the lock (PLAN.md §13.2).

## Consequences

- No Node server runs in production. The Rust binary serves the static build.
- Visual changes go through the preset and the lock file, which keeps the design consistent and reviewable.
- App-specific styling uses Tailwind utilities on wrapper elements, never overrides of Lyra variables (PLAN.md §13.2 rule 3).
- Charts use the shadcn chart components on Lyra's chart colour tokens (PLAN.md §13.1).
