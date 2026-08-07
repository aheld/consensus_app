# Technical Decisions

ADR-lite log. Newest last. Anything recorded here supersedes
[technical-roadmap-v1-draft.md](technical-roadmap-v1-draft.md), which is an unratified first pass.

Format: one entry per decision. Status is `settled`, `provisional`, or `superseded`.

---

## D-001 — Product scope is ratified; technical stack is not

- **Date:** 2026-08-07
- **Status:** settled

`docs/PRD.md` is accepted as the product north star: personas, functional requirements, MVP/Post-MVP split, and success metrics are not up for re-litigation without an explicit decision here.

`docs/technical-roadmap-v1-draft.md` is retained as a reference proposal only. Its stack picks (NestJS, Socket.io, self-managed Redis, Render/Fargate, an 18-week three-phase schedule) are treated as *one candidate*, not the plan. No code should be written against it until the corresponding decisions are logged here.

**Open for revision:** frontend framework, backend shape (dedicated API service vs. serverless routes), realtime transport, database host, caching strategy, hosting, and the phase schedule. See [open-questions.md](open-questions.md).

---

## D-002 — The PRD carries no technical implementation decisions

- **Date:** 2026-08-07
- **Status:** settled

`docs/PRD.md` (v2.0 → v3.0) was reduced to product content only: what the product must do, for whom, and how success is measured. Removed: the PWA/React/Next.js/Postgres-with-Supabase-Realtime stack proposal (§4), named vendor integrations inside requirements (Google Places, Yelp, OpenTable, Resy, Gracenote, Fandango, Airbnb/VRBO), the Borda-vs-IRV tabulation choice, the database schema sketch with JSONB payload examples (§6), and the engineering phase diagram with technical spikes (§8).

**Why:** requirements that name a vendor or a table can't be evaluated against alternatives — the decision is already made and hidden inside the requirement. Splitting them lets the stack be revised without touching product scope, and makes the roadmap's contradictions with the PRD visible instead of latent.

**What replaced them:**
- §4 is now *Access & Distribution Requirements* — stated as constraints (no install, no account, works in messaging-app in-app browsers, ~10s to vote) rather than a technology.
- §5 requirements name capabilities, not integrations; "Real-time Engine" became "Live Vote State" (the user-visible property, not the component).
- §6 is now *Extensibility Requirement* — five testable conditions for activity-agnosticism, with the custom/manual free-text activity type as the floor test.
- §8 is now product-level release sequencing; only Release 1 is committed scope.

**Preserved, not deleted:** everything removed is in [prd-technical-extracts.md](prd-technical-extracts.md) at draft authority. This matters because the PRD's Supabase Realtime proposal is one side of Q-1 and would otherwise have vanished.

**Consequences:** two unratified technical drafts now exist and they conflict — the roadmap wants a self-hosted NestJS/Socket.io/Redis stack, the ex-PRD wants managed realtime. Q-1 must resolve that explicitly. Also: nothing in the repo currently specifies a stack, which is the intended state until decisions land here.

---

<!-- Append new decisions below.

## D-00N — <short title>

- **Date:** YYYY-MM-DD
- **Status:** settled | provisional | superseded by D-00M
- **Decision:** what we're doing.
- **Why:** the reasoning, including what it buys us against the PRD's invariants.
- **Alternatives rejected:** and why.
- **Consequences:** what this forecloses or obligates later.

-->
