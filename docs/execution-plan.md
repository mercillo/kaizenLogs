# KaizenLogs — Execution Plan

Companion to [`system-design.md`](./system-design.md). The design says **what** and **why**; this file says **in what order**, **what "done" means**, and **how we'll know**.

## Working agreements

- **One milestone per PR (or a small PR stack) on `main`.** Each PR is deployable, and Vercel preview deploys run on every PR.
- **Schema changes only through migrations** in `supabase/migrations/`. Never edit the hosted DB by hand, except for the dashboard kill switch.
- **RLS tests are written in the same PR as the tables they protect.** A table without a passing isolation test isn't done.
- **The UI stays functional-but-plain until M8.** Use semantic HTML and Tailwind defaults, with no design system work before then.
- **Definition of done, for every milestone:**
  - typecheck, lint, and tests pass in CI
  - the Vercel preview works
  - `system-design.md` is updated if a decision changed

## Estimates

Effort is in **focused days** (about 4–6 hrs of real work), solo. The total is **about 20–25 focused days**, or roughly 5–7 weeks of evenings and weekends.

---

## M0 — Accounts & prerequisites (0.5 day)

- [x] GitHub repo `kaizenlogs` (private), connected to this folder
- [x] Supabase project (free tier), region `us-west-1`
- [x] Google Cloud project → OAuth consent screen (External, app name KaizenLogs) → OAuth client (Web)
  - [x] Authorized redirect: `https://<project-ref>.supabase.co/auth/v1/callback`
  - [x] Local redirect: `http://127.0.0.1:54321/auth/v1/callback` (and the `localhost` variant)
- [ ] Vercel project linked to the GitHub repo (deferred until there's something to preview)
- [ ] Anthropic API key (only needed by M7)
- [x] Install Docker Desktop (Supabase local stack), Node 24 LTS, pnpm (the Supabase CLI is a dev dependency, run as `pnpm supabase`)

**Done when:** every account exists, and the secrets are recorded in a password manager (not in git).

## M1 — Scaffold (1 day)

- [x] `pnpm create next-app` (App Router, TS, Tailwind, ESLint), strict `tsconfig`
- [x] Prettier, `lint-staged` + husky pre-commit
- [x] `supabase init`
- [x] `supabase start` runs locally (needs Docker Desktop)
- [x] `lib/supabase/{server,client,proxy}.ts` using `@supabase/ssr`, plus root `proxy.ts` (Next 16 renamed `middleware.ts` to `proxy.ts`)
- [x] `.env.example`; `.env.local` gitignored
- [x] GitHub Actions CI: install → typecheck → lint → format check → unit tests → build; separate job runs `supabase db reset` + `supabase test db`
- [x] `shadcn init` (Radix base, components land in `components/ui/`); install `lucide-react`, `date-fns`, `date-fns-tz`, `next-themes`
- [x] Vitest (unit) and Playwright (e2e) configured, one smoke test each (e2e runs locally, not in CI yet)
- [x] README: how to run locally

**Done when:** `pnpm dev` serves a placeholder page, CI passes on the first PR, and the Vercel preview deploys.

## M2 — Auth (1.5 days)

- [ ] Enable the Google provider in Supabase (local `config.toml` + hosted dashboard)
- [ ] `/login` page with a "Continue with Google" button
- [ ] `app/auth/callback/route.ts`: exchange the code for a session
- [ ] `proxy.ts`: refresh the session and redirect logged-out users away from `(app)` routes
- [ ] Migration: `profiles` table + `on auth.users insert` trigger (creates the profile, copies the email, defaults the timezone)
- [ ] `profiles.role` + `is_admin()` helper; seed Marky as admin
- [ ] Sign-out
- [ ] RLS on `profiles` (read/update own row only) + pgTAP test

**Done when:** you can sign in with Gmail locally and on a preview, a profile row exists, logged-out users get redirected, and the RLS test passes.

## M3 — Schema, RLS, seed (3 days)

The biggest-risk milestone. Get the data model right before building UI.

- [ ] Migrations for every table in the design:
  - `templates`, `template_versions`, `user_templates`, `entry_presets`
  - `entries`, `entry_sections`, `prompts`, `generated_prompts`
  - `kaizen_goals`, `kaizen_checkins`, `todos`
- [ ] Constraints:
  - unique (entry_id, template_id)
  - unique (goal_id, date)
  - `on delete cascade` from `auth.users` down through everything
  - check constraints on enums and scales
- [ ] Indexes: (user_id, entry_date desc), (user_id, template_id), (user_id, for_date)
- [ ] RLS policies for every table, per the Security section
- [ ] Extend the signup trigger: add the built-in templates to `user_templates` and set the default preset to Recommended
- [ ] `seed.sql`:
  - the 6 built-in templates: Gratitude, 15 Things I Did Well, Reflection, Kaizen (1%), Intention, Mood
  - a To-dos linked template
  - the Recommended preset
  - starter prompts (placeholder set; final content comes from the prompt workshop)
- [ ] SQL function `chop_wood_streak(uid)` with the grace-day rule + `kaizen_goal_streak(goal_id)`
- [ ] `supabase gen types typescript` → `lib/db/types.ts`, plus a CI step that fails if the types are stale
- [ ] **pgTAP suite:** user A cannot read, insert, update, or delete user B's rows in _every_ per-user table. Also: no section can be inserted on someone else's entry, and no one can write built-in templates.
- [ ] **Streak tests:**
  - consecutive days
  - 1 miss in 7 days (kept)
  - 2 misses in 7 days (reset)
  - timezone boundary
  - backdated entry that doesn't repair a missed day

**Done when:** `supabase db reset && supabase test db` is green, and the generated types compile.

## M4 — Template engine + entry editor (4 days)

- [ ] `lib/templates/fields.ts`: `Field` union type (text, list, scale, bool, todos) + `fieldsToZod()`
- [ ] Unit tests for `fieldsToZod`: valid and invalid data for each field type; list `max` enforced; `target` never blocks saving
- [ ] `components/template-form/`: one renderer per field type + `<TemplateForm fields data onChange>`
  - list shows a counter against its target (e.g. 9/15)
  - scale is a 1–5 tap control
- [ ] `lib/data/entries.ts` (data-access layer): create an entry, add/remove/reorder sections, update the body, update a section
- [ ] Server actions + zod validation, built from the section's template version
- [ ] `/entry/new`: choose **Recommended** or **Blank** (or the user's default preset)
- [ ] `/entry/[id]`:
  - title, body (textarea)
  - sections in order; "+ Add section" (from My Templates), remove, move up/down
- [ ] Autosave: debounced (~1.5s) per section and for the body; "Saved" indicator; `localStorage` draft backup that's cleared on successful save
- [ ] Markdown render for the read view (`react-markdown` + sanitize)
- [ ] "Stuck? Try this": a prompt chip per section; clicking it inserts the prompt text

**Done when:** you can create a Recommended entry, fill every section type, reorder, reload, and nothing is lost. Validation rejects malformed data server-side.

## M5 — Today, history, template library (2.5 days)

- [ ] `/today`:
  - chop wood streak
  - today's entries (cards)
  - "New entry" button
  - kaizen check-ins strip (stubbed until M6)
  - today's to-dos (stubbed until M6)
- [ ] `/log`:
  - month calendar with an intensity per day, from one `group by entry_date` query
  - click a day to list its entries
  - prev/next month
- [ ] `/templates`:
  - library of built-in templates with description and source
  - add to or remove from My Templates
  - per-template settings (e.g. gratitude target 3 → 15)
  - choose the default preset
- [ ] Timezone handling: `entry_date` computed from `profiles.timezone`; editable in settings

**Done when:** a week of test entries shows correctly on the calendar, and the streak matches the pgTAP expectations in the UI.

## M6 — Kaizen goals & to-dos (3 days)

- [ ] Pick the chart library (Recharts is the likely pick, via shadcn's chart wrapper)
- [ ] `/kaizen`:
  - create a goal (`check` or `measure` with unit, direction, and optional target)
  - archive a goal
  - per-goal streak
  - trend chart for measured goals (small, dependency-light chart lib)
- [ ] Daily check-in UI on `/today` + the Kaizen (1%) section can link a goal
- [ ] To-dos data layer + `<TodoList date>` component, reused in:
  - `/today`
  - `/todos`
  - the **To-dos linked section** inside entries
- [ ] Rollover: when you open the app, any open to-dos from past dates prompt **Carry over** (creates a linked copy for today, original marked done-as-carried) or **Let go** (status `let_go`)
- [ ] Intention section's "Today's focus" items get a "→ make to-do" action

**Done when:** a to-do added inside an entry shows on `/today` and `/todos` and in a second entry for the same date. Rollover works across a day boundary (tested with a mocked clock in e2e).

## M7 — Settings, data ownership, AI prompt (2.5 days)

- [ ] `/settings`: display name, timezone, default preset, AI opt-in toggle with a plain-language disclosure
- [ ] **Export:** a route handler streams a zip of Markdown files (one per entry; sections rendered from template fields) + `kaizenlogs.json`
- [ ] **Delete account:**
  - typed confirmation
  - server action uses the service role _only here_ to delete the auth user; cascade wipes the data
  - e2e verifies no rows remain
- [ ] **AI prompt:**
  - `/api/ai/prompt`: auth check, `ai_enabled` check, 1/day cap via unique (user_id, date), last ~5 entries trimmed, no PII, Claude API call
  - store the result in `generated_prompts`; on any error, fall back to the curated prompt
  - shown as a "Today's prompt" chip
- [ ] Basic per-user rate limit on write actions

**Done when:**

- export opens cleanly
- delete leaves zero rows (verified by a test)
- AI prompt works once per day and degrades gracefully with a bad API key

## M8 — UI pass (3–4 days)

- [ ] Pick a direction (see "Open items"): palette, type, spacing scale
- [ ] Tailwind theme tokens + dark mode
- [ ] Layout shell: sidebar on desktop, collapsible on mobile
- [ ] Polish the editor, calendar, and Today page; empty states; loading states
- [ ] Accessibility pass: keyboard navigation, focus rings, labels, contrast

**Done when:** it feels calm to write in on desktop, it's usable on a phone browser, and Lighthouse accessibility scores ≥ 95.

## M9 — Production launch (1 day)

- [ ] Hosted Supabase: `supabase db push` migrations, run the seed for built-ins, enable Google in the dashboard
- [ ] Vercel production env vars
- [ ] Google OAuth consent screen: add the production domain, publish the app (move out of "Testing" so any Gmail can sign in)
- [ ] Subdomain: `kaizenlogs.<your-domain>` CNAME → Vercel; update the Supabase Site URL + redirect URLs + Google authorized origins
- [ ] Error monitoring (Vercel logs is enough for now; Sentry optional)
- [ ] Smoke test in production with 2 real Gmail accounts, including an isolation check

**Done when:** a friend can sign up on the real domain and write an entry, and neither of you can see the other's journal.

---

## Critical path & risks

```
M0 → M1 → M2 → M3 ──→ M4 ──→ M5 ──→ M8 → M9
                  └──→ M6 (after M4's data layer) ─┘
                  └──→ M7 (after M4) ──────────────┘
```

| Risk                                                     | Mitigation                                                                                                     |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Template versioning gets fiddly                          | Keep `template_versions` immutable. Sections always read fields from the exact version they were written with. |
| Timezone bugs in streaks and rollover                    | All "today" logic uses `profiles.timezone` in SQL. Tests cover the UTC/PT boundary.                            |
| RLS gap on a new table                                   | CI runs the pgTAP isolation suite. The PR template has a checklist item: "new table → RLS + test".             |
| Google OAuth "Testing" mode blocks strangers             | Publish the consent screen in M9. Basic scopes (email, profile) don't need Google verification.                |
| Supabase free tier pauses when idle                      | Acceptable pre-launch. Upgrade or add a keep-alive when real users arrive.                                     |
| Scope creep (custom template builder, presets UI, admin) | Already parked under "Later" in the design. Don't start them before M9.                                        |

## Open items to resolve before the milestone that needs them

| Item                                                           | Needed by                              |
| -------------------------------------------------------------- | -------------------------------------- |
| Starter prompts per template (prompt workshop from your books) | M3 seed (placeholders OK), final by M8 |
| UI direction: mood, palette, fonts                             | M8                                     |
| Subdomain name                                                 | M9                                     |
