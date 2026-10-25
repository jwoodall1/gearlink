# GearLink

Equipment management with a Next.js web dashboard, a SwiftUI iOS app, and a shared Supabase backend.

## Repository layout

- `src/`: web dashboard, authentication, and roster pages.
- `public/brand/`: web logo and branding assets.
- `iOS/`: Xcode project, Swift app, and bundled iOS assets. See [iOS setup](iOS/README.md).
- `supabase/migrations/`: versioned database schema and access policies.

## Web development

Install dependencies with `npm ci`. Copy `.env.example` to `.env.local` and fill in the Supabase project URL and publishable key, then run `npm run dev`.

## iOS development

Open `iOS/GearLink.xcodeproj` in Xcode. Follow `iOS/README.md` for local Supabase configuration and device signing. NFC scanning is enabled and requires a compatible physical iPhone and an NFC-capable provisioning profile from your approved Apple Developer Program team.

## What belongs in Git

Commit source, assets, migrations, shared project configuration, configuration examples, `package-lock.json`, and Xcode's `Package.resolved`. The iOS asset catalog keeps its own logo copy so the app can bundle it independently.

Local credentials (`.env.local`, `.local/`, and `iOS/Config/Local.xcconfig`), dependencies, build caches, logs, signing material, and Xcode user state are ignored. Keep shared Xcode schemes and workspace configuration tracked.


## Production improvement phases

See [the audit and phased plan](docs/production-plan.md) and [Phase 1 results](docs/phase-1-status.md). Each phase requires an owner check-in before the next begins.

Run `npm run typecheck`, `npm test`, and `npm run build` for the web checks. Regression tests use an in-memory query adapter and do not modify hosted records. The dashboard's current organization follows the signed-in user's earliest membership, consistently across web and iOS.
