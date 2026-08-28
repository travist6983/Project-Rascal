# App Privacy labels — derived from the tree

> **A note on this document's own citations, added when it was committed.**
>
> This report was written, adversarially verified, corrected and verified again — three passes —
> **while the phase 124/125/126 code it describes was still being edited in the same tree.** Every
> pass found stale line numbers in the pass before it, and the last recheck found several more,
> because the anchors kept moving underneath. Two consequences, stated rather than hidden:
>
> 1. **Line numbers in this document may be off by a few lines.** The file names, the symbol names
>    and the findings were each verified by reading; the integers were true when written. Chase a
>    symbol, not a line.
> 2. **One recheck finding was a false positive caused by this very race** — an agent read
>    `ios/Rascal/Config.xcconfig` during a break-test window in which the two legal keys had been
>    temporarily removed, and reported that the file defines neither. It defines both. The file is
>    87 lines and carries them at `TERMS_URL` / `PRIVACY_URL`;
>    `SubmissionComplianceTests.theLegalURLsResolveInThisBuild` asserts they resolve at runtime and
>    passes.
>
> **The findings are the deliverable; the line numbers are a convenience.** Nothing in the analysis
> below turns on an integer.



**Aug 26, 2026.** Phase 126, Part 2 — **corrected second pass, plus a verification pass and this
correction pass.** Derived by reading `ios/` and `api/` on branch
**`ios/phase-124-submission-compliance`** at commit **`d7ece87`** (*"Merge pull request #173 from
travist6983/api/phase-127-siwa-revocation"*), confirmed with `git rev-parse HEAD` by this pass.

**The working tree is not clean, and it moved while this pass was running.** `git status --porcelain`
returned **15** paths when this correction pass started and **16** when it finished —
`ios/Rascal/RascalTests/MembershipTests.swift` became modified in between, so another session is
editing this same tree. The sixteen, as of the final check:

```
 M docs/blocked.md
 M docs/decisions-log.md
 M docs/design/design-conformance-110.md
 M docs/design/free-tier-copy.md
 M docs/roadmap-status.md
 M ios/Rascal/Rascal/Settings/SettingsScreen.swift
 M ios/Rascal/Rascal/Subscription/MembershipCopy.swift
 M ios/Rascal/Rascal/Subscription/MembershipPresentation.swift
 M ios/Rascal/Rascal/Subscription/PaywallSheet.swift
 M ios/Rascal/Rascal/Subscription/SubscriptionModel.swift
 M ios/Rascal/Rascal/Subscription/SubscriptionSection.swift
 M ios/Rascal/RascalTests/MembershipTests.swift
 M ios/Rascal/RascalTests/SettingsMembershipTests.swift
 M ios/Rascal/RascalTests/SubscriptionTests.swift
?? ios/Rascal/Rascal/DesignSystem/SafariView.swift
?? ios/Rascal/RascalTests/SubmissionComplianceTests.swift
```

*(Corrected by this pass: the previous version of this header listed **ten** paths and omitted all
five modified `docs/` files, in a document whose stated method is reading against the tree as it
stands. §10 records the same correction.)*

The uncommitted work is phases 124/125/126 in the iOS lane. That diff **changes two findings** the
first pass got right at the time and would now get wrong: the app's module list gained
`SafariServices` (§5), and the app gained a second in-app web surface (§9). Both are corrected below.
**Nothing in either lane was changed by any pass over this document** — they read only.

This file exists to be transcribed by hand into App Store Connect → App Privacy. It is not a
privacy policy and it is not legal advice. Every row carries the `file:line` where the collection
actually happens, so the next person can re-derive it rather than trust it.

**How to read the markers.** Every substantive claim is tagged **VERIFIED-BY-READING** (that line was
opened at `d7ece87` in the tree described above and it says what this document says it says) or
**INFERRED** (a conclusion drawn from documented framework behaviour or from reasoning, which nothing
in this repository proves). No inference is stated as a fact anywhere in this document, and §10 lists
all of them in one place with the check that would settle each. **§10 also states which pass re-read
which lines** — the coverage is not uniform, and it should not be read as uniform.

**Three items in here need a human decision before anything is typed into App Store Connect**, and
they are §1, §2 and §3 — deliberately ahead of the table, because a label filled in without
settling them is a label that is wrong in a way Apple can act on. **All three are UNRESOLVED and
this document does not resolve them.**

---

## 1. FLAG — the archive's subject is a child who has no account · **UNRESOLVED**

**This is the item that most needs a person, and an attorney (§3), and it is not something an
agent should quietly map to a convenient category. It is not resolved by this document and must
not be recorded as resolved by anything downstream of it.**

Every category in Apple's taxonomy is written from the premise that the data is *about the person
using the app*. This app's central purpose is to accumulate, permanently, a detailed record about
somebody else — a child who has no account, no credential row, no way to consent, and no way to
ask for erasure today.

What is held about that child — all **VERIFIED-BY-READING**:

| Held | Where |
|---|---|
| Given name | `api/src/rascal/models/child.py:20` — `name: Mapped[str] = mapped_column(Text)` |
| Date of birth | `api/src/rascal/models/child.py:21` — `birthdate: Mapped[dt.date] = mapped_column(Date)` |
| Pronouns | `api/src/rascal/models/child.py:25` |
| Face — avatar photo | `api/src/rascal/models/child.py:26` (`avatar_key`); picked at `ios/Rascal/Rascal/Onboarding/AvatarStep.swift:109` (`PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared())`), loaded at `:133-141`, cropped by `AvatarCrop.square` at `:147` *(corrected from `:145`, which is `private func process(_ data: Data) {`)*, queued by `ios/Rascal/Rascal/Onboarding/AvatarUpload.swift`, PUT to S3 by `ios/Rascal/Rascal/Onboarding/AvatarSync.swift:44-50` |
| Photographs and video of them | `api/src/rascal/models/entry.py:137` (`s3_key`), staged at `ios/Rascal/Rascal/Composer/MediaDraft.swift:62,67,98` |
| Their recorded voice | `ios/Rascal/Rascal/Media/AudioPipeline.swift:179` (`AVAudioRecorder(url:settings:)`) |
| Transcripts of their voice | `api/src/rascal/models/entry.py:146` |
| A written record of their behaviour, moods, fears, health, relationships and development | `api/src/rascal/models/entry.py:95-96` (`title`, `body`) |
| Their age in months at every logged moment | `api/src/rascal/models/entry.py:94` — `child_age_months`, computed at write and stored |
| Their household's timezone | `api/src/rascal/models/child.py:29` (`family_timezone`) |

**The label cannot express what is true here.** App Store Connect offers exactly one identity axis
— *Linked to You* / *Not Linked to You* — and "you" means the account holder. Declaring the child's
name under **Contact Info → Name, Linked to You** is *technically accurate* (it is linked to the
parent's account) and *substantively misleading* (it reads as the parent's own name). There is no
field that says "this is about a third party who cannot consent."

**Consequences a person needs to weigh, not an agent:**

- **Whether the app is in the Kids Category is not a fact this tree contains.** — **INFERRED /
  NOT DERIVABLE.** *(Corrected: the first pass asserted "the app is not in the Kids Category" as
  fact with no citation. There is none to give — Kids Category and age rating are App Store Connect
  settings.)* `grep -rniE 'kids category|age rating|made for kids|COPPA' docs/ ios/` returns **six
  lines, and every one of them is a COPPA match** — `docs/decisions.md:59`,
  `docs/archive/decisions-changelog-aug-3-11.md:59`, `docs/archive/decisions-log-aug-3-16.md:3061`,
  `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md:49`,
  `docs/sprint-aug16/sprint-story-7-reconciliation.md:95`, `docs/sprint-aug16/story-5-report.md:17`.
  **None of the six states the Kids Category answer or the age rating.** *(Corrected again by this
  pass: the previous wording — the grep "finds nothing that states either" — is defensible but reads
  as an empty grep, and the grep is not empty.)* The reader transcribing this must **confirm the
  Kids Category answer in App Store Connect** before relying on it.
- **COPPA is already a settled owner decision, and this document had been arguing past it.** —
  **VERIFIED-BY-READING** `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md:49-53`: *"**COPPA is
  out of scope for this assessment, by the owner's decision, Aug 16, 2026.** Record the decision and
  its reasoning in one line so it is not mistaken for an oversight: COPPA attaches when a child is a
  *user* of the service. Here the child is a data subject only — the parent supplies everything, the
  child has no account, and handoff is years away. **Note that this stops being true the day a child
  gets their own access**, which `decisions.md` already contemplates with 13 as a floor."* *(Added by
  this pass — the reasoning was on record and this document was re-deriving it from scratch.)* That
  decision does not make the underlying question disappear: the service knowingly holds personal
  information about identified minors, supplied by their parent. It does mean the question reaching
  an attorney (§3) is the one the owner has *not* already answered.
- **The retention horizon is stated as eighteen years, in copy shown to the parent.** —
  **VERIFIED-BY-READING** `ios/Rascal/Info.plist:111` (`NSPhotoLibraryAddUsageDescription`):
  *"Save the original, full-quality video back to your photos. The archive keeps a smaller copy so
  it stays affordable to store for eighteen years."* *(Corrected: the first pass cited
  `Networking/TokenStore.swift:11` for this. That line is real and says something adjacent —
  *"Keychain rather than UserDefaults: these tokens reach a child's photos and voice."* — but it
  says nothing about eighteen years. `Info.plist:111` is the line that does.)* A child who turns
  eighteen has never agreed to any of it and has no account through which to object.
- **A second guardian can be invited** — **VERIFIED-BY-READING**
  `api/src/rascal/models/family.py:134` (`class GuardianInvite(Base)`) *(corrected from `:132`,
  which is blank)* — so the set of adults who can read the record can grow without the subject's
  involvement.
- **The erasure path is the parent's, not the child's.** — **VERIFIED-BY-READING**
  `api/src/rascal/models/deletion.py:14` (`class DeletionRequest`) and
  `api/src/rascal/services/deletion.py:67` (`GRACE_PERIOD = dt.timedelta(days=7)`). Account deletion
  hard-deletes after seven days, which is `CLAUDE.md` rule 5's one deliberate exception and is the
  right shape — but it is a control only the account holder has. **Phase 127, merged into this very
  commit, worked on the erasure path and on Sign in with Apple revocation and did not change that**:
  `api/src/rascal/services/apple_events.py:52` treats `consent-revoked` and `account-delete` as a
  credential event, not a subject-initiated erasure.
- **A mechanism for the child is contemplated, and it is settled rather than open.** —
  **VERIFIED-BY-READING** `docs/decisions.md:59`, settled Aug 11, 2026, closing open items 2 and 3:
  the shape is *"**shared access, not transfer**: the child becomes a second `users` row with a
  guardian-style role of `subject` against the same archive, and the parent keeps theirs"*, with a
  floor of **13** on self-owned access, and *"`POST /children/{id}/guardians` already exists as a P2
  stub."* *(Added by this pass. That the child has no control **today** is true of this tree and
  stands. The framing that no mechanism is contemplated at all was not, and `decisions.md` is the
  file `CLAUDE.md` calls authoritative and not to be relitigated.)*

**Recommendation, offered as a recommendation and explicitly not as a resolution:** declare the
child's data under the categories in §6 as *Linked to You*, because under-declaring is the worse
failure and the identity axis genuinely is the parent's account — **and then say the thing the
label cannot say, in plain words, in the privacy policy.**
`docs/sprint-aug16/sprint-story-5-privacy-and-terms.md` is the place that copy lives, and it already
carries the instruction not to soften it. The label is a checklist; the policy is where this fact
gets stated honestly.

**Do not treat this section as resolved by this document.**

### 1.1 FLAG — names of *other* third parties, extracted on device and persisted · **UNRESOLVED**

*(Added by this pass. The first pass missed it; the brief's "Cover at minimum, **and flag anything
else found**" — `docs/phase-briefs/phase-126-submission-gaps.md:97` — puts it in scope.)*

§1's thesis is data about somebody who is not the user. **This is the same question one layer down,
and it is the one place the app *derives* third-party identity rather than merely receiving it.**

**VERIFIED-BY-READING** `ios/Rascal/Rascal/Extraction/ExtractedDetails.swift:113-114`:

```swift
@Guide(description: "Names of people mentioned. Empty if the text names nobody. Never guess.")
var people: [String]
```

The on-device model reads what a parent wrote and returns the **names of people it mentions** —
grandparents, teachers, the child's friends, a neighbour. None of those people is the account
holder, none is the child, and none has any relationship with this service at all. Those names then
reach the server: `entry_tags` (`api/src/rascal/models/entry.py:184` — the
`__tablename__ = "entry_tags"` line) with `source` (`:196`) set to `device_ai` — one of two allowed
values, `api/src/rascal/constants.py:233` — written through `PATCH /media/{id}/derived`
(`api/src/rascal/routers/media.py:124,134`).

**The open question, which this document does not answer:** §6 files these under *Other User
Content — tags*, which is where they land as a data structure. But **Contact Info → Name** is the
category Apple would recognise for "names of people," and nothing in the taxonomy distinguishes a
name you typed about yourself from a name a model lifted out of your diary about a fourth party.
Filing derived third-party names as "tags" is a defensible reading and it is also the convenient
one, which is exactly why it should not be settled by whoever transcribes the form. **This belongs
in the attorney read (§3).**

The extraction itself is disciplined and worth crediting: the guide says *"Never guess"*, the
plain-Swift mirror at `:18-19` says *"Never inferred from context — if the parent did not write a
name, there is no name"*, tags are bounded to five (`:31` — `static let tagLimit = 5`, corrected
from `:29`, which is mid-comment), and re-running extraction is forbidden so a tag a parent deleted
cannot come back (`ios/Rascal/Rascal/Extraction/ExtractionQueue.swift:11-19`). None of that answers
the labelling question.

---

## 2. FLAG — the monthly measurement prompt solicits a child's height and weight · **DECISION PENDING**

The brief called this "health-adjacent." Having read it, that is right, and the mapping is less
obvious than it looks. **This section is not resolved by this document.**

**There is no structured health field anywhere.** — **VERIFIED-BY-READING.** `children` holds name,
birthdate, pronouns, avatar key and family timezone and nothing else
(`api/src/rascal/models/child.py:20-29`). A case-insensitive grep for `height|weight|bmi|inches|
centimet|pounds|kilo` across `api/src/rascal/models/` returns **five lines and no column**: four
Postgres `setweight()` calls in the search-vector expressions (`entry.py:50,51,54,55`) and one
sentence of prose in a docstring — `api/src/rascal/models/prompt.py:84`, *"So suppression is not a
cooldown and not a weight."* *(Corrected: the first pass reported this grep as returning only
`setweight()` calls. It does not; the `prompt.py` hit is harmless but the stated output did not
reproduce.)* So there is no column an auditor can point at.

**But `measurement` is a prompt *kind*, and one seeded prompt asks for the numbers by name.**

**VERIFIED-BY-READING:** there are **three** `measurement` prompts, not one —
`api/seeds/prompts.yaml:1351`, `:1363` and `:1386` — and **only the first asks for a measurement**.
*(Added by this pass: the first pass cited one and never said the kind had others, so a reader could
not tell whether the rest of the kind solicited numbers too. They do not, and saying so strengthens
the section.)*

| Line | `completion_mode` | Body |
|---|---|---|
| `:1351-1355` | `media` (`:1353`) | *"Measure {their} height and weight. Photograph {them} against the same wall, same spot as last time."* |
| `:1363-1366` | `media` | *"Take the same photo you took last month — same chair, same angle."* |
| `:1386-1389` | `media` | *"Trace {their} hand on paper and photograph it."* |

**The material fact the first pass omitted: the one soliciting prompt is a `media` prompt.**
`completion_mode: media` at `api/seeds/prompts.yaml:1353` — **VERIFIED-BY-READING**. The completion
this prompt asks for is a *photograph*. That cuts against the section's own argument and it belongs
in the section rather than outside it.

**What actually happens with the numbers is INFERRED, not verified.** A parent who reads *"Measure
{their} height and weight"* and writes the two numbers down puts them in `entries.body`
(`api/src/rascal/models/entry.py:96`) — free text, indistinguishable from any other entry, and
indexed into the full-text search vector along with everything else
(`ENTRY_SEARCH_VECTOR`, `entry.py:49-52`). **Nothing in this repository establishes that any parent
does this.** It is a prediction about behaviour, and it is the prediction the whole Health question
rests on. *(Corrected: the first pass stated it flatly.)*

**Why "we can't know what's in free text" is a weak defence here.** It is a good defence for
unsolicited text. It is a poorer one when the product's own seeded content asks for the measurement
by name, on a monthly cadence, as a named prompt kind. A reviewer who opens the mission library
finds the request in one grep. It is weaker than the first pass implied, though, because the prompt
asks for a photograph and the numbers are the parent's own addition.

**Apple's Health & Fitness → Health** reads *"…or any other user provided health or medical data."*
A child's height and weight, provided by the parent because the app asked, is on the wrong side of
that sentence to be comfortable.

**Three options, and the choice is the owner's:**

1. **Declare Health & Fitness → Health, Linked to You, App Functionality.** Costs almost nothing
   (health data may not be used for advertising — this app has no advertising), and it is the
   defensible answer if anyone ever asks why the library contains that prompt.
2. **Do not declare it**, on the grounds that the schema has no health field, the app performs no
   health function, and the prompt's own completion mode is a photograph. Defensible on the
   storage, weak on the solicitation.
3. **Change the prompt** so it stops asking for numbers — *"Photograph {them} against the same wall,
   same spot as last time"* is the same ritual without the measurement. **This would be an API-lane
   phase** (`prompts.yaml` is generated from `docs/mission-library.md`, and re-seeding keys
   idempotency on `sha256(kind, cadence, body)` so an edited body is a new prompt), so it is named
   here as an option and not proposed as work.

**This document leans toward option 1** — declare it. It is the cheapest of the three and the only
one that is true regardless of what a parent types. **But it is a judgment call, it is flagged
rather than absorbed, it feeds the attorney read in §3, and the table in §6 marks it DECISION
PENDING rather than pretending it is settled.**

The app uses **no HealthKit** — `grep -rn 'import HealthKit' ios/` returns nothing.
**VERIFIED-BY-READING.**

### 2.1 Sensitive Info — asked, and answered **No**, with the evidence

*(Added by this pass. The first pass never raised the category, which is a gap: §2's argument —
"soliciting free text defeats 'we can't know what's in free text'" — reaches Apple's **Sensitive
Info** category by exactly the same route, through the same `entries.body` column.)*

Apple's *Sensitive Info* covers racial or ethnic data, sexual orientation, pregnancy, disability,
religious or philosophical beliefs, trade union membership, political opinion, genetic and
biometric data.

**VERIFIED-BY-READING.** `grep -niE 'doctor|hospital|sick|allergy|therapy|church|pray|faith|diagnos|
medic|ethnic|race|sexual|union|political|disab' api/seeds/prompts.yaml` returns **exactly one line**
— `:1389`, *"Trace {their} hand on paper and photograph it."* — and that is `race` matching inside
*"Trace"*. **The same grep over `docs/mission-library.md` — the authoring surface the YAML is
generated from — returns exactly one line too**, `:182`, the same "Trace" prompt. *(Added by this
pass: the first pass checked only the generated file, so a prompt authored but not yet regenerated
into `prompts.yaml` would not have shown up. It checked both now.)* **No seeded prompt, and nothing
in the library it is generated from, solicits anything in the Sensitive Info category.**

**Answer *No* to Sensitive Info.** The asymmetry with §2 is the point and is deliberate: there the
library asks for the thing by name, here it never does. What a parent volunteers unprompted into a
diary is the case Apple's own guidance treats as not-collected-by-design.

**One qualification, and it is INFERRED rather than verified.** *(Corrected: the first pass ended
this section with "this app has no mechanism that reads it," stated flatly. That sentence is broader
than either grep supports.)* The on-device extraction model **does** read whatever a parent wrote —
mood at `ios/Rascal/Rascal/Extraction/ExtractedDetails.swift:24`, tags at `:25`, a summary at `:26`
— and its output is persisted as `entry_tags`. It is not a sensitive-category classifier and nothing
asks it to be one, so the *No* stands; but "no mechanism reads the body" is not a true sentence about
this tree, and "no mechanism classifies the body into Apple's Sensitive Info categories" is the claim
that is actually being made. **Check: the `@Guide` descriptions in `ExtractedDetails.swift` read
against Apple's category list.**

---

## 3. FLAG — what an attorney has to answer, and this document cannot · **UNRESOLVED**

**Kept as its own section so it cannot be quietly folded into a category on the form.** These are
not questions about the tree. Reading more code does not settle any of them, and nothing downstream
of this document should record them as settled.

1. **Whether a service may hold, indefinitely, an identified minor's name, face, voice, DOB and a
   behavioural record, on a parent's authority alone**, when the app is not in the Kids Category and
   the minor has no account and no erasure control (§1). **Read
   `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md:49-53` and `docs/decisions.md:59` before
   this one is re-argued** *(added by this pass)*: COPPA is already out of scope by the owner's
   decision of Aug 16, 2026, with its reasoning recorded, and the handoff shape — shared access at a
   floor of 13 — is settled. Neither answers the question above. Both are its starting point.
2. **Whether "Linked to You" is an acceptable declaration when the "you" is not the subject** —
   i.e. whether the truthful label is available at all, and what the privacy policy must say
   instead (§1).
3. **Whether third-party names derived by an on-device model and persisted server-side are
   Contact Info → Name**, when those third parties have no relationship with the service (§1.1).
4. **Whether a seeded prompt that asks a parent to "Measure {their} height and weight" makes the
   resulting free text user-provided health data** for App Privacy purposes (§2).
5. **What retention promise, if any, the eighteen-year copy in `Info.plist:111` creates**, and
   what the child's rights against it are on their eighteenth birthday — including on the day the
   `decisions.md:59` handoff gives them their own row.
6. **Whether an access log containing a household identifier and a parent's search terms is
   retention** for the purposes of Apple's "collect" definition (§8.2) — a question about a
   definition, not about uvicorn.

**None of the above is answered here.** Items 1–5 also have a product half the owner decides; item
6 has a factual half that one log line settles (§8.2).

---

## 4. Tracking: **No**, for every data type — verified, not assumed

"Tracking" under ATT has a specific meaning: linking data from this app with third-party data for
targeted advertising or advertising measurement, or sharing it with a data broker. Checked
directly, and all six rows are **VERIFIED-BY-READING**:

| Check | Result |
|---|---|
| `AppTrackingTransparency` / `ATTrackingManager` | **Absent.** No match in any `.swift` or `.plist` under `ios/`. |
| IDFA — `advertisingIdentifier`, `ASIdentifierManager` | **Absent.** No match. |
| `NSUserTrackingUsageDescription` | **Absent** from `ios/Rascal/Info.plist` and every other plist. |
| `identifierForVendor`, `UIDevice.current` | **Absent.** No match anywhere in `ios/`. |
| Ad networks, attribution SDKs, data brokers | **None** — there are no third-party SDKs at all (§5). |
| Custom `User-Agent` or device fingerprint on API requests | **None.** See the correction below. |

**Correction to the first pass — "sets only" was false.** It claimed `APIClient` *"sets only
`Accept`, `Content-Type` and `Authorization`."* **VERIFIED-BY-READING**
`ios/Rascal/Rascal/Networking/APIClient.swift:201`, inside the very range that pass cited:

```swift
for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
```

That is an arbitrary caller-supplied header dictionary. It has one caller today —
`ios/Rascal/Rascal/Networking/RascalAPI.swift:70`, `headers: ["Idempotency-Key":
entry.idempotencyKey.uuidString]` — and the parameter defaults to `[:]` at `APIClient.swift:102`
and `:121`.

**The conclusion survives; the sentence did not.** Every header this app sets, enumerated by
`grep -rn 'setValue(.*forHTTPHeaderField\|addValue(.*forHTTPHeaderField' ios/Rascal/Rascal/`:

| Site | Header |
|---|---|
| `APIClient.swift:200` | `Accept: application/json` |
| `APIClient.swift:201` | caller-supplied dictionary — one caller, `Idempotency-Key` |
| `APIClient.swift:204` | `Content-Type: application/json` |
| `APIClient.swift:208`, `:132`, `ArchiveExport.swift:131` | `Authorization: Bearer …` |
| `APIClient.swift:264-265` | `Content-Type`, `Accept` on the token-refresh request |
| `GoogleSignIn.swift:321` | `Content-Type: application/x-www-form-urlencoded` |
| `AvatarSync.swift:47`, `Uploader.swift:141` | `Content-Type` on the S3 PUT |

**Not one is a device attribute.** No `User-Agent` is set, so URLSession's default is what goes out.

**Answer *No* to "Used for Tracking" on every data type.** The app has no mechanism by which it
could be otherwise.

---

## 5. Third-party SDKs: **there are none** — enumerated, not assumed

The brief warns that one transitive analytics SDK would invalidate the no-tracking position on the
marketing site. There is nothing to invalidate it. **Re-run against the current tree; every row is
VERIFIED-BY-READING.**

| Dependency channel | Finding |
|---|---|
| Swift Package Manager | **Zero.** `grep -c 'XCRemoteSwiftPackageReference\|XCLocalSwiftPackageReference\|packageReferences\|repositoryURL\|XCSwiftPackageProductDependency' ios/Rascal/Rascal.xcodeproj/project.pbxproj` prints **0**. |
| `Package.resolved` / `Package.swift` | **Do not exist** anywhere in the repository. |
| CocoaPods / Carthage | **Absent.** No `Pods/`, `Podfile`, `Cartfile` or `Carthage/`. |
| Linked binaries | **None.** All four `PBXFrameworksBuildPhase` blocks have empty `files = ( );` lists — `project.pbxproj:118-147`. |
| Vendored source / xcframeworks | **None.** `find` for `.framework`, `.xcframework` and `.a` across the repo returns nothing. |
| Linker escape hatches | **None.** `OTHER_LDFLAGS`, `FRAMEWORK_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS` and `HEADER_SEARCH_PATHS` appear **nowhere** in `project.pbxproj`. |

**The count is zero, which is what `ios/CLAUDE.md` rule 4 requires**: *"**No third-party
dependencies.** No SPM packages, no CocoaPods, no vendored source."*

**The complete list of modules imported anywhere in `ios/`**, from
`grep -rh '^import ' --include='*.swift' ios/ | sort -u` — **28 modules**, one more than the first
pass found:

> AuthenticationServices · AVFoundation · AVKit · CoreGraphics · CoreTransferable · CryptoKit ·
> Darwin · Foundation · FoundationModels · ImageIO · MediaAccessibility · Network · Observation ·
> OSLog · Photos · PhotosUI · **SafariServices** · Security · Speech · StoreKit · StoreKitTest ·
> SwiftData · SwiftUI · Testing · UIKit · UniformTypeIdentifiers · UserNotifications · WidgetKit

**The list is VERIFIED-BY-READING. That all 28 are Apple first-party is INFERRED.** *(Corrected by
this pass: the first pass wrote "Every module imported anywhere in `ios/` is Apple first-party" and
tagged the whole sentence VERIFIED-BY-READING. Reading `^import` lines proves *what* is imported, not
who publishes it. The inference is a short one — every dependency channel in the table above is
empty, so there is no route by which a third-party module could reach a build — but it is an
inference, and §10 now lists it as one.)*

**`SafariServices` is new in the uncommitted working tree** — `ios/Rascal/Rascal/DesignSystem/
SafariView.swift:1`, added by phase 124 so Terms and Privacy open *inside* the app for a guideline
3.1.2 reviewer instead of ejecting them to Safari. It is first-party, so rule 4 is not in play, and
the file says so itself at `:13`. Its privacy consequence is in §9.

`StoreKitTest` (`RascalTests/SubscriptionStoreKitTests.swift:3`), `Testing` and `Darwin`
(`RascalTests/ShareInboxTests.swift:2`) are test-target only.

**Google sign-in is hand-rolled rather than SDK'd**, and the file says why —
**VERIFIED-BY-READING** `ios/Rascal/Rascal/Onboarding/GoogleSignIn.swift:11-15`:
*"`ASWebAuthenticationSession` + PKCE rather than the GoogleSignIn SDK, and that was not a close
call. `ios/CLAUDE.md` rule 4 forbids SPM packages outright, so the SDK was never available; the
trade it would have bought — less code for one more dependency and a third-party privacy manifest —
is the wrong side of the trade for an app whose promise is that a child's record does not leave."*
The flow requests `openid email profile` and nothing else (`GoogleSignIn.swift:41`) and discards the
access token (`:346-354` — *"Only `id_token` is read. `access_token` is deliberately dropped on the
floor"*).

**Consequence: no third-party privacy manifests to collect, no SDK signatures to verify, and no
transitive collection to declare.** The marketing site's no-tracking position survives contact with
the tree.

---

## 6. The labels

Transcribe these. *Linked* = "Linked to You" in App Store Connect. *Tracking* is **No** on every row
(§4). Purposes use Apple's taxonomy. Every `file:line` in this section was re-opened at `d7ece87` by
the verification pass; the ones this correction pass changed are re-opened again and named in §10.

### Contact Info

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **Email Address** | Yes | App Functionality | Apple: `ios/…/Onboarding/WelcomeScreen.swift:76` — `request.requestedScopes = [.fullName, .email]`. Google: `ios/…/Onboarding/GoogleSignIn.swift:41` — `static let scope = "openid email profile"`. Magic link: `ios/…/Settings/CredentialsSheet.swift:158` — `TextField("you@example.com", text: $newAddress)`. Stored at `api/src/rascal/models/user.py:47`. |
| **Name** — the parent's | Yes | App Functionality | `WelcomeScreen.swift:76` (`.fullName`); reduced to nil-or-nonempty at `ios/…/Onboarding/AppleSignIn.swift:52-60`; stored at `api/src/rascal/models/user.py:48` (`display_name`). |
| **Name** — the child's | Yes | App Functionality | `ios/…/Onboarding/AddChildSheet.swift:26` (`@State private var name`), `:57` (`TextField("Their name", text: $name)`); stored at `api/src/rascal/models/child.py:20`. **See §1 — this is a name that is not the user's.** |
| **Name** — third parties named in an entry | **See §1.1 — UNRESOLVED** | — | Derived on device at `ios/…/Extraction/ExtractedDetails.swift:113-114`; persisted as `entry_tags` rows with `source = 'device_ai'` (`api/src/rascal/models/entry.py:184` — `__tablename__`, and `:196` — the `source` column) via `PATCH /media/{id}/derived` (`api/src/rascal/routers/media.py:124,134`). §6 files these under *Other User Content — tags* below; **whether Contact Info → Name is the right home is an open question for §3, not a decision this table makes.** |

**Private Relay addresses.** The app requests the `email` scope every time —
**VERIFIED-BY-READING** `WelcomeScreen.swift:72-76`, whose comment explains why: *"**Every time, not
just the first.** The client cannot know which authorization is the first one for this Apple ID, and
asking for a scope you did not request is not possible after the fact."* A parent who chooses *Hide
My Email* yields a `@privaterelay.appleid.com` address, which lands in the same `users.email` column
(`api/src/rascal/models/user.py:46-47`, whose comment reads *"Nullable on purpose: Apple relay
addresses are unreliable and may never arrive"*). **A relay address is still an email address for
labelling purposes** — it is stored and it is mailed to. Declare Email Address either way; the relay
does not exempt it.

### User Content

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **Photos or Videos** | Yes | App Functionality | Photos: `ios/…/Composer/MediaDraft.swift:62,67` → `ImagePipeline.process`. Video: `MediaDraft.swift:98` → `VideoPipeline.process`. Shared in: `ios/…/Share/ShareDrain.swift:265` (photo), `:285` (video). Child avatar: `ios/…/Onboarding/AvatarStep.swift:109,133`. Uploaded device→S3 by `ios/…/Media/Uploader.swift:141` and `ios/…/Onboarding/AvatarSync.swift:44-50`; keyed at `api/src/rascal/models/entry.py:137`. |
| **Audio Data** | Yes | App Functionality | `ios/…/Media/AudioPipeline.swift:179` — `AVAudioRecorder(url:settings:)`, AAC per `:29-30`. Staged by `MediaDraft.makeAudio`. |
| **Other User Content** — entry title and body, including sealed letters | Yes | App Functionality | `ios/…/Composer/ComposerView.swift:405` (`TextEditor(text: $text)`), `:441` (`TextField("Anything worth remembering", …)`). Stored at `api/src/rascal/models/entry.py:95-96`; seal age at `:99` (`unlock_at_age`). |
| **Other User Content** — on-device transcripts | Yes | App Functionality | Produced by `ios/…/Media/SpeechTranscription.swift:173` (`SpeechAnalyzer(modules: [transcriber])`, on device, offline — see `:6`). Persisted server-side via `PATCH /media/{id}/derived` (`api/src/rascal/routers/media.py:124,134`) → `api/src/rascal/models/entry.py:146`. |
| **Other User Content** — captions | Yes | App Functionality | `api/src/rascal/models/entry.py:147`. See the note below on caption provenance. |
| **Other User Content** — tags, human and model-extracted | Yes | App Functionality | Human: typed at `ios/…/Timeline/TagEditorSheet.swift:102` (`TextField("Kitchen table", text: $typed)`) and written at `:201` (`EntryTagWrite(name: $0, source: .user)`) *(corrected: the first pass labelled both lines `EntryTagWrite(name:, source: .user)`; only `:201` is)*. On-device model: `ios/…/Extraction/ExtractedDetails.swift:20` (`people`), `:22` (`place`), `:24` (`mood`), `:25` (`tags`), `:26` (`summary`), bounded to five tags at `:31`. Stored in `entry_tags` (`api/src/rascal/models/entry.py:184`) with a `source` column (`:196`) whose two values are `user` and `device_ai` (`api/src/rascal/constants.py:233`). **The `people` field is also §1.1.** |
| **Other User Content** — child profile: date of birth, pronouns | Yes | App Functionality | `ios/…/Onboarding/AddChildSheet.swift:27,28`; stored at `api/src/rascal/models/child.py:21,25`. **See §1.** |

*(Corrected: the first pass cited `ExtractedDetails.swift:19-25` for the five fields — line 19 is
comment text and `summary` is at `:26` — and `:29` for the tag limit, which is mid-comment. The
fields span `:20-26` and `static let tagLimit = 5` is at `:31`. All **VERIFIED-BY-READING**.)*

**On transcripts and captions — the important nuance for the label.** The *processing* is entirely
on-device: `SpeechTranscription.swift:4,6,173` uses Apple's `SpeechAnalyzer`, offline; the
extraction model is `FoundationModels`. **Neither sends audio or text to any server for inference.**
But the *output is persisted server-side and is durable data* — `CLAUDE.md` rule 7: *"On-device AI
output is durable data. `PATCH /media/{id}/derived` persists transcripts and captions written back
from the phone. The server never regenerates them."* The transcript is also indexed into a Postgres
search vector (`MEDIA_SEARCH_VECTOR`, `api/src/rascal/models/entry.py:53-56`, transcript at `:54`).
**So it is collected**, even though it was never processed off-device. Declare it.

*(Corrected: the first pass said "`ExtractionQueue` uses `FoundationModels`." It does not —
`ios/Rascal/Rascal/Extraction/ExtractionQueue.swift:1-3` imports only `Foundation`, `OSLog` and
`SwiftData`, and `grep -n 'FoundationModels\|LanguageModelSession\|SystemLanguageModel'` on that
file returns nothing. The framework is imported at `ExtractedDetails.swift:4` — inside
`#if canImport(FoundationModels)` — and at `ios/…/Personalization/PromptPersonalization.swift:4`,
and the sessions are created at `ExtractedDetails.swift:168` and `PromptPersonalization.swift:77`.
The label conclusion is unaffected; the citation was wrong.)*

**On captions specifically:** `ios/Rascal/Rascal/Captions/CaptionProbe.swift` is a *diagnostic, not
a pipeline* — `:17` says it *"writes nothing, uploads nothing, and persists nothing"* and `:11` says
it reads only the existing XMP field `Iptc4xmpExt:AOContentDescription` from photos already on the
phone. The `media.caption` column exists and is writable through the API, so the data type is
declarable; but on today's tree the iOS app has no caption *writer*. Declare it if you intend to
ship one; it is honest either way, and over-declaring is the safer error.

### Health & Fitness — **DECISION PENDING, see §2**

| Data type | Linked | Purpose | Where |
|---|---|---|---|
| **Health** — child height and weight, as free text | Yes | App Functionality | Solicited by `api/seeds/prompts.yaml:1351-1355` (one of three `measurement` prompts; the other two, `:1363` and `:1386`, ask for photographs only). Its own `completion_mode` is `media` (`:1353`). Numbers, if a parent writes them, land in `api/src/rascal/models/entry.py:96` (`body`). No structured column exists. **The landing is INFERRED, not verified — see §2.** |

### Sensitive Info — **No**, see §2.1

### Identifiers

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **User ID** | Yes | App Functionality | Server-minted `users.id` UUID. Provider subjects: `api/src/rascal/models/user.py:141` (`subject_id`) — Apple's stable subject and Google's `sub`. The Apple subject is also kept on-device at `ios/…/Onboarding/AppleSignIn.swift:169-181` (`UserDefaultsAppleUserIDStore`, key `session.appleUserID` at `:173`) so a later launch can call `getCredentialState`. |
| **Device ID** — APNs push token | Yes | App Functionality | Hex-encoded at `ios/…/Push/PushRegistrar.swift:71`; cached locally under key `push.deviceToken` (`:37`); registered by `ios/…/Networking/DevicesAPI.swift:18-28` (`POST /v1/devices`); stored at `api/src/rascal/models/device.py:59-61` with `platform` and `environment`. Revoked on sign-out (`DevicesAPI.swift:37-43`). |

The APNs token is **not** an advertising identifier and is used for one thing: delivering the daily
prompt notification. Purpose is App Functionality, not Advertising.

### Purchases

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **Purchase History** | Yes | App Functionality | **The client never uploads a receipt** — no `appStoreReceiptURL` and no `jwsRepresentation` is sent anywhere in `ios/Rascal/Rascal/`. `ios/…/Subscription/SubscriptionStore.swift:107` — `result = try await product.purchase(options: [.appAccountToken(familyID)])` — is the only linkage the device creates. Apple's server-to-server notification populates `api/src/rascal/models/app_store.py:45` (`AppStoreTransaction`, `original_transaction_id` PK at `:61`, `family_id` at `:68`). |

Declare it. The data reaches the developer and is linked to the account, which is what the question
asks — the fact that it arrives via Apple's webhook rather than the device does not exempt it. Note
that the server stores the *decoded* payload rather than the JWS, deliberately (`app_store.py:24`).

Phase 125's `restore()` path (`ios/…/Subscription/SubscriptionModel.swift:476-528` — *corrected from
`:476-513`, which is one line inside the function, not its end*) reaches `AppStore.sync()` through
`SubscriptionStore.restore()` (`ios/…/Subscription/SubscriptionStore.swift:152`) and adds no new
collection: it asks Apple what this Apple ID already owns and re-reads the server's own entitlement.

### Search History — **verify §8.2 before answering**

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **Search History** | Yes (if declared) | App Functionality | `ios/…/Timeline/TimelineSearchModel.swift:160-165` sends the typed query to `GET /v1/entries?q=` *(corrected from `:158-164`; the `api.entries(…)` call opens at `:160` and closes at `:165`)*; received at `api/src/rascal/routers/entries.py:117` (`q: str | None = Query(`). |

**Search is server-side, not local** — `TimelineSearchModel.swift:20` says so directly: *"rank is the
server's answer and only the server has it."* So the query text leaves the device on every keystroke
batch. Under Apple's definition, transmitting data to service a request *in real time* is not
"collection" — **but retaining it is**, and §8.2 is an open question about exactly that.

### Usage Data

| Data type | Linked | Purpose | Where collection happens |
|---|---|---|---|
| **Product Interaction** | Yes | App Functionality **and Analytics** | `api/src/rascal/models/user.py:85` — `last_sign_in_at`; assignment completion state in `assignments`; `notification_sends` ledger — `api/src/rascal/models/device.py:74` (`class NotificationSend`). |

**Why "Analytics" belongs on this row and not only "App Functionality."** These records exist for
functional reasons — `last_sign_in_at` drives D3's deletion-eligibility arithmetic, the assignment
state drives the Today board. But they are *also* read by the admin console's growth and engagement
dashboards (`api/src/rascal/services/admin_metrics.py`, `top_themes` at `:487`). That is product
analytics by any honest reading, even though it is first-party and self-hosted. **Tick both
purposes.** Judgment call, flagged in §10.

To the module's credit, it is written to a strict rule (`admin_metrics.py:3`): *"**The rule this
module is written to, and the only one that matters: counts, never content.** … Nothing here selects
`entries.title`, `entries.body`, `media.caption`, `media.transcript`, a child's name, or an
`s3_key`."* The one exception is deliberate and documented — `recent_signups` (`:528`, rationale at
`:531-534`) returns the account email, *"because a support conversation starts with one."* That does
not change the label; it is worth knowing.

### Other Data

| Data type | Linked | Purpose | Where |
|---|---|---|---|
| **Other Data Types** — notification preference and delivery time | Yes | App Functionality | `api/src/rascal/models/user.py:60` (`notify_enabled`), `:65` (`notify_local_time`). |
| **Other Data Types** — household timezone | Yes | App Functionality | `ios/…/Onboarding/AddChildSheet.swift:29` (`@State private var timezone`), `:42` (`TimeZoneCatalog.deviceZone` default), `:119` (`TimeZonePickerSheet`); stored at `api/src/rascal/models/child.py:29`. **See §8.3 — this is deliberately *not* filed under Location, and the reasoning is written down.** |

### Diagnostics — **nothing to declare**

| Data type | Collected? |
|---|---|
| Crash Data | **No.** |
| Performance Data | **No.** |
| Other Diagnostic Data | **No.** |

**VERIFIED-BY-READING:** no Crashlytics, Sentry, Firebase, Amplitude, Mixpanel, Segment, PostHog,
MetricKit or `MXMetricManager` anywhere in `ios/`. The app's only logging is `OSLog`, which writes
to the device's own log store and transmits nothing. The API's logging is one JSON object per line
to stdout (`api/src/rascal/logging_config.py:1`) and receives nothing from the client.

**On Xcode Organizer / TestFlight crash reports:** those are collected by *Apple*, require the user
to have opted into sharing with developers in iOS Settings, and are conventionally not declared as
developer collection. **Recommendation: do not declare Crash Data.** Flagged in §10 as a convention
rather than a certainty — if you would rather be conservative, declaring it costs nothing.

---

## 7. Privacy Manifest — **`PrivacyInfo.xcprivacy` does not exist anywhere in this repository**

**VERIFIED-BY-READING.** `find /Users/travis/repos/personal/Project-Rascal -iname '*xcprivacy*'`
returns **zero results**, re-run against the current working tree. Not in the app target, not in
either extension, not in the test target, not anywhere in `api/` or `docs/`.

**This will block or flag an App Store upload.** — **INFERRED** from Apple's published policy: since
spring 2024, an upload that uses a required-reason API without a manifest declaring it draws an
`ITMS-91053: Missing API declaration` notice. Nothing in this repository proves what App Store
Connect will do; the API usage below is what is verified. There are no third-party SDKs to collect
manifests from (§5), so the entire obligation is the app's own — which makes it a small,
self-contained piece of work.

### Which required-reason APIs the app actually uses

All five categories the brief names, re-checked one at a time against the current tree:

| Category | Used? | Evidence |
|---|---|---|
| **`NSPrivacyAccessedAPICategoryUserDefaults`** | **YES** | **VERIFIED-BY-READING — 16 files** in the app target. Reproduce with `grep -rn 'UserDefaults' --include='*.swift' ios/Rascal/Rascal/ \| grep -v '///' \| awk -F: '{print $1}' \| sort -u`. Full list below. |
| **`NSPrivacyAccessedAPICategoryFileTimestamp`** | **YES — on exactly one line** | **VERIFIED-BY-READING** `ios/Rascal/Rascal/Media/StagingStore.swift:124` — `(try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil`. **That is the only app-target file-timestamp read in `ios/`.** |
| **`NSPrivacyAccessedAPICategoryDiskSpace`** | **No** | No `volumeAvailableCapacity`, `systemFreeSize` or `attributesOfFileSystem` anywhere in `ios/`. |
| **`NSPrivacyAccessedAPICategoryActiveKeyboards`** | **No** | No `activeInputModes` or `UITextInputMode` anywhere in `ios/`. |
| **`NSPrivacyAccessedAPICategorySystemBootTime`** | **No** | No `systemUptime`, `kern.boottime`, `mach_absolute_time` or `CACurrentMediaTime` anywhere in `ios/`. |

**The 16 UserDefaults files**, verbatim from the command above:

```
Rascal/App/AppEnvironment.swift              Rascal/Onboarding/OnboardingGate.swift
Rascal/App/RootView.swift                    Rascal/Onboarding/SelectedChildStore.swift
Rascal/Backfill/BackfillScan.swift           Rascal/Push/NotificationPreference.swift
Rascal/Backfill/BackfillScanner.swift        Rascal/Push/PushRegistrar.swift
Rascal/Networking/UserRecordStore.swift      Rascal/Subscription/MembershipPresentation.swift
Rascal/Onboarding/AppleSignIn.swift          Rascal/Sync/SyncCursorStore.swift
Rascal/Onboarding/AvatarSync.swift           Rascal/Today/TodayScreen.swift
Rascal/Onboarding/AvatarUpload.swift
Rascal/Onboarding/OnboardingDraft.swift
```

Representative keys: `session.appleUserID` (`AppleSignIn.swift:173`), `push.deviceToken`
(`PushRegistrar.swift:37`), `backfill.dismissedMonths` (`BackfillScan.swift:215`),
`avatar.pendingUploads` (`AvatarUpload.swift:124`), `membership.presentation`
(`MembershipPresentation.swift:54` — new in the uncommitted phase-125 work, and explicitly local
presentation state per `:5-8`).

**Correction to the first pass — five of its six FileTimestamp citations were not timestamps.**
It listed `ArchiveExport.swift:153`, `ShareInbox.swift:216`, `StagingStore.swift:115`,
`AudioPipeline.swift:355` and `VideoPipeline.swift:68` alongside `StagingStore.swift:124`, in a
column headed "Evidence." **VERIFIED-BY-READING: all five read `[.size]`, not a timestamp.**
`NSFileSize` is not on Apple's file-timestamp required-reason symbol list; `NSFileModificationDate`
is. **The category conclusion stands on `StagingStore.swift:124` alone** — one line, which is
enough, and it is better to know that than to think six lines support it.

**Other `creationDate` occurrences exist and none is a file-system timestamp — enumerated in full
this time.** *(Corrected: the previous version said "Three further `creationDate` reads exist" and
then listed four citations, and its list was not exhaustive.)* `grep -rn 'creationDate'
--include='*.swift' ios/` returns **21 lines outside `RascalTests/`**, in three groups:

- **Framework metadata reads — 4 lines.** `VideoPipeline.swift:67` and
  `RascalShare/ShareItemLoader.swift:155` read `AVAsset.creationDate` (asset metadata);
  `BackfillScanner.swift:378,447` read `PHAsset.creationDate` (Photos framework).
- **Photos fetch-option strings — 4 lines.** `BackfillScanner.swift:365,433` and
  `CaptionProbe.swift:79` pass `"creationDate"` to an `NSSortDescriptor`, and
  `BackfillScanner.swift:430` uses it in an `NSPredicate` format string. These are Photos queries,
  not reads of anything on disk.
- **This app's own value, carried around — 13 lines.** `BackfillAsset.swift:15,36` declare
  `BackfillAsset.creationDate` and derive from it; `BackfillEntryPlan.swift:24,26,31`,
  `BackfillDate.swift:152,156`, `BackfillScanner.swift:34,198,353` and its comment at `:411`, and
  `BackfillMonthPickerScreen.swift:411,468` pass that property or the `creationDates()` function
  around. No framework call at all.

**None of the 21 is on Apple's required-reason symbol list.**
`RascalTests/WidgetSnapshotWriteTests.swift:271,278` do read `[.modificationDate]`, but a unit-test
bundle is not submitted.

### The reason codes that fit

- **UserDefaults → `CA92.1`** — *"access information from the same app, or from the app's App Group
  container."* Correct here: every use is the app's own defaults, and the App Group
  (`group.com.travisterry.childarchive`, present in all three entitlements files —
  `Rascal.entitlements:30`, `RascalShare.entitlements:21`, `RascalWidget.entitlements:9`, wired at
  `project.pbxproj:429,586,620,652,722,754`) is shared only with this app's own widget and share
  extension. **Not** `1C8F.1` (third-party SDK) or `C56D.1` (app group shared with other developers'
  apps). Reason-code selection is **INFERRED** from Apple's published descriptions.
- **File timestamp → `DDA9.1`** — *"access the timestamps of files inside the app container, app
  group container, or the app's CloudKit container."* Correct: `StagingStore` operates inside the
  app's own container, and `:118-122` says exactly why the timestamp is read — *"Used by the sweep
  to tell debris from a take somebody is still holding."* **Not** `C617.1`, which is for displaying
  a timestamp to the user. Also **INFERRED** from Apple's descriptions.

### What the manifest also needs

- `NSPrivacyTracking` → `false` (§4).
- `NSPrivacyTrackingDomains` → empty array.
- `NSPrivacyCollectedDataTypes` → **must agree with what is typed into App Store Connect.** Two
  sources of truth that disagree is the failure mode here; derive both from this document.

### Placement — **corrected, and the correction cuts both ways**

There are four native targets: `Rascal` (`com.apple.product-type.application`), `RascalShare` and
`RascalWidget` (both `com.apple.product-type.app-extension`), and `RascalTests`
(`com.apple.product-type.bundle.unit-test`) — `project.pbxproj:199-284`, the `PBXNativeTarget`
section *(corrected from `:198-283`; line 198 is blank and the section runs 199–284)*.

**The first pass justified per-extension manifests by claiming the extensions compile the same
shared source files that use `UserDefaults` and file timestamps. Half of that is true and the half
that matters is not.**

**They do compile app-target files — VERIFIED-BY-READING.** Each target has one
`fileSystemSynchronizedGroups` entry pointing at its own folder (`project.pbxproj:215-217, 235-237,
256-258, 276-278`), but the project *also* carries an explicit `Shared` `PBXGroup`
(`project.pbxproj:175-196`, fifteen children — *corrected from `:172-193`, which is the tail of the
`Products` group*) whose `PBXFileReference` entries point **into the app target's folder** — e.g.
`project.pbxproj:84`, `path = Rascal/Media/ImagePipeline.swift`; `:87`,
`path = Rascal/Share/ShareInbox.swift`; `:72`, `path = Rascal/Widget/WidgetSnapshotStore.swift`.
Those files appear in the extensions' `PBXSourcesBuildPhase` blocks — the whole
`PBXSourcesBuildPhase` section is `project.pbxproj:357-403`:

- **RascalWidget** (`project.pbxproj:365-379`, files at `:369-376` — *corrected from `:130-142`,
  which is inside `PBXFrameworksBuildPhase`*) compiles `Palette.swift`, `Typography.swift`,
  `WidgetSnapshot.swift`, `WidgetSnapshotStore.swift`, `WidgetDeepLink.swift`, `PromptText.swift`,
  `WidgetNarration.swift`, `WidgetTimelinePlan.swift`.
- **RascalShare** (`project.pbxproj:387-402`, files at `:391-399` — *corrected from `:150-162`,
  which is the root `PBXGroup`'s children list*) compiles `Palette.swift`, `Typography.swift`,
  `Layout.swift`, `Motion.swift`, `ImagePipeline.swift`, `PendingShare.swift`, `ShareInbox.swift`,
  `Formatting.swift`, `ShareCopy.swift`.

*(Both file lists were right in content — eight and nine files — and only the line ranges were
wrong. That is the worse failure of the two, because the section's argument rests on those blocks
and a reader checking the argument would have found the wrong part of the file.)*

**But none of those shared files, and nothing in either extension's own folder, uses a
required-reason API — VERIFIED-BY-READING.** `grep -n 'UserDefaults'` across all fifteen
shared-compiled files returns nothing. `grep -rn 'UserDefaults\|attributesOfItem\|modificationDate\|
creationDate' ios/Rascal/RascalShare/ ios/Rascal/RascalWidget/` returns exactly one line —
`RascalShare/ShareItemLoader.swift:155`, an `AVAsset.creationDate` read, which is not on the list.
The one `attributesOfItem` call the extensions do compile, `ShareInbox.swift:216`, reads `[.size]`.

**So: the app target `Rascal` needs a manifest. Neither extension needs one today.** The
conservative choice of shipping one per extension anyway is still defensible — but as
future-proofing against a shared file gaining a `UserDefaults` read, not because they use one now.
And that risk is *real* rather than theoretical precisely because the sharing above exists: a
required-reason API added to `ImagePipeline.swift` would silently enter `RascalShare` with no
project-file change to notice.

**Writing the manifest is not part of this phase** (Part 2 is report-only). It should be its own
iOS-lane phase, and this section is the specification for it.

---

## 8. Three things to resolve before transcribing

### 8.1 Video may carry a GPS location into the archive — photos verifiably do not

This is the one place the two media paths behave differently, and the difference decides whether
**Location** appears on the label at all.

**Photos: metadata is dropped. VERIFIED-BY-READING the encode call.**
`ios/Rascal/Rascal/Media/ImagePipeline.swift:189-191` writes the JPEG with a properties dictionary
containing exactly one key:

```swift
CGImageDestinationAddImage(destination, image, [
    kCGImageDestinationLossyCompressionQuality: quality,
] as CFDictionary)
```

No source metadata dictionary is copied. The image is redrawn through a `CGContext` first
(`withoutAlpha`, `:165-178`), so what is encoded is decoded pixels, not the original file. **The
EXIF GPS block cannot survive that.** The only EXIF the pipeline deliberately *keeps* is the capture
date, and it keeps it as a separate `Date` value rather than in the file
(`exifDate(from:)`, `ImagePipeline.swift:201-214`; `exifDate(fileAt:)`, `:216-221`) — *corrected
from `:201-215` and `:217-222`; the first range ran one line past the closing brace and the second
started one line late, on a blank.*

**Note this is a side effect, not a guarded invariant. VERIFIED-BY-READING:** no test pins it.
`ios/Rascal/RascalTests/ImagePipelineTests.swift` asserts orientation on pixels at `:129-135`
(`#expect(processed.pixelWidth == 20, "a baked rotation swaps the stored dimensions")` and
`#expect(tag == nil || tag == 1, "got \(tag ?? 0): a residual tag double-rotates")`) — *corrected
from `:13`, which is the suite's doc comment saying orientation "is asserted on the *pixels*, not on
metadata," not an assertion* — and EXIF date parsing at `:151-180`; nothing asserts that metadata is
stripped, and nothing in `ImagePipeline.swift` says "do not copy metadata here." A future change that
passes source properties through to preserve, say, colour profile would silently begin uploading GPS
coordinates. **Worth a one-line test and a comment**, in whatever phase next touches that file.

**Video: metadata is never explicitly cleared. VERIFIED-BY-READING.**
`ios/Rascal/Rascal/Media/VideoPipeline.swift:55-63` constructs an `AVAssetExportSession` and sets
`outputURL` (`:58`), `outputFileType = .mp4` (`:59`) and `shouldOptimizeForNetworkUse` (`:62`), then
exports at `:64`. **`session.metadata` is never assigned** — `grep -n metadata
ios/Rascal/Rascal/Media/VideoPipeline.swift` returns nothing at all. The file's only interest in the
source asset's metadata is reading one value *out* (`:67`, `asset.load(.creationDate)`).

**INFERRED, not verified:** AVFoundation's documented behaviour when `AVAssetExportSession.metadata`
is nil is to pass the source asset's metadata through to the output where the output format supports
it. An iPhone video recorded with Location Services enabled carries
`com.apple.quicktime.location.ISO6709` — a precise latitude/longitude. If that atom survives the
`.mov` → `.mp4` conversion, **the archive is storing precise location for every video, and
Location → Precise Location must be declared.**

**This must be settled by measurement, not by reading.** It cannot be settled from the source, and
no pass over this document ran a build or a device. The check is small:

1. Record a video in-app on a device with Location Services on for the camera.
2. Let it upload.
3. Run `exiftool` (or `ffprobe -show_format`) over the resulting MP4 and look for a location atom.

**Until that is done, do not tick "no Location" with confidence.** If the atom survives, the right
fix is one line in `VideoPipeline` setting `session.metadata = []` — and that is an iOS-lane change,
not a labelling decision.

### 8.2 Search queries and child ids are almost certainly landing in the server's access log

**VERIFIED-BY-READING:** `api/Dockerfile:72` starts the server as

```
CMD ["uvicorn", "rascal.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
```

with **no `--no-access-log` flag**, and no request-logging middleware of the project's own — the only
middleware installed is `CORSMiddleware` (`api/src/rascal/main.py:70`), and
`api/src/rascal/logging_config.py` is a formatter only (`:1` — *"Structured logging. One JSON object
per line, which is all the observability P0 gets."*).

**VERIFIED-BY-READING:** the search term is a query parameter (`api/src/rascal/routers/entries.py:117`
— `q: str | None = Query(`), and so is the child id (`api/src/rascal/deps.py:268` — `child_id:
Annotated[uuid.UUID, Query(description="The child whose data to read.")]`).

**INFERRED:** uvicorn's access log is enabled by default and writes the full request line including
the query string. If so, every search produces a retained log line of the shape
`GET /v1/entries?child_id=<uuid>&q=<what the parent typed> HTTP/1.1`, held for whatever the
platform's log retention is.

**Why this matters for the label:** Apple's definition of "collect" excludes data transmitted only
to service a request in real time. A retained access log is retention, and it would move **Search
History** from *not collected* to *collected and linked* (the line carries a child id, which
identifies a household). Whether that is the right reading of Apple's definition is §3's sixth
question.

**Adjacent finding, outside App Privacy but worth the owner knowing now.** The same mechanism
applies to the magic-link sign-in URL. The app claims the path `/signin` with the token in the query
string (`ios/…/Onboarding/SignInLink.swift:31` — `static let path = "/signin"`; `:45` — the `token`
query item), and the API serves it at
**`api/src/rascal/routers/wellknown.py:105-106`** — `@router.get("/signin",
response_class=HTMLResponse, …)` / `async def signin_landing()`. *(Corrected: the first pass cited
`api/src/rascal/main.py:53`, which is a string literal inside the FastAPI `description=` blob, not a
handler.)* If access logging is on as inferred, **a raw, unhashed, still-valid sign-in credential is
being written to stdout logs.** The database is careful here — `GuardianInvite` stores only a
SHA-256 (`api/src/rascal/models/family.py:137`: *"**Only the SHA-256 is stored**, the rule
`refresh_tokens` and `email_sign_in_tokens` already follow"*) — so the log would be the one place
the raw value survives. **This is an API-lane concern and is reported, not acted on.** It deserves
its own phase and probably `docs/blocked.md` if it turns out to be real.

**Resolve 8.2 by checking one production log line.** That is a two-minute check and it settles both
findings at once.

### 8.3 The household timezone — a judgment call, made explicit rather than silently

The app collects an IANA timezone for each child, defaulted from the device
(`ios/…/Onboarding/AddChildSheet.swift:42` — `TimeZoneCatalog.deviceZone`) and stored at
`api/src/rascal/models/child.py:29`. It has a real functional purpose, and the column's own comment
says it: *"IANA, e.g. America/Detroit. The scheduler's definition of 'today' — without it the 5am
job hands you tomorrow's mission at 9pm."* `CLAUDE.md` rule 1 is the same rule.

**This document files it under Other Data, not Location.** The reasoning, written down so it can be
argued with: Apple's Location category covers data obtained through location services, and *Coarse
Location* is defined at roughly a three-square-kilometre resolution. A timezone is orders of
magnitude coarser and is a user-editable setting (there is a picker — `AddChildSheet.swift:119`), not
a device location reading. Filing it under Location would over-declare in a way that misleads
readers about what the app does.

**It is a judgment call, and a reasonable person could file it differently.** Recorded here so the
decision is visible rather than invisible, and listed in §10.

---

## 9. What is *not* collected — the negative findings, which are load-bearing

These took as much reading as the positive ones and are worth keeping, because next year somebody
will ask. All **VERIFIED-BY-READING** against the current working tree.

- **No location APIs.** `CoreLocation` is imported nowhere in `ios/`. No `CLLocationManager`. The
  only `.location` match in the whole tree is `value.location.x` in a SwiftUI drag gesture
  (`Timeline/VideoPlayback.swift:198`).
- **No contacts access.** `Contacts` / `ContactsUI` imported nowhere. The guardian invite is a
  shareable one-time link (`ios/…/Settings/GuardiansModel.swift:78-96`), never an address-book read.
- **The photo-library scan does not upload anything.** `BackfillScanner` reads asset *creation dates
  and counts* to suggest months worth writing about; the individual photos are not identified until a
  parent opens a month (`Backfill/BackfillScanner.swift:41-43` — *"identifying individual photos is a
  different act from counting them, and it does not happen until someone has chosen to look"*). Only
  dismissed months persist, in local UserDefaults (`Backfill/BackfillScan.swift:209-215`). The
  Info.plist string says the same thing to the parent (`ios/Rascal/Info.plist:109`): *"The pictures
  themselves stay on your phone — nothing is uploaded, and nothing is added to the archive unless you
  pick it."* **This is accurate.**
- **No health framework.** No `import HealthKit` anywhere.
- **No financial data.** All payment handling is StoreKit; no card details ever reach this app or its
  server. `AppStoreTransaction` holds Apple's decoded notification, not payment instruments.
- **No advertising anything.** No ad SDK, no IDFA, no attribution, no `NSPrivacyTrackingDomains`
  candidates.
- **Access tokens are keychain-stored, not UserDefaults** (`Networking/TokenStore.swift:11`,
  `:28` — `KeychainTokenStore`, `:90` — `kSecClassGenericPassword`). The Apple subject id *is* in
  UserDefaults, deliberately, and the file gives the reason (`AppleSignIn.swift:160-161`): *"the
  token is the secret, and an opaque provider subject is not."*
- **The name Apple sends once is held in memory only** — `AppleSignIn.swift:72-73`: *"**In memory
  only.** A lost name is acceptable; a child's parent's name sitting in UserDefaults or the keychain
  to survive a process death is not."*
- **`Browsing History`: not collected — but there are now two in-app web surfaces, not one.**
  *(Updated for the current tree. The first pass said "the only web view is the OAuth sheet," which
  was true before the uncommitted phase-124 work and is not true now.)*
  1. The Google OAuth sheet — `ASWebAuthenticationSession`, showing Google's own page.
  2. **`SFSafariViewController`, new**, presented from two places: the paywall's legal row
     (`ios/…/Subscription/PaywallSheet.swift:95` — `SafariView(url: page.url)`; `:528` —
     `legalLink("Terms of Use", to: terms)`; `:531` — `legalLink("Privacy Policy", to: privacy)`;
     `:556` — the `legalLink` definition; the row itself is `legalRow` at `:479`) and Settings'
     *About* section (`ios/…/Settings/SettingsScreen.swift:277,615,621`), through the wrapper at
     `ios/…/DesignSystem/SafariView.swift:18-36`. *(Corrected: the first pass cited
     `PaywallSheet.swift:95,532,535,560` — `:532` and `:535` are bare closing braces and `:560` is
     `Text(title)`. Only `:95` resolved.)* It opens only two URLs, both this product's own,
     both configured out of `ios/Rascal/Config.xcconfig:86-87` (`TERMS_URL`, `PRIVACY_URL` →
     `getvellumapp.com/terms` and `/privacy`) and read through Info.plist at
     `PaywallSheet.swift:720`, with a `url.host()` guard at `:728` and an `https`/`http` scheme guard
     at `:739` *(corrected from the range `:726-745`, which ran past the end of `LegalLinks` into
     `#if DEBUG`)* so an unset key renders as an *absent* row rather than a dead one.
  **Still No — INFERRED from framework behaviour**, on the standard grounds: `SFSafariViewController`
  runs out of process and the host app cannot observe navigation, read its cookies, or inject script,
  so no browsing data reaches this developer through it. Worth one honest note for whoever writes the
  privacy policy: fetching those two pages does put the reader's IP in the *marketing site's* server
  logs, which is that site's own collection and not the app's.

---

## 10. Verification honesty

**No pass over this document ran a build or a test.** No `xcodebuild`, no `swift build`, no `pytest`,
no simulator, no device, no network call, no `exiftool`, no `ffprobe`, no log inspection, no App
Store Connect session. **Every pass read code and read nothing else.** Where that is not enough, §8
says so rather than guessing.

**Provenance.** Aug 26, 2026. Branch `ios/phase-124-submission-compliance`, commit `d7ece87`
(*"Merge pull request #173 from travist6983/api/phase-127-siwa-revocation"*) — re-checked with
`git rev-parse HEAD` by this pass rather than carried forward. **Working tree dirty: `git status
--porcelain` returns 16 paths**, the sixteen listed in the header.

**Corrected, and it matters more than a number.** The header and this section previously said *"the
ten files listed in the header"* and listed ten, omitting all five modified `docs/` files
(`blocked.md`, `decisions-log.md`, `design/design-conformance-110.md`, `design/free-tier-copy.md`,
`roadmap-status.md`) and `RascalTests/MembershipTests.swift`. A document whose stated method is
reading against the tree as it stands cannot be wrong about what the tree is.

**And the tree moved mid-pass.** `git status --porcelain` returned **15** at the start of this
correction pass and **16** at the end — `ios/Rascal/RascalTests/MembershipTests.swift` became
modified in between, so another session is editing this same working tree. Nothing in this document
cites that file, and no citation checked below changed under it; but the same concurrency is why
every line number here is stamped with a commit and a pass rather than presented as durable.

**What was actually re-read, and by which pass.** This is the third pass over this document, and the
three do not have the same coverage. **Do not read a VERIFIED-BY-READING tag as "re-opened by the
pass that most recently edited this file."**

- **Pass 2** — the corrected second pass, which wrote most of the prose above — opened the lines it
  cites.
- **The verification pass** re-resolved **every** `file:line` in the document against `d7ece87` and
  reported which ones did not resolve. Its findings are the reason this pass exists.
- **This correction pass re-opened only the lines it corrected**, the lines it had to read to derive
  each correction, and the citations living in files another session is editing right now. **It did
  not re-open every citation in this document and does not claim to have.** The files it opened or
  grepped are: `ios/Rascal/Rascal.xcodeproj/project.pbxproj`, `Subscription/PaywallSheet.swift`,
  `Subscription/SubscriptionModel.swift`, `Subscription/SubscriptionStore.swift`,
  `Onboarding/AvatarStep.swift`, `Media/ImagePipeline.swift`, `RascalTests/ImagePipelineTests.swift`,
  `Timeline/TimelineSearchModel.swift`, `Timeline/TagEditorSheet.swift`,
  `Backfill/BackfillMonthPickerScreen.swift`, `Settings/SettingsScreen.swift`,
  `DesignSystem/SafariView.swift`, `ios/Rascal/Config.xcconfig`,
  `api/src/rascal/models/entry.py`, `docs/decisions.md`,
  `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md`, `docs/mission-library.md`, plus repo-wide
  greps for `creationDate`, `^import`, `restoreFound` and the COPPA / Kids-Category terms.

**Verified by reading, across the three passes:** the complete absence of `*.xcprivacy` repo-wide;
the four empty `PBXFrameworksBuildPhase` file lists; the zero count for every
SPM/CocoaPods/Carthage/vendored-binary channel; the `Shared` `PBXGroup` and both extension
`PBXSourcesBuildPhase` blocks; the 28-module import list; the absence of ATT, IDFA, `UIDevice`,
`identifierForVendor`, CoreLocation, HealthKit, Contacts, MetricKit and every named analytics or
crash SDK; all five required-reason API searches in §7 and the 16-file UserDefaults list; the photo
encode call's one-key properties dictionary and the absence of any metadata-stripping test; the
absence of any `session.metadata` assignment in `VideoPipeline`; the uvicorn `CMD` line and the
absence of a `--no-access-log` flag; the `/signin` handler in `wellknown.py`; the three
`measurement` prompts and the one that asks for numbers; the Sensitive Info greps over both
`prompts.yaml` and `mission-library.md`; and the API model columns for users, credentials, children,
entries, media, tags, devices, deletion requests and app-store transactions.

**Inferred, and labelled as such at every point of use** — eight claims, none of which should be
repeated as fact without the check named beside it:

1. That `AVAssetExportSession` passes source metadata through when `.metadata` is nil, and therefore
   that video *may* carry a GPS atom into S3 (§8.1). **Check: `exiftool` on one uploaded MP4.**
2. That uvicorn's default access log is enabled and records query strings, and therefore that search
   terms and child ids are retained in logs (§8.2). **Check: one production log line.**
3. That a raw magic-link token consequently appears in those same logs (§8.2, adjacent finding).
   **Same check.**
4. That a parent answering the measurement prompt writes height and weight into `entries.body`
   (§2). It is a prediction about behaviour, and the prompt's own `completion_mode` is `media`.
   **Check: none available from the tree — this is a product question.**
5. That a missing manifest draws `ITMS-91053`, and that `CA92.1` and `DDA9.1` are the right reason
   codes (§7). **Check: Apple's current required-reason API documentation, and one upload.**
6. That `SFSafariViewController` exposes no browsing data to the host app (§9). **Check: Apple's
   documentation; it is standard framework behaviour, not something this tree proves.**
7. **That all 28 imported modules are Apple first-party (§5)** — *added by this pass; the first pass
   tagged it VERIFIED-BY-READING.* Reading `^import` lines proves what is imported, not who
   publishes it. **Check: the dependency-channel table in §5 is the supporting evidence — every
   channel is empty — but the provenance of a module name is not something a grep establishes.**
8. **That nothing in the app classifies free text into Apple's Sensitive Info categories (§2.1)** —
   *added by this pass; the first pass wrote the broader "this app has no mechanism that reads it,"
   which is false, because the on-device extractor does read the body.* **Check: the `@Guide`
   descriptions in `ExtractedDetails.swift` against Apple's category list.**

**Not derivable from this tree at all**, and stated nowhere in it as fact: whether the app is in the
Kids Category or what age rating it carries (§1). **Confirm in App Store Connect.** The COPPA
question adjacent to it *is* on record — `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md:49-53`
— and §1 now cites it.

**Judgment calls, flagged rather than absorbed:** the child-data mapping (§1), the derived
third-party names mapping (§1.1), the Health & Fitness mapping (§2), the Sensitive Info *No* (§2.1),
the timezone-not-Location call (§8.3), the both-purposes call on Product Interaction (§6), and the
recommendation not to declare Crash Data (§6). **§1, §2 and §3 are UNRESOLVED by design and are not
resolved anywhere in this document.**

**Corrections applied by the second pass**, each re-verified against the tree at the time: the branch
name in the provenance line; the extension-manifest justification in §7 (rewritten — the extensions
*do* compile app-target files, but none of those files uses a required-reason API); the "APIClient
sets only…" claim in §4; the `models/` grep output in §2; `family.py:132`→`:134`;
`ExtractedDetails.swift:29`→`:31` and `:19-25`→`:20-26`; `main.py:53`→`wellknown.py:105-106`; the
`ExtractionQueue` / `FoundationModels` attribution; the five `[.size]` reads mislabelled as
file-timestamp evidence in §7; the measurement prompt's unstated `completion_mode: media` and its two
unmentioned siblings; the eighteen-year citation `TokenStore.swift:11`→`Info.plist:111`; and the Kids
Category assertion. Three things were **added** as missed against the brief: derived third-party
names (§1.1), Sensitive Info (§2.1), and the full three-prompt `measurement` picture (§2). Two were
**updated for the changed tree**: the module list and the Browsing History finding.

**Corrections applied by this pass**, each re-opened in the tree before it was written:

- **Provenance.** Ten files → sixteen, with the five `docs/` files named; the 15→16 change recorded;
  the "every line was re-read" claim replaced with which pass read what.
- **§7 Placement — four `project.pbxproj` citations, including the two the argument turns on.**
  Widget Sources `:130-142`→`:365-379`; Share Sources `:150-162`→`:387-402`; `Shared` `PBXGroup`
  `:172-193`→`:175-196`; native targets `:198-283`→`:199-284`. The file lists were right; the ranges
  pointed at `PBXFrameworksBuildPhase` and the root group.
- **§9 — three of four `PaywallSheet.swift` line numbers.** `:95,532,535,560`→`:95,528,531,556`
  (plus `legalRow` at `:479`); the `LegalLinks` guard range `:726-745`→`:728` and `:739`.
- **§1 — `AvatarCrop.square`** `:145`→`:147`.
- **§8.1 — `exifDate(from:)`** `:201-215`→`:201-214` and **`exifDate(fileAt:)`** `:217-222`→`:216-221`;
  **`ImagePipelineTests.swift:13`**, a doc comment, → `:129-135`, the actual assertions.
- **§7 — the `creationDate` paragraph**, which said "three" and listed four and was not exhaustive:
  replaced with all 21 non-test occurrences in three classified groups.
- **§6 — `TimelineSearchModel.swift:158-164`**→`:160-165`; **`SubscriptionModel.swift:476-513`**→
  `:476-528`, with `AppStore.sync()` attributed to `SubscriptionStore.swift:152` where it is actually
  called; **`TagEditorSheet.swift:102`** relabelled (it is the `TextField`, not the `EntryTagWrite`);
  **`entry.py:184`** annotated as the `__tablename__` line.
- **§5 — the module-provenance claim** downgraded from VERIFIED-BY-READING to INFERRED, and added to
  the list above as item 7.
- **§2.1 — "this app has no mechanism that reads it"** downgraded to a narrower INFERRED claim, with
  the `docs/mission-library.md` grep added so the evidence covers the authoring surface and not only
  the generated file; added to the list above as item 8.
- **§1 and §3 — two settled decisions this document was arguing past**, both added:
  `docs/sprint-aug16/sprint-story-5-privacy-and-terms.md:49-53` (COPPA out of scope, Aug 16, 2026)
  and `docs/decisions.md:59` (the handoff is shared access with a floor of 13, settled Aug 11, 2026,
  and `POST /children/{id}/guardians` exists as a P2 stub).
- **§1 — the Kids-Category grep**, described as finding "nothing," now reports its six lines and says
  what they are.
- **§8.2 — the middleware claim** now names `CORSMiddleware` (`main.py:70`) as the only one installed,
  rather than asserting an absence without showing what is present.

**One correction remains rejected, and its evidence is now correct.** The rejected claim is that
neither extension compiles a single app-target file. `project.pbxproj:84`
(`path = Rascal/Media/ImagePipeline.swift`) and **`project.pbxproj:387-402`** — RascalShare's real
`PBXSourcesBuildPhase`, *corrected from the `:150-162` this paragraph used to cite, which is the root
`PBXGroup`* — say otherwise. Its *conclusion* — that neither extension uses a required-reason API
today — is right, and §7 keeps it.

**Not done, and out of this phase's scope:** writing `PrivacyInfo.xcprivacy` (§7 is its
specification), Part 1's export audit, and Part 3's Settings work.