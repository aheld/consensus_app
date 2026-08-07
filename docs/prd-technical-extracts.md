# Technical Content Extracted from the PRD

On 2026-08-07 the PRD was reduced to product requirements only (v2.0 → v3.0). Everything technical
it asserted is captured verbatim below so no proposal is lost and so
[open-questions.md](open-questions.md) keeps its citations.

**Status: none of this is ratified.** These are prior proposals, at the same authority level as
[technical-roadmap-v1-draft.md](technical-roadmap-v1-draft.md) — which, notably, contradicts several
of them. Settled decisions go in [decisions.md](decisions.md).

---

## From §1 — Distribution Strategy

> **The Solution:** A **Progressive Web App (PWA)** combined with a **Frictionless "Link-Share" Model**.

**What survived in the PRD:** the access requirements — no install, no account, works in the browser
the link opens in, including messaging-app in-app browsers.

**What became a technical question:** whether "PWA" in the installable sense (service worker,
manifest, install prompt, offline buffer) is part of the MVP at all, versus plain mobile-optimized
web. See Q-13.

---

## From §3 — Competitive positioning

The competitor table row read `**Consensus (Our PWA)**` and the positioning line read
"Our Positioning (Consensus PWA)". Both now say "Consensus" — the *positioning* claim (zero
friction, very high richness) is product; the delivery mechanism is not.

---

## From §4 — System Architecture & Platform Strategy

> ### The progressive Web App (PWA) Choice
> To maximize engagement, the platform will be built as a mobile-optimized PWA using a
> React-based frontend framework (e.g., Next.js) and a fast backend database
> (e.g., PostgreSQL with Supabase Realtime).

This is the PRD's stack proposal, and it is **the one cited in Q-1/Q-2**: it directly contradicts
`technical-roadmap-v1-draft.md`, which proposes a separate NestJS service with Socket.io and Redis
pub/sub on Render or ECS Fargate. Two source documents, two incompatible architectures. Resolving
that is Q-1.

Also from §4, the rich chat preview:

> When an organizer starts a session, the app compiles a beautiful preview card

The *outcome* (a rich preview renders in the chat) stayed in the PRD as a requirement. The
*mechanism* (server-rendered Open Graph / Twitter card metadata, per roadmap Milestone 2.3) is
technical.

---

## From §5.1 — Named vendor integrations in MVP requirements

| PRD text | Now stated as | Vendor question |
|---|---|---|
| "Integrates Google Places or Yelp API to query and display nearby restaurants" | organizer can search restaurants near the session location | Q-6 — provider choice, pricing model, caching terms |
| "Embedded link to Google Maps or Yelp for reviews" | link out to a map and reviews | follows from Q-6 |
| "linking directly to booking platforms (OpenTable, Resy, or the restaurant's website)" | a primary CTA that takes the group toward an actual reservation | Q-5 — whether public deep-links exist at our tier |
| "Real-time API checks flag sold-out showtimes or fully-booked restaurants" (§2, Jessica) | options are checked for availability before the group votes | depends on Q-5/Q-6; live availability may not be obtainable |
| "Real-time Engine: Active votes update in real-time" | vote tallies update without a manual refresh | Q-2 — sockets vs. managed realtime vs. polling |

The last row matters: "real-time" as a *user-visible property* is a requirement; "a real-time
engine" as a *component* was a design decision smuggled into a requirement.

---

## From §5.2 — Algorithm and vendor specifics

> Backend calculates the **Borda count or Instant Runoff** to ensure maximum group satisfaction and
> eliminate majority-splitting.

Borda and IRV are different systems that produce different winners from the same ballots. The PRD
now states the *fairness goal* (a broadly-liked second choice should be able to beat a polarizing
plurality winner); picking the tabulation method is a technical decision — and note that goal as
phrased leans Borda.

> The system automatically queries local theater APIs (**Gracenote, Fandango**) … the primary action
> button transforms into a direct **Fandango** checkout link.

> **Travel/Lodging Module:** … utilizing **Airbnb/VRBO API** concepts.

Also from the roadmap, not the PRD: **TMDB** for movie metadata. All Post-MVP vendor selection.

---

## From §6 — Technical Architecture: Activity-Agnostic Schema

Removed in full. The PRD now carries the *requirement* (§6, Extensibility) — new activity types
without engine changes or migrations — while the schema below is a candidate implementation.

> The database must support polymorphic payloads so that the consensus engine operates independently
> of what is being voted on.

```
┌─────────────────────────────────────────────────────────────┐
│                       DATABASE SCHEMA                       │
├─────────────────┬───────────────────────────────────────────┤
│ Table           │ Core Attributes                           │
├─────────────────┼───────────────────────────────────────────┤
│ Session         │ id, host_id, activity_type, deadline,      │
│                 │ phase (1 or 2), status (active, completed)│
├─────────────────┼───────────────────────────────────────────┤
│ Option          │ id, session_id, title, description,       │
│                 │ image_url, metadata (JSONB), action_url   │
├─────────────────┼───────────────────────────────────────────┤
│ Vote            │ id, session_id, user_id, option_id,       │
│                 │ rank_weight, preference_type (yes/no/veto)│
└─────────────────┴───────────────────────────────────────────┘
```

> The `metadata` column utilizes a PostgreSQL **JSONB** format. This allows the backend to store
> restaurant ratings, movie runtimes, or cabin check-in times without database migrations:
> * **Dining Payload:** `{"cuisine": "Italian", "price": "$$$", "rating": 4.5}`
> * **Movie Payload:** `{"duration": "166 mins", "rating": "PG-13", "format": "IMAX"}`
> * **Lodging Payload:** `{"price_per_night": "$180", "beds": 3, "amenities": ["Pool", "Wifi"]}`

**Keep in view when the real schema is designed:** this version has `Vote.preference_type
(yes/no/veto)`, which the roadmap's schema drops even though veto is an MVP must-have — that
discrepancy is Q-9. It also has no `Participant` table (Q-10) and uses `user_id` on votes, implying
registered users the MVP won't have (Q-11).

---

## From §8 — Development Phases & Roadmap

The PRD's phase diagram was engineering sequencing, including technical spikes. Replaced with
product-level release sequencing. Original:

```
  [ PHASE 1: Technical Spikes ] ──► [ PHASE 2: Core Dining PWA MVP ]
  - Test Google Places/Yelp APIs      - Simple named voting
  - Validate Resy/OpenTable deep-links - Automated countdown & winner lock

                │
                ▼
  [ PHASE 3: Activity Expansion ] ◄─ [ PHASE 4: Sequential Protocols ]
  - TMDB/Fandango showtime engines     - Phase 1 (What) ➔ Phase 2 (When)
  - Custom opinion polling module      - Ranked-Choice Voting (RCV)
```

Worth keeping: **the instinct to spike the third-party dependencies before committing to
requirements that assume them** — the PRD put spikes in Phase 1 while the roadmap draft schedules
booking deep-links as buildable work in Milestone 1.3. The PRD's ordering was the more honest one
(Q-5, Q-6).
