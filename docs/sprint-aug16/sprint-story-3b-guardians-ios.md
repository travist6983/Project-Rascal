# Story 3b — Guardians on the phone

**Lane:** `ios/` only. **Runs:** after story 6 in this lane, and after story 3a merges.
**Read `sprint-runbook.md` before starting.**

A second parent taps a link, signs in, and arrives inside the household with the shared timeline and
their own Today. The inviting parent manages guardians from Settings.

---

## Hard-stop preflight gates

**Gate 1 — Phase number.** Per the runbook.

**Gate 2 — 3a's contract is real.** `GET /v1/families/me` must be present in `docs/api-contract.md`
and story 3a must have merged. **Do not build against a contract you inferred from story 3a's prompt
file** — build against what shipped. If they differ, report both and halt.

**Gate 3 — Idempotency.** If the invite-accept screen and the Settings guardians section both exist,
report `ALREADY LANDED` and exit 0.

**Gate 4 — Design authority.** If a `.dc.html` design file exists for any screen here, **the design
file wins on composition** and `docs/design-system.md` remains authoritative for tokens and motion.
If they conflict on something that is not composition, halt and report both sides rather than
picking. Do not silently edit `design-system.md` — propose the diff in the report.

**Gate 5 — Sign-in providers.** Only `apple` and `google` exist. If the auth PR landed Google, the
accept flow offers both. If it did not, it offers Apple alone and the report says plainly that an
invitee without an Apple ID cannot accept. **Do not add a third provider and do not reach for
`dev-login`** — that fixture has claimed the `password` namespace and a second sign-up path before
credential linking risks duplicate `users` rows.

**Gate 6 — 21 inherited warnings.** These exist across specific files and are not new issues. Do not
"fix" them as drive-by work; do not count them as findings.

---

## Implementation

### P1 — The link

Universal link on the marketing domain plus a custom scheme fallback. The invite URL from 3a opens:

1. **Preview** — unauthenticated `GET /v1/invites/{token}`. Shows who invited them, the household,
   the children's first names. If the app is not installed the link should land on a web page that
   says what this is; coordinate the path with story 2's base URL constant but **do not edit the
   marketing repo** — note the required page in the report for a follow-up.
2. **Sign in** — the existing `OnboardingGate` path, not a parallel one.
3. **Accept** — `POST /v1/invites/{token}/accept`, then a full refresh.

**Every failure mode gets its own screen state:** expired, revoked, already accepted, already in
another household, network down. A generic error here is a dead end for someone who has just been
handed a link by their spouse.

### P2 — Settings

A **Guardians** section on the existing Settings screen, following its established card language.

- Lists current guardians with name and joined date. The current user is marked.
- **Invite** — calls `POST /v1/families/me/invites`, presents the raw token URL through the system
  share sheet. The token is returned once; if the user dismisses the sheet the link is gone and they
  create another. Say that in the UI in one short line.
- **Revoke** an outstanding invite.
- Removing an existing guardian is **out of scope** — it is a destructive action over shared history
  and it needs its own thinking about what happens to their entries. Note it as an open question.

### P3 — The paywall, which is a door

On `402`, show the upgrade state. This is the product's first paywall surface and it inherits every
rule the rest of the app follows.

- Frame it as what the subscription **unlocks**, never as what the free tier lacks.
- No red. No countdown. No urgency. No guilt. No "you're missing out."
- Terracotta primary action, cream canvas, Nunito, the existing card shapes.
- There is no StoreKit purchase to route to yet — phase 37 owns that. The button explains and
  dismisses. **Do not stub a fake purchase flow**, and do not add a "coming soon" that will read as
  furniture for months.

### P4 — Today

If the server returns this user's assignments, Today should need no logic change. **Verify that
rather than assuming it**, and specifically check the six local reads phase 31 re-scoped for
multi-kid — a `@Query` predicate is fixed at init, and `WidgetSnapshotSync.swift:60` filters in
memory for exactly that reason. A board that silently merges two guardians' assignments looks
completely normal and is wrong.

The widget snapshot is written per-user; confirm a second guardian on the same device is not a case
that can arise, or handle it.

### P5 — SwiftData

The local cache is a cache; **the server is the source of truth**. On accepting an invite, the
newly-arrived children and their history sync down through the existing pull path. Do not write a
special-case importer.

`syncPullEnabled` is still off. Do not turn it on and do not build anything that requires it.

---

## Accessibility and verification

- **Dynamic Type XXL screenshots** for every new or changed screen: the preview, each failure state,
  the Settings section, and the upgrade state. Attach them to the PR.
- VoiceOver labels on every new control.
- Note in the report that none of this has run on a device, because it has not. The device
  verification backlog gains boxes from this work — **list them in the report and do not add them to
  any checklist file yourself.** Story 7 files them.

---

## Break-test at least two assertions

1. **Household isolation.** Point a test at a child the current user does not guardian. The fetch
   must be empty or refused. If it returns rows, the client is trusting the server's filter and has
   no assertion of its own — write one.
2. **Accept idempotency.** Call accept twice. The second must succeed without creating a second
   `guardians` row or a duplicate child locally.

---

## Deliberately out of scope

- Removing a guardian. See P2.
- Per-entry visibility and the `viewer` role — phase 30, iceboxed.
- Any StoreKit purchase.
- Google sign-in implementation, if it did not land in the auth PR.
- Anything in `api/`. Anything in the marketing repo.
- `roadmap-status.md`, `phase-queue.md`, and every device-verification checklist file.

## Report to

`docs/sprint-aug16/story-3b-report.md`, plus the PR description in the runbook's format.
