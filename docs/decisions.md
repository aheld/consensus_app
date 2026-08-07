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

<!-- Append new decisions below.

## D-00N — <short title>

- **Date:** YYYY-MM-DD
- **Status:** settled | provisional | superseded by D-00M
- **Decision:** what we're doing.
- **Why:** the reasoning, including what it buys us against the PRD's invariants.
- **Alternatives rejected:** and why.
- **Consequences:** what this forecloses or obligates later.

-->
