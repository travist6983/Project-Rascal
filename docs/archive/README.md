# RASCAL — the documentation archive

**Created Aug 25, 2026 by phase 123.** Everything in this directory was moved out of a live
document **whole and unedited**. Nothing here was summarised, trimmed or rewritten, and nothing was
deleted to get here — each file is a contiguous span of a document that is still in the tree, with
a header saying which document, which span, and why it moved.

## Why

The four documents this project keeps its memory in had reached **1.17 MB between them**:

| file | was | now |
| --- | --- | --- |
| `docs/decisions-log.md` | 411 KB | 180 KB |
| `docs/roadmap-status.md` | 323 KB | 252 KB |
| `docs/decisions.md` | 234 KB | 168 KB |
| `docs/blocked.md` | 203 KB | 108 KB |
| **total** | **1,171 KB** | **709 KB** |

**That is not a tidiness problem, it is a cost.** Every agent session that opens these files carries
them for the rest of its life, and the number was measured rather than asserted: the phase 122 docs
sweep spent **170 M cache-read tokens** across 23 agents, and the single largest input to that
figure was the size of the documents being audited. A file that costs six figures of tokens to
consult is a file that will not be consulted.

**The cut is always a date or a status, never a relevance judgment.** Nobody read three thousand
lines and decided which mattered — that would be a rewrite wearing the word *archive*, and it would
throw away exactly the entries whose value is that they are inconvenient. Each file below states
its boundary.

## What is here

| file | from | boundary |
| --- | --- | --- |
| [`decisions-log-aug-3-16.md`](decisions-log-aug-3-16.md) | `docs/decisions-log.md` | Everything before **Aug 17, 2026** (the Vellum rename). The live file carries Aug 17 onward |
| [`roadmap-ledger-pre-100.md`](roadmap-ledger-pre-100.md) | `docs/roadmap-status.md` | The **detail cell** of every ledger row for phases **below 100**. Numbers, titles and status markers all stay in the live ledger |
| [`decisions-changelog-aug-3-11.md`](decisions-changelog-aug-3-11.md) | `docs/decisions.md` | Changelog entries before **Aug 19, 2026 (phase 95)**. The Settled and Open sections did not move |
| [`blocked-resolved.md`](blocked-resolved.md) | `docs/blocked.md` | **Seventeen fully-resolved sections.** A section moved only when every item under it was closed — §10a and §18 each still have an open half and stayed |

## How to find something

**`grep -rn '<thing>' docs/`** — unchanged. These files are in the tree and in the repository; the
grep that found an entry last week finds it this week, one directory deeper. The only thing that
changed is which files an agent loads without being asked.

Each ledger row in `docs/roadmap-status.md` for a phase below 100 links directly to its archived
detail: `[full entry](archive/roadmap-ledger-pre-100.md#phase-N)`.

## The rule this establishes, and its one exception

`CLAUDE.md` says wrong text is **struck, not deleted** — kept visible so a reader can see what the
document used to claim. **Archiving is not an exception to that and must not become one.** Struck
text moves here still struck; nothing was un-struck, and no claim was quietly corrected on its way
out of a live file. What archiving changes is *where* a superseded record lives, never *whether* it
exists.

**The exception is the one the rule already names.** Account deletion hard-deletes, per `CLAUDE.md`
rule 5 and `data-model.md`'s `deletion_requests` section. Nothing in this directory may ever hold a
family's data, and nothing in it does: these four files are project records — decisions, blockers,
phase status — and contain no archive content, no media keys and no personal data.

## When to add to this directory

**When a live document's growth starts costing more than its history is worth**, and only then.
Adding a file here is a phase, it takes a number, and its boundary goes in the table above. Do not
archive a document nobody has complained about, and do not archive a *section* — archive a span
with a stated rule, so the next person can tell what is missing without diffing.
