# GearLink production implementation

## Phase gates

Complete and review each phase with the owner before beginning the next. NFC is outside this initiative. No production deployments or database changes are included in Phase 1.

## Audit — 2026-10-23

### Architecture and existing capabilities

- Web: Next.js App Router 16, React 19, TypeScript, server components/actions, CSS variables, Supabase SSR authentication. Pages: overview, equipment, athletes, activity, login.
- iOS: SwiftUI, native navigation/forms, Supabase Swift, observable roster/session stores. Supports login, paginated roster loading, admin roster creation/editing, appearance preferences, sign-out. NFC remains disabled.
- Shared backend: Supabase Auth/Postgres/RLS. Live column metadata matches the checked-in foundation for organizations, memberships, athletes, equipment, assignments, events. Admin/coach are the only supported roles. Team is a free-text athlete field.
- Inventory supports available, checked_out, maintenance, retired; condition supports new, good, fair, needs_repair, retired. Missing status, due dates, jersey numbers, positions, costs, and seasons do not exist.
- Single-item checkout and return functions exist with row locking, open-assignment uniqueness, actor/timestamp fields and events. No operational UI currently invokes them. Bulk transactions are absent.
- Equipment list and activity are read-only. Web roster can create; iOS roster can create/edit/archive through active status. Imports, exports, reports, maintenance records, offline cache/queue, and automated tests are absent.

### Highest-impact findings

1. Overview available/athlete totals count an eight-row preview, so larger programs see wrong totals. No-organization result omits count fields.
2. Web membership queries can select a colleague's membership because RLS permits reading organization colleagues. Other lists combine all visible organizations while the header names just one. Match the signed-in user explicitly and consistently scope every view/write.
3. All web users are labeled Administrator; coaches see a roster creation form they cannot use. UI should show the real role while preserving backend enforcement.
4. Overview offers Add Equipment although the destination has no creation workflow. Empty copy implies capabilities that are not implemented.
5. Mobile web hides sign-out and account details. Web colors are light-only; state/error and status styles are duplicated. Sign-out ignores failures.
6. iOS roster requires a dashboard detour. Design tokens/components are private to one large file. Success notices can persist across reloads; initial failure and empty states need differentiation. Fixed horizontal cards compress at accessibility text sizes.
7. Web roster assumes related equipment is always an array, which can lose assignment labels. Shared relationship formatters should handle object and array responses.
8. Web lists lack pagination and can silently stop at the API row cap. Add explicit bounded pages during presentation fixes; broader search/filter workflows remain Phase 2.
9. Current RLS allows members to directly update equipment and assignment rows. Tenant isolation exists, but transactional lifecycle consistency can be bypassed. Resolve before releasing assignment workflows in Phase 2; revisit role granularity in Phase 3.

## Prioritized implementation

### Phase 1 — audit and design consistency (implemented; awaiting review)

- Shared, request-scoped web workspace resolver with verified user membership; organization-scoped list pages and roster creation; real role labels.
- Accurate exact dashboard counts, useful inventory/roster/activity links, attention summary using existing maintenance/repair data, honest setup/empty copy.
- Reusable web headings, panels, status badges, metric cards, empty/error/loading states and pending submit controls; responsive navigation/account access; system dark mode and reduced motion.
- Shared iOS visual tokens/components, direct roster tab, adaptive dashboard layout, clear loading/empty/retry/stale states and save feedback.
- Validate TypeScript/build, query responses, navigation/appearance where tooling permits, and iOS simulator compilation. Record constraints honestly.

### Phase 2 — core operational efficiency (requires owner approval)

- Athlete detail and equipment detail/history screens on mobile; web administrative inventory edits.
- Transactional bulk issue/return APIs, availability checks, concurrency/duplicate protection, condition handling and actor audit. Tighten direct mutation paths before shipping these workflows.
- Search, practical filters, and scalable inventory navigation. Use shared backend operations across platforms.

### Phase 3 — program setup and administration (requires owner approval)

- Onboarding, validated previewed CSV imports/templates, configurable categories, role model refinement, reports/CSV exports.
- Add schema fields only as required by concrete workflows and with migration/backward compatibility review.

### Phase 4 — reliability and optimization (requires owner approval)

- Measure fetching/rendering, caching and offline read support; queue only operations with idempotency/conflict contracts.
- Strengthen history and test concurrency, failure, scale, synchronization, and authorization.

### Phase 5 — advanced features (requires owner approval)

- Prioritize season rollover, collection campaigns, maintenance, replacement planning and multi-sport tools only after core workflows are stable.

## Phase 1 validation/results

See [Phase 1 results](phase-1-status.md) for implemented files, passing builds and tests, and remaining device QA. Phase 2 has not started.
