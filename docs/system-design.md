# KaizenLogs — System Design & Build Plan

## Context

A journaling web app inspired by _Chop Wood, Carry Water_, _Be Water, My Friend_, and other mind-training reading: gratitude, reflection, small daily improvement. **KaizenLogs**: "log" is the wood you chop _and_ the entry you log. It lives in a **new standalone repo** (separate from the Next.js personal site) and will later be pointed at a subdomain of the personal domain. System design comes first, UI last. **Status: planning only, no code yet.**

## Decisions at a glance

| Area       | Decision                                                                                         |
| ---------- | ------------------------------------------------------------------------------------------------ |
| Stack      | Next.js (App Router, TS) on Vercel + Supabase (Postgres + Auth) — ADR-001                        |
| Auth       | Google sign-in, open signup (dashboard kill switch)                                              |
| Privacy    | Private per user, enforced in the DB with Row-Level Security                                     |
| Entries    | **A journal entry is a page; templates are sections you add to it** (or keep it blank) — ADR-002 |
| Daily flow | Log anytime; "chop wood streak" counts days with a journal entry, 1 grace day per 7              |
| Kaizen     | Goals are yes/no habits _or_ measured numbers                                                    |
| To-dos     | Daily "wood to chop": carry over or let go at rollover                                           |
| Prompts    | Curated sample prompts per template + opt-in AI daily prompt                                     |
| Editor     | Plain textarea, autosave, rendered as Markdown                                                   |
| History    | Month calendar                                                                                   |
| Platform   | Desktop-first web, still usable on phones; no offline mode                                       |
| Frontend   | React Server Components + Tailwind + **shadcn/ui** — ADR-003                                     |
| Your data  | Export (Markdown zip + JSON), delete account                                                     |

## ADR-001: Hosting & database

**Decision:** Vercel + Supabase. Postgres is the real decision; Supabase is how we get it managed.

**Why relational/Postgres:** the data is relational and per-user (users → entries, goals → check-ins, todos). Streaks and the calendar are date-range aggregates. Constraints like one check-in per goal per day are enforced in the DB. NoSQL would push joins and streak math into app code.

| Option                   | Ease    | Senior-review story                                                                          | Verdict             |
| ------------------------ | ------- | -------------------------------------------------------------------------------------------- | ------------------- |
| **Supabase + Vercel**    | Highest | Privacy enforced in the DB (RLS); migrations in git; plain Postgres, portable with `pg_dump` | **Chosen**          |
| Neon + Auth.js + Drizzle | Medium  | Own the auth layer, but authorization lives only in app code                                 | Good alt, more code |
| AWS (RDS + Cognito)      | Low     | Overkill for v1 (VPC, IAM, ~$15+/mo)                                                         | Over-engineered     |
| Firebase                 | High    | NoSQL fits relational data poorly                                                            | Rejected            |

**Accepted tradeoffs:**

- _Vendor coupling:_ limited by routing all SDK calls through `lib/supabase/*` + `lib/data/*`.
- _Free tier:_ the project pauses after about 1 week idle; go Pro ($25/mo) when others depend on it.
- _Vercel Hobby:_ non-commercial only, which is fine here.
- _Scale:_ one Postgres instance handles thousands of users.

## ADR-002: Journal entries composed of template sections

**Decision:**

- A **journal entry** is the unit you write: a page with an optional title and a free-writing `body`.
- You can **add template sections** to it (Gratitude, 15 Things I Did Well, Reflection…) in any order, or leave it as a blank page.
- Templates are **data, not code**: a `templates` table describes each exercise's fields.

```
entries          one row per journal entry (the page)
  └─< entry_sections   one row per template added to that entry, ordered by position
         └── templates      describes the fields the section renders
```

**Why:**

- _The streak means one thing:_ "did I write a journal entry today?" Only one table is involved.
- _One `entries` table:_ calendar, streaks, search, export, and AI context all query "my entries on a date." That's one query, one index, one RLS policy, with no per-type tables and no `UNION`s.
- _Sections as a child table, not a jsonb array on the entry:_
  - Autosave writes one section at a time instead of rewriting the whole entry.
  - Each section is validated against its own template version.
  - Queries by template work directly, e.g. "all my gratitude lists this month" is `where template_id = gratitude`.
  - `user_id` is copied onto each section so RLS stays a simple `user_id = auth.uid()`.
- _Templates as rows:_ a new exercise is an insert, not a deploy, which leaves room for user-created templates.
- _The rule applied:_ separate tables for separate _entities_ (goals, todos, sections have their own lifecycles). One template engine handles the _variants_.

**Field system:** a small set of field types covers every template.

```ts
type Field =
  | { key; type: "text"; label; placeholder? }
  | { key; type: "list"; label; target?; max? } // "15 things…", with a counter
  | { key; type: "scale"; label; min: 1; max: 5 } // mood, energy
  | { key; type: "bool"; label };
```

- One `<TemplateForm>` renders any template.
- `fieldsToZod(fields)` builds the validation schema, which runs in the server action before insert.

**Versioning:**

- Templates carry a `version`; each section stores `template_id` + `template_version`.
- Editing a template bumps the version. Old entries render with the version they were written in, so a version-history row or a fields snapshot is kept per version.

**Promote-later path:** if we ever want analytics across list items (e.g. "most common gratitude themes"), move them into an `entry_items` table.

### Built-in templates (v1)

| Template             | Source                                                                                                                                                                                  | Fields                                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Gratitude            | gratitude practice                                                                                                                                                                      | list "I'm grateful for…" (target 3, user-adjustable) + optional text                                                 |
| 15 Things I Did Well | _Chop Wood Carry Water_: "Write out 15 specific things you did well today. Feel free to use examples of areas you got better in even if they weren't the very best you are capable of." | list (target 15)                                                                                                     |
| Intention            | process over outcome                                                                                                                                                                    | text "What's in my control today?", list "Today's focus" (items can become todos), optional text "I am someone who…" |
| Reflection           | Stoic evening review                                                                                                                                                                    | text: went well, could be better, what I learned                                                                     |
| Kaizen (1%)          | kaizen                                                                                                                                                                                  | text "How was I 1% better today?" + optional linked goal                                                             |
| Mood                 | check-in                                                                                                                                                                                | scale mood, scale energy, optional note                                                                              |

- Free write is no longer a template; it's the entry's own `body`.
- The same template can't be added twice to one entry: unique (entry_id, template_id).
- **Mood is an optional section**, added like any other.
- **To-dos section ("Wood to chop"):** a _linked_ section. It stores nothing in `entry_sections.data`; it renders and edits the rows in `todos` where `for_date = entry.entry_date`.
  - The `todos` table stays the single source of truth, so carry-over and let-go keep working.
  - The same list shows on `/today` and `/todos`, and in any entry for that date. There's no duplicated data.
  - Implemented as a special field type `{ type: "todos" }` that the form renderer maps to `<TodoList date=…>`.
- **Starting points: presets.** "New entry" offers two choices:
  1. **Recommended**: a built-in preset. **Final:** Gratitude, 15 Things I Did Well, Reflection, Kaizen (1%), To-dos. There's no morning/evening split: journal whenever you like, and the To-dos section is simply that day's to-dos and goals. Intention and Mood are optional add-ons.
  2. **Blank**: an empty page; you pick your sections with "+ Add section".
- Presets are rows in `entry_presets`: owner null means built-in, otherwise the user's own.
- A user can set any preset as their default. In v1.1 they can also save their own ("Morning", "Evening"); the table supports that from day one.
- A preset only pre-fills sections. The entry is still fully editable, so you can add, remove, or reorder after starting.

- **v1.1 candidates** (_Be Water, My Friend_, Shannon Lee's tools): Aim + Affirmation, Be Water (an obstacle and how I adapted).
- **Also v1.1:** user-created templates. The schema supports them from day one; only the builder UI is deferred.
- **Sample prompts ("Stuck? Try this")** are attached per template, rotate daily, and pre-fill the entry when clicked.

## Other product design

**Streaks: the "chop wood streak"**

- "Chop wood" is the daily practice itself, shown as "12 days chopping wood."
- A day counts when it has ≥1 **journal entry** with content (non-empty body or at least one filled section), in the user's timezone.
- Grace rule: 1 missed day per rolling 7 is forgiven; a 2nd miss resets the streak.
- Computed by a SQL function, not stored.
- Backdating an entry can't repair a missed day.
- Each kaizen goal has its own streak.

**Kaizen goals:** `kind` is `check` (yes/no) or `measure` (number + unit + direction up/down + optional target). Measured goals get a trend chart.

**To-dos:** belong to one day (`for_date`). At rollover, open items prompt a choice: **carry over** (creates a linked copy) or **let go**. No backlog, priorities, or projects.

**Editor:**

- A plain textarea; autosave to the DB every few seconds, plus a local draft backup.
- Rendered with `react-markdown` (sanitized).

**History:** a month calendar with a dot/intensity per day; click a day to see its entries. One `group by entry_date` query per month.

**AI prompt (opt-in):**

- Server-side Claude API call, only for users with `ai_enabled` on.
- Input: the last ~5 entries, no name or email.
- At most 1 per user per day, cached in `generated_prompts`.
- Falls back to the curated prompt if the call fails.
- Weekly summaries are deferred.

**Your data:**

- Export: Markdown zip, one file per entry, rendered from template fields; plus a full JSON dump.
- Delete account: typed confirmation, then an `on delete cascade` wipes everything.

## ADR-003: Frontend & UI library

**Decision:** Tailwind CSS + **shadcn/ui** (Radix primitives), not Material UI.

**Why shadcn/ui over MUI:**

- _The look:_ MUI ships Material Design, so apps tend to look like Google products. A journal should feel calm and personal. shadcn components start nearly unstyled, so we build our own look instead of overriding someone else's.
- _One styling system:_ MUI brings its own engine (Emotion) and theme object, which would sit alongside Tailwind and conflict with it. shadcn is Tailwind.
- _Server rendering:_ shadcn components are plain React + Tailwind and need no App Router setup. MUI needs extra configuration and ships more client JavaScript.
- _Ownership:_ shadcn copies component source into the repo (`components/ui/`), so we can change anything.
- _When MUI would win:_ data-heavy admin tools (its data grid), or when a finished look on day one matters more than a custom one. Neither applies here.

**Frontend choices:**

| Need                | Choice                                                                                   | Notes                                                              |
| ------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Rendering           | Server Components for reads; client components only for the editor, sections, and to-dos | Refresh after each save; no client data-fetching library           |
| Components          | shadcn/ui                                                                                | Dialogs, dropdowns, toggles, calendar                              |
| Icons               | lucide-react                                                                             | shadcn's default set                                               |
| Forms + autosave    | React state + debounced save, validated with Zod                                         | No form library; schemas come from the template engine             |
| Dates & timezones   | date-fns + date-fns-tz                                                                   | "Today" in the user's timezone, calendar grid, to-do rollover      |
| Reordering sections | Up/down buttons in v1                                                                    | dnd-kit drag-and-drop later                                        |
| Dark mode           | next-themes                                                                              |                                                                    |
| Fonts               | next/font                                                                                |                                                                    |
| Charts              | Undecided until M6                                                                       | Recharts is the likely pick; only needed for measured kaizen goals |

**Still open:** the look and feel (palette, typography), decided in M8.

## Architecture

```
Browser ──> Next.js on Vercel (App Router)
              ├─ proxy.ts             → refresh Supabase session, gate (app) routes
              ├─ Server Components    → reads as the user (JWT → RLS applies)
              ├─ Server Actions + zod → all writes (zod built from template fields)
              ├─ /auth/callback       → OAuth code exchange
              └─ /api/ai/prompt       → Claude API (server-only key)
                     │
                     ▼
            Supabase: Auth (Google) · Postgres + RLS
```

Every query runs as the logged-in user, so RLS is the source of truth for privacy. The service-role key is used only in seed and admin scripts.

## Auth & signup

- Supabase Google provider; Google Cloud OAuth client.
- **Open signup:** any Google account can create an account. There's no allowlist, no auth hook, and no `allowed_emails`/`app_settings` tables.
- **Kill switch:** Supabase Auth → "Allow new users to sign up" can be turned off in the dashboard if signups need to pause. No code needed.
- A trigger creates the `profiles` row and adds the built-in templates to the new user's `user_templates`.
- **Guardrails for open signup:**
  - AI prompts are opt-in and capped at 1 per user per day, so cost is bounded at about users × 1 call/day.
  - Server actions are rate-limited per user, e.g. max entries per minute, via a lightweight Postgres counter or Vercel's rate limiting.
  - Supabase free tier covers 50k monthly active users, far beyond expected usage.
- **No admin page in v1.** User counts come from a saved SQL query in the Supabase dashboard. `profiles.role` and `is_admin()` still ship, so `/admin` later is only UI work.
- **Admins never see journal content**, enforced by RLS.

## Data model

| Table               | Key columns                                                                                                            | Notes                                                      |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `profiles`          | id (= auth.users.id), email, display_name, role (user/admin), timezone, ai_enabled                                     |                                                            |
| `templates`         | id, owner_id? (null = built-in), slug, name, description, source, fields jsonb, version, is_public                     | built-ins seeded                                           |
| `template_versions` | template_id, version, fields jsonb                                                                                     | pk (template_id, version); keeps old entries renderable    |
| `entry_presets`     | id, owner_id? (null = built-in), name, template_ids uuid[] (ordered)                                                   | "Recommended" seeded; `profiles.default_preset_id`         |
| `user_templates`    | user_id, template_id, position, settings jsonb (e.g. `{target: 15}`), archived                                         | pk (user_id, template_id): "My Journal"                    |
| `entries`           | id, user_id, entry_date, title?, body (markdown), created_at, updated_at                                               | the journal page; idx (user_id, entry_date desc)           |
| `entry_sections`    | id, entry_id → entries (cascade), user_id, template_id, template_version, position, data jsonb, prompt_id?, updated_at | unique (entry_id, template_id); idx (user_id, template_id) |
| `prompts`           | id, template_id, text, source, active                                                                                  | sample prompts                                             |
| `generated_prompts` | user_id, date, template_id?, text, model                                                                               | unique (user_id, date)                                     |
| `kaizen_goals`      | id, user_id, title, why, kind (check/measure), unit?, target?, direction?, cadence, started_at, archived_at            |                                                            |
| `kaizen_checkins`   | id, goal_id, user_id, date, done, value?, note?                                                                        | unique (goal_id, date)                                     |
| `todos`             | id, user_id, title, for_date, status (open/done/let_go), carried_from_id?, sort_order, completed_at                    |                                                            |

## Security (RLS)

- **Per-user tables** (`entries`, `user_templates`, `kaizen_*`, `todos`, `generated_prompts`): `user_id = auth.uid()` for all operations.
- **`templates` / `template_versions` / `prompts`:** read if built-in, public, or owned by you; write only your own (built-ins are admin-only).
- **`entry_sections` insert check:** the parent entry must belong to the user, and the template must be one they can read.
- **`kaizen_checkins` insert check:** the goal must belong to the user.
- **Built-in templates/prompts writes:** gated by an `is_admin()` security-definer helper.

## App routes

- `/login`
- `/today`: streak, today's journal entries, "New entry" (blank or defaults), kaizen check-ins, today's to-dos
- `/entry/new`, `/entry/[id]`: title, body, "+ Add section" (pick from My Templates), reorder or remove sections
- `/log`: calendar history
- `/templates`: library; add, remove, and customize templates
- `/kaizen`, `/todos`
- `/settings`: profile, timezone, AI opt-in, export, delete account

## Repo layout

```
kaizenlogs/
  app/(auth)/login, app/auth/callback/route.ts
  app/(app)/today, entry, log, templates, kaizen, todos, settings
  components/template-form/        # field renderers + <TemplateForm>
  lib/templates/fields.ts          # Field types + fieldsToZod()
  proxy.ts                         # Next 16's renamed middleware
  lib/supabase/{server,client,proxy}.ts
  lib/data/*.ts                    # data-access layer
  lib/actions/*.ts                 # server actions
  supabase/migrations/*.sql, supabase/seed.sql   # schema, RLS, triggers, built-in templates, prompts
  supabase/tests/database/*.test.sql (pgTAP), e2e/*.spec.ts (Playwright)
```

## Build phases

1. Scaffold: repo, Next.js + TS + Tailwind, Supabase CLI local stack.
2. Auth: Google OAuth, proxy, profile trigger, admin role seed.
3. Schema + RLS + seed: built-in templates and prompts, streak functions, generated types, pgTAP tests.
4. Template engine + entry editor: field types, `fieldsToZod`, `<TemplateForm>`; entry page with body + add/reorder/remove sections, autosaved per section.
5. Today, calendar history, template library.
6. Kaizen goals + check-ins; to-dos with carry-over/let-go.
7. Settings (export, delete, AI opt-in) + AI prompt.
8. UI pass: calm, minimal, desktop-first, dark mode.
9. Deploy to Vercel + hosted Supabase; subdomain later.

**Later:** `/admin` page (user counts, disable users, template management), user-created templates (builder UI), Be Water templates, weekly AI reflections, reminders, family-app sharing.

## Verification

- **pgTAP:** user A can't read or modify B's entries, templates, goals, or todos; can't insert an entry against another user's private template; non-admins can't write built-in templates or prompts.
- **Signup:** a new Google account gets a profile plus the built-in templates.
- **Unit:** `fieldsToZod` accepts and rejects the right shapes; streak function handles grace days, timezones, and backdating.
- **Old entries:** entries written on an old template version still render after the template is edited.
- **E2E (Playwright):** log in → new entry → add Gratitude + "15 Things I Did Well" sections → write → it shows on the calendar → streak increments → check in a goal → carry over a todo.

## Open items

- Repo name and subdomain.
- Starter prompt list per template (from Marky's books).
- UI direction.
