# U179-U184 — UX improvement series (Phase 7 Track B)

The technical work is done — 152 active slugs, all backends live. What's
missing is **the human layer**: how a staff member, a manager, and Jo
each look at a page and find what they need without help.

This series is structured as **6 short sprints**, each gated on a small
Jo session. No sprint is bigger than 1 day of my exec time + 30 min of Jo.

---

## Principles driving the series

1. **The phone is the daily-driver device.** Desktop is for setup; ops happens on a phone in a busy pub kitchen.
2. **Action beats information.** "You need to do X" outranks "here's a number".
3. **First glance must orient.** Within 3 seconds of opening a page, the user knows what changed and what matters.
4. **Role-appropriate.** Staff sees less than Karl sees less than Jo — automatically, without surprise.
5. **Empty states are first impressions.** A page that says "no data yet" looks broken; a page that says "no orders for tomorrow yet — guests usually order by 9pm" feels intentional.
6. **Trust through traceability.** Every number should be click-throughable to its source.

---

## U179 — UX audit + pain-point capture (¾ day)

**Jo's part (30 min)**: walk through these pages on **your phone** (Authelia → `https://jolybox.tailc27dff.ts.net/`):

- `/app` (default landing)
- `/app/staff`
- `/app/restaurant`
- `/app/bar`
- `/app/cafe`
- `/app/rooms`
- `/app/sales`
- `/app/tasks`
- `/app/tasks/cashup`
- `/app/comms`
- `/app/admin`

For each, tell me: **the first thing you look at, the first thing that confuses you, anything that's there but you'd remove.** Voice notes / numbered bullets / screenshots — whatever's easiest.

**My part (½ day)**: capture findings to `audits/u179-ux-pain-points.md`. Categorise: information-architecture / styling / content / role-gating. Prioritise into the next 5 sprints.

**Acceptance**: Jo has reviewed every page once. List of top 15 issues exists, sorted by impact × effort.

---

## U180 — Landing page hierarchy (~½ day, autonomous after U179)

**Why**: the `/app` landing should answer "what should I look at first?" in 3 seconds. Right now it shows a generic dashboard.

**Build** (without your eyes — based on U179 findings):
- A `frontend_today_priority` slug returning the single most important "right now" signal — bias order: open critical exception > staff member on no-show > till variance >£20 yesterday > revenue tracking behind target > everything else.
- Hero card on `/app` consuming that slug.
- Below: 3-card "context" row with today's revenue / today's expense / contribution.
- Below: collapsed action queue (top 5 only; "see all" links to /tasks).

**Acceptance**: opening `/app` cold, you can answer "what's the most important thing right now?" in 3 seconds.

---

## U181 — Mobile-first audit + fixes (1 day)

**Build**:
- Walk every page on iPhone Safari + Android Chrome.
- For each: tap targets ≥44px, no horizontal scroll, text ≥16px, modals dismissable without keyboard.
- Fix top 10 mobile-broken interactions found.
- Replace any inline-too-wide tables with vertical card layout on mobile.

**Jo's part (15 min)**: confirm post-fix that each daily-driver page is usable on phone.

**Acceptance**: every Track B happy path completable on iPhone in portrait. No swipe-to-scroll required for primary action.

---

## U182 — Role-aware UI gating (~½ day, autonomous)

**Build**:
- Read `Remote-Groups` header in Next.js middleware; expose role to React via cookie/context.
- Hide finance-y tiles from non-owner roles (Karl sees rota/recon/restaurant; Staff sees what they need to do their shift).
- Hide /admin nav link from non-owner; show /work/* nav from manager up.
- Empty states per-role: when Staff opens `/admin`, get a clear "not for you" page, not 403.
- Test matrix: jo (owner), karl (manager), staff (general) × every page.

**Acceptance**: Karl + Staff can each list 5 things they expect to see + 5 they shouldn't, matrix passes.

---

## U183 — Empty + error states (~½ day)

**Why**: today, every page with no data shows the same generic "PlaceholderState" component. This makes "nothing has been ingested" look identical to "everything's fine, no events today".

**Build**:
- Replace generic placeholders with **page-specific contextual** messages:
  - `/work/restaurant` empty: "No reservations for tonight. Last check Collins polled 5 min ago." vs "Collins sync hasn't run today — check `data_source_freshness`."
  - `/tasks/cashup` empty: "Yesterday reconciled clean. Next: tonight close-out."
- For every slug that powers a page, define an `empty_state_template` + `error_state_template`.
- Show a "last refresh" timestamp + "stale" indicator when data is older than expected cadence.

**Acceptance**: every page tells the user **what it would mean if it's empty** — not just "no data".

---

## U184 — Onboarding flow + role help text (~¾ day)

**Build**:
- First-time-login walkthrough for each role: a 3-step modal that introduces the 3 most important pages.
- "?" tooltip on every tile explaining what the number means + how it's calculated + when it last refreshed.
- `docs/staff-onboarding.md`, `docs/manager-onboarding.md`, `docs/owner-tour.md` — markdown linked from inside the UI.

**Acceptance**: a staff member who has never seen the system can self-onboard within 10 minutes by reading the walkthrough.

---

## Dependencies + timing

```
U179 (audit, gated on Jo 30min) ──┬─ U180 (landing) ──┐
                                  ├─ U181 (mobile)    ├─ U184 (onboarding)
                                  ├─ U182 (role)      │
                                  └─ U183 (empty)     │
                                                      └─ Track B closes
```

- **U179**: today/this week (Jo's 30 min unlocks everything)
- **U180-U183**: parallel-isable after U179; ~3-4 working days of my exec
- **U184**: after U180-U183 to ensure walkthrough reflects new UX

**Track B close**: ~2 weeks from U179 kickoff. Phase 7 closes at end of Track B.

---

## What this series deliberately does NOT do

- **No new functionality**. Slugs exist; pages exist; this series polishes.
- **No backend changes** apart from `empty_state_template` metadata.
- **No design-system rewrite**. We work with the Section/KPICard/PlaceholderState components already in use.

---

## Ready to start

When you have 30 minutes for the walkthrough, kick off with:

```
"Open /app on my phone, here's what I see…"
```

Anything in that format works. I'll capture, prioritise, and start U180-U184 from there.
