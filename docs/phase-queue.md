# RASCAL — the phase queue

The short list. `docs/roadmap-status.md` is the long one: it explains *why* and carries the
evidence. **This file says what to do next, one line each. Delete a line when it is done.**

If a line needs more than a sentence, the sentence goes in `roadmap-status.md` and the line
stays short. If a line stops being true, delete it — a queue that carries finished work is the
exact failure `roadmap-status.md` has now made six revisions running.

~~*Synced with `roadmap-status.md` at **Aug 18, 2026 (the docs audit)**. The highest number used is
78, so a genuinely new phase takes 79*~~ — ~~**struck Aug 19, 2026. The highest number used is 97 —
96 is the admin console and 97 the social studio; a genuinely new phase takes 98.**~~ — **struck
again Aug 20, 2026. The highest number used is 101**; 98 is the console's second database, 99 the
console sign-in, 100 the extended cost panel and 101 the fixes found by driving it. ~~**A genuinely
new phase takes 102.**~~ — **struck a fourth time the same day, Aug 20, 2026, and this one lasted
hours rather than a day.** 102 was taken within the hour by `api/phase-102-console-tweaks` and PR
#152, and 103 by the prompt-candidate queue on the same branch. ~~**The highest number used is 103.
A genuinely new phase takes 104.**~~ — **struck a fifth time on Aug 21, 2026, and this strike is
different from the four before it: the collision it warned about actually happened.**

~~*The highest number used is 106. A genuinely new phase takes 107.*~~ — **struck a sixth time on
Aug 21, 2026.** 104 is Instagram publishing, 105 is the phase 104 review (open as PR #155), and 106
is the video renderer's provider switch — **built and green in the working tree on `main`, on no
branch, uncommitted**, which is a state this header had never had to describe before and the reason
its row went into `roadmap-status.md` before the commit rather than after it.

~~*The highest number used is 109. A genuinely new phase takes 110.*~~ — **struck a seventh time on
Aug 21, 2026, within the hour, by 110 itself taking the number this sentence offered.** 107 is the
entitlement and cadence work (API lane), 108 is the locked board and membership sheet (iOS lane),
and 109 is the marketing site's free-tier copy. **107, 108, 109 and 110 all wrote their rows into
`roadmap-status.md` at allocation rather than at ship** — the remedy this header has asked for
across nine instances, had never once received before tonight, and has now received four times
running.

~~*The highest number used is 110. A genuinely new phase takes 111.*~~ — **struck an eighth time
on Aug 22, 2026, by 111 taking the number this sentence offered.** 110 is the design-conformance
pass over 108: the approved Claude Design bundle, committed to the repository, and 108's tree
audited against it.

~~**The highest number used is 111. A genuinely new phase takes 112.**~~ — **struck a ninth time on
Aug 22, 2026, and this strike is the first one taken by two phases at once.** 112 and 113 were
allocated together, by two sessions running concurrently against one owner's instruction: **112 is
the iOS Settings membership surface** (`ios/phase-112-settings-membership`) and **113 is the API
lane's membership wire** (`api/phase-113-membership-wire`), which exists because 112's second
tranche cannot be built without it. **The highest number used is 113. A genuinely new phase takes
114.**

**This is the first allocation in this file's history where the two lanes agreed the split by
message before either wrote a line**, rather than discovering the collision afterwards — which is
what 103 did, twice, and what the eight strikes above are mostly about. The API session wrote this
header and the 113 row; the iOS session wrote the 112 row and touched neither this sentence nor
that one. **Worth recording because the remedy is cheap and the failure it prevents is the one this
header keeps having to describe.**

~~**The highest number used is 113. A genuinely new phase takes 114.**~~ — **struck a tenth time on
Aug 23, 2026, by 114.** **114 is the bundle name in the Google sign-in alert** (iOS lane): the
consent alert `ASWebAuthenticationSession` shows before the browser opens read *"Rascal" Wants to
Use "accounts.google.com" to Sign In*, six days after phase 73 renamed the app to Vellum in all four
plists. The rename moved `CFBundleDisplayName`; that alert reads **`CFBundleName`**, which was still
`$(PRODUCT_NAME)` and therefore the Xcode target name. ~~**The highest number used is 114. A genuinely
new phase takes 115.**~~ — **struck an eleventh time on Aug 23, 2026, by 115 taking the number this
sentence offered.** **115 is CRUD for the child's photo** (iOS lane, `ios/phase-115-avatar-edit`):
onboarding could set an avatar and Settings could show one, and between the two there was no way to
replace or remove it — `EditChildSheet` contained the word "avatar" zero times and `updateChild`
omits `avatar_key` by design. The API lane needed nothing; all four operations have been served
since phase 21. ~~**The highest number used is 115. A genuinely new phase takes 116.**~~ — **struck a
twelfth time on Aug 23, 2026, by 116 taking the number this sentence offered.** **116 is the merge
markers in `roadmap-status.md`**: six rows still read `allocated` or `open` after their pull requests
had merged — 107, 111, 112, 113, 114 and 115 — and this is the ninth consecutive revision to find
that ledger trailing `main` in the same direction. **The interesting part is that the remedy this
header spent nine strikes asking for is working**: rows are written at allocation now, every time.
It just fixed the wrong half. **Nothing has ever owned the merge** — this file deletes a line when
it is done and that file never deletes a row, so a merge leaves no trace in either. ~~**The highest
number used is 116. A genuinely new phase takes 117.**~~ — **struck a thirteenth time on Aug 23,
2026, by 117 taking the number this sentence offered.** **117 moves the child's photo into
`EditChildSheet`** (iOS lane) — the sheet the name, birthday, pronouns and timezone are already
edited on — and deletes the `Photo` row and `ChildPhotoSheet` that **phase 115 shipped the same
day**. That is worth one line here rather than only in `roadmap-status.md`, because it is the first
time this file has allocated a number to undo the shape of the number before it: 115 was not wrong
about the risk it named, it was wrong about the remedy, and the remedy is one sentence of copy
rather than a second sheet. ~~**The highest number used is 117. A genuinely new phase takes 118.**~~ — **struck a fourteenth time on Aug 24, 2026, and this strike is the largest single jump this header has ever recorded: three numbers went by without touching it.** 118 is the photo-as-its-own-control pass (iOS lane), 119 is the health/liveness split (API lane, branch `api/phase-119-health-liveness`) and ~~**120 is the canvas video work, which exists only as a branch — `worktree-api-phase-120-canvas-video` — and appears in no commit subject, no pull request and nowhere under `docs/`.**~~ — **struck Aug 25, 2026 by phase 122: all three negatives are false, and stopped being true the day after they were written.** 120's commit subject is *"Phase 120: no vendor generates video for this product any more"* (`e66fffa`), its pull request is **#170**, merged as `01318be` at 22:45 UTC on Aug 25, and `grep -rliE 'phase[- ]120' docs/` returns **eight** files — `api-contract.md`, `data-model.md`, `decisions-log.md`, this file, `roadmap-status.md`, `runbook-admin-console.md` and the two reports under `reports/`. **The sentence is struck rather than deleted because the observation it was making is the point of the paragraph and merging does not touch it.** That is the shape the four prescribed commands exist for: three of the four answer 118 or 119 and only `git for-each-ref` sees 120, so a number read from any single source would have collided. **121 is entitlement grants and the console panel that issues them** (API lane, branch `api/phase-121-entitlement-grants`): a household can be entitled by a grant an admin issued as well as by a receipt Apple signed, `entitlements.tier` keeps its one writer, and the union is computed in `services/guardians.access_for` — the same authority phase 107 made. **119, 120 and 121 have all merged since this paragraph was written** — PR #169 (`aa130db`), PR #170 (`01318be`) and PR #168 (`084cfd2`) — so every branch it names is now on `main`. ~~**The highest number used is 121. A genuinely new phase takes 122.**~~ — **struck a fifteenth time on Aug 25, 2026, by 122 taking the number this sentence offered.** **122 is the docs sweep since 116** (branch `docs/phase-122-docs-sweep-since-116`): this file, `roadmap-status.md`, `decisions.md` and `CLAUDE.md` reconciled against the five phases that merged after PR #165 — 117, 118, 119, 120 and 121. **This is the system working rather than the system failing, and it is the second consecutive strike of the benign kind `:126` describes**: per this file's own rule at `:242` **a number is taken the moment a branch or a PR carries it, not when it merges**, and 122 was read out of this sentence and written back into it in the same pass, before a line of the work existed. `git for-each-ref refs/heads refs/remotes | grep -oiE 'phase-[0-9]+' | sort -u -t'-' -k2 -n | tail -4` returns `phase-119`, `phase-120`, `phase-121`, `phase-122`. ~~**The highest number used is 122. A genuinely new phase takes 123.**~~ — **struck a sixteenth time on Aug 25, 2026, within the hour, by 123 taking the number this sentence offered — and this strike is the first one caused by a measurement rather than by a defect or a plan.** **123 is the compaction of the four documents this project keeps its memory in** (docs lane, same branch as 122): `decisions-log.md`, `roadmap-status.md`, `decisions.md` and `blocked.md` had reached **1.17 MB between them**, and the phase 122 sweep immediately above spent **170 M cache-read tokens across 23 agents** largely because of it. Four spans moved to `docs/archive/` whole and unedited, each with a stated boundary; **live big four 1,171 KB → 709 KB**, nothing deleted, everything still under `docs/`. **The two allocations were three hours apart on one branch and neither collided**, because the owner changed the scope in a message and the number was read from this line before the first file moved — which is the remedy this header has spent fifteen strikes asking for, working for the second consecutive phase. ~~**The highest number used is 123. A genuinely new phase takes 124.**~~ — **struck a seventeenth time on Aug 25, 2026, by 124 and 125 taking the two numbers this sentence offered, allocated in the same minute from one owner instruction.** **124 is paywall review compliance** (iOS lane, branch `ios/phase-124-app-review-compliance`): guideline 3.1.2's disclosures and the Restore control, and **its preflight is the more useful half** — it found that phase 110 already shipped most of the scope, that both legal links are in the code and dark only because `Config.xcconfig` supplies neither URL, and that restore is built and visible on two surfaces the brief describes as lacking it. **125 is the Settings membership copy** (iOS lane, riding 124's branch by the owner's call rather than taking its own): eight owner-authored strings replaced verbatim, with a match rule that leaves every unsupplied state variant alone. **Both rows were written into `roadmap-status.md` at allocation, before a line of code**, which is the remedy this header has now spent sixteen strikes asking for and the fourth consecutive phase to honour. ~~**The highest number used is 125. A genuinely new phase takes 126.**~~ — **struck an eighteenth time on Aug 25, 2026, within the hour, by 126 taking the number this sentence offered.** **126 is the submission-gap audit** (iOS lane, riding 124's branch): an export audit and an App Privacy derivation that both produce documents rather than code, plus three rows in Settings. **It is the second consecutive brief whose own preflight gate would halt it**, and for the same reason 124's gate 4 did — a gate written to forbid a shape the owner then chose deliberately. Gate 1 says to stop if the paywall compliance phase is in flight; 124 is in flight, on this branch, because the owner put them there. **The gates are kept and the conflicts are written into the briefs**, rather than the gates being quietly edited, since a gate that gets relaxed whenever it fires stops being a gate. ~~**The highest number used is 126. A genuinely new phase takes 127.**~~ — **struck a nineteenth time on Aug 25, 2026, by 127 taking the number this sentence offered.** **127 is Sign in with Apple revocation** (API lane, branch `api/phase-127-siwa-revocation`): Apple's REST token-revocation call that Guideline 5.1.1(v) requires and that `decisions.md:404-409` has said *"needs a phase number of its own"* since Aug 17, 2026 without ever getting one. **This strike is the first one caused by a stale worktree, and it is the near-miss this header exists for.** The tree was four commits behind `origin/main`, and the on-disk copy of this file ended *"the highest number used is 123, a genuinely new phase takes 124"* — a number `origin/main` had already spent three ways on 124, 125 and 126. **Reading the file is not sufficient if the file is stale; the pull comes first.** That is the 103 collision's exact mechanism — two allocations that could not see each other — caught this time only because the preflight diffed the working tree against the remote before believing either. ~~**The highest number used is 127. A genuinely new phase takes 128.**~~ — **struck a twentieth time on Aug 28, 2026, by 128 and 129 taking the two numbers this sentence offered.** **128 is `api/phase-128-pocket-chronicle`**, allocated concurrently and not detailed here — this file did not write its row. **129 is the App Store blocker corrections** (API lane, docs-only, branch `docs/phase-129-appstore-blocker-corrections`): `blocked.md` §10a item 2 said `APP_STORE_APP_APPLE_ID` was still absent, and it had been deployed since before this was checked — both the Sandbox and Production verifiers build on the production machine, and a live Sandbox notification round-tripped through signature verification, transaction decode and family resolution the same day it was found. **129's number came from `git for-each-ref`, not from this sentence** — the four prescribed commands split 127/127/127/128, because 128 already existed as a branch with no row anywhere under `docs/`, which is exactly the shape this header exists to catch. ~~**The highest number used is 129. A genuinely new phase takes 130.**~~ — **struck a twenty-first time on Aug 28, 2026, and this strike is the second of the kind that is not a failure of the remedy but of the *reading*: the sentence went stale in the ordinary way and the phase that consumed it did not come here for the number.** **130 is the iOS half of the Pocket Chronicle rename** (PR #177, `ios/phase-130-pocket-chronicle`) and **131 is the domain half** (PR #178, `api/phase-131-pocket-chronicle-domain`); both merged before this line was read, and neither wrote a row in `roadmap-status.md` — nor did **128** — so that ledger has no row for any of the three. **132 is the beta auth flap** (iOS lane, branch `ios/phase-132-beta-auth-flap`): a TestFlight tester's intermittent "Can't reach the archive", which sometimes ends at the sign-in screen, and a several-hundred-word text entry lost after the composer said "Saving". **Its number is the first in a while that all four prescribed commands agreed on** — commits, refs, PRs and a grep of `docs/` every one of them answered 131 — which is worth one line because the four have split on three of the last five allocations, and the one thing that did *not* agree was this sentence. **The row was written into `roadmap-status.md` before a line of the work existed.** ~~**The highest number used is 132. A genuinely new phase takes 133.**~~ — **struck a twenty-second time on Aug 29, 2026, by 133 taking the number this sentence offered.** **133 is this docs-only reconciliation against a live App Store Connect session** (API lane, branch `docs/phase-133-appstore-connect-submission`): all four prescribed commands answered **132** with no disagreement, so 133 is `max + 1`. **The row went into `roadmap-status.md` at allocation, before these edits, per the remedy this header keeps asking for.** ~~**The highest number used is 133. A genuinely new phase takes 134.**~~ — **struck a twenty-third time on Aug 29, 2026, by 134 taking the number this sentence offered.** **134 is the app icon's dead-name wordmark, redrawn, and the `render-appicon.mjs` pipeline it broke the same morning** (docs lane, `docs/app-icon/` only, no branch — worked directly against `main`): full detail in `roadmap-status.md`'s row. **The highest number used is 134. A genuinely new phase takes 135.**

**111 is the blocked-list
reconciliation** (API lane, branch `api/phase-111-blocked-list-reconciliation`): Apple Root CA - G3
committed and `blocked.md` §10a item 1 closed, §14 struck as resolved by phase 86, the four resolved
`##` sections at the top of `blocked.md` moved into *Resolved since the last review*, and the
marketing-broadcast claims corrected across five documents now that the job has been sending for
four consecutive days.
**112 is the Settings membership surface** (iOS lane, branch `ios/phase-112-settings-membership`),
allocated Aug 22, 2026 and **paired with 113 in the API lane rather than queued behind it** — 113 is
the wire half and 112's second tranche consumes it. Its first tranche needs nothing from 113 and is
built. **The header sentence above is phase 113's to move, not this paragraph's**, and it is
deliberately left alone here so two concurrent branches do not both rewrite one line.

**What 112 found that its own brief did not know**, recorded because the brief was written from the
component list rather than from the tree: the 16pt-terracotta contrast failure is **nine** sites, not
one. The brief called it *"every action row in Settings"* — it is every action row **and** eight
standalone labels, across `SettingsRow`, `SyncPullSection` ×2, `SettingsScreen` ×2,
`NotificationSettingsSection`, `GuardiansSection` and `TranscriptionBacklogSection` ×2. **Six more
survive outside Settings** — `Onboarding/` ×4, `Timeline/` ×1, `DesignSystemCatalog` ×1 — on `canvas`
`#FDFAF4`, which is within a hair of `surface` and fails identically. They are **not** fixed by 112
and are a free-standing candidate for a later number.


**The eighth strike is the second consecutive one that is not a failure**, and it was nearly the
first strike caused by the thing this header cannot see. 111 was cut from a **stale local `main` at
`6c93c39`** while `origin/main` had already moved to `9af51c8` carrying 105, 107 and 108 — so the
four prescribed commands, run in that worktree, could see no ledger row for 107, 108 or 110 —
~~*and would have answered **106***~~. **Struck Aug 22, 2026: that figure was derived rather than
run, and the commands answer 109.** `roadmap-status.md` at `6c93c39` **did** carry a 109 row:
`git show 6c93c39:docs/roadmap-status.md | grep -c '| \*\*109\*\* |'` returns **1**. And the
fourth prescribed command is a grep of `docs/` for the phase pattern, not a grep for ledger rows —
at that commit it finds `Phase 107`, `phase-107` and `phase-109`, so **its answer was 109**.
**Absent-from-the-ledger and invisible-to-the-commands are two different sets and this paragraph
had merged them**: 107 and 109 were both findable in `docs/` while having no row; **108, 110 and
111 appear nowhere under `docs/` at `6c93c39` at all** — `git grep -ohiE 'phase[- ]1(08|10|11)'
6c93c39 -- docs/` returns nothing — and those three are the real blind spot this paragraph exists
to record.
**The number was right anyway because it was read from this file rather than measured**, which is
the case this header has been arguing for across ~~ten~~ **nine** instances — **corrected
Aug 22, 2026 in the same pass that wrote it**; nine is the count the correction paragraph below
rules on and the number the rest of this header carries — the file a human writes the number into
outranks any command that counts. What caught the stale base was an
adversarial audit of the phase's own diff, not the numbering rule.

**110 is the first strike in this file's history that is not a failure**, and the distinction is
worth keeping rather than filing it with the other nine. Every previous strike records a number
found spent *after* somebody had already taken it. This one records the sentence being consumed
**as designed** — 110 read *"a genuinely new phase takes 110"*, took 110, and rewrote the line in
the same commit, before a line of its own work existed. **The header went stale in under an hour
and that is the system working**, not drifting: a next-number claim is meant to be consumed and
replaced, and the nine instances above are all cases where it was consumed and *not* replaced.
**The failure this file records has never been staleness. It is the gap between reading a number
and writing it down**, and four phases in one evening have now closed it.

**109 is the ninth instance, and it is the fifth blind spot rather than any of the four before it.**
All four prescribed commands were run on Aug 21 before 108 took its number. They returned: commits
**107**, branches **108**, PRs **105**, docs **106**. **Not one of them can see 109**, because 109
exists only in the sentence of a prompt the owner wrote — no branch, no commit, no PR, no line in
any file under `docs/`. This header already names the failure exactly — *"the measurement being
unable, in principle, to see an allocation that exists only in somebody's head"* — and 103 is the
case it was written for. **The difference worth recording is that 103's collision was discovered
afterwards and this one was not.** 109 was declared in the same prompt that told phase 108 to write
this line, so the allocation and its record arrived together for the first time. **That is the
remedy working, and it worked because a human wrote the number down where an agent would read it —
not because any command found it.** The commands still cannot, and a tenth instance will look
exactly like this one if the next allocation is spoken rather than written.

**103 was spent twice and both halves shipped.** *The shot list becomes a video* (PR #153) and
*LLM prompt generation* (PR #152) were allocated hours apart on Aug 20 by two branches running in
parallel, neither of which had written a row in `roadmap-status.md` yet — so **the four commands
below would have answered 102 for both of them, correctly, at the moment each one asked.** That is
not a gap in the measurement; it is the measurement being unable, in principle, to see an
allocation that exists only in somebody's head. **Nothing is renumbered** — `CLAUDE.md` is explicit
that a phase number is an identifier, and both PRs, both branch names and every commit subject say
`103`. The full note is under the ledger in `roadmap-status.md`.

**The remedy has not changed across ~~eight~~ nine instances, and ~~has still never been
followed~~** — **both halves corrected Aug 22, 2026 by phase 111.** The count is **nine**, which is
the number the rest of this header already carries and ~~*this line alone did not*~~ — **that
half was false the moment it was written and is struck Aug 22, 2026 by the same phase that wrote
it**: the eighth-strike paragraph above, added on this same branch, said *"across ten instances"*
and is corrected there. **Two lines disagreed, not one, and the exhaustive claim was made without
grepping the file it was about** — which is this phase's own stated failure mode wearing the
opposite face. The three that were already right: *"the remedy this
header has asked for across nine instances"* above, *"the nine instances above"* below it, and
*"109 is the ninth instance"* naming the last of them. And it **has** been followed — five times
running, by 107, 108, 109, 110 and 111, all of which wrote their rows at allocation. The remedy
itself is unchanged: write the
row when you take the number, not when you ship. Every one of these strikes is a session that
measured honestly, got the right answer, and then left a gap between reading a number and
recording it.

**The fourth strike is the first one this file's own rule predicted.** `:76` already says a number
is taken the moment a branch or a PR carries it — 102 was carried by both while this paragraph
still offered it to the next reader. The lag is not the docs audit being late; it is that the
sentence is written at allocation time and read at allocation time by somebody else, and nothing
recomputes it in between. **`roadmap-status.md`'s ledger is the only thing that is actually true**,
and it is out of numeric order there (102 sits above 101), so a reader who tails the table sees 101
and believes it.

**Seventh instance, and it is a *fifth* blind spot rather than the fourth firing again.** The
fourth is a number spent by a commit whose subject names no phase; this is the opposite. 98 and 99
were spent by commits whose subjects *do* say `Phase 98:` and `Phase 99:`, and all four prescribed
commands would have found them — but neither reached `roadmap-status.md`, the file `CLAUDE.md`
sends you to as the authority. So the ledger sat at 95 while four phases had merged, and a session
obeying `CLAUDE.md` literally would have taken 96 and collided with the admin console. **The commit log and the ledger disagreed, and
the ledger is the one people are told to read.** Phase 100 filled 96 through 99 in the same pass
that added its own row, which is the only remedy that has ever worked: *write the row when you
take the number, not when you ship.*

**Sixth instance, and this one broke the remedy rather than the count.** Phase 96 ran all three
commands below, got 95, and 95 was already spent — by the *content* of `docs/decisions-log.md`,
committed under the subject `docs: Update decisions log and roadmap status following Aug 18
proposals`, which names no phase anywhere a `git log` grep can see. **A docs commit can spend a
number without its message ever saying so**, and none of the three prescribed measurements looks
inside a file. The fourth command below is the fix and is now part of the rule:

```
grep -rhoiE 'phase[- ][0-9]+' docs/ | sort -u -t' ' -k2 -n | tail -5   # what the docs already claim
```

The original header follows, kept because the pattern it records is the point.

**The highest number used was
78**, so a genuinely new phase takes **79** — and **79 through 83 are already allocated**, and **each now has a row in
`roadmap-status.md`** — which is the authority `CLAUDE.md` sends you to, and which carried the
allocation nowhere for the first few hours it existed. **That gap was a fifth instance of this
header's own failure waiting to happen**: a session obeying `CLAUDE.md` literally would read the
ledger, see it stop at 78, and take 79 — colliding with work that is written and green. **An
allocation recorded only in the queue is not recorded.** They go to a
paired session building the four-prompt recording/sync/display-name pack: 79 and 80 and 81 iOS,
**82 iOS and 83 API, split because that item crosses lanes and CI is path-scoped.**

~~*"The highest number used is 75, so a genuinely new phase takes 76"*~~ — **struck Aug 18, 2026,
and this is the fourth instance, not the third.** 76 and 77 merged (`3b6f832`, `0ad7f30`) and
**78 is open as PR #129**, so a reader trusting that line would have collided with *two merged
phases and one open pull request*. Before it: ~~*"the highest number used is 73, so a genuinely new
phase takes 74"*~~, which was true when written and stopped being true the same evening, and
~~*"61 through 67 all went on Aug 17, so the next is 68"*~~ before that, and *"…is 46, so a
genuinely new phase takes 47"* at line 31 below.

**The count inside this header was itself stale, which is the finding worth carrying.** The block
below still opens *"Third time this header has been wrong"* — it was written when three had
happened, and by not being re-counted it committed the very drift it exists to record. **A tally of
your own failures is a figure like any other and rots like any other.**

**The rule needed strengthening, not just the integer — the integer will rot again by morning.**
This file's stated remedy was *"measure `main`, not this file"*, and **`main` alone would not have
saved anyone this time**: 78 is real, is taken, and is not on `main`. The measurement that works is
all three at once, and it is what allocated 79–83:

```
git log --all --pretty=format:'%s%n%b' | grep -oiE 'phase [0-9]+'   # commits, every ref
git for-each-ref refs/heads refs/remotes | grep -oiE 'phase-[0-9]+'  # branch names
gh pr list --state all --limit 200 --jq '.[].title'                  # open PRs included
grep -rhoiE 'phase[- ][0-9]+' docs/                                  # what the docs already claim
```

**The fourth line was added Aug 19, 2026 after the first three came back 95 and 95 was gone.**

**A number is taken the moment a branch or a PR carries it, not when it merges.**
68 unblocked the sprint, 69 built the daily broadcast, 70 went to the icon and wordmark work,
71 and 73 are the two halves of the Vellum rename, and 72 was the false-claims sweep. 67 closed
the App Store deletion blocker that 65 found; the universal-link surface took 59; **60 was the
marketing signup endpoint and the Resend swap**. 51–59 merged on Aug 16, 2026 (PRs #99, #100,
#101) and are live in production.

> **Third time this header has been wrong, and this one is the mildest of the three** — it was
> stale rather than self-contradicting, and it was stale by six numbers in a single evening
> because seven phases ran in one night. Recorded rather than quietly corrected, because that
> is what the two entries below it are for. **The rule that works has not changed and worked
> again here: measure `main`, not a status document's count.** Phase 71 read this line, found
> it said 68, checked `main`, and found 68 already merged as `364154c`.

> **This header has now been wrong twice in two days, and the second time was worse.** It said
> *"the highest number used is 46, so a genuinely new phase takes 47"* while line 121 of this
> same file, added by the **same commit**, said the icon shipped as phase 47 — a file made to
> contradict itself six lines apart. Meanwhile **48, 49 and 50 had merged** and neither this
> file nor `roadmap-status.md` recorded any of them. A preflight gate caught it before anything
> was numbered; had it not, the auth bundle would have been numbered 47 and collided with three
> merged phases. **Neither file was right. `main` was.** Both are corrected, and the rule that
> works is the one `roadmap-status.md:231` already stated: *measure `main` rather than quoting a
> status document's count.*

Everything else in scope has shipped: 24, 25, 27, 28, 31, 35, adding a child, the visibility
design and Settings' hero strip, with **33 blocked on the platform**. 36–39 are monetization's
forward items, 40 settled the numbering, 41 retired the caption clobber into 33, 42 iceboxed
guardian invites, 43 scoped the export by date, 44 reconciled the verification backlog, 45 gave
multi-kid device coverage, 46 shipped the caption probe, 47 the app icon, 48 cleared the iOS
concurrency warnings, 49 the activity clock and consent lanes, 50 pool-health's observed rate,
and **51–57 the auth bundle's API half**.

---

## Questions I need from you

~~**Nothing is open.**~~ — **struck Aug 25, 2026 by phase 122: one question is open, and it is the
only kind this section takes — a decision nobody but the owner can make.**

**D5b — may entitlement have a second source that Apple never signed?** Phase 121 shipped
`entitlement_grants`, `POST /v1/admin/grants` and the console panel that issues them (`bb78fbc`,
merged as `084cfd2`, PR #168), and said so in its own body: *"**`docs/decisions.md` was not
edited.** The proposed **D5b** is below, for you to apply."* **It is still a proposal and phase 122
deliberately did not apply it**, because a row that asks the owner three questions is not a stale
fact a sweep may correct — `decisions.md`'s **Settled** table carries no D5b row, only a Changelog
entry saying why it does not, while `data-model.md`, `api-contract.md`, `runbook-deploy.md` §7a and
`runbook-admin-console.md` §3b all describe the grant as shipped. **So the one file `CLAUDE.md`
calls *settled — do not relitigate* has a decision-shaped hole in it about a term that is already
computing `entitled` in production, and this list is where that hole is parked until you close
it.** The drafted row is in `gh pr view 168`, to be applied verbatim or rejected; **three things
it says it is really asking you to settle**, in its own words: *(i)* *"That a second source of entitlement is
acceptable at all"* — 121 reads D5 as protecting *who decides about payment* rather than *how many
reasons a household can be entitled*, and if the stronger reading was the intent then **121 is the
wrong shape and gets reverted rather than amended**; *(ii)* *"That `entitled` includes the
trial"*; *(iii)* *"That a granted household reads `access: "subscribed"`."* **Rejecting it is a
real option and costs a revert**, which is why it is on this list rather than in `decisions.md`.

Every other question this file has asked has been answered, and the answers are in
`docs/decisions.md`. Add new ones here as they come up.

**Answered Aug 14–15, 2026.** Per-entry visibility: **per-entry with a per-kind default**, a
`viewer` sees **everything not marked private**, and **a seal is a separate axis** from visibility
— all three in `decisions.md`, with the column specified in `data-model.md`. The four `his mom`
prompts were **rewritten household-neutral** rather than tokenised around. And the hero's stats
strip: the middle cell **counts photographs, not media**; the strip **does not render until the
server answers**, because nil is not zero; and an **empty archive shows nothing** rather than three
zeros. Those last three are recorded in `settings-v2-inventory.md` where D1 and D12 were dropped.

**Answered Aug 12, 2026** and written into `docs/decisions.md`, which is the authority for all of
these — **the app is called ~~`Dogear`~~ `Vellum`** (superseded Aug 17, 2026 by the owner; `decisions.md:115` is the settled row and this line was left saying the dead name for a day after the rename shipped in both lanes), tokenise all ~~113~~ **133** prompts — phase 25 added twenty photo bodies on Aug 14 and `mission-library.md` has said 133 since — letter-on-any-day is
freeform-plus-seal with the age asked only once sealing is chosen, a seal is always editable, the
kind chip takes `periwinkleDeep` in all three places, sage stays below AA as a recorded exception,
multi-kid is in scope and prioritised, per-entry visibility gets designed now, and paper grain
stays rejected (no action).

---

## Now — production

**Four of the five things this section carried were closed on Aug 14, 2026.** What is left is the
iOS build, and it is the one nobody here can do.

- **The `mission` slot served a photo** on the morning of Aug 14 — observed on the phone, which is
  the first time it has ever happened. **The scheduler was not the cause and the machine image was
  not the fix**: that run fired at ~09:00 UTC, hours before the images were refreshed, so the
  narrowing was working and the slot was simply never drawing a photo before. Recorded this way on
  purpose, because "we changed something and then it worked" is how a real cause goes unfound. If
  the photo slot goes quiet again, the pool is where to look, not the machine.
- **Both scheduled machines are on the deployed image.** `185d762c643778` and `8900ddf6719058`
  were updated in place with `fly machine update --image` on Aug 14 — their `schedule`, restart
  policy, command and env were all already correct, and only the image was stale. **The recurrence
  is closed in code**: the deploy workflow now moves any machine with a non-empty `schedule` onto
  the image the app is running. That step shipped with a defect of its own — it compared
  `…:deployment-X` against `…:deployment-X@sha256:…`, which are never equal, so it restarted both
  machines on every deploy — fixed Aug 15 by comparing on the tag.
- **The prompt library is seeded in production.** The Aug 14 run reported
  `99 inserted, 0 updated, 14 unchanged, 99 retired (113 in the library)` — the tokenised bodies
  are live and the 99 literal ones are deactivated. **The recurrence is closed in code**: the seed
  is on `fly.toml`'s `release_command`, so every deploy reconciles the library with the file.
- **Ship an iOS build — still open, and still yours.** `ios.yml` is a *test* workflow: it builds
  for the simulator and runs the suite, and has no archive, signing or upload step anywhere. The
  only signing identity on the build machine is `Apple Development`, so a TestFlight build needs a
  Distribution certificate and an App Store Connect key that live with the owner. Until one ships,
  the installed build predates `3df6cd4` and renders `mission_b` as an unknown grey "Still open"
  slot regardless of what the server does. **Which key, decided Aug 22, 2026, because a key's access
  is fixed at generation and cannot be narrowed later without revoke-and-regenerate:** mint an
  **upload-only** key now for this, and leave the **team key with Sales and Finance access**
  deferred until after launch, per `blocked.md` §16 — sales reports 404 on an empty period anyway.
  Two errands rather than one, on purpose; the alternative is a single over-scoped key that can read
  the money.

## Blocked on you, not on code

- ~~**Put Apple Root CA - G3 in the repository.** One `curl`, and `POST /v1/webhooks/app-store`
  answers `401` to every notification until it is done — deliberately, because the alternative to
  a trust anchor is accepting unverified billing payloads. The command and the fingerprint check
  are in `docs/blocked.md` §10a and in `api/src/rascal/certs/appstore/README.md`. **The branch that
  wrote the code could not do this**: `www.apple.com` is refused by that environment's egress
  policy, and the root is in neither `certifi` nor the system CA bundle.~~ — **done Aug 22, 2026 by
  phase 111; line struck per this file's rule that a queue line goes when it is done.** 583 bytes at
  `api/src/rascal/certs/appstore/AppleRootCA-G3.cer`, self-signed `CN=Apple Root CA - G3`, valid to
  Apr 30 2039, and `load_root_certificates` now returns one anchor. **The blocker was true of its
  own environment and false as a generalisation** — `www.apple.com` answered `200` from here — which
  is the part worth keeping: an egress policy is a property of the machine that hit it, not of the
  errand. **The fingerprint check it pointed at could not be performed as written**: Apple's
  certificate authority page publishes no fingerprints at all, so the substitute is a byte-for-byte
  `cmp` against the copy macOS ships in `SystemRootCertificates.keychain`. Written into
  `blocked.md` §10a and the certs `README.md`.
- **Read `APP_STORE_APP_APPLE_ID` off App Store Connect** and set it as a Fly secret. Apple's
  library refuses to build a Production verifier without it. **This one does not wait on the Paid
  Applications agreement** — the app record has existed since TestFlight — so unlike the rest of
  `docs/blocked.md` §10 it is available today. **Still open, and its scope narrowed Aug 22, 2026**:
  confirmed absent from `flyctl secrets list -a rascal-api`, and now that the root certificate is
  in, it is the **only** thing between here and a verified notification — but only for
  `Environment.PRODUCTION`. **The sandbox verifier builds today**, so the first sandbox purchase in
  §10 is verifiable now and Production is not.
- Read the ~~**79 prompt candidates**~~ **139 prompt candidates** — **corrected Aug 22, 2026 by
  phase 111; both sets are kept, on the owner's call.** 79 from Aug 4 and **60 dated
  2026-08-22**, five worksheets at 12 each. The Aug 4 set was generated before `decisions.md`
  settled the tone as warm and cheerful on Aug 11 — read those for warmth as well as accuracy.
  ~~All 79 are `question` kind.~~ — **that stops being true of the whole pile**: the new five are
  a kind spread, one worksheet each — `fears-comfort` **question**, `outdoors` **video**,
  `me-as-a-parent` **question**, `physical-affection` **audio**, `seasons-holidays`
  **activity** — so three of the five land in kinds the Aug 4 pass never produced. **They target
  the themes that are thin now** rather than the ones Aug 4 chose: `fears-comfort` 2, `outdoors`
  4, `me-as-a-parent` 5, `physical-affection` 5, `seasons-holidays` 5, while Aug 4's
  `making-building` and `sleep-routine` sit at 6 each and are no longer thin.
- Run a **restore drill**. The machinery is tested; the act has never been performed. Use the
  pinned Postgres 16 binaries — a 17 client writes a dump 16 will not take back.

## Verification backlog — 467 boxes, 93 ticked, **374 open**, and the only instrument that reads what tests cannot

**Recounted Aug 18, 2026, and the headline moved for the first time.** ~~*460 boxes*~~ was right when
written; it is 467 now because phase 79 added seven to the transcription list. **93 are ticked** —
and 84 of those were ticked on Aug 18 by the owner, on a device, in commit `d99204d` (*"notes
update"*). **That work was invisible to every status document in this repo until this recount**,
which is the same failure this file records about phase numbers, arriving from the other
direction: not work claimed and not done, but **work done and not claimed.**

Count them with `grep -cE '^\s*-? *\[[ xX]\]'` for the total and `\[[xX]\]` for the ticked. **A
`grep '\[ \]'` counts only the unticked ones and will tell you the backlog is shrinking when it is
not** — that mistake was made once during this very recount.

Run in this order. Details and the "why here" for each are in `roadmap-status.md`.

- The App Group check: `device-verification-widget.md` §1 **+** `-share-extension.md` §1. Half an
  hour, answers both at once, and do it before anything else.
- `device-verification-widget.md` — 48. **The whole file, which this list only ever pointed at.**
  §8a is new: the snapshot it writes is what the Lock Screen renders, so a wrong-child one is
  wrong where nobody opens the app to look.
- `device-verification-share-extension.md` — 45 boxes. The only one with a number to write down.
- `device-verification-today-v2.md` — 44. Swipe-to-skip has never been swiped. **§8 is new** —
  two children on one board.
- ~~`device-verification-settings.md` — 87. Longest; §0 is five minutes.~~ — **84 of 87 ticked on
  Aug 18, 2026 by the owner. Three boxes left, and they are specific rather than "finish the
  file":** `:78` interrupt an export by enabling Airplane Mode mid-download, `:99` confirm
  **Archive → Birthday** shows the same day as the row behind it, and `:213` §8a.3 cold launch
  with Airplane Mode on — the stats strip **must not render at all**, because nil is not zero.
  ~~**This was the longest file in the backlog and is now the shortest thing left on it.**~~ —
  **struck Aug 25, 2026 by phase 122: three boxes is the count, not the remaining work.** Phases
  115, 117 and 118 put an entire photo flow inside the very sheet §2, §3 and §8 already open —
  `ChildPhotoField` is the **first** field of `EditChildSheet`, above Name
  (`ios/Rascal/Rascal/Settings/EditChildSheet.swift:64`, `nameField` at `:71`) — and **this file
  has no box for choosing, replacing, framing or removing a photo anywhere**: `grep -in
  'photo\|avatar'` over it returns seven lines and not one of them is a box about the avatar. The
  totals are unchanged at 84 of 87, so phase 117 edited a **ticked** line's text (`:263-265`, the
  hero hint) and added none. **The camera path and `AvatarFramingScreen`'s pinch-and-drag crop
  cannot be reached in a simulator at all**, which is the exact category this backlog exists for.
  Somebody owes this file a section.
- The audio list in PR #22 — needs iOS 26+ and a quiet room. Prerequisite for transcription.
- `device-verification-transcription.md` — ~~45~~ **52**. The one whose answer could invalidate a
  design. **§4a is new (phase 79)** — seven boxes on the screen going dark mid-recording. Two of
  them expect opposite outcomes on purpose: the screen stays lit while **capturing** and locks
  normally during **review playback**, because the wake lock is scoped to capture. The box that
  matters most is the staged `.m4a` still existing after a return to the foreground — that one
  was genuinely failing.
- `device-verification-backfill.md` — 23. Needs a real camera roll, and **two children** — §3a is
  the silent one: a sibling's month used to count as covered, so this child was never offered it.
- `device-verification-extraction.md` — 22. Needs Apple Intelligence hardware. **§4a is new.**
- `device-verification-entry-detail.md` — 36. **Header fixed and the v2 checks added by 44** — two
  boxes asked about a navigation bar v2 removed, and §7 is new. Runnable as written now.
- `device-verification-captions.md` — 9. **Needs a real camera roll, and its answer decides
  phase 33.** Measures how many photos already carry a written description; near-zero closes 33.
  **The owner said Aug 22, 2026 that he will run it this week, and the probe stays until he does** —
  so this is the one item on this list with a date attached to it. Its first line no longer says the
  checklist is waiting on a TestFlight build; that was superseded by the owner's Aug 16 device build
  and corrected in the checklist by phase 111.
- `device-verification-personalization.md` — 25. Same hardware gate as extraction.
- `device-verification-moments.md` — 44.
- `device-verification-push.md` — 32, of which **9 are ticked** (§0–§3, Aug 12). Left: force-quit delivery, the
  sandbox row alongside production, all of §4–§7, and **§6a — the re-offer with a second child**,
  which is spent once and never comes back.
- The sync-pull sequence — not a file: Settings → dry run → read the report → flip
  `syncPullEnabled` → pull to refresh. Never run against the real archive.

## The build queue

Numbered items match `roadmap-status.md`'s forward queue. **Prioritised, in order**, per Aug 12.

- **107 — the trial, the entitlement gate, and the weekday cadence.** API lane. `entitlements.trial_ends_at` and a computed `access`; the free tier serves the daily question and locks the rest of the day, never the archive. Reverses D2, narrows D3. Paired with **108** (iOS: the locked board and the membership sheet) and **109** (the marketing site's pricing page). The long form is the 107 row in `roadmap-status.md`.

- **108 — the locked board, the membership sheet, the trial welcome. iOS lane, open on
  `ios/phase-108-locked-today-membership`, PR #158 — merged with `main` after 107 and 110
  landed, green and mergeable, awaiting the owner.** The client half of 107. A `LockedPromptCard` below the
  live prompts on Today, a membership sheet reached from it and from Settings, a one-time trial
  welcome and a one-time post-trial `Notice`. **Three things a reader needs before touching it, and
  the first is not a task:** *(i)* this phase and 107 **reverse D2 and D3**, which `CLAUDE.md` marks
  settled — the reversal is the owner's and is authorised, but its diff
  (`docs/decisions/proposed-d2-d3-reversal-diff.md`) **was never written**, so both lanes applied
  the intent of a file neither could read; Lane A's amendment to `decisions.md:30-31` is the record
  that now exists. *(ii)* **The live marketing site still promises the un-reversed D2** in four
  places including indexed JSON-LD — **109 is presumed to own that**, and it is logged in both lane
  PRs so it survives 109 slipping. *(iii)* `docs/design/free-tier-copy.md`, named as the verbatim
  source for every string, **did not exist**; this phase authored it and **it is unreviewed**. The
  standing rule the phase must not break, whatever else changes: **`access` absent or unrecognised
  means entitled** — the device never decides entitlement, and the failure direction is the full
  board, never a paywall; settled as **D9**. **Three things it found that outlive it and belong on
  somebody's list, none of them fixable inside this phase:** the free tier **has no 100-photo cap**
  and D2 promises one; **the paywall has no Terms or Privacy link** because `Config.xcconfig`
  defines neither key, which is an App Review rejection under 3.1.2 rather than a cosmetic gap
  (`blocked.md` §19); and **`PrimaryButtonStyle` fails AA at 4.36:1** on every screen in the app —
  `terracottaDeep` as the resting fill measures 6.47:1, but that is a palette change touching
  every screen and was deliberately not taken here.

- ~~**37b — StoreKit, the client half.**~~ — **shipped Aug 20, 2026, merged as PR #154; line
  struck per this file's rule that a queue line goes when it is done.** The long form is the 37b
  row in `roadmap-status.md`. **What does not go with it, because it is an obligation rather than a
  task:** `appAccountToken` must carry the purchasing user's `family_id` — it is the only channel
  Apple has for carrying one, and a transaction made without it is **unattributable permanently**,
  with no later fix server-side or otherwise. `docs/api-contract.md` states it as a named client
  requirement and the shipped client honours it. **Nothing has been bought**, so it is proven in
  the suite and unproven against Apple; that waits on the same TestFlight build everything else
  here waits on, and on ~~`blocked.md` §10a and §16~~ — **corrected Aug 22, 2026 by phase 111, and
  it named the wrong two sections.** It waits on **§10** — the subscription products have to exist
  in App Store Connect before anything can be bought — and on the TestFlight build. **§16 was never
  a dependency**: its own first line is *"Not blocked, because nothing is waiting on it"*, and it
  defers a Sales-and-Finance reporting key that no purchase needs. **§10a is no longer one either**:
  item 1 closed today with Apple Root CA - G3 committed, and item 2 (`APP_STORE_APP_APPLE_ID`)
  gates only the **Production** verifier — the **sandbox** verifier builds without it, so the first
  sandbox purchase is verifiable today and only a Production notification is not.

- **iOS lane: `ios/Rascal/RascalTests/Vellum.storekit` describes an introductory offer the products
  will not have.** *New Aug 22, 2026, from phase 111, and recorded here because the API lane may not
  edit it.* The owner decided that day that the App Store products are created with **no
  introductory offer**: the 14-day trial is server-side only — granted at INSERT into
  `entitlements.trial_ends_at` — and an Apple intro offer would stack on top of it, because Apple's
  eligibility is per Apple ID and cannot see that column. Fourteen free days total, not
  twenty-eight. The fixture carries **two** `introductoryOffer` blocks, so the local StoreKit test
  configuration now models a product that will not exist. **Nothing is broken and nothing goes red**
  — which is why it needs a line rather than a bug report — but a paywall verified against this
  fixture is verified against the wrong product. The decision is written up in `blocked.md` §10 and
  amended into D1 in `decisions.md`.

- **iOS lane: three device documents still say `/health` answers `{"status":"ok","db":"ok"}`.**
  *New Aug 25, 2026, from phase 119, and recorded here because the API lane may not edit `ios/`.*
  `GET /health` is **liveness only** since `aa130db` (PR #169) — `api/src/rascal/main.py:106-107`
  is `async def health() -> dict[str, str]: return {"status": "ok"}` and the database check is its
  own route, `GET /health/db`, registered at `main.py:110`. **Two of the three are gates rather
  than records**, which is what makes this worth a line rather than a shrug:
  `ios/device-session.md:93` and `ios/device-test.md:36-37` are setup steps a developer follows
  before anything else, and the second says the body ***should*** match — so a developer whose
  local server is behaving exactly as designed reads a passing step as a failed one and goes
  looking for a database that was never unreachable. `ios/preflight-report.md:117` sits under
  *"Run in the order given"*. **Nothing goes red and nothing is broken**; the cost is entirely a
  person's afternoon. One line each: point the reachability check at `/health` expecting
  `{"status":"ok"}`, and add `/health/db` → `{"status":"ok","db":"ok"}` as the separate database
  check.

- **Rename to ~~`Dogear`~~ `Vellum` — code is done, ~~three things left~~ two, and both are yours.**
  **Three errors were live in this bullet until Aug 18, 2026, and they compounded.** *(i)* It was
  headed **`Dogear`**, a name superseded on Aug 17 (`decisions.md:115`) and renamed out of both
  lanes as phases 71 and 73. *(ii)* It said the display name shipped on *"the app, widget and share
  extension"* — **that is three, and there are four**, because the app carries both `Info.plist` and
  `Info-Debug.plist`; `roadmap-status.md`'s phase 73 row has this right, and the same off-by-one is
  in a source comment at `RascalShare-Info.plist:22`. *(iii)* Its *"verified out of the built
  bundles, not just the source"* was performed **Aug 12, against a name that has changed twice
  since**, so the strongest-sounding clause in the bullet was the most stale — **a verification is
  only as current as the thing it was run against, and this one outlived two renames.** All four
  bundles read `Vellum` in source today, and `project.pbxproj` sets no
  `INFOPLIST_KEY_CFBundleDisplayName` override, so **a device still showing the old name is a stale
  install rather than a source defect** — a distinction that cost another session a retracted
  finding on Aug 18. Shipped Aug 12 and re-verified in source Aug 18: the display name on all four
  bundles, the onboarding wordmark, 13 in-app copy strings, the export viewer's
  titles and the download filename. ~~**Left: the app icon** (a design asset)~~ — **the icon
  shipped Aug 16 as phase 47**, and it was never really a rename item: the mark carries no word,
  so it was decidable before the name and would not have changed after it. **Left: the App Store
  Connect / TestFlight listing name**, and **the repo name plus `docs/` prose** — the last is
  cosmetic and deliberately not swept, because it would bury a real diff under a few hundred
  mechanical lines. Ship a build for any of it to reach the phone.
- **Check Tinybeans Group's ASX announcements quarterly (ticker TNY).** It is the only competitor whose product roadmap is legally required to be public, and the Qeepsake acquisition release announced an AI-prompt, voice-and-video, transcription-searchable journaling roadmap — which is this product's feature set. Whether that ships is the single most decision-relevant external fact available, and it arrives on a schedule rather than needing to be dug for.
- **Re-measure `mission`'s pool health.** Phase 25 took the untagged photo pool from 20 to 40, so
  the relaxation date in `mission-library.md` is stale by arithmetic. One call to
  `GET /children/{id}/pool-health` replaces a projection this file must not invent.
- **33 — Photo captioning. Blocked on the platform, and now waiting on a measurement rather than
  on Apple — see `docs/blocked.md` §9.** Re-verified Aug 16: the block is unchanged. **Phase 46
  shipped the measurement instead of the feature** — `MAImageCaptioning` reads a description a
  human already wrote into a photo's metadata, and nobody has counted how many real photos have
  one. Run `device-verification-captions.md` on a phone with a real camera roll; **near-zero
  deletes the probe and closes this phase**, and anything better gets it a real one. The server
  half is complete and the *generating* half cannot be written: the on-device model's whole input
  vocabulary is `Transcript.Segment`, which is text or structure, so there is no pixels-to-prose
  call to make. **The stated reason here was half wrong** — `SpeechTranscribing` takes a file URL
  and *returns* text, so the two seams never shared an input to widen. It is a third protocol
  because they diverge, which is the stronger argument. **Do not land the seam ahead of the API**:
  its state ladder is a SwiftData migration on every media row for a feature that may never ship,
  and a Settings row that permanently reads "0 waiting" is the furniture this app refuses.
  **It also inherits the caption clobber** — a queue line of its own until Aug 16, now on 33's row
  and in §9, where the three call sites and the reason it cannot be fixed early are written out.
  **46 deliberately did not guard it**: `applyServerSummary` and `differs(_:from:)` agree today, so
  there is no live defect, and a guard would guard a writer that does not exist. The deferral now
  points at the measurement rather than at a phase that may never land.
- **32 — Year One book.** Year scoping closed with 43 on Aug 16; `GET /export` takes `from` and
  `to`. **The other four problems are one problem** — print layout, PDF generation, QR
  substitution and the playback surface all need a web client this API has never had. That is
  the gate, and scoping did not move it.
- **34 — Membership billing / costs. Fully decided; it is D1–D6 and phases 36–39 now.** ~~Two
  questions still open.~~ **Both were answered the same day this line was written, and the line
  never caught up** — corrected by 42 on Aug 16. (1) *Export during the cold year without paying*
  is **yes**: D2 says the export is "always free and complete", and D3a puts a one-click free
  export link inside every deletion warning. (2) *What the free tier caps* is **media**, exactly
  the shape the open question recommended: D2 caps photos at 100 lifetime and leaves every prompt,
  all text and all `did_it` entries uncapped. Its "then deletion" summary is also superseded — D3
  deletes **media only, never text**, on two computed clocks. **Nothing here blocks anything.** The
  real gate is `blocked.md` §10 and it is an account action: Small Business Program enrollment and
  the subscription products in App Store Connect, both yours. §10 also records that **38 needs no
  Apple account at all.**
- ~~**auth — the whole bundle.**~~ **Shipped and merged Aug 16, 2026: 51, 52, 53, 54, 55, 56,
  57, 58, 59.** Both lanes, deployed, and verified against production rather than against the
  deploy's green tick — routes answer, migrations are at `0013`, the association file serves
  with the right `appID`, `GOOGLE_CLIENT_IDS` took, and dev-login still 404s.
- **Run `blocked.md` §11 — Apple's `sub` across a revoke. Still the sharpest thing on this
  list.** Phase 53 is live and its central assumption has never once been observed: that
  Apple's `sub` survives a revoke-and-reauthorize cycle. **All nineteen of its tests pass
  whether or not it holds**, so nothing in CI can tell you. If it changes, the recoverability
  design is wrong rather than buggy — and that is worth knowing before anything tells a parent
  that removing the app is reversible. **Runnable for real as of Aug 22, 2026, and the runbook
  changed to match**: attach an email credential first, via ~~`POST /me/credentials`~~ **`POST
  /v1/me/credentials/email`** — **corrected Aug 22, 2026: the route named here cannot do it.**
  `POST /v1/me/credentials` verifies a *provider token* and attaches Apple or Google; the email
  attach is its own route, takes an address, always answers `202`, and creates the credential
  **inactive** until the magic link is opened through `POST /v1/auth/email/complete`. Following
  the old line literally would fail before the experiment started — so that a
  changed `sub` is repairable with already-shipped code — sign in by magic link and the new Apple
  subject attaches to the same `users` row — instead of stranding a production archive behind an
  account nobody can sign in as. That pre-step only became possible now, because Resend is live and
  the magic link actually sends.
- **Nothing in the auth bundle has run on a phone**, and it cannot until there is a TestFlight
  build: `ios.yml` has no archive, signing or upload step, and the only identity on the build
  machine is `Apple Development`. Google sign-in has never been attempted against real Google,
  no magic link has ever been tapped, and no Dynamic Type XXL screenshots exist for either
  screen. **Merged and invisible** is the honest description.
- ~~**No real email has ever been sent.** `MAIL_PROVIDER` is `console` everywhere; Postmark has
  never been called, so the magic link is proven as logic and unproven as mail.~~ — **struck Aug 22,
  2026 by phase 111. Real email has been sent.** `MAIL_PROVIDER`, `MAIL_FROM`, `MAIL_API_KEY`,
  `MARKETING_EMAIL_ENABLED` and `RESEND_AUDIENCE_ID` are all Deployed secrets on `rascal-api`, and
  `email_broadcasts` holds four rows, **all `status='sent'`**, for Aug 19–22. **The half of this
  line that survives is the half about the magic link**: the marketing broadcast is what has sent,
  and no `POST /auth/email/start` link has been tapped by a person, so that path is still proven as
  logic and unproven as mail. Postmark cannot be called at all — `PostmarkProvider` was deleted, not
  disabled, by phase 60.
- ~~**60 — `POST /v1/subscribe`, and Resend replaces Postmark on both lanes.**~~ — **shipped Aug 17, 2026; line deleted per this file's own rule that a queue line goes when it is done.** The specification it carried is preserved in `roadmap-status.md`'s phase 60 row, which is where the long form belongs. **Everything it specified landed as specified**, including the two things most likely to have drifted: the `stream` argument went onto the existing `services/mail.py` port rather than beside it, and **no `subscribers` table was created** — the list is provider-held per open item 12(4).
- **The marketing site itself — `Rascal-Marketing`, a different repository, so it takes no phase
  number here.** GitHub Pages custom domain with **Enforce HTTPS**, CSP via `<meta http-equiv>`
  (the header set is fixed on this host — an accepted exception, D7), the signup form, and the
  Turnstile widget. **`prompts.yaml` and `mission-library.md` never enter that repo**, whole or
  sliced. Owner actions it waits on are `blocked.md` §13. ~~**Timing: the page and its form may ship
  before the P0 gate; no marketing email sends before it.**~~ — **struck Aug 22, 2026 on the owner's
  call. The P0 behavioural gate no longer gates marketing email**, and the broadcast has been
  arming and sending since Aug 19. The timing constraint on this bullet is gone; what is left is
  the Turnstile site key in §13, which is what stops the form saying *"signups are not open yet"*.
- **60's port is a prerequisite for 38 (lifecycle notices), whose email channel cannot be built
  without it.** Recorded as a dependency rather than a phase. **The webhook that writes the
  `email` outcome into `lifecycle_notice_deliveries` belongs to 38 and gets no number of its own**
  — `data-model.md` names the dependency and 38 inherits it. Note the trap recorded there:
  `delivered` must mean the provider confirmed delivery, never that the send call returned without
  raising, because D3 lets a deletion proceed once one channel reads `delivered`. **Timing: 38 is
  itself downstream of the P0 gate, and its notices are transactional rather than marketing — the
  constraint that binds it is D3's, not this one's.**

- ~~**96 — the admin console.**~~ **Shipped Aug 19, 2026.** `/admin` behind `is_admin`: business
  snapshot, a prompt-library editor that survives a re-seed, a five-vendor costs panel, and a
  scheduler grid that reads what the job produced. **Two things it hands you.** The cost cards for
  Anthropic, Fly and Neon are `unconfigured` and each names the environment variable and where the
  key comes from — Tigris and Resend already work off credentials this repo has. And **the
  scheduler grid says `mission_b` has served nothing for a fortnight locally**; the same panel
  against production is the "read the rows" check `roadmap-status.md` keeps asking for.

- ~~**97 — the social studio.**~~ **Shipped Aug 19, 2026.** A Studio tab: Claude as art
  director, schema-enforced post concepts, brand cards drawn on a canvas and exported as PNG or
  WebM, and ~~shot lists with a WebVTT caption track~~ **a typed scene graph, with a WebVTT
  caption track derived from its copy and its cumulative durations, one cue per scene** —
  **corrected Aug 25, 2026 by phase 122, for phase 120 (`01318be`, PR #170): `POST
  /social/shot-list` is now `POST /social/treatment`** (`api/src/rascal/routers/social.py:178`;
  `grep -rn 'shot-list\|shot_list' api/src/rascal` finds nothing but the column comment recording
  the rename), **and the Studio no longer stops at a written plan** — the browser records the
  graph and the API hands back a finished H.264 MP4 from `GET /social/renders/{id}/file`
  (`social.py:588`). **Two things to know before using it.**
  It needs `ANTHROPIC_API_KEY` — the ordinary `sk-ant-api…` kind, not the admin key the cost
  panel wants — and **Claude generates no images or video**, because no Anthropic model has
  such an endpoint; the cards are drawn locally and photographs need `OPENAI_API_KEY` or
  `REPLICATE_API_TOKEN`. **Nothing posts anywhere.** Featuring a mission-library prompt is
  counted and capped at 24 per D7; the Studio shows the running total.

## Iceboxed

**Not rejected and not scheduled.** The section below is for things the owner has decided against
doing *for now*, which is a different answer from the one "Deliberately not doing" records — those
are settled no's. Anything here can come back without relitigating it, and the note says what it
would cost to restart.

- **30 — Guardian invites and the `viewer` role, and per-entry visibility with it.** Owner's call,
  Aug 16, 2026: *not for a while.* **Nothing has to be unwound**, which is why this is cheap to
  park — `visibility` is specified in `data-model.md` and was never migrated, so there is no column
  on `entries`, no filter in `deps.py` and no dead code anywhere. The design is not lost either:
  the three answers are settled in `decisions.md` and the column is specified down to its default,
  so restarting is a build against a finished spec rather than a fresh design. **The `viewer` role
  in the schema stays** — it has been in `guardians.role` since `0001` and is enforced by
  `child_access`; what does not exist is any route that can create one, which is exactly the state
  this has always been in. Nothing regresses by leaving it there.
- **Per-entry visibility — the build, not the design.** Iced with 30 above, because it has no other
  consumer. `decisions.md` is unchanged and stays authoritative for when it returns: per-entry with
  a per-kind default, a viewer sees everything not marked private, a seal is a separate axis.
  **The reason it was designed before being scheduled still holds** — a visibility model retrofitted
  onto an archive that already has guardians is a migration over user content, so having it settled
  in advance is worth more now than it was when nothing was iceboxed.

~~**36 is deliberately still in the build queue**~~ — **36 shipped Aug 17, 2026 and is out of
the queue entirely.** The server half is phase 36 itself and the client half is phases 61 and 63;
the sprint's stories 3a and 3b both re-reported it as `ALREADY LANDED` at their own idempotency
gates.

**The distinction that had it iced is the thing that turned out to be confusing, and it is worth
keeping in the owner's own framing:** he had been reading *guardian* as **grandparents** — which
is phase 30, still iced — when what he actually wanted was a **second parent**. The two were
separated on Aug 15 for exactly that reason, and the separation is what let one ship while the
other stayed parked. 30 is unchanged and nothing tonight un-ices it or needs unwinding.

**What un-icing 36 restored: D4's consumer.** *"One price for the whole household"* now has the
thing it is sold on, which it did not while this was parked — and the free tier deliberately does
**not** include a second guardian, so the invite surface is the upgrade surface.

## Deliberately not doing

Delete nothing here without a decision to go with it.

- Cross-share deduplication — sharing the same photo twice makes two entries, on purpose.
- Renumbering the phase collisions (3, 11, 19, 20 each mean two things). The ledger disambiguates.
- Paper grain. Already in `decisions.md` under "Rejected — do not revisit"; confirmed Aug 12, no
  action. The design exports will keep shipping it and the answer stays no.

---

## Follow-ups the Aug 17 sprint generated

One line each, per this file's rule. The reasoning is in `roadmap-status.md` and the story
reports; these are only the things somebody has to *do*.

- **Owner: set the Turnstile site key** in `Rascal-Marketing`'s `src/assets/site.js`. Public key,
  belongs in markup. Until then the signup form declines to post and says so.
- **Owner: the §13 errand.** `docs/blocked.md` now carries a table of every value it produces and
  the exact file or `fly secrets set` command each one lands in. **Turnstile is the only step with
  no prerequisite** and is what makes the signup form stop saying "signups are not open yet".
- ~~Owner: rename the product in `docs/marketing/email-sequence.md`~~ — **done in phase 76**, by
  the owner's explicit say-so, as a name swap and nothing else. The generator was re-run and the
  YAML follows.
- **Owner: write down the trademark check you say you ran** — where you looked and what you
  found, one line. Open item 15. You answered *"already checked — it's fine"* on Aug 18; the repo
  holds the assurance but not the evidence, and only the second kind is auditable later.
- **Re-capture the marketing site's onboarding screenshot** — ~~once phase 73 merges~~ **73 merged Aug 18, 2026, so this is unblocked and waiting on a build.** The old wordmark is baked into its pixels and cannot be fixed from the marketing repo. **It needs a fresh capture from a build carrying the phase 77 wordmark**, which means it is gated on the same iOS build everything else here is gated on.
- ~~**Exercise `POST /v1/subscribe` end to end once**, from the real GitHub Pages origin, to confirm
  CORS and a real Turnstile verification. Never yet done against the deployed API.~~ — **struck
  Aug 22, 2026 by phase 111: it has been done, and this line was the flattest of the three
  contradicting accounts.** `blocked.md` §13 is the evidence and the form to defer to: *"`POST
  /v1/subscribe` has now been exercised from the real origin — that signup is what revealed that
  Resend's contacts API does **not** do double opt-in, which phase 88 then fixed. So CORS and a
  genuine Turnstile verification have both run against the deployed API for the first time."*
  **Nothing is owed here any more**, so it is struck rather than reworded: the errand this line
  named is spent.
- ~~**Run the daily broadcast once with `--date` against an audience of one** before it ever runs for
  the list. The Resend Broadcasts API has never been called.~~ — ~~**A Fly scheduled machine for
  `python -m rascal.jobs.broadcast`**, once the above is verified.~~ — **both struck Aug 22, 2026 by
  phase 111, and they were struck by events rather than by anybody doing them.** The machine exists:
  `683e1eea463d28` / `late-fire-837`, created **2026-08-19T02:15:36Z**, command
  `["python","-m","rascal.jobs.broadcast"]`, `grp=(none)`. The Resend Broadcasts API has been called
  four times — `email_broadcasts` holds Aug 19, 20, 21 and 22, **all `status='sent'`**, none failed
  and none skipped. **The audience-of-one rehearsal never happened; the first real send was the
  first send.** ⚠️ **How many people received those four emails is not knowable from this repository
  or from Fly**, and is written as unknown rather than estimated: `MAIL_API_KEY` is send-scoped and
  `GET /audiences/{id}/contacts` answers **403** from inside the production machine. Only the Resend
  dashboard can answer it, and that is an owner errand nobody has run. **The invocation is written
  down** in `runbook-deploy.md` §4d. **And a second machine is still missing, which nothing here was
  tracking: `python -m rascal.jobs.delete`.** It has its own line below rather than a clause
  here, because a legal deadline buried in a paragraph about email is a thing nobody reads.
- **Create the deletion machine: `python -m rascal.jobs.delete`.** *New Aug 22, 2026, and the only
  line on this list with a promise on the clock.* `flyctl machine list --app rascal-api`, read today,
  returns **five** machines — two `app` running uvicorn, and one each for `rascal.jobs.scheduler`,
  `rascal.jobs.notify` and `rascal.jobs.broadcast`. **None runs `rascal.jobs.delete`.** The job has
  existed since phase 66 shipped on Aug 17, 2026 and `runbook-deploy.md` §4c writes down how to
  create it, so this is one `flyctl machine run` and not a build. **Nothing goes red while it is
  missing**: `POST /v1/me/deletion` accepts, the row lands in `deletion_requests`, the API stays
  green, and the seven days pass with nothing scheduled to finish the erasure — so a parent who asked
  to be forgotten is not forgotten and no instrument in this project says so. It is the one
  hard-delete `CLAUDE.md` rule 5 carves out, an App Store commitment rather than a feature, and the
  long form is `blocked.md`.
- **113 — the membership wire.** *New Aug 22, 2026, API lane, branch
  `api/phase-113-membership-wire`, paired with 112 in the iOS lane.* Four additive optional fields
  so the Settings surface can tell more than three household states apart: `lapsed_at`, `plan`,
  `billing_retry` and `is_payer` on `FamilyOut`, with `plan` and `billing_retry` on `EntitlementOut`
  too. **`access` keeps exactly three values** — a fourth would mean *entitled* on every client
  predating it, under D9. **`billing_retry` gates nothing** and a household in grace stays fully
  subscribed. **`is_payer` is `bool | null` and null never means false**; it is unknown in the
  two-guardian case, which is the only case where the question means anything, and `blocked.md` §21
  records why that cannot be fixed server-side and what the client half would need.
- **A client change is the only way to know who is paying in a two-guardian household.** *New
  Aug 22, 2026, iOS lane, not allocated.* `appAccountToken` carries a `family_id` by contract, so no
  Apple notification can ever name a user. It needs a request field carrying the purchasing user id
  plus a change to `SubscriptionStore.purchase(_:familyID:)`, whose argument is non-optional and
  pinned by two tests — so it is a phase, not a drive-by, and it fixes nothing retroactively.
  Nothing is broken while it waits: `is_payer: null` means *show the control*. Long form in
  `blocked.md` §21.
- **Owner: read the Resend dashboard and write down the recipient count for the four sends.** *New
  Aug 22, 2026.* One look, and it is the only place the number exists. Until it is written down,
  every document in this repository can say the broadcast sends and none of them can say to whom.
- **§0 device verification is still 0 of 45.** Unchanged by this sprint and still wants running.
- ~~**Render one full treatment end to end, and read the invoice afterwards.** Gemini billing is
  enabled and phase 106 proved the path with **one four-second clip**. A real treatment is seven
  generations plus an ffmpeg concatenation, and **nothing has exercised the concatenation against
  clips a vendor actually produced** — only against fixtures. The other half is the number:
  `GEMINI_VIDEO_CENTS_PER_SECOND` is 5 because Google publishes $0.05 a second, and **that figure
  has never been reconciled against a Google invoice**, so the console is currently showing an
  estimate somebody typed. One render settles both.~~ — **struck Aug 25, 2026 by phase 120
  (`e66fffa`, merged as `01318be`, PR #170), and closed by removal rather than by doing it.**
  **There is no invoice to read and no price to reconcile.** `services/social/gemini.py` and
  `stitch.py` are deleted, all three `GEMINI_*` settings are gone from `config.py` and
  `.env.example`, `renders.estimate_cents` went with them — `grep -rn GEMINI api/src/rascal` and
  `grep -rn estimate_cents api/src/rascal` both return nothing — and a treatment now costs
  nothing. `cost_cents` is still written, as `0`, on the success path **and** the failure path,
  because *"a ledger that stops recording when the number becomes zero is a ledger that cannot
  show you it went to zero"* (`services/social/renders.py:21`). **The observation this bullet
  actually recorded is the one worth keeping** — that a paid path had never once run end to end in
  production, only against fixtures — and it is the reason the replacement was arguable at all.
  **Five treatments have since been recorded and transcoded end to end against a real browser** —
  7 scenes / 21.6s, 5 / 14.7s, 4 / 11.4s, 4 / 14.0s and 5 / 16.2s, each probed `h264 · 1080×1920 ·
  yuv420p · 30fps · 0 audio streams` — and `roadmap-status.md`'s 120 row lists all five. **The
  identical correction reached `roadmap-status.md:499`(iii) in phase 120's own commit and did not
  reach this line**, which is precisely what that strike is about.

  *(This file's rule is to delete a line when it is done. This one is struck rather than deleted
  because it was not done — it was removed, and a line closed by having its subject deleted is the
  one kind this file has always kept.)*
- **Owner: `flyctl secrets unset GEMINI_API_KEY GEMINI_VIDEO_MODEL GEMINI_VIDEO_CENTS_PER_SECOND -a rascal-api`.**
  *New Aug 25, 2026, from phase 120.* All three settings are gone from `config.py` and
  `.env.example`, and the phase deliberately did not touch the Fly secrets — **a branch cannot
  unset a production secret**, so this was always going to be somebody's one-line errand.
  **Nothing goes red while they sit there**, which is exactly why nobody will notice: a live
  vendor credential on `rascal-api` for a vendor this product no longer calls, and `grep -rn
  GEMINI api/src/rascal` returns nothing that would ever read it.
  `runbook-admin-console.md:161-163` and `.env.example:183-185` both write the command down.
- **Owner: refresh `IG_ACCESS_TOKEN` before ~Oct 19, 2026.** ~~*in two places at once … Fly
  secrets and `.env` here, **and** the `Rascal-Marketing` Actions secret — refreshing one leaves
  the other posting to the same account with a dead token*~~ — **struck Aug 22, 2026 by phase 111:
  it is a one-store errand today, and this line is where the correction had not reached.** The
  complete `flyctl secrets list -a rascal-api`, read Aug 22, holds **no `IG_ACCESS_TOKEN`, no
  `IG_USER_ID` and no `SOCIAL_PUBLISH_ENABLED`**, and none of the five machines on the app is a
  social publisher — so the API-lane publisher has never been armed in production and there is no
  second live copy to go stale. **What moves is the `Rascal-Marketing` Actions secret**, plus
  whatever a developer keeps in a local `.env`. Meta issues the token for about sixty days and the
  only real timestamp either repo has puts the lapse there. **Nothing refreshes it and nothing
  warns**; the first sign is a failed publish with `OAuthException 190`. **It becomes a two-store
  errand the day the API-lane publisher is armed** — setting `IG_ACCESS_TOKEN` on `rascal-api` is
  the moment to un-strike the sentence above rather than rewrite this line. `blocked.md` §18.
- **Owner: two unverified things about the Instagram integration, both one look each.** Which
  scopes the token actually carries (Meta's Access Token Debugger shows them in seconds; the
  marketing repo recorded that they were confirmed and never wrote down what they were), and
  whether `alt_text` lands on a published post — both pipelines have been sending it for a day
  with no evidence Meta does anything with it on this flow.

## Follow-ups the Aug 29 App Store Connect session generated (phase 133)

- **Owner: re-verify Small Business Program enrollment status directly in App Store Connect.**
  *New Aug 29, 2026.* A blank enrollment form was seen this session; the owner believes it was done
  in an earlier pass but that was not confirmed end to end. `blocked.md` §10 step 2 reads
  needs-verification, not done, until this is checked.
- **Audit for stray references to the old App Store listing name `Pocket Chronicle`.** *New
  Aug 29, 2026, decisions.md open item 18.* Apple rejected `Pocket Chronicle` as a listing name and
  it is now `PocketChronicle.App`. `CFBundleName`, `CFBundleDisplayName` and every in-app string are
  unaffected and stay exactly as phase 130 set them — this audit is narrowly for surfaces that quote
  the *App Store listing name specifically*: the App Store Connect product page copy, the marketing
  site if it names the listing rather than the product, and any broadcast that links to the store
  listing. Nobody has looked yet.
- **Verify the App Review Notes' onboarding walkthrough against actual build 20.** *New
  Aug 29, 2026.* The notes were written from docs, not from running the build.
- **Confirm the "search" and "export" claims in the App Store description are genuinely present in
  build 20.** *New Aug 29, 2026.* Not yet checked against the submitted build.
- **Run one cold Sign in with Apple test before clicking Submit for Review.** *New Aug 29, 2026.*
  Not yet done.

## Allocation

**The highest number used is 136. A genuinely new phase takes 137.** 136 is the household invite
email (Sep 2, 2026), and it is the first row in this file's history written by a session working
**both lanes on one branch** rather than a worktree per lane — see its `roadmap-status.md` row for
why, and treat it as the exception it is rather than the new shape.

## Follow-ups phase 134 generated (docs/app-icon/, Aug 29, 2026)

- **Port the drawn Pocket Chronicle wordmark into `Wordmark.swift`'s `Shape`.** iOS lane. The path
  lives in `docs/app-icon/pocket-chronicle-icon-fan-lockup.svg`; `WordmarkView(width:tint:)` still
  sets the name as type, per phase 130's stopgap.
- **Port the same path into `api/src/rascal/admin/static/index.html` and `cards.js`'s `.wordmark`.**
  API lane, same source file. Also unstarted.
- **Decide whether `render-appicon.mjs` should ever move to the lockup variant, once the above
  ship** — not a foregone conclusion. Until then it stays on `pocket-chronicle-icon-fan.svg`
  (wordless).
- **Owner: re-run `node docs/app-icon/render-appicon.mjs` when ready to refresh the shipped icon.**
  Not run by phase 134 — it rewrites a committed iOS asset while build 20 sits Ready for Review.
