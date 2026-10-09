# KaizenLogs

A journaling web app inspired by _Chop Wood, Carry Water_: gratitude, reflection, and small daily improvement.

- Design: [`docs/system-design.md`](docs/system-design.md)
- Plan and milestones: [`docs/execution-plan.md`](docs/execution-plan.md)

Stack: Next.js 16 (App Router, TypeScript) on Vercel, Supabase (Postgres + Auth), Tailwind v4 + shadcn/ui.

## Prerequisites

- Node 24 (`nvm use` reads `.nvmrc`)
- pnpm (`corepack enable`)
- Docker Desktop, running, for the local Supabase stack

The Supabase CLI is a dev dependency, so run it as `pnpm supabase …`. There's no global install.

## Run locally

```bash
pnpm install
pnpm db:start                 # local Supabase in Docker; prints URLs and keys
cp .env.example .env.local    # paste the API URL and publishable key from `pnpm supabase status`
pnpm dev                      # http://localhost:3000
```

Supabase Studio runs at http://127.0.0.1:54323. Stop the stack with `pnpm db:stop`.

## Scripts

| Command          | What it does                                      |
| ---------------- | ------------------------------------------------- |
| `pnpm dev`       | Next.js dev server                                |
| `pnpm typecheck` | Generate route types, then `tsc --noEmit`         |
| `pnpm lint`      | ESLint                                            |
| `pnpm format`    | Prettier (write)                                  |
| `pnpm test`      | Vitest unit tests                                 |
| `pnpm test:e2e`  | Playwright e2e (starts `pnpm dev` if not running) |
| `pnpm db:reset`  | Re-apply `supabase/migrations/` and `seed.sql`    |
| `pnpm db:test`   | pgTAP tests in `supabase/tests/`                  |

First time running e2e: `pnpm exec playwright install chromium`.

## Conventions

- Schema changes go through migrations in `supabase/migrations/` only (`pnpm supabase migration new <name>`).
- Every new table ships with RLS policies and a pgTAP isolation test in the same PR.
- A pre-commit hook runs ESLint and Prettier on staged files.
