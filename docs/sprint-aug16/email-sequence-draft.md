# Dogear — email copy

> **Reviewed and approved by the owner, Aug 16, 2026.** Story 4 implements this copy **verbatim**.
> An agent does not author, edit, extend or "improve" anything in this file — not a subject line,
> not a prompt. If copy will not fit a template, report the conflict; do not resolve it by rewriting
> the copy. The owner edits this file directly and the change takes effect on the next send.

Two things live here: a **five-email welcome sequence** sent per-subscriber off their own
`confirmed_at`, and a **daily prompt pool** the broadcast draws from.

**Voice:** warm, plain, a little wry. Short sentences. Never breathless. No exclamation stacking.
No streaks, no guilt, no "don't miss out," no red, no countdowns. The product's rule that a
parenting app must not punish a missed day applies to email at least as much as to the app.

**Every email ends with the same unsubscribe line.** It is a real link and it works forever.

---

## Part 1 — The welcome sequence

Five emails. Days 0, 2, 5, 9, 16 after confirmation. The prompt in each is a real prompt — the
pitch sits underneath it, never on top of it.

---

### Email 1 — Day 0. Subject: `Your first question`

> That's you on the list. Here's the first one.
>
> **What did they say today that you want to remember?**
>
> Write it down somewhere — a notes app, a napkin, the back of your hand. The point isn't where. The
> point is that in nine years you will not remember it, and right now you do.
>
> That's the whole idea behind Dogear. One question a day about your kid, and one small mission —
> take a photo, record their voice, get on the floor for ten minutes. What you capture becomes a
> timeline they inherit, with the question that caused it still attached.
>
> A photo without context is a photo. A photo with the question that made you take it is a story.
>
> We'll send you a question most days. No streaks, nothing to keep up with.

---

### Email 2 — Day 2. Subject: `The thing camera rolls can't do`

> **What are they afraid of right now?**
>
> Worth writing down, because it will change, and because you will forget that it was ever true.
>
> Here's the thing about your camera roll: it already has eleven thousand photos of your kid. What
> it doesn't have is why. Which one was the day they finally let go of the couch. Which blurry one
> is the good one.
>
> Dogear isn't storage. You've got storage. It's the prompt, the context, and being able to find it
> again in 2040.

---

### Email 3 — Day 5. Subject: `Some days you just get on the floor`

> **What's a small thing they're better at than they were a month ago?**
>
> A note on missions, since a couple of you asked.
>
> Not every mission produces something to upload. "Get on the floor and play for ten minutes" makes
> nothing you can post, and it is a complete, legitimate entry in the archive. So is a sentence you
> typed. So is a photo.
>
> Three shapes: you did it, you captured it, you wrote it. All three count the same.
>
> Most apps in this category quietly assume a photo. Ours doesn't, and that was a decision, not an
> oversight.

---

### Email 4 — Day 9. Subject: `Missed a few?`

> **What do they do that nobody else would notice?**
>
> If you haven't written anything down since the first email — that's fine, and it's the reason this
> email exists.
>
> Dogear has no streaks. Nothing turns red. Missed prompts stack up quietly and expire after two
> weeks without ever mentioning it again. An app that makes you feel worse about parenting has
> failed at the only thing it was for.
>
> The exit test we used while building it wasn't a feature list. It was: did I use this for seven
> days without forcing myself.

---

### Email 5 — Day 16. Subject: `Where this is going`

> **What's something they believe right now that isn't true?**
>
> Write that one down. Trust me.
>
> Quick note on what Dogear actually is, since you've been getting these for a couple of weeks.
>
> It's an iPhone app. One question a day, one mission, a bigger mission weekly, a measurement monthly.
> Everything lands on a searchable timeline — searchable through what was said, not just when it
> happened, because voice recordings get transcribed.
>
> It's built to be handed over. Not exported into a folder someone loses. Handed over, as a thing
> with the questions still attached.
>
> It's being built by one person in the evenings, for one four-year-old, and it works. You'll hear
> from us when it's ready for anyone else.
>
> Until then: the questions keep coming.

---

## Part 2 — The daily prompt pool

**30 prompts.** Age-neutral and token-free by design — a subscriber has no child on file, no
birthdate and no pronouns, so nothing here may assume an age or need a pronoun substitution. That is
the cheap answer to open question 12(3): the signup stays an email box instead of becoming an
onboarding flow.

**These are not drawn from the seeded library.** The library's 113 prompts are age-targeted and
pronoun-tokenised and cannot render for a subscriber. This pool is separate, deliberately, and is
never written into the `prompts` table.

Selection: day-of-year modulo the pool length. Deterministic, no state, and it means every subscriber
gets the same prompt on the same day — which is what a Broadcast sends anyway.

1. What did they say today that you want to remember?
2. What are they afraid of right now?
3. What's a small thing they're better at than they were a month ago?
4. What do they do that nobody else would notice?
5. What's something they believe right now that isn't true?
6. Who is their favourite person outside this house, and why?
7. What's the current obsession? The one you're a little tired of.
8. What makes them laugh the hardest?
9. What did they teach you this week?
10. What do they call something, using the wrong word, that you'll be sad to lose?
11. What are they proud of right now?
12. What does bedtime actually look like, honestly?
13. What's the sound of your house right now?
14. What's a thing they're allowed to do now that they weren't six months ago?
15. What do they want to be? Ask them today, not from memory.
16. What's the hardest part of this age?
17. What's the part you'd keep, exactly as it is?
18. Where do they go when they're upset?
19. What's their favourite meal this month?
20. What's a phrase they've picked up from you that you wish they hadn't?
21. What did you do together today that cost nothing?
22. Who are they at somebody else's house, versus here?
23. What's the last thing they were completely absorbed by?
24. What's something they've stopped doing that you didn't notice stopping?
25. What do they smell like right now? Be specific.
26. What's the argument you keep having?
27. What are their hands doing when they're thinking?
28. What's a thing about them that's entirely their own — from neither of you?
29. What did today actually look like, from waking up to now?
30. What would you want them to know about this exact week, twenty years from now?

---

## The footer, on every email

> You're getting this because you signed up at [site]. One email a day, and you can stop them any
> time — [unsubscribe].

No PS. No "was this useful?" No social icons.
