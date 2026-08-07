# Consensus

Universal group consensus & activity voting platform. A PWA that lets one organizer create a voting session and share a link; 4–7 friends click, type a name, and vote — **zero downloads, zero accounts**. MVP is a dining module; the core is an activity-agnostic decision engine.

**Status: pre-implementation.** No application code exists yet. The product scope is settled; the technical stack is not.

## Read first

| Doc | Authority |
|---|---|
| [docs/PRD.md](docs/PRD.md) | **North star for product.** Personas, functional requirements, success metrics. Ratified. Contains **no** stack, schema, vendor, or algorithm decisions — by design. |
| [docs/decisions.md](docs/decisions.md) | **North star for technical.** Running log of decisions as they get settled. |
| [docs/open-questions.md](docs/open-questions.md) | What still needs a decision before code gets written. |
| [docs/technical-roadmap-v1-draft.md](docs/technical-roadmap-v1-draft.md) | **Not ratified.** First-pass stack and schema proposal. Reference only — do not implement from it. |
| [docs/prd-technical-extracts.md](docs/prd-technical-extracts.md) | **Not ratified.** Technical content removed from PRD v2.0, preserved as a second candidate proposal. It contradicts the roadmap draft in places. Reference only. |

Authority order: `decisions.md` > `PRD.md` > the two unratified drafts. If a draft and `decisions.md` disagree, `decisions.md` is correct. If nothing covers it, ask — don't infer a stack choice.

**Keep the separation clean.** Product docs say what and why; technical docs say how. Don't reintroduce a vendor name, table definition, framework, or algorithm into the PRD — put it in `decisions.md` (settled) or `open-questions.md` (not).

## Repo layout

```
/
├── CLAUDE.md                          # this file — read first every session
├── .claude/
│   ├── agents/                        # subagent definitions (empty until stack is set)
│   ├── skills/                        # invocable workflows (empty until stack is set)
│   └── settings.json
└── docs/
    ├── PRD.md                         # product requirements only (north star)
    ├── decisions.md                   # ADR-lite log — technical source of truth
    ├── open-questions.md              # blocking + non-blocking unknowns
    ├── technical-roadmap-v1-draft.md  # unratified stack proposal #1
    ├── prd-technical-extracts.md      # unratified stack proposal #2 (ex-PRD §4/§6/§8)
    └── plans/                         # per-feature implementation plans
```

## Product invariants

These come from the PRD and should not be traded away for implementation convenience:

1. **Voter friction is zero.** A guest voting via a shared link never sees a signup, a password, an email field, or an app-store redirect. Name entry (or anonymous) is the maximum ask.
2. **The engine is activity-agnostic.** Nothing in the voting, tally, or session-lifecycle code may reference `restaurant`. Dining is one activity module among several (movie, travel, lodging, custom).
3. **Every session has a hard deadline.** Voting locks automatically; a winner is declared without organizer intervention.
4. **Results are real-time.** Participants see vote state update without a manual refresh.
5. **The session ends in an action, not a summary.** A winner renders a booking/ticketing CTA plus a runner-up failsafe and a paste-back-to-chat summary string.
6. **Anonymous voting is a first-class mode**, not a toggle bolted on later — it's the core relief for the indecisive-voter persona.

Primary success metric: **Time to Consensus under 5 minutes.** Guest drop-off on the link interface under 5%.

## Scope discipline

MVP is the dining module only. These are explicitly Post-MVP and should not be built early:

- Ranked-choice voting (Borda / IRV)
- Two-phase sequential funnels (movie → showtime)
- TMDB / Fandango / Gracenote integrations
- Travel & lodging modules
- Organizer accounts, saved friend groups, venue blacklists

Post-MVP features may inform the *shape* of MVP data models (so the refactor isn't painful), but no Post-MVP code paths.

## Working agreements

- Non-trivial features get a plan in `docs/plans/<feature>.md` before code.
- Any settled technical choice gets appended to `docs/decisions.md` with the date and the reasoning — including choices made mid-conversation.
- Third-party API keys never land in the repo. `.env.local` only.
- External API calls (Places/Yelp and later TMDB) must go through a caching layer from the first commit that touches them — the roadmap flags per-query cost as the top financial risk.
