# RASCAL — Mission Library (seed set)

~105 hand-authored prompts. This is the content that makes or breaks the app; treat it as the most valuable file in the project.

**Ages** are in months. `all` = 24–216. **Mode** maps to `completion_mode`.
Rows with a **Months** value get `month_tags` set; everything else is any-month.

**This file is the authoring surface.** It is converted once into
`api/seeds/prompts.yaml`, which is what the seed loader reads. Runtime never parses a
markdown table. When you add prompts here, regenerate the YAML and re-run `make seed` —
the loader is keyed on a hash of `(kind, cadence, body)`, so it updates and inserts but
never duplicates and never deletes.

Tone rules for anything added later: **specific over sentimental**, second person, imperative for missions, and never sanctimonious. "Photograph the mess he made, don't clean it first" beats "capture a precious everyday moment."

---

## Questions — `kind: question` · `cadence: daily` · `mode: text`

| Prompt | Theme | Ages |
|---|---|---|
| What did he say this week that you want to remember exactly? | his-words | all |
| What is he obsessed with right now? | everyday-ordinary | all |
| What does he call you? Write down every version. | his-words | 24–96 |
| What's the bedtime routine right now, step by step? | sleep-routine | 24–120 |
| What food is he refusing this week? | food | 24–120 |
| What did he do today that annoyed you and will be funny in ten years? | humor | all |
| Who is his best friend right now, and what do they do together? | relationships | 36–216 |
| What word does he mispronounce that you don't want to correct? | his-words | 24–84 |
| What is he afraid of right now? | fears-comfort | 24–144 |
| What did he teach himself this month? | skills-firsts | all |
| Describe his laugh. | everyday-ordinary | all |
| What does he want to be when he grows up — this week's version? | everyday-ordinary | 36–216 |
| What song is stuck in the house right now? | everyday-ordinary | all |
| What's the last thing he asked that you couldn't answer? | his-words | 36–216 |
| What's the first thing he does when he wakes up? | everyday-ordinary | all |
| What are you worried about with him right now? | me-as-a-parent | all |
| What did you get wrong as a parent this week? Write it honestly — he'll need to know you were human. | me-as-a-parent | all |
| What does his room look like right now? Describe the mess. | everyday-ordinary | all |
| What's his favorite thing to do with his mom? | relationships | all |
| What's a rule in your house he'd be surprised to learn isn't universal? | everyday-ordinary | 48–216 |
| What did he cry about today? | fears-comfort | 24–144 |
| What's the last thing he was proud of himself for? | skills-firsts | all |
| What toy has he not put down this month? | everyday-ordinary | 24–120 |
| What does he smell like right now? | everyday-ordinary | 24–96 |
| Who does he look like today? | everyday-ordinary | all |
| What phrase has he picked up from you that you wish he hadn't? | humor | 30–216 |
| What's the thing he does that nobody else would notice? | everyday-ordinary | all |
| What did the two of you argue about? | relationships | 36–216 |
| How does he say goodbye? | physical-affection | 24–144 |
| What's changed about him in the last three months? | growth-measurement | all |

## Photo missions — `kind: photo` · `cadence: daily` · `mode: media`

| Prompt | Theme | Ages | Months |
|---|---|---|---|
| Photograph his hands. Just his hands. | growth-measurement | all | |
| Get down to his eye level and take the photo from there. | everyday-ordinary | 24–120 | |
| Photograph his shoes by the door. | everyday-ordinary | all | |
| Take a picture of what he built today, however unimpressive. | making-building | 30–144 | |
| Photograph the mess he made. Don't clean it up first. | humor | 24–144 | |
| Take a photo of him sleeping. | sleep-routine | 24–144 | |
| Photograph his drawing or his handwriting, exactly as it is. | skills-firsts | 36–144 | |
| Take a picture of him with whoever he's most attached to right now. | relationships | all | |
| Photograph his lunch, arranged the way he arranged it. | food | 30–120 | |
| Take a photo of him doing the thing he does every single day. | everyday-ordinary | all | |
| Photograph his face mid-laugh. Burst mode. Take twenty, keep one. | humor | all | |
| Take a picture of him in the same spot you photographed him a year ago. | growth-measurement | 36–216 | |
| Photograph what he's wearing today, head to toe. In ten years this is a costume. | everyday-ordinary | all | |
| Take a photo of the two of you. You're in almost none of them. | relationships | all | |
| Photograph his favorite toy alone, like a portrait. | everyday-ordinary | 24–120 | |
| Take a picture of him outside doing nothing in particular. | outdoors | all | |
| Take a photo of him with his grandparents. | relationships | all | |
| Photograph him next to something for scale — a doorway, the dog, your hand. | growth-measurement | all | |
| Photograph him in the first snow. | seasons-holidays | all | 12,1,2 |
| Take a photo of him on the first day of school. | seasons-holidays | 48–216 | 8,9 |
| Photograph whatever he made out of leaves, pumpkins, or mud this month. | seasons-holidays | 24–144 | 9,10,11 |
| Take a photo of what summer looks like for him this year. | seasons-holidays | all | 6,7,8 |

## Video missions — `kind: video` · `cadence: daily` · `mode: media`

| Prompt | Theme | Ages | Months |
|---|---|---|---|
| Film him telling you about his day. Don't prompt him. | his-words | 36–216 | |
| Ask him ten questions about his mom and film the answers. Don't correct anything. | relationships | 36–216 | |
| Film him doing the thing he's currently best at. | skills-firsts | all | |
| Record thirty seconds of him just playing. No talking to the camera. | everyday-ordinary | 24–120 | |
| Film him explaining how something works. | humor | 36–144 | |
| Record him running toward you. | physical-affection | 24–96 | |
| Film the bedtime routine start to finish, one take. | sleep-routine | 24–120 | |
| Ask him what he'd say to himself at eighteen. Film it. | letters-forward | 48–216 | |
| Film him eating something for the first time. | food | 24–144 | |
| Record him dancing to whatever's playing. | humor | 24–144 | |
| Film him on the last day of the school year. | seasons-holidays | 48–216 | 5,6 |

## Audio missions — `kind: audio` · `cadence: daily` · `mode: media`

The highest-value entries in the whole archive. Transcription makes them searchable forever.

| Prompt | Theme | Ages |
|---|---|---|
| Record him telling you a story. Any story. Don't correct the words he says wrong. | voice | 30–144 |
| Record him singing. Whatever he's singing. | voice | 24–144 |
| Record him counting as high as he can go. | voice | 30–96 |
| Record him saying the alphabet. | voice | 30–84 |
| Record him saying his own full name. | voice | 24–96 |
| Record him describing you. | voice | 36–216 |
| Record two minutes of dinner. Don't announce it. Just the room. | everyday-ordinary | all |
| Record him reading a page out loud. | skills-firsts | 60–144 |
| Record him telling a joke. | humor | 36–144 |
| Record him talking about his best friend. | relationships | 48–216 |
| Record him answering "what's the best thing that happened today?" | his-words | 36–216 |
| Record him making up a song about nothing. | humor | 30–96 |

## Activity missions — `kind: activity` · `cadence: daily` · `mode: did_it`

No artifact required. These are behaviors, and they're half the reason this app exists.

| Prompt | Theme | Ages |
|---|---|---|
| Never let go of the hug first today. Let him be the one to pull away. | physical-affection | all |
| Get on the floor for ten minutes. That's the whole mission. | physical-affection | 24–120 |
| Carry him when he asks, even though he can walk fine. | physical-affection | 24–96 |
| Use his baby nickname out loud today, while he still answers to it. | his-words | 24–120 |
| Let him help with something, even though it triples the time. | making-building | 30–144 |
| Don't rush lights-out tonight. Stay an extra ten minutes. | sleep-routine | 24–144 |
| Say yes to the next thing you'd normally say no to. | me-as-a-parent | all |
| Let him choose dinner. Entirely. | food | 36–216 |
| Ask him a question and let the silence sit until he answers it. | his-words | 36–216 |
| Go outside with him with no plan and no phone. | outdoors | all |
| Apologize to him for something. Out loud. | me-as-a-parent | 36–216 |
| Let him win, and don't tell him you did. | humor | 36–120 |
| Tell him one specific thing you admire about him. Not "good job." | relationships | 36–216 |
| Do nothing next to him for fifteen minutes. | everyday-ordinary | all |
| Ask him to teach you something. | skills-firsts | 48–216 |
| Put your phone in another room for the whole evening. | me-as-a-parent | all |

## Weekly missions — `cadence: weekly`

Bigger, drops Saturday, expires in two weeks like everything else.

| Prompt | Kind | Theme | Mode | Ages |
|---|---|---|---|---|
| Take him on a solo date and let him pick everything — where you go, what you eat, what you do. | activity | relationships | media | 36–216 |
| Make cookies together this week. Photograph the mess, not the cookies. | activity | making-building | media | 30–144 |
| Build something with him that takes more than one sitting. | activity | making-building | media | 48–216 |
| Interview him with ten questions about his mom and film the whole thing. | video | relationships | media | 36–216 |
| Go somewhere neither of you has been before. | activity | outdoors | media | all |
| Spend an afternoon doing only what he suggests. | activity | everyday-ordinary | did_it | 36–216 |
| Cook something from your own childhood and tell him where it came from. | activity | food | media | 36–216 |
| Show him where you grew up — go there, or go through the photos. | activity | letters-forward | media | 48–216 |
| Ask him to pick three songs and play them loud in the kitchen. | activity | humor | media | 30–216 |
| Let him plan and "cook" one meal, whatever that means at his age. | activity | food | media | 48–216 |

## Monthly missions — `cadence: monthly` · fires on the 1st

| Prompt | Kind | Theme | Mode | Ages |
|---|---|---|---|---|
| Measure his height and weight. Photograph him against the same wall, same spot as last time. | measurement | growth-measurement | media | all |
| Take the same photo you took last month — same chair, same angle. | measurement | growth-measurement | media | all |
| Go back through your camera roll to this month last year and log three photos you never wrote down. | photo | growth-measurement | media | all |
| Trace his hand on paper and photograph it. | measurement | growth-measurement | media | 24–120 |

## Letters — `kind: letter` · `cadence: monthly` · `mode: text` · sealed

These set `unlock_at_age`. They're written *to* him, not about him.

| Prompt | Theme | Unlock | Ages |
|---|---|---|---|
| Write him something about money that you wish someone had told you at nineteen. | letters-forward | 18 | all |
| Write him a letter about exactly who he is right now. He won't be this person next year. | letters-forward | 16 | all |
| Write down what you were afraid of before he was born, and what actually happened. | letters-forward | 18 | all |
| Write him about a mistake you made that he'll probably make too. | letters-forward | 18 | all |
| Write down the story of the day he was born, in as much detail as you can still remember. | letters-forward | 13 | all |
| Write him something about his mother he'd never think to ask about. | relationships | 18 | all |
| Write down what you hope he keeps from being four years old. | letters-forward | 16 | 24–96 |
| Write him what you'd want him to know if you weren't around to say it. | letters-forward | 18 | all |

---

## Coverage check for the POC

Your son is 48 months. Prompts eligible at 48 months, by kind:

| Kind | Eligible | Enough for 14 days? |
|---|---|---|
| Question | 30 | ✅ |
| Photo | ~19 (before seasonal filtering) | ✅ |
| Video | 9 | ✅ |
| Audio | 11 | ✅ |
| Activity | 15 | ✅ |
| Weekly | 9 | ✅ |
| Monthly | 4 | ✅ |
| Letter | 8 | ✅ |

The 180-day cooldown holds comfortably at this size. When the library grows past ~300 you can tighten theme rotation instead of loosening cooldown.

## Expanding the library

Batch-generate candidates **server-side with a real model**, into a review queue. Never at request time, never on-device. Feed the generator this file as the style reference, plus a target theme and age band, and ask for 20 candidates at a time. Reject anything that:

- uses the words *precious*, *cherish*, *treasure*, or *little moments*
- describes a feeling instead of an action
- couldn't be done in the middle of an ordinary Tuesday
- assumes a two-parent household, a particular income, or a particular ability
