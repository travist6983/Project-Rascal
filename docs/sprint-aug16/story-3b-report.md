# Story 3b — guardians on the phone. Report.

## ALREADY LANDED. Gate 3, exit 0. No phase number consumed.

Story 3b's gate 3: *"If the invite-accept screen and the Settings guardians section both exist,
report `ALREADY LANDED` and exit 0."*

Both exist, delivered by two phases that ran on Aug 17, 2026:

- **Phase 61 — "inviting the other parent, from the phone"** (`af45a65`):
  `Settings/GuardiansSection.swift`, `Settings/GuardiansModel.swift`, `Networking/FamiliesAPI.swift`
- **Phase 63 — "tapping the invitation"** (`d307f9a`):
  `Onboarding/InviteAcceptScreen.swift`, `Onboarding/InviteAcceptModel.swift`,
  `Onboarding/InviteLink.swift`

## Gate 2 — the contract it was built against

Gate 2 says *"do not build against a contract you inferred from story 3a's prompt file — build
against what shipped."* That is what happened, and it is visible in the artifact: `FamiliesAPI.swift`
is written against `GET /v1/families/me` and the invite routes as they exist in
`routers/families.py`, not against story 3a's description of them.

Worth noting because story 3a's spec and the shipped API **do** differ in places — the sprint's
stories were authored roughly thirteen phases behind `main`. Building from the spec would have
produced a client for an API that does not exist.

## Gate 5 — sign-in providers, and the honest limitation

Both `apple` and `google` shipped (phases 55 and 58 on the client, 54 and 57 on the server), so
the accept flow can offer both rather than Apple alone. The limitation gate 5 asked to be stated
plainly does not apply in the form it anticipated — **an invitee without an Apple ID can accept**,
because Google is a real second path.

`dev-login` was not reached for, as instructed.

## What this story does not tell you

**It is still gated behind the tier.** `services/guardians.py` refuses to create an invite unless
the family's entitlement is `subscribed`, per decision 4 of story 3a. The owner's own family was
set to `subscribed` in production on Aug 17 to verify the gate opens; a free-tier household still
cannot invite anybody, which is the design and not a defect.

So "guardians works on the phone" is true, and "any parent can invite another today" is not.
