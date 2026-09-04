# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Enoscrigno is a wine-cellar / tasting-diary webapp for sommeliers and enthusiasts (AIS/FISAR tasting methods, AI label scanning, multi-user with cellar sharing). It is a **single static HTML file** (`index.html`, ~4100 lines) backed by **Supabase** (Postgres + Auth + Storage + Edge Functions). There is no build step, no bundler, no package manager, and no test suite.

## Commands

There is nothing to install or build. To work on the frontend, just open `index.html` in a browser (it also works offline per the service worker), or serve the directory with any static file server.

**Deploying the frontend:** the site is published via GitHub Pages from the `main` branch (root), custom domain `www.enoscrigno.it` (see `CNAME`). Pushing to a feature branch does **not** go live — changes only reach production once merged into `main`.

**Deploying an Edge Function** (after editing anything in `supabase/functions/`):
```bash
supabase login
supabase link --project-ref xvtbsanxvkshqyeqordp
supabase functions deploy <function-name>
```
Each function can also be pasted directly into Dashboard → Edge Functions → Create/Edit, without the CLI.

**Applying schema changes:** `supabase_schema.sql` is a running migration log, not a clean idempotent schema dump — new changes are appended at the bottom as dated sections (mirroring the table's evolution), not merged into the original `create table` statements above them. It is **never executed automatically**; after editing it, run it manually via Supabase SQL Editor (paste and Run) or `supabase db push`. Existing statements use `if not exists` / `create or replace`, so re-running the whole file is safe.

**Secrets** (`supabase secrets set KEY=value`, never in frontend code):
`ANTHROPIC_API_KEY` (scan-label), `RESEND_API_KEY` (send-confirmation-email), `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` / `STRIPE_PRICE_ID` (checkout/webhook), plus `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` which Supabase injects into every Edge Function automatically. `SUPABASE_URL` and the anon key are hardcoded in `index.html` — that's intentional, the anon key is public by design and access control is entirely via RLS, not secrecy.

## Architecture

### Frontend: one file, three parts
`index.html` is, in order: a `<style>` block (all CSS, custom properties for the wine/gold brand palette, dark mode via `prefers-color-scheme`), the HTML body (a set of sibling `<div id="screen-X" class="screen">` elements — login, home, wine list/detail/add-edit form, network, guide, profile, export), and two `<script>` blocks — a tiny classic script that registers `sw.js`, and one big `<script type="module">` holding the entire app (Supabase client + all state + all logic). There is no framework, router, or component system: navigation is `showScreen(id)` toggling a `.active` class, and all data lives in module-level `let` globals (`currentUser`, `winesCache`, `currentCellarOwnerId`, `frontImg`/`backImg`, `activeDeg`, etc.).

### Data model (`supabase_schema.sql`)
- `profiles` — extends `auth.users` (sommelier name, association/tessera, `ai_scan_enabled`, Stripe fields, `email_confirmed`). Auto-created by the `handle_new_user()` trigger (`SECURITY DEFINER`) on `auth.users` insert — required because the client can't write to `profiles` before it has an authenticated session, e.g. immediately after signup.
- `wines` — one row per bottle/tasting: identity, provenance, technical, cellar (price/qty/purchase), and *three* independent tasting-schema payloads (`deg_schema`: `ais` | `fisar` | `free`, plus a `fisar_desc_params` variant) with scores precomputed client-side (`recalcAIS()`, `calcFISAR()`) and stored in `ais_score`/`fisar_score`/`score`.
- `scan_usage` — per-user and global monthly counters for the AI scan rate limit. RLS enabled with **no policies** (deny-all to clients); only the `scan-label` Edge Function writes it via the service-role key.
- `follows` — one-directional follow requests (`pending`/`accepted`) powering the Network feed.
- `cellar_shares` — the **current** cellar-sharing model (v2): a plain owner/member/status row, no separate cellar entity, wines stay attached to the original owner's `user_id`. `has_cellar_access()` is the RLS helper used everywhere access needs to extend beyond the owner. **`cellars` and `cellar_members` are an earlier (v1) multi-cellar design that `cellar_shares` superseded** — they're still in the schema for historical/migration reasons (some existing databases have them), but `handle_new_user()` no longer writes to them (a database missing these tables — never created there — used to make every signup fail with "Database error saving new user") and the frontend never reads from them; don't build new features on top of them.
- `email_confirmations` — token-based email verification, deliberately separate from Supabase's own confirm-email system.

### Edge Functions (`supabase/functions/`, Deno, one per subfolder)
- `scan-label` — AI label scanning via the Anthropic API. Gated on `profiles.ai_scan_enabled` (Premium). Checks `scan_usage` against `PER_USER_MONTHLY_LIMIT` (40) and `GLOBAL_MONTHLY_LIMIT` (800) **before** calling Anthropic, so an exceeded limit costs nothing.
- `create-checkout-session` / `stripe-webhook` — Stripe Checkout subscription flow for Premium (AI scan access). The webhook is the only writer of `ai_scan_enabled`/`subscription_status` once a subscription exists; it verifies the Stripe signature before trusting any event.
- `send-confirmation-email` / `confirm-email` — a custom, Resend-based email verification system that is **intentionally independent of Supabase's native "Confirm email" toggle** (which stays OFF in Supabase Auth settings so login is immediate after signup — see `index.html`'s `doRegister()`). This email is purely informational and never blocks access. `send-confirmation-email` accepts either an authenticated call (JWT — always uses the token's own email) or an unauthenticated call with `{ email }` in the body (used from the login screen before a session exists); the unauthenticated path always returns a generic "if registered..." response to avoid leaking which emails are registered, and is rate-limited to one send per 60s per user via `email_confirmations.sent_at`.

### Offline support
`sw.js` caches only the app shell (HTML/CSS/JS/icons) with a network-first/cache-fallback strategy, and explicitly never intercepts cross-origin (Supabase) requests. Separately, `index.html` queues wine saves made while offline in `localStorage` (`getPendingWines`/`savePendingWine`/`syncPendingWines`, keyed per user) and flushes the queue automatically on the browser's `online` event.

### Naming note
The project was previously called "Enosfera" — remnants of that name persist in a few places (e.g. the Supabase-layer comment header in `index.html`, the default `APP_URL` fallback in `create-checkout-session`). These are historical and not functionally significant.
