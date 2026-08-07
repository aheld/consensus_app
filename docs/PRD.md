# Product Requirements Document (PRD)
## Universal Group Consensus & Activity Voting Platform

**Project Codename:** Consensus  
**Target Market:** Friend groups (5–8 people) planning dinner outings and group activities 1–2 days in advance [1]  
**Document Version:** 2.0 (Updated based on Competitive & Architectural Market Analysis)  

---

## 1. Executive Summary & Strategic Pivot

The original "Restaurant Voting App" PRD aimed to solve the acute friction friend groups face when deciding where to eat [1]. However, a deep dive into the competitive landscape and group psychology reveals that **"where to eat" is just a subset of a much larger, universal problem: collaborative group decision-making**. 

### The Strategic Pivot: The Activity-Agnostic Core Engine
We are pivoting the platform from a single-use restaurant picker to a **Universal Group Consensus Platform**. The core IP of the platform is an **Activity-Agnostic Decision Engine**. 
* **MVP Focus:** A laser-focused, frictionless **Dining Module** to capture the immediate high-pain market (restaurant voting) [1, 10].
* **Post-MVP Focus:** Seamless extensions into other high-frequency group activities (movies, concerts, travel, lodging, and custom polling) without rewriting the core voting architecture.

### The Distribution Strategy: Combating "Friction Asymmetry"
Group planning apps usually suffer from **Friction Asymmetry**: while the organizer is highly motivated to download an app and coordinate, the other 4–7 participants are passive and will refuse to download a native app or register an account just to vote on Friday dinner.
* **The Solution:** A **Progressive Web App (PWA)** combined with a **Frictionless "Link-Share" Model**.
* **How it works:** Only the organizer needs to create a session. Friends receive a web link via standard messaging apps (WhatsApp, iMessage), click it, enter their name, and vote instantly inside their mobile browser. **Zero app downloads, zero account creation.**

---

## 2. Updated User Personas & Pain-Point Mapping

The platform is designed to resolve the specific anxieties of our five core personas by mapping our platform decisions directly to their frustrations:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        ANXIETY & PAIN MAPPING                          │
├───────────────────────┬────────────────────────┬───────────────────────┤
│ Persona               │ Core Frustration       │ Platform Solution     │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Sarah "The Organizer" │ Doing all the admin    │ Automated consensus & │
│ (Age 28) [1]          │ work; taking blame [1] │ direct booking loops  │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Aaron "Indecisive"    │ Social pressure;       │ Anonymous voting;     │
│ (Age 50+) [2]         │ fear of vetos [2]      │ clean micro-choices   │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Jessica "The Planner" │ Endless delays;        │ Hard deadlines; real- │
│ (Age 29) [3]          │ sold-out listings [3]  │ time availability checks│
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Alex "The Foodie"     │ Suggestions get lost;  │ Rich visual cards;    │
│ (Age 30) [4]          │ quiet default picks [4]│ easy review embeds    │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Rachel "Quiet Voter"  │ catching up on 200+    │ Instant plan summary  │
│ (Age 27) [5]          │ missed messages [5]    │ with deep ticket links│
└───────────────────────┴────────────────────────┴───────────────────────┘
```

### 1. Sarah "The Organizer" (28, Marketing Manager) [1]
* **Profile:** Coordinates friend hangouts via multiple daily group chats [1].
* **Frustrations:** Spends 30+ minutes in group chats gathering input; gets blamed when restaurant picks fail; manages restaurant availability manually [1].
* **Platform Relief:** Sarah generates a session link in 10 seconds. The app automatically tracks who has/hasn't voted, closes voting at a set deadline, declares the winner, and presents booking links [10, 11].

### 2. Aaron "The Indecisive One" (50+, Software Engineer) [2]
* **Profile:** Easygoing, likes most foods, but struggles with decisions and commitment [2].
* **Frustrations:** Feels pressured when asked "where do you want to eat?"; hates vetoing options out loud; gets overwhelmed by massive lists [2].
* **Platform Relief:** The app uses micro-interactions (e.g., swiping or list voting) and anonymous voting options [11, 12], eliminating the social pressure of committing or vetoing in public group text threads [2].

### 3. Jessica "The Planner" (29, Teacher) [3]
* **Profile:** Highly organized, hates last-minute changes or open-ended plans [3].
* **Frustrations:** Group decisions drag on for days; friends suggest fully-booked or closed venues; cannot plan her week due to lack of confirmation [3].
* **Platform Relief:** Every session is bound to a hard, organizer-defined **decision deadline** [10]. Real-time API checks flag sold-out showtimes or fully-booked restaurants before users vote on them.

### 4. Alex "The Foodie" (30, Graphic Designer) [4]
* **Profile:** Passionate about discovery, has strong opinions but doesn't want to dominate [4].
* **Frustrations:** Great suggestions get lost in text noise; people don't click links he shares; groups default to "safe" options [4].
* **Platform Relief:** Rich interactive visual cards showcase high-resolution photos, ratings, price levels, and expert highlights, ensuring his premium recommendations are presented beautifully and get noticed [11].

### 5. Rachel "The Quiet Voter" (27, Nurse) [5]
* **Profile:** Works irregular shifts, belongs to multiple active friend groups [5].
* **Frustrations:** Misses live discussions; catches up to find 200+ unread text messages; misses changes in plans [5].
* **Platform Relief:** Rachel opens the shared session link, sees the exact curated list of options, casts her vote in 10 seconds, and receives an automatic winner notification with reservation/ticketing details without reading group chat logs [5, 6, 11].

---

## 3. Competitive Landscape & Market Positioning

```
┌────────────────────────────────────────────────────────────────────────┐
│                        COMPETITOR LANDSCAPE                            │
├────────────────────────────┬──────────────────┬────────────────────────┤
│ Competitor/Method          │ Friction Level   │ Visual & Data Richness │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ Group Texts [6]            │ Zero             │ Extremely Low          │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ Instagram/Snapchat Polls [7]│ Low              │ Medium (Static Polls)  │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ Google Forms / Doodle [8]  │ Medium (Formal)  │ Low (Text Only)        │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ Native Apps (MunchMatch)   │ High (App Store) │ Very High              │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ WhatsApp Chatbots          │ Very Low         │ Low (Text Menus Only)  │
├────────────────────────────┼──────────────────┼────────────────────────┤
│ **Consensus (Our PWA)**    │ **Zero**         │ **Very High**          │
└────────────────────────────┴──────────────────┴────────────────────────┘
```

* **Group Text Messages (Primary Competitor):** Unstructured, highly conversational, but has no decision logic, lacks visual comparisons, and creates massive decision fatigue (8/10 Pain Point) [6, 7].
* **Google Forms / Doodle Polls:** Structured but too formal for casual friend hangouts; lacks integrated discovery, photos, and automated booking loops (5/10 Pain Point) [8].
* **Native-Only Swiping Apps (MunchMatch):** Fun Tinder-style UI, but introduces high friction by requiring all group members to download an app and register accounts. This kills conversion.
* **WhatsApp Chatbots:** Low friction but highly constrained by text-based WhatsApp layouts, a hard 12-poll-option limit, and an inability to display maps, menus, and media easily.
* **Our Positioning (Consensus PWA):** Combines the frictionless entry of group web links with the rich, visual, real-time gaming elements of native apps.

---

## 4. System Architecture & Platform Strategy

### The progressive Web App (PWA) Choice
To maximize engagement, the platform will be built as a mobile-optimized PWA using a React-based frontend framework (e.g., Next.js) and a fast backend database (e.g., PostgreSQL with Supabase Realtime).
1. **Organizer Loop:** Organizers can optionally create an account to save their friend groups, historical voting preferences, and blacklisted venues [12, 13].
2. **Voter Loop:** Invited guests enter their name (or remain anonymous) upon clicking the shared web link and vote instantly [11]. **No password or registration required.**

### The Link-Share Model
Instead of trying to replace WhatsApp or iMessage, **Consensus** rides on top of them. When an organizer starts a session, the app compiles a beautiful preview card:

> 🗳️ **Dinner Friday? Let's Decide!**  
> Sarah has set up a session to pick a spot.  
> 🕒 *Votes close Thursday at 6:00 PM*  
> 🔗 **Tap to Swipe & Vote:** `https://consensus.app/join/session_abc123`

---

## 5. Functional Requirements: MVP vs. Post-MVP

### 5.1 MVP Dining Module (Must-Haves) [10, 11]

#### A. Core Voting Mechanism
* **Session Creation:** Organizers specify a title, voting deadline, and search location/radius [10].
* **Option Discovery:** Integrates Google Places or Yelp API to query and display nearby restaurants [10, 11].
* **Co-Creation:** Group members can search and add their own restaurant suggestions to the voting pool [10, 11].
* **Real-time Engine:** Active votes update in real-time. A visual status bar shows who has and hasn't voted [10, 11].
* **Veto Power:** Each voter can apply one "Veto" to an option they absolutely refuse to visit, instantly removing it from the eligible list and preventing group deadlock.

#### B. Restaurant Detail Cards
* Display name, high-resolution photo, cuisine tags, and price rating ($ to $$$$) [11].
* Embedded link to Google Maps or Yelp for reviews [11].

#### C. Resolution & Booking Loops
* **Winner Lock:** When the deadline passes, the system locks voting and declares the winning restaurant [10, 11].
* **Instant Booking Action:** Renders a primary call-to-action button linking directly to booking platforms (OpenTable, Resy, or the restaurant's website) [11].
* **Failsafe Option:** If the top choice is fully booked or closed, the app immediately displays the runner-up (#2) option with active reservation links [11].
* **Social Summary Copy:** Generates a one-click summary of the results (e.g., *"It's a Match! We are going to Osteria Mozza on Friday at 7:30 PM. Book here: [Link]"*) that organizers can paste back into their WhatsApp group [11].

---

### 5.2 Post-MVP Advanced Modules (Nice-to-Haves) [12, 13]

#### A. Advanced Consensus Engine: Ranked-Choice Voting (RCV)
* Users drag and drop options to rank them (#1, #2, #3).
* Backend calculates the Borda count or Instant Runoff to ensure maximum group satisfaction and eliminate majority-splitting.

#### B. Two-Phase Sequential Funnels (The Movie Showtime Use Case)
To prevent combinatorial cognitive overload, the app handles multi-variable decisions in a structured two-stage funnel:
* **Phase 1: Content Consensus (The "What")**
  * Group votes on the movie they want to watch (e.g., *Dune* vs. *The Batman*) using Ranked-Choice Voting.
  * System declares the winning movie ID.
* **Phase 2: Logistics Consensus (The "When & Where")**
  * The system automatically queries local theater APIs (Gracenote, Fandango) based on the winning movie.
  * It generates a dynamic calendar showtime grid.
  * Friends tap the showtime pills that fit their schedules (e.g., *Friday 7:15 PM* or *Saturday 4:00 PM*).
  * Showtime with the most votes wins, and the primary action button transforms into a direct Fandango checkout link.

#### C. Additional Activity Modules
* **Travel/Lodging Module:** Integrative photo carousels of rentals/hotels showing nightly price and dates, utilizing Airbnb/VRBO API concepts.
* **Custom Polling Module:** General opinion polls for custom activities (e.g., "Whose house are we pre-gaming at?") [11].

---

## 6. Technical Architecture: Activity-Agnostic Schema

The database must support polymorphic payloads so that the consensus engine operates independently of what is being voted on.

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

The `metadata` column utilizes a PostgreSQL **JSONB** format. This allows the backend to store restaurant ratings, movie runtimes, or cabin check-in times without database migrations:
* **Dining Payload:** `{"cuisine": "Italian", "price": "$$$", "rating": 4.5}`
* **Movie Payload:** `{"duration": "166 mins", "rating": "PG-13", "format": "IMAX"}`
* **Lodging Payload:** `{"price_per_night": "$180", "beds": 3, "amenities": ["Pool", "Wifi"]}`

---

## 7. Success Metrics

### Primary Metric [13]
* **Time to Consensus (TTC):** Time elapsed from Session Creation to Winner Declaration/Action taken (Targeting under 5 minutes vs. 30+ minutes in group texts) [13].

### Secondary Metrics [13]
* **Friction Quotient:** Drop-off rate of invited guests on the web-link interface (Target: < 5%).
* **Booking Conversion Rate:** Percentage of completed sessions that result in a click on the primary "Book Now" or "Get Tickets" action button [13].
* **Virality Index (K-Factor):** Number of new organizers acquired via links shared by existing organizers (Target: K > 1.2).

---

## 8. Development Phases & Roadmap

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
