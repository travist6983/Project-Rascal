# Proposed diff to `CLAUDE.md` — the rate-limiting scope line

✅ **APPLIED Aug 17, 2026, in phase 68 — this file is kept as the reasoning, not as a pending
change.** What landed differs from the proposal below in two ways, both because the tree moved
under it: **the guardian invite flow came off the out-of-scope list too** (phase 36 built it, so
the proposal's own quoted block was already stale), and the line now records that
`POST /v1/subscribe` deliberately carries **no** rate limit because Turnstile is its whole
protection — the owner's call of Aug 16, which the proposal predates.

~~Proposed, not applied.~~ Phase 57 shipped rate limiting, which `CLAUDE.md` currently lists as
out of scope for the API lane. The plan for that phase said to propose the change rather than
edit the standing rules silently, so here it is. **Nothing in the code depends on this edit
landing** — the behaviour ships either way; what is at stake is whether the standing rules
describe the codebase.

## The line as it stands

`CLAUDE.md:77-79`, the "Out of scope for the API lane" section:

```
Swift or iOS code (that is the other lane, not this one), push notifications, full-text
search, thumbnail or transcode pipelines,
LLM prompt generation, the guardian invite flow, the admin prompt review queue, a web
frontend, multi-kid UI concerns, rate limiting, observability beyond structured logging.
```

## The proposed replacement

```
Swift or iOS code (that is the other lane, not this one), push notifications, full-text
search, thumbnail or transcode pipelines,
LLM prompt generation, the guardian invite flow, the admin prompt review queue, a web
frontend, multi-kid UI concerns, observability beyond structured logging.

**Rate limiting is out of scope for routes that only touch the caller's own data, and
required for any route that can reach somebody else.** A signed-in parent hammering their
own archive is a support conversation, not an attack.

Two routes qualify, and the second is the reason this is not simply "unauthenticated
endpoints". `POST /auth/email/start` is unauthenticated and mails an address a stranger
chose. `POST /me/credentials/email` is *authenticated* and mails an address the account does
not own and has not proved anything about — so without a limit, anyone who can create a free
account can use it, and our sending reputation, to mail a stranger repeatedly.

The limit lives in the app rather than at the edge because an edge limiter cannot see the
address: it is inside the request body. It is Postgres-backed because there is more than one
Fly machine, so an in-memory counter is per-process theatre. And the client address comes
from `Fly-Client-IP` rather than the socket peer, which behind the proxy is the same value
for every request on the internet.
```

## Why the distinction rather than deleting the line

Three things make the narrow version worth more than either "rate limiting is out of scope" or
"rate limiting is in scope":

1. **The original rule was right about what it was aimed at.** Nothing behind `current_user`
   needs a limiter, and adding one would be a middleware, a config surface and a class of
   support ticket in exchange for nothing.
2. **`decisions.md` open item 12 already anticipated this**, in these words: *"a public
   unauthenticated write endpoint is a spam surface, and `CLAUDE.md` currently lists rate
   limiting as out of scope for the API lane — so this item forces that call rather than
   inheriting it."* That item is the marketing list, which is still undecided. Phase 57 got
   there first with a narrower case, and settling the scope line here means the marketing list
   inherits an answer rather than reopening the question.
3. **The exception names its own mechanism**, so the next unauthenticated endpoint does not
   have to rediscover why the limiter is in Postgres. That reasoning is the expensive part, and
   it is the part that would be lost if the line simply said "except where required".

## What it is not

It does not put a limiter on anything authenticated, and it does not commit to one at the edge.
Cloudflare in front of this API is still a reasonable thing to want; it is just not a
replacement for the per-address limit, which is the one protecting a person rather than the
service.
