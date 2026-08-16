# Proposed diff to `CLAUDE.md` — the rate-limiting scope line

**Proposed, not applied.** Phase 57 shipped rate limiting, which `CLAUDE.md` currently lists as
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

**Rate limiting is out of scope behind a bearer token, and required in front of one.** A
signed-in parent hammering their own archive is a support conversation, not an attack. An
unauthenticated endpoint is a different thing: `POST /auth/email/start` sends mail to an
address a stranger chose, and the only place that can be limited is here — an edge limiter
cannot see the address, because it is inside the request body. In-app and Postgres-backed;
there is more than one Fly machine, so an in-memory counter is per-process theatre.
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
