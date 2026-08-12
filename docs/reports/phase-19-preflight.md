# Phase 19 — Lane A cleanup: preflight evidence

Run 2026-08-11 on `ios/phase-19-lane-a-cleanup`, branched from `main` @ 87ec490.

## The stale-server finding

Preflight 2 **failed on its first run** — an explicit `"unlock_at_age": null` came back as `13`.
That is a STOP condition. It was an artefact:

```
$ ps -p 72691 -o lstart=   → Sun Aug  9 10:24:20 2026   (no --reload)
$ git log -1 --date=iso 7ef9b3d
  7ef9b3d 2026-08-10 21:36:41 -0400 feat(api): close the five gaps the iOS lane was working around
```

The API process predated the fix by ~35 hours. Restarted against current source; the same
request then returned `null`. **A preflight that exercises a long-running local server has to
establish that the server is the code under test.**

## Check 2 — explicit null vs absent key
```
### PROMPT: default_unlock_age = 13 (letter), assignment 49001e44-4a67-4640-8382-83170c942ca2

### REQUEST A — unlock_at_age explicitly null
{
  "id": "f1474007-e3fc-48fa-931c-dd5b5e5baff7",
  "child_id": "ca5dda95-6712-4a1b-a818-f1c1f2e9b40b",
  "assignment_id": "49001e44-4a67-4640-8382-83170c942ca2",
  "occurred_at": "2026-08-11T13:00:00Z",
  "body": "explicit null case",
  "unlock_at_age": null
}
### RESPONSE A
{
  "id": "f1474007-e3fc-48fa-931c-dd5b5e5baff7",
  "unlock_at_age": null,
  "assignment_id": "49001e44-4a67-4640-8382-83170c942ca2",
  "prompt_body": "Write down the story of the day he was born, in as much detail as you can still remember."
}

### REQUEST B — unlock_at_age key absent
{
  "id": "13944536-411d-47df-90ae-26e5b96945a8",
  "child_id": "ca5dda95-6712-4a1b-a818-f1c1f2e9b40b",
  "assignment_id": "49001e44-4a67-4640-8382-83170c942ca2",
  "occurred_at": "2026-08-11T13:01:00Z",
  "body": "key absent case"
}
### RESPONSE B
{
  "id": "13944536-411d-47df-90ae-26e5b96945a8",
  "unlock_at_age": 13,
  "assignment_id": "49001e44-4a67-4640-8382-83170c942ca2",
  "prompt_body": "Write down the story of the day he was born, in as much detail as you can still remember."
}
```
## Check 3 — prompt_body on list rows
```
### grep prompt_body in schema
119:    prompt_body: str | None = None

### GET /v1/entries?limit=5 — first row
{
  "id": "13944536-411d-47df-90ae-26e5b96945a8",
  "assignment_id": "49001e44-4a67-4640-8382-83170c942ca2",
  "unlock_at_age": 13,
  "prompt_body": "Write down the story of the day he was born, in as much detail as you can still remember."
}

### every row with an assignment_id: is prompt_body non-null?
{
  "rows_with_assignment": 11,
  "with_prompt_body": 11,
  "null_prompt_body": 0
}
```
## Check 4 — sealed filter purity, counts, and paging
```
### does the route declare 'sealed'?
109:    sealed: bool | None = Query(
112:            "`true` returns only sealed entries (`unlock_at_age` set), `false` only unsealed. "
113:            "Omit for both. Sealing is not an `entry_type` — a sealed letter is a `text` "
135:        sealed=sealed,

### counts at limit=100 (response is EntryPage: {entries, next_cursor})
  sealed='&sealed=true' -> 7
  sealed='&sealed=false' -> 100
  sealed='<none>' -> 100

### purity: sealed=true rows all have unlock_at_age != null?
{
  "n": 7,
  "unsealed_leaked": 0
}
### purity: sealed=false rows all have unlock_at_age == null?
{
  "n": 100,
  "sealed_leaked": 0
}

### DB truth for child ca5dda95-6712-4a1b-a818-f1c1f2e9b40b (deleted_at IS NULL)
7|747|754

### page sealed=true with limit=3, following next_cursor
  page 1: n=3 unsealed_leaked=0 next_cursor=eyJvIjogIjIwMjYtMDgtMTFU
  page 2: n=3 unsealed_leaked=0 next_cursor=eyJvIjogIjIwMjUtMTItMjVU
  page 3: n=1 unsealed_leaked=0 next_cursor=

### totals across pages
  rows: 7  duplicates: 0
```
## Check 5 — cold baseline on main
```
rm -rf ~/Library/Developer/Xcode/DerivedData/Rascal-*
xcodebuild test -project ios/Rascal/Rascal.xcodeproj -scheme Rascal \
  -destination "id=<iPhone 17>" CODE_SIGNING_ALLOWED=NO

Test run with 714 tests in 87 suites passed
warnings: 21  (14 PushPermissionTests, 4 ExtractionTests, 3 ExtractedDetails — all inherited)
```

The brief names `iPhone 15 Pro Max`, which is not installed here; `iPhone 17` was used.
Only `Rascal-*` was removed from DerivedData rather than the whole directory — same cold
guarantee for this project, without destroying every other project's build cache.

## Adversarial grep — after the deletions
```
# Adversarial grep — every deleted symbol, whole ios/ tree, including tests and comments

## $ grep -rn "unsealIfTheServerSealedItAnyway" ios/
  ios/Rascal/Rascal/Models/Entry.swift:270:    /// `unsealIfTheServerSealedItAnyway` — the corrective `PATCH` that used to follow every

## $ grep -rn "clientFilterPageBudget" ios/
  (no hits)

## $ grep -rn "isClientSideOnly" ios/
  ios/Rascal/Rascal/Models/Timeline.swift:152:    /// did not always, which is what the deleted `isClientSideOnly` existed to say out loud.
  ios/Rascal/Rascal/Models/Timeline.swift:170:    /// This replaced `isClientSideOnly`. Every chip is now a server filter, so one request per
  ios/Rascal/RascalTests/TimelineDataTests.swift:150:        // this asserts against. Was `isClientSideOnly` until the server grew the parameter.

## $ grep -rn "assignedPrompt" ios/
  ios/Rascal/Rascal/Timeline/EntryCardModel.swift:137:    /// `assignedPrompt` fallback the caller looked up from cached `Assignment` rows; see the note

## $ grep -rn "PageResult" ios/
  (no hits)

## $ grep -rn "promptByAssignment" ios/
  (no hits)

## $ grep -rn "unsealOnServerIfNeeded" ios/
  (no hits)

## $ grep -rn "drainsUntilSomethingMatches" ios/
  ios/Rascal/RascalTests/TimelinePagingTests.swift:490:    /// `drainsUntilSomethingMatches` and `stopsAtTheEndOfTheArchive` each built an archive whose

## $ grep -rn "stopsAtTheEndOfTheArchive" ios/
  ios/Rascal/RascalTests/TimelinePagingTests.swift:490:    /// `drainsUntilSomethingMatches` and `stopsAtTheEndOfTheArchive` each built an archive whose

## $ grep -rn "respectsThePageBudget" ios/
  (no hits)

```
