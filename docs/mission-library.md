# RASCAL — Mission Library (seed set)

~105 hand-authored prompts. This is the content that makes or breaks the app; treat it as the most valuable file in the project.

**Ages** are in months. `all` = 24–216. **Mode** maps to `completion_mode`.
Rows with a **Months** value get `month_tags` set; everything else is any-month.

**This file is the authoring surface.** It is converted once into
`api/seeds/prompts.yaml`, which is what the seed loader reads. Runtime never parses a
markdown table. When you add prompts here, regenerate the YAML and re-run `make seed` —
the loader is keyed on a hash of `(kind, cadence, body)`, so it updates and inserts but
never duplicates and never deletes.

Tone rules for anything added later: **specific over sentimental**, second person, imperative for missions, and never sanctimonious. "Photograph the mess {they} made, don't clean it first" beats "capture a precious everyday moment."

---

## Questions — `kind: question` · `cadence: daily` · `mode: text`

| Prompt | Theme | Ages |
|---|---|---|
| What did {they} say this week that you want to remember exactly? | their-words | all |
| What is {name} obsessed with right now? | everyday-ordinary | all |
| What does {name} call you? Write down every version. | their-words | 24–96 |
| What's the bedtime routine right now, step by step? | sleep-routine | 24–120 |
| What food is {name} refusing this week? | food | 24–120 |
| What did {they} do today that annoyed you and will be funny in ten years? | humor | all |
| Who is {their} best friend right now, and what do they do together? | relationships | 36–216 |
| What word does {name} mispronounce that you don't want to correct? | their-words | 24–84 |
| What is {name} afraid of right now? | fears-comfort | 24–144 |
| What did {they} teach {themself} this month? | skills-firsts | all |
| Describe {their} laugh. | everyday-ordinary | all |
| What's {their} answer to "what do you want to be when you grow up" — this week's version? | everyday-ordinary | 36–216 |
| What song is stuck in the house right now? | everyday-ordinary | all |
| What's the last thing {they} asked that you couldn't answer? | their-words | 36–216 |
| What's the first thing {they_do} in the morning? | everyday-ordinary | all |
| What are you worried about with {them} right now? | me-as-a-parent | all |
| What did you get wrong as a parent this week? Write it honestly — {they}'ll need to know you were human. | me-as-a-parent | all |
| What does {their} room look like right now? Describe the mess. | everyday-ordinary | all |
| What's {their} favorite thing to do with someone who isn't you? | relationships | all |
| What's a rule in your house {they}'d be surprised to learn isn't universal? | everyday-ordinary | 48–216 |
| What did {they} cry about today? | fears-comfort | 24–144 |
| What's the last thing {they_were} proud of {themself} for? | skills-firsts | all |
| What toy has {name} not put down this month? | everyday-ordinary | 24–120 |
| What does {name} smell like right now? | everyday-ordinary | 24–96 |
| Who does {name} look like today? | everyday-ordinary | all |
| What phrase has {name} picked up from you that you wish {they} hadn't? | humor | 30–216 |
| What's the thing {they_do} that nobody else would notice? | everyday-ordinary | all |
| What did the two of you argue about? | relationships | 36–216 |
| How does {name} say goodbye? | physical-affection | 24–144 |
| What's changed about {them} in the last three months? | growth-measurement | all |

## Photo missions — `kind: photo` · `cadence: daily` · `mode: media`

| Prompt | Theme | Ages | Months |
|---|---|---|---|
| Photograph {their} hands. Just {their} hands. | growth-measurement | all | |
| Get down to {their} eye level and take the photo from there. | everyday-ordinary | 24–120 | |
| Photograph {their} shoes by the door. | everyday-ordinary | all | |
| Take a picture of what {they} built today, however unimpressive. | making-building | 30–144 | |
| Photograph the mess {they} made. Don't clean it up first. | humor | 24–144 | |
| Take a photo of {them} sleeping. | sleep-routine | 24–144 | |
| Photograph {their} drawing or {their} handwriting, exactly as it is. | skills-firsts | 36–144 | |
| Take a picture of {them} with whoever {they_are} most attached to right now. | relationships | all | |
| Photograph {their} lunch, arranged the way {they} arranged it. | food | 30–120 | |
| Take a photo of {them} doing the thing {they_do} every single day. | everyday-ordinary | all | |
| Photograph {their} face mid-laugh. Burst mode. Take twenty, keep one. | humor | all | |
| Take a picture of {them} in the same spot you photographed {them} a year ago. | growth-measurement | 36–216 | |
| Photograph what {they_are} wearing today, head to toe. In ten years this is a costume. | everyday-ordinary | all | |
| Take a photo of the two of you. You're in almost none of them. | relationships | all | |
| Photograph {their} favorite toy alone, like a portrait. | everyday-ordinary | 24–120 | |
| Take a picture of {them} outside doing nothing in particular. | outdoors | all | |
| Take a photo of {them} with {their} grandparents. | relationships | all | |
| Photograph {them} next to something for scale — a doorway, the dog, your hand. | growth-measurement | all | |
| Photograph {them} in the first snow. | seasons-holidays | all | 12,1,2 |
| Take a photo of {them} on the first day of school. | seasons-holidays | 48–216 | 8,9 |
| Photograph whatever {they} made out of leaves, pumpkins, or mud this month. | seasons-holidays | 24–144 | 9,10,11 |
| Take a photo of what summer looks like for {them} this year. | seasons-holidays | all | 6,7,8 |

## Video missions — `kind: video` · `cadence: daily` · `mode: media`

| Prompt | Theme | Ages | Months |
|---|---|---|---|
| Film {them} telling you about {their} day. Don't prompt {them}. | their-words | 36–216 | |
| Ask {them} ten questions about someone else in the family and film the answers. Don't correct anything. | relationships | 36–216 | |
| Film {them} doing the thing {they_are} currently best at. | skills-firsts | all | |
| Record thirty seconds of {them} just playing. No talking to the camera. | everyday-ordinary | 24–120 | |
| Film {them} explaining how something works. | humor | 36–144 | |
| Record {them} running toward you. | physical-affection | 24–96 | |
| Film the bedtime routine start to finish, one take. | sleep-routine | 24–120 | |
| Ask {them} what {they}'d say to {themself} at eighteen. Film it. | letters-forward | 48–216 | |
| Film {them} eating something for the first time. | food | 24–144 | |
| Record {them} dancing to whatever's playing. | humor | 24–144 | |
| Film {them} on the last day of the school year. | seasons-holidays | 48–216 | 5,6 |

## Audio missions — `kind: audio` · `cadence: daily` · `mode: media`

The highest-value entries in the whole archive. Transcription makes them searchable forever.

| Prompt | Theme | Ages |
|---|---|---|
| Record {them} telling you a story. Any story. Don't correct a single word. | voice | 30–144 |
| Record {them} singing. Whatever {they_are} singing. | voice | 24–144 |
| Record {them} counting as high as {they} can go. | voice | 30–96 |
| Record {them} saying the alphabet. | voice | 30–84 |
| Record {them} saying {their} own full name. | voice | 24–96 |
| Record {them} describing you. | voice | 36–216 |
| Record two minutes of dinner. Don't announce it. Just the room. | everyday-ordinary | all |
| Record {them} reading a page out loud. | skills-firsts | 60–144 |
| Record {them} telling a joke. | humor | 36–144 |
| Record {them} talking about {their} best friend. | relationships | 48–216 |
| Record {them} answering "what's the best thing that happened today?" | their-words | 36–216 |
| Record {them} making up a song about nothing. | humor | 30–96 |

## Activity missions — `kind: activity` · `cadence: daily` · `mode: did_it`

No artifact required. These are behaviors, and they're half the reason this app exists.

| Prompt | Theme | Ages |
|---|---|---|
| Never let go of the hug first today. Let {them} be the one to pull away. | physical-affection | all |
| Get on the floor for ten minutes. That's the whole mission. | physical-affection | 24–120 |
| Carry {them} when asked, even though {they} can walk fine. | physical-affection | 24–96 |
| Use {their} baby nickname out loud today, while {they_do} still answer to it. | their-words | 24–120 |
| Let {them} help with something, even though it triples the time. | making-building | 30–144 |
| Don't rush lights-out tonight. Stay an extra ten minutes. | sleep-routine | 24–144 |
| Say yes to the next thing you'd normally say no to. | me-as-a-parent | all |
| Let {them} choose dinner. Entirely. | food | 36–216 |
| Ask {them} a question and let the silence sit until the answer comes. | their-words | 36–216 |
| Go outside with {them} with no plan and no phone. | outdoors | all |
| Apologize to {them} for something. Out loud. | me-as-a-parent | 36–216 |
| Let {them} win, and don't tell {them} you did. | humor | 36–120 |
| Tell {them} one specific thing you admire about {them}. Not "good job." | relationships | 36–216 |
| Do nothing next to {them} for fifteen minutes. | everyday-ordinary | all |
| Ask {them} to teach you something. | skills-firsts | 48–216 |
| Put your phone in another room for the whole evening. | me-as-a-parent | all |

## Weekly missions — `cadence: weekly`

Bigger, drops Saturday, expires in two weeks like everything else.

| Prompt | Kind | Theme | Mode | Ages |
|---|---|---|---|---|
| Take {them} on a solo date and let {them} pick everything — where you go, what you eat, what you do. | activity | relationships | media | 36–216 |
| Make cookies together this week. Photograph the mess, not the cookies. | activity | making-building | media | 30–144 |
| Build something with {them} that takes more than one sitting. | activity | making-building | media | 48–216 |
| Interview {them} with ten questions about someone else in the family and film the whole thing. | video | relationships | media | 36–216 |
| Go somewhere neither of you has been before. | activity | outdoors | media | all |
| Spend an afternoon following only {their} suggestions. | activity | everyday-ordinary | did_it | 36–216 |
| Cook something from your own childhood and tell {them} where it came from. | activity | food | media | 36–216 |
| Show {them} where you grew up — go there, or go through the photos. | activity | letters-forward | media | 48–216 |
| Ask {them} to pick three songs and play them loud in the kitchen. | activity | humor | media | 30–216 |
| Let {them} plan and "cook" one meal, whatever that means at {their} age. | activity | food | media | 48–216 |

## Monthly missions — `cadence: monthly` · fires on the 1st

| Prompt | Kind | Theme | Mode | Ages |
|---|---|---|---|---|
| Measure {their} height and weight. Photograph {them} against the same wall, same spot as last time. | measurement | growth-measurement | media | all |
| Take the same photo you took last month — same chair, same angle. | measurement | growth-measurement | media | all |
| Go back through your camera roll to this month last year and log three photos you never wrote down. | photo | growth-measurement | media | all |
| Trace {their} hand on paper and photograph it. | measurement | growth-measurement | media | 24–120 |

## Letters — `kind: letter` · `cadence: monthly` · `mode: text` · sealed

These set `unlock_at_age`. They're written *to* the child, not about them.

| Prompt | Theme | Unlock | Ages |
|---|---|---|---|
| Write {them} something about money that you wish someone had told you at nineteen. | letters-forward | 18 | all |
| Write {them} a letter about exactly who {they_are} right now. {They} won't be this person next year. | letters-forward | 16 | all |
| Write down what you were afraid of before {they_were} born, and what actually happened. | letters-forward | 18 | all |
| Write {them} about a mistake you made that {they}'ll probably make too. | letters-forward | 18 | all |
| Write down the story of the day {they_were} born, in as much detail as you can still remember. | letters-forward | 13 | all |
| Write {them} something about someone in {their} family that {they}'d never think to ask about. | relationships | 18 | all |
| Write down what you hope stays with {them} from being four years old. | letters-forward | 16 | 24–96 |
| Write {them} what you'd want {them} to know if you weren't around to say it. | letters-forward | 18 | all |

---

## Coverage check for the POC

Your son is 48 months. Prompts eligible at 48 months, by kind.

**These figures are generated from `api/seeds/prompts.yaml`, and
`api/tests/test_seeding.py` asserts them exactly** — if you add prompts and this table stops
matching, the test fails and tells you the new numbers. Corrected Aug 4, 2026: the previous
version predated the last handful of prompts and under-counted video, activity, and weekly.

| Kind | Total | Active | Eligible at 48mo | Of those, any-month | Slot it feeds | Enough for 14 days? |
|---|---|---|---|---|---|---|
| Question | 30 | 30 | 30 | 30 | `question` | ✅ |
| Photo | 22 | 22 | 22 | 18 | `mission` | ✅ |
| Video | 11 | 11 | 11 | 10 | `mission_b` | ✅ (pooled) |
| Audio | 12 | 12 | 11 | 11 | `mission_b` | ✅ (pooled) |
| Activity | 16 | 16 | 16 | 16 | `mission_b` | ✅ |
| Weekly | 10 | 10 | 10 | 10 | `weekly` | ✅ |
| Monthly | 4 | 4 | 4 | 4 | `monthly` | ✅ |
| Letter | 8 | 8 | 8 | 8 | `letter` | ✅ |

**113 prompts in the library, and all 113 are active.** This table said `active: 0` for video
and audio for far longer than it was true. Both kinds were deactivated through
`UNCOMPLETABLE_KINDS` in `api/scripts/mission_library_to_yaml.py` because no client could
complete them, and a prompt the client cannot complete is a dead end rather than a mission — a
device session hit exactly that, with the composer offering a still camera on a prompt that
said to film. **Video came back when multipart upload shipped and audio when the recorder did.**
`UNCOMPLETABLE_KINDS` is now empty and stays in place for the next kind that needs it.

Deactivation lives in the generator, not hand-edited into the yaml: this markdown is the
authoring surface and the yaml is generated from it, so an edit made only in the yaml is erased
by the next regeneration and drifts silently until then. "Any-month" excludes the seasonal ones — a prompt tagged to December
is eligible by age but will not be served in August, so that column is what the scheduler
actually has to draw from on an arbitrary day.

**There are three daily slots, not two, and they no longer share a pool.** The sentence that
used to sit here — "the daily `mission` slot draws from photo, video, audio, and activity
together" — stopped being true when the day split into three. What replaced it:

| Slot | Draws from | Available on an August day at 49mo | First repeat | Relaxation begins |
|---|---|---|---|---|
| `question` | question | 30 | ~30 days | 2026-09-10 |
| `mission` | **photo only** | 20 | ~20 days | **2026-08-31** |
| `mission_b` | video + audio + activity, pooled | 37 | ~37 days | 2026-09-17 |

Measured with `GET /children/{id}/pool-health` on 2026-08-11, not estimated from this file.
The figures differ slightly from the "any-month" column above because that column counts only
untagged prompts, while the scheduler also serves prompts tagged to the current month.

**`mission` is now the thin slot, and it is thin because the photo pool is the smallest of the
three.** Splitting a 57-prompt combined pool into 20 and 37 is what buys three items a day; the
cost is that the photo slot reaches its cooldown relaxation in under three weeks rather than
in two months. That is a call for authoring, not for tuning: **the fix is more photo prompts**,
and nothing in this phase generated any. `estimated_days_until_first_repeat` is a projection
from pool size, not a promise — theme rotation can relax a single pick earlier without the
slot being exhausted.

`weekly` draws from the ten weekly prompts on Saturday; `monthly` draws from the four
measurement and camera-roll prompts on the 1st; `letter` draws from the eight letters on the
15th. **All three fire on top of the daily three rather than replacing any of them**, so a
Saturday is four items, the 15th is four, and a Saturday that is also the 15th is five.

The 180-day cooldown holds comfortably at this size. When the library grows past ~300 you can tighten theme rotation instead of loosening cooldown.

## Expanding the library

Batch-generate candidates **server-side with a real model**. Never at request time, never
on-device. Feed the generator this file as the style reference, plus a target theme and age
band, and ask for 20 candidates at a time. Reject anything that:

- uses the words *precious*, *cherish*, *treasure*, or *little moments*
- describes a feeling instead of an action
- couldn't be done in the middle of an ordinary Tuesday
- assumes a two-parent household, a particular income, or a particular ability

> **The library used to violate the last rule, and as of Aug 13, 2026 it no longer does.** All 113
> bodies were written he/him, and four said *his mom* — a gender and a household shape. Every one
> of them now carries the token table below, and the four household references were rewritten to
> *someone else in the family* rather than tokenised around, because `{their} mom` fixes the
> gender and keeps the household. See `docs/decisions.md` — the owner reversed the coexistence
> decision on Aug 12 because what the literal library rendered was `he/him` to a she/her child, on
> every screen, permanently.
>
> **Roughly a fifth of the rewrite was not substitution, and this is the part to know before
> editing.** The token table has no inverted forms — `{they_are}` is *"he is" / "they are"*, and
> English questions invert to *"is he" / "are they"*. So "What is he obsessed with right now?"
> cannot be tokenised in place; it became "What is {name} obsessed with right now?", where a name
> is third-person singular and the verb stops moving. Eighteen bodies were rephrased that way, and
> the rule that produced them is: **prefer `{name}` when it preserves the sentence exactly, and
> rephrase only when `{name}` would have to appear twice.** The alternative — adding `{are_they}`
> and friends — was rejected because it widens a wire contract three clients implement.
>
> **This file is where any further rewrite happens** — `api/seeds/prompts.yaml` is generated from
> it by `scripts/mission_library_to_yaml.py` and must never be hand-edited. Re-seeding keys
> idempotency on `sha256(kind, cadence, body)`, so a changed body **inserts** a new prompt rather
> than updating the old one; `seed_prompts` now deactivates any seeded prompt the file no longer
> contains, which is what retired the 113 literal ones in the same pass. Entries and assignments
> still point at them, so they are deactivated and never deleted.

### Pronoun and name tokens

New prompts may use the token table in `docs/api-contract.md` — `{they}`, `{them}`, `{their}`,
`{theirs}`, `{themself}`, the four verb compounds `{they_are}` / `{they_were}` / `{they_have}` /
`{they_do}`, the three capitalised forms `{They}` / `{Them}` / `{Their}`, and `{name}`. They-forms
are the keys because they/them is the only English pronoun set whose five slots are five distinct
words. Capitalisation is explicit — write `{They}` at the start of a sentence, never `{they}`.

An unanswered pronoun renders the they/them column, so a tokenised prompt is grammatical for every
child including one whose parent skipped the question.

> A prompt may use `{name}` at most once, and only where a parent would naturally say the child's
> name aloud — usually the opening. "What made {name} laugh today?" reads warm. "What did {name}
> do when {name}'s cousin arrived?" reads like a mail merge. Pronoun tokens carry every other
> reference.

**This rule is authored, not enforced.** The four rejection rules above are implemented in
`api/scripts/generate_prompts.py` and tested; the `{name}` rule is not, and constrains new batches
only through this file being the generator's style reference. A reviewer reading a candidate
worksheet is what actually catches a mail merge.

**This is built.** `api/scripts/generate_prompts.py` does exactly the above — including all
four rejection rules, implemented in code and tested in `api/tests/test_generate_prompts.py`
against real prompts from this file, so a filter that would reject "get on the floor for ten
minutes" fails the suite.

```
uv run python scripts/generate_prompts.py --thinnest 4
```

Candidates land in `docs/prompt-candidates/<theme>-<date>.md`, and **the review queue is a
pull request** — the *Prompt candidates* workflow opens one. Accepting a candidate means
pasting its row into the right table above, regenerating the YAML, and deleting the
worksheet. See `docs/prompt-candidates/README.md`.

The filters are a spam trap, not an editor. They catch the failures that are textually
detectable so that you are reading twelve plausible prompts instead of twenty with eight duds
in them. The judgment is still yours, and this file is still the most valuable one in the
project.
