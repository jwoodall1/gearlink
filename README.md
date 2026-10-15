# GearLink dashboard

Next.js App Router dashboard for organization administrators. Supabase Auth handles identity, Postgres with RLS is the authorization boundary, and Vercel hosts the web app. The iOS client can use the same organization, athlete, equipment, tag, assignment, and event records.

## Architecture

- `src/app/` contains routes and server-rendered dashboard pages.
- `src/components/` contains shared navigation and dashboard UI.
- `src/lib/supabase/` creates request-scoped server clients and refreshes auth cookies.
- `supabase/migrations/` contains additive database changes. Keep it aligned with Supabase migration history.
- The public Supabase URL and publishable key are safe for browser use; never add a service-role or secret key to the dashboard.
- RLS scopes each business record through `organization_members`. Assignment actions use database functions so state changes and audit events commit together.

## Local development

The repository root is `/Users/jonathanwoodall/Desktop/Dev/gearlink`. Run commands there; there is no nested `gearlink` app directory.

1. Use Node.js 24 to match Vercel (`nvm use` if you have nvm).
2. Install dependencies with `npm ci`.
3. Use the existing `.env.local` in this restored workspace. For a fresh clone, copy `.env.example` to `.env.local` and replace both placeholders with the GearLink project's URL and publishable key, or pull them from Vercel as described below.
4. Run `npm run dev` and open `http://localhost:3000`.

Run `npm run typecheck` to check TypeScript and `npm run build` to produce a production build. Run `npm start` after building to serve that build locally.

Configure the Supabase Auth site URL and redirect allowlist for local and deployed dashboard URLs before inviting users. The dashboard starts in a clear empty state until an organization exists and the signed-in user belongs to it.

## Routes

- `/login` — email and password sign-in.
- `/dashboard` — inventory and checkout overview.
- `/dashboard/equipment` — organization equipment list.
- `/dashboard/athletes` — organization roster.
- `/dashboard/activity` — equipment event history.

Every data query is performed with the signed-in user's Supabase session. RLS remains authoritative even when routes or UI filters change.

## Existing projects

- GitHub: `jwoodall1/gearlink`.
- Vercel: `gearlink`, under the `coachpoints` team. `.vercel/project.json` holds the local link and is ignored by Git. `vercel.json` selects Next.js and uses `npm ci` for reproducible installs.
- Supabase: `gearlink`, project ref `uehgejyjyxdopujrwzpl`. The web app connects through the two public variables in `.env.local`. Those variables are also configured in Vercel for development, preview, and production.

To restore the Vercel link and environment on another machine, authenticate with the Vercel CLI, then run:

```sh
npx vercel link --yes --project gearlink --scope coachpoints
npx vercel env pull .env.local --environment development --scope coachpoints
```

The four SQL migrations in `supabase/migrations/` are already applied to the existing Supabase project. Their version numbers match remote migration history. Do not rerun them manually on that database or reset the remote database. For future CLI migrations, authenticate with Supabase and link using `npx supabase link --project-ref uehgejyjyxdopujrwzpl`, then inspect migration history before applying new migrations.

## Current feature scope

This is the dashboard foundation: email/password login, organization creation, and inventory, roster, and activity views. The Add equipment and Add athlete controls are placeholders; web creation/editing and checkout/return forms are not implemented yet. NFC scanning belongs to the iOS app and has not been verified on a physical device here.

Environment files, dependencies, generated build files, local Vercel linkage, and Supabase CLI caches are ignored. Commit `.env.example`, `package-lock.json`, application source, and migrations. Never commit service-role keys or real athlete data.
