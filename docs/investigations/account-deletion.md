# In-app account deletion — investigation

Run 2026-08-17 on `docs/phase-65-account-deletion`, cut from `main` @ `86f82fc`. **Read-only: no
code changed and no production row written.** Everything below is a query against the running
app's own schema, a route enumeration from the live OpenAPI document, or a grep.

This answers `docs/decisions.md` open item **14**, which was filed the day before as *unanswered
rather than as a known gap* — the sprint story that would have covered it halted because the tool
it named does not exist, so nobody had checked.

---

## The answer

**It is a real gap and it blocks App Store review.** Apple has required in-app account deletion
for apps offering account creation since June 2022 (guideline 5.1.1(v)). This app creates
accounts three ways — Sign in with Apple, Google, and the magic link — and has **never been
submitted**.

**The gap is larger than "one endpoint is missing".** There is no deletion machinery anywhere, on
either side of the wire, and one piece of it does not exist even for the deletion D3 already
promises.

---

## What was checked, and what it returned

### 1. Every `DELETE` route the API serves

From the live OpenAPI document, not from a grep:

```
DELETE /v1/children/{child_id}/prompt-suppressions/{prompt_id}
DELETE /v1/devices/{token}
DELETE /v1/entries/{entry_id}
DELETE /v1/families/me/invites/{invite_id}
DELETE /v1/me/credentials/{credential_id}
```

**Five routes, none of which deletes an account.** The closest, `DELETE /me/credentials/{id}`, is
a soft revocation that the server *refuses* when it would be the last one — it exists precisely to
stop a parent locking themselves out, which is the opposite of this.

### 2. Any account-deletion surface at all

```
grep -rniE "delete.?account|account.?deletion|close.?account|erase.?account" \
  api/src ios/Rascal/Rascal docs/api-contract.md
→ (no matches)
```

Not in the API, not in the client, not in the contract.

### 3. **There is no object-storage delete path.** This is the finding that costs the most.

```
grep -rn "delete_object\|delete_objects" api/src
→ (no matches)
```

`boto3` is used for presigned PUTs and GETs. **Nothing in this service has ever removed a byte
from Tigris.** That matters beyond this item: **D3 already promises that lapsed media is deleted
after its clocks elapse, and there is no code that could carry that out.** Phase 38 inherits that
whether or not user-initiated deletion is built.

The production bucket has soft delete enabled with 30-day retention (`roadmap-status.md`), so a
delete is recoverable for a month — which is a safety net worth knowing about and **not** a reason
to treat the operation as reversible.

### 4. What a deletion would have to reach

Twenty tables. A user reaches a child only through `guardians`; children own the archive:

| Reaches `users` | Reaches `children` | Reaches `entries` | Root / ledger |
|---|---|---|---|
| `credentials`, `devices`, `refresh_tokens`, `idempotency_keys`, `guardian_invites`, `entitlements` | `guardians`, `assignments`, `tags`, `prompt_suppressions`, `notification_sends` | `media`, `entry_tags` | `families`, `prompts`, `rate_limit_events`, `email_sign_in_tokens` |

`entries` reaches both. `media` reaches a child only through its entry, which is the same
indirection `deps.py` already resolves for authorization.

### 5. The client

`LocalArchiveErasing` exists and is wired to **sign-out only** (`App/AppEnvironment.swift:374`).
It erases the local SwiftData store; it has no notion of asking the server to forget anything.

---

## Why D3 does not already cover this

**D3 is a different trigger with a different scope**, and reading it as coverage is the mistake
this section exists to prevent.

- **Trigger.** D3 fires on *lapse and inactivity* — `max(lapsed_at + 24 months, last_sign_in_at +
  12 months)`. A user asking to leave is neither.
- **Scope.** D3 is explicitly **media only, and text never**: *"we have never deleted a word a
  parent wrote"* must remain true. A user-initiated erasure that honoured that promise would leave
  the parent's words behind, which is not what "delete my account" means to the person asking, and
  not what GDPR erasure or Apple's guideline contemplate.

**These are not in conflict, and the distinction is the useful part:** D3 is a promise about what
*we* delete on our own initiative. It says nothing about what we do when the person whose data it
is asks us to stop holding it. **One sentence in D3 saying so would prevent the next reader
concluding this was already decided.**

---

## Answered Aug 17, 2026

All three were settled by the owner the same day this was written, so the section below is kept
as the reasoning rather than as an open list.

| | Settled |
|---|---|
| **Two-guardian household** | **Account always; archive only when no other guardian remains.** As recommended. Answers open item 13 in the same breath, deliberately — two answers to one question eventually disagree |
| **Grace period** | **7 days, signed out immediately, cancel on sign-in.** As recommended, and the cancel is D3's precedent rather than a new rule |
| **The marketing sentence** | **Reworded, not kept — and this is the one the owner did not take the recommendation on.** The argument for keeping it was that it stays literally true. The owner's reading: literal truth is not the bar for a line whose whole job is to reassure, and somebody who has just deleted their account should not have to reconcile it. The exact wording belongs with whoever writes the copy |

**The build is now a phase against a finished spec.** What it costs is unchanged and is below.

## The reasoning behind those three

Everything above is a fact. These were product decisions, and they were the reason this was a
spec rather than a pull request — the operation is irreversible over a child's archive, which is
the one failure this project treats as unrecoverable.

**1. What does "delete my account" delete in a two-guardian household?**

My recommendation, and the one I would build absent a different answer: **the account always, the
archive only when no other guardian remains.** A shared archive is not one parent's to destroy,
and the other parent did not ask for anything. So deleting your account revokes your `guardians`
rows and removes your credentials, devices and tokens; the children, entries and media survive as
long as somebody else guards them. When the last guardian leaves, the archive goes with them.

This is open item **13** (removing a guardian) arriving from the other direction, and answering
one should answer both.

**2. How long is the grace period, and does signing in cancel it?**

Apple permits a delay. D3 already establishes the shape — *any sign-in during the warning window
cancels deletion outright and resets the clocks* — and the same reasoning applies more strongly
here, because a person who signs back in has changed their mind about leaving. **I would take
7 days, immediate sign-out on request, and cancel-on-sign-in.** The number is yours; the
cancel-on-sign-in is D3's precedent and I would keep it.

**3. Does the marketing promise need rewording?**

*"We have never deleted a word a parent wrote"* stays literally true under this design — we would
be deleting words a parent **asked** us to delete. Whether the sentence still reads honestly to
somebody who has just used the feature is a copy question, and it is worth asking before the
sentence is printed somewhere.

---

## What building it actually costs

Larger than it looks, and the object-storage half is why:

1. **An S3 delete path that does not exist** — `services/s3.py` gained presign and nothing else.
   Deleting a child's media means enumerating keys and deleting them, with the 30-day soft-delete
   window as the net. **Phase 38 needs this too**, independently.
2. **A deletion request record**, so a grace period is a state rather than a job nobody can see.
3. **The route**, plus the cascade decisions above.
4. **A client surface** in Settings, which by Apple's rule must be reachable in-app rather than by
   emailing support.
5. **Tests that prove what survives**, not only what goes. A deletion test that asserts rows are
   gone and never asserts the *other* parent's archive is intact is the shape of test that passes
   while the feature destroys something.

---

## Recommendation

**Treat this as P1 and build it before submission, not after a rejection.** The cheapest possible
outcome — that it was already satisfied and nobody wrote it down — is now ruled out.

Answer the three questions above and the build is a phase against a finished spec rather than a
fresh design, which is the shape `data-model.md` already uses for the marketing list.
