# Technical Roadmap: Universal Group Consensus Platform

This document outlines the end-to-end technical execution, architecture, and phase-by-phase implementation schedule to transition the original Restaurant Voting PRD [1] into a scalable, **Universal Group Consensus Platform**. 

The engineering strategy is built on a single, core philosophy: **Minimize Voter Friction [11] while Maximizing Core Architectural Flexibility.**

---

## 🏛️ 1. Platform Architecture & Tech Stack

To support the Progressive Web App (PWA) link-share model and the polymorphic database architecture, we will utilize a highly decoupled, modern, and scalable stack.

```
       [ Client-Side (PWA) ] 
          (Next.js / React)
                 │
                 ├── WebSockets (Real-time sync)
                 ▼
     [ API Gateway / Backend ] (Node.js / TypeScript / NestJS)
                 │
                 ├── Polling / Caching (Redis)
                 ▼
       [ DB / Storage Layer ] (PostgreSQL with JSONB)
                 │
                 └── External API Integrations (Yelp, TMDB, Fandango)
```

### Frontend (PWA Shell)
* **Framework:** **Next.js (React)** with Tailwind CSS. Next.js App Router allows us to server-side render (SSR) the landing card for instant link loads, while client-side React handles fluid swipe physics and real-time state changes.
* **State Management:** **Zustand** (lightweight, optimized for high-performance reactive updates) combined with **WebSockets** for live voting updates [10].
* **Deployment:** Hosted on **Vercel** for globally distributed, instant loads on mobile browsers.

### Backend (Consensus Engine API)
* **Runtime:** **Node.js with TypeScript** (NestJS framework). NestJS offers strict structure, built-in WebSocket gateways, and clean dependency injection for swap-in/swap-out activity modules.
* **Real-time Protocol:** **Socket.io** / native WebSockets fallback. Necessary to sync votes in real time without forcing manual page refreshes [10].
* **Hosting:** **Render** or **AWS ECS Fargate** to manage stateless HTTP API routes and persistent WebSocket connections.

### Database (Polymorphic Storage)
* **Database:** **PostgreSQL**. Relational tables handle structured relationships (Sessions, Votes, Participants), while native **JSONB** support handles dynamic schema variants (e.g., cuisine type vs. movie showtimes).
* **Caching Layer:** **Redis** for managing active websocket rooms and caching expensive third-party search queries (Yelp, TMDB) to prevent API rate limiting.

---

## 🗺️ 2. Phase-by-Phase Execution Plan

```
  Phase 1: MVP - Frictionless Dining  [Weeks 1-6]
  ├── Core voting engine, temporary sessions, iMessage/WhatsApp link sharing [11]
  
  Phase 2: Polymorphic Refactoring   [Weeks 7-12]
  ├── Database decoupling, dynamic cards, custom manual entry [11]
  
  Phase 3: Advanced Funnels & Media  [Weeks 13-18]
  └── Ranked-Choice Voting (RCV) [13], TMDB API, 2-phase movie scheduler
```

### 🗓️ Phase 1: MVP - Frictionless Dining (Weeks 1-6)
**Objective:** Deliver a highly polished, zero-friction voting experience for friend groups planning dinners 1-2 days in advance [1, 12].

* **Milestone 1.1: The Frictionless Gateway (Week 1-2)**
  * Implement **localStorage-based "Guest Sessions."** Guests clicking an invite link simply type a display name and vote [11]. No email, passwords, or authentication required.
  * Establish the short-code session router (e.g., `app.domain/join/XYZ-123`).
* **Milestone 1.2: Restaurant Discovery & Maps API (Week 3-4)**
  * Integrate the **Yelp Fusion API** & **Google Places API** [10]. 
  * Build the initial search/filtering loop where Sarah "The Organizer" can query nearby spots and curate a shortlist [10].
* **Milestone 1.3: Real-Time Vote Sync (Week 5-6)**
  * Establish WebSocket rooms for active voting sessions [10].
  * Implement the single-vote tally mechanics and automatic timer locks [10].
  * Design the **"Book Now" deep-link router** pointing to OpenTable and Resy checkout endpoints [11].

---

### 🗓️ Phase 2: Polymorphic Refactoring (Weeks 7-12)
**Objective:** Decouple the dining-specific models from the engine to prepare for non-dining activities.

* **Milestone 2.1: JSONB Schema Migration (Week 7-8)**
  * Migrate `restaurant_id` fields to generic, polymorphic `option_id` fields.
  * Convert hardcoded database columns (e.g., `cuisine`, `price`) into a flexible `metadata` JSONB schema in PostgreSQL (see schema section).
* **Milestone 2.2: Dynamic UI Card Registry (Week 9-10)**
  * Refactor frontend layout engines to load component wrappers based on the `activity_type` of the session.
  * Implement a **Custom Manual Entry Template** that lets users vote on completely custom ideas (e.g., "Whose house are we pre-gaming at?") using plain text and uploaded images [11].
* **Milestone 2.3: Shared Link Previews (Week 11-12)**
  * Implement Server-Side Render (SSR) metadata tagging so that sharing a voting session link on WhatsApp or iMessage displays a beautiful rich preview (e.g., *"Sarah is planning: Friday Dinner 🍕"*).

---

### 🗓️ Phase 3: Advanced Funnels & Media (Weeks 13-18)
**Objective:** Implement multi-stage sequencing, advanced voting protocols, and movie showtime logistics [13].

* **Milestone 3.1: Ranked-Choice Voting (RCV) Engine (Week 13-14)**
  * Write the consensus algorithm in the NestJS backend to process weighted arrays (e.g., `[Option A, Option C, Option B]`) and output a single, fairer winner [13].
  * Build a frontend drag-and-drop ranking UI with fluid card sorting animations.
* **Milestone 3.2: Media Discovery Integration (Week 15-16)**
  * Integrate with the **The Movie Database (TMDB) API** to retrieve posters, trailers, runtimes, and descriptions.
  * Integrate with **Gracenote / Fandango API** to fetch local theater listings and times.
* **Milestone 3.3: Two-Phase Sequential Planning (Week 17-18)**
  * Implement the state machine logic allowing sessions to transition from **Phase 1 (What movie to watch)** directly to **Phase 2 (When & where to watch it)**.
  * Render the calendar scheduling grid showing time availability, auto-populating final ticketing checkouts.

---

## 💾 3. Core Database Models (PostgreSQL & JSONB)

To demonstrate the polymorphic capabilities of the backend, the PostgreSQL schema handles dynamic options in a unified data structure.

### Sessions Table (`sessions`)
Tracks the active group planning session, its deadline [10], current phase, and the activity type.

| Column Name | Data Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | `UUID` | Primary Key, default `gen_random_uuid()` | Unique session identifier |
| `share_code` | `VARCHAR(8)` | Unique, Indexed | Short code for URL entry (e.g., `BFA82X`) |
| `organizer_id` | `UUID` | Foreign Key (`users.id`), Nullable | Reference to the organizer (if registered) |
| `title` | `VARCHAR(255)` | Not Null | Title of the event (e.g., "Friday Dinner!") |
| `activity_type`| `VARCHAR(50)` | Not Null (Default: `'dining'`) | `'dining'`, `'movie'`, `'travel'`, `'custom'` |
| `current_phase`| `INTEGER` | Not Null (Default: `1`) | Tracks multi-stage funnels (`1` or `2`) |
| `status` | `VARCHAR(20)` | Not Null (Default: `'voting'`) | `'voting'`, `'locked'`, `'completed'` |
| `deadline` | `TIMESTAMP` | Not Null | Dynamic lock time [10] |

### Options Table (`options`)
Stores the choices available for the vote. The `metadata` column stores the dynamic content fields.

| Column Name | Data Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | `UUID` | Primary Key | Unique option identifier |
| `session_id` | `UUID` | Foreign Key (`sessions.id`), Cascade Delete | Links option to specific session |
| `title` | `VARCHAR(255)` | Not Null | Name of option (e.g., restaurant/movie name) |
| `image_url` | `VARCHAR(512)` | Nullable | Primary photo link |
| `description` | `TEXT` | Nullable | Short synopsis |
| `metadata` | `JSONB` | Not Null (Default: `'{}'`) | Dynamic key-value pairs (polymorphic fields) |
| `action_url` | `VARCHAR(512)` | Nullable | Third-party booking or purchase deep-link [11] |

#### Polymorphic JSONB Metadata Payload Examples:
```json
// If activity_type is "dining"
{
  "price": "$$$",
  "rating": 4.6,
  "cuisine": "Italian",
  "address": "123 Pasta Way, Los Angeles, CA",
  "phone": "555-0199"
}

// If activity_type is "movie"
{
  "rating": "PG-13",
  "duration": "166 mins",
  "genre": "Sci-Fi / Drama",
  "theater": "AMC Century City",
  "showtime": "7:15 PM (Friday)",
  "trailer_url": "https://youtube.com/watch?v=..."
}
```

### Votes Table (`votes`)
Records client consensus. Supports standard single-choice voting [10], ranked preference arrays, and showtime-selections.

| Column Name | Data Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | `UUID` | Primary Key | Unique vote identifier |
| `session_id` | `UUID` | Foreign Key (`sessions.id`) | Links vote to specific session |
| `participant_id`| `UUID` | Foreign Key (`participants.id`) | Unique guest voter tracking ID |
| `option_id` | `UUID` | Foreign Key (`options.id`) | Selected choice |
| `rank_weight` | `INTEGER` | Nullable (Default: `1`) | Used in RCV [13] (e.g., 1 = Top Pick, 2 = Second, etc.) |
| `phase` | `INTEGER` | Not Null (Default: `1`) | Records which planning phase the vote belongs to |

---

## ⚡ 4. Real-Time State Sync Architecture

To ensure a smooth, lag-free experience for users like Rachel "The Quiet Voter" [5], state changes must update instantly across all active screens.

```
       User A (Casts Vote)             NestJS Server               User B (On Session Page)
               │                             │                                 │
               ├─── websocket: castVote ────►│                                 │
               │                            ├─── Calculates New Totals        │
               │                            ├─── Updates DB Cache             │
               │                            │                                 │
               │                            └─── broadcast: sessionUpdate ───►│
               │                                                              │ (UI Updates instantly)
```

1. **State Broadcasts:** When a user swipes or votes, a JSON payload is pushed over WebSockets. The NestJS backend captures the vote, commits it to the Postgres transactional database, updates the active session cache in Redis, and broadcasts the new percentage results to all participants in that room.
2. **Offline Resilience:** If Rachel loses cell signal during her nursing shift [5], the app queues state changes in a localized `localStorage` buffer. When connection is re-established, the PWA client fires a single synchronization packet to catch her screen up instantly.

---

## 🛡️ 5. Key Technical Risks & Mitigations

### 1. The Yelp / Google Maps API "Cost Trap"
* **The Risk:** Every search query by organizers can quickly trigger thousands of expensive external API requests, exceeding free tiers and scaling backend operational costs.
* **The Mitigation:** Implement a robust **Elastic Redis Cache**. When an organizer queries "Tacos in Santa Monica," the backend first queries Redis. Results are cached for 24 hours, shielding your API credits from repetitive neighborhood searches.

### 2. Live Session WebSocket Flooding
* **The Risk:** Highly active friend chats (frequent voting, real-time message alerts) can overwhelm a single WebSocket node during peak Friday dinner-planning hours.
* **The Mitigation:** Design the backend to be entirely **stateless**. Use Redis as a Pub/Sub message broker to scale WebSockets horizontally across multiple platform nodes.

### 3. Deep-Link Reservation Breakage
* **The Risk:** Third-party reservation systems (Resy, OpenTable) frequently update their URL deep-linking structures, which could cause our "Book Now" button to break [11].
* **The Mitigation:** Route all booking checkouts through a dynamic redirection gateway (e.g., `app.domain/api/redirect/booking?option_id=XYZ`). If a platform changes its endpoint design, we can fix it instantly in the backend config without pushing a new build of the web app.
