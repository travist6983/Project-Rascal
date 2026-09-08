# Before you share `presskit-final/` — owner checklist

**This file is for you, not for press. It lives outside `presskit-final/` on purpose — do not copy
it into the folder you upload.**

`presskit-final/` is the only thing a writer should ever receive. Everything else under
`docs/press-kit/` is working material: the internal fact sheet with its source file paths, the
outreach emails, the raw screen recordings, the tracker.

## Four things to do first

1. **Read the three quotes — they are already public.** They are on the live page at
   https://pocketchronicle.app/press, in `presskit-final/index.html`, and in `boilerplate.txt`. They are written in
   your voice out of your own words, but **you have not said them verbatim**, and a writer will
   print them as spoken. Change anything you would not say and both copies need updating.

2. **Decide what to do about the App Store name.** The listing is `PocketChronicle.App`; everything
   here calls the product Pocket Chronicle. The page says so plainly in the facts table, so a writer
   will not be confused — but if you would rather they matched, renaming the listing is the cheaper
   fix and it removes a line from the page.

3. **Check the price and the tier rule against App Store Connect one more time.** The page states
   $5.99 monthly, $59.99 annual, one membership per household, the first 14 days open with no card,
   and then the daily question free with anything needing storage behind membership. That last rule
   went live with phase 147, deployed on the merge of PR #197.

4. **Fix the marketing site before a writer compares the two.** `pocketchronicle.app/pricing` still
   advertises 100 free photographs and unlimited two-minute voice notes on the free tier, which the
   app no longer does. The work order is
   `Rascal-Marketing/docs/site-accuracy-update-prompt.md`. A journalist checking the press kit
   against the website today will find them disagreeing about what is free.

## How to share it — settled

**It is published at https://pocketchronicle.app/press.** The kit went up on the marketing site as a real page
(built through the site's own pipeline, so it has a Markdown twin and sits in `llms.txt` like every
other page), and **all fourteen emails already link it.** There is nothing to upload and no
placeholder left to replace.

The page carries the zip too, so a writer who wants files rather than a page gets them in one click.
If you ever need to hand someone the folder directly, `presskit-final/` is it, and
`pocket-chronicle-press-kit.zip` is that folder zipped.

**If you change anything in `presskit-final/`, the site copy does not follow automatically.** They
are two builds of the same kit: the folder is the offline one, `Rascal-Marketing/src/pages/press.html`
and `src/assets/press/` are the published one. Change the quotes and you have to change both, then
rebuild and redeploy the site.

## What is deliberately not in there

- Internal file paths, phase numbers, and the "do not claim" notes from the working fact sheet.
- The raw screen recordings in `video/raw/` — the finished cut is enough, and the raws are 6 MB of
  material a writer will not use.
- The outreach emails and the tracker.
- Anything about the site being wrong. That is your problem to fix, not a writer's to read about.
