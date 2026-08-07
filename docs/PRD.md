# Product Requirements Document (PRD)
## Universal Group Consensus & Activity Voting Platform

**Project Codename:** Consensus  
**Target Market:** Friend groups (5–8 people) planning dinner outings and group activities 1–2 days in advance [1]  
**Document Version:** 3.0 (product-only; technical implementation content extracted)

> **Scope of this document.** This PRD defines *what* the product must do and *why*. It deliberately
> contains no stack, schema, vendor, or algorithm decisions. Technical content that previously lived
> here is preserved in [prd-technical-extracts.md](prd-technical-extracts.md); settled technical
> decisions live in [decisions.md](decisions.md) and unresolved ones in
> [open-questions.md](open-questions.md).

---

## 1. Executive Summary & Strategic Pivot

The original "Restaurant Voting App" PRD aimed to solve the acute friction friend groups face when deciding where to eat [1]. However, a deep dive into the competitive landscape and group psychology reveals that **"where to eat" is just a subset of a much larger, universal problem: collaborative group decision-making**.

### The Strategic Pivot: The Activity-Agnostic Core Engine
We are pivoting the platform from a single-use restaurant picker to a **Universal Group Consensus Platform**. The core IP of the platform is an **Activity-Agnostic Decision Engine**.
* **MVP Focus:** A laser-focused, frictionless **Dining Module** to capture the immediate high-pain market (restaurant voting) [1, 10].
* **Post-MVP Focus:** Seamless extensions into other high-frequency group activities (movies, concerts, travel, lodging, and custom polling) without rewriting the core voting architecture.

### The Distribution Strategy: Combating "Friction Asymmetry"
Group planning apps usually suffer from **Friction Asymmetry**: while the organizer is highly motivated to download an app and coordinate, the other 4–7 participants are passive and will refuse to download a native app or register an account just to vote on Friday dinner.
* **The Solution:** A **frictionless "Link-Share" model** — the product meets participants where they already are, inside their existing group chat and mobile browser.
* **How it works:** Only the organizer needs to create a session. Friends receive a link via standard messaging apps (WhatsApp, iMessage), tap it, enter their name, and vote immediately in whatever browser opens. **Zero app downloads, zero account creation.**

---

## 2. User Personas & Pain-Point Mapping

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
* **Platform Relief:** Every session is bound to a hard, organizer-defined **decision deadline** [10]. Options are checked for availability so the group is not asked to vote on sold-out showtimes or fully-booked restaurants.

### 4. Alex "The Foodie" (30, Graphic Designer) [4]
* **Profile:** Passionate about discovery, has strong opinions but doesn't want to dominate [4].
* **Frustrations:** Great suggestions get lost in text noise; people don't click links he shares; groups default to "safe" options [4].
* **Platform Relief:** Rich interactive visual cards showcase high-resolution photos, ratings, price levels, and expert highlights, ensuring his premium recommendations are presented beautifully and get noticed [11].

### 5. Rachel "The Quiet Voter" (27, Nurse) [5]
* **Profile:** Works irregular shifts, belongs to multiple active friend groups [5].
* **Frustrations:** Misses live discussions; catches up to find 200+ unread text messages; misses changes in plans [5].
* **Platform Relief:** Rachel opens the shared session link, sees the exact curated list of options, casts her vote in 10 seconds, and receives an automatic winner notification with reservation/ticketing details without reading group chat logs [5, 6, 11]. *(How a notification reaches an account-less guest is unresolved — see Q-7 in [open-questions.md](open-questions.md).)*

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
│ **Consensus**              │ **Zero**         │ **Very High**          │
└────────────────────────────┴──────────────────┴────────────────────────┘
```

* **Group Text Messages (Primary Competitor):** Unstructured, highly conversational, but has no decision logic, lacks visual comparisons, and creates massive decision fatigue (8/10 Pain Point) [6, 7].
* **Google Forms / Doodle Polls:** Structured but too formal for casual friend hangouts; lacks integrated discovery, photos, and automated booking loops (5/10 Pain Point) [8].
* **Native-Only Swiping Apps (MunchMatch):** Fun Tinder-style UI, but introduces high friction by requiring all group members to download an app and register accounts. This kills conversion.
* **WhatsApp Chatbots:** Low friction but highly constrained by text-based WhatsApp layouts, a hard 12-poll-option limit, and an inability to display maps, menus, and media easily.
* **Our Positioning:** Combines the frictionless entry of a shared web link with the rich, visual, real-time feel of a native app.

---

## 4. Access & Distribution Requirements

These are product constraints on how people reach and use the product. They bind the implementation without prescribing it.

### Participant access (non-negotiable)
1. A participant must be able to go from tapping a shared link to a cast vote **without installing anything and without creating an account**. Name entry — or choosing to stay anonymous — is the maximum permitted ask.
2. The experience must work in whatever browser the link opens in, including the in-app browsers used by messaging apps, on a phone, in portrait, one-handed.
3. Voting must take on the order of 10 seconds for a returning participant who already knows the options.

### Organizer access
1. An organizer can create and run a session with no more setup than a participant needs.
2. An organizer may **optionally** create a persistent account to save friend groups, historical voting preferences, and blacklisted venues [12, 13]. This is Post-MVP and must never become a precondition for running a session.

### The Link-Share Model
Instead of trying to replace WhatsApp or iMessage, **Consensus** rides on top of them. Sharing a session link into a group chat must render a rich, self-explanatory preview card — enough that a recipient understands what they're being asked and by whom before tapping:

> 🗳️ **Dinner Friday? Let's Decide!**  
> Sarah has set up a session to pick a spot.  
> 🕒 *Votes close Thursday at 6:00 PM*  
> 🔗 **Tap to Swipe & Vote:** `https://consensus.app/join/session_abc123`

---

## 5. Functional Requirements: MVP vs. Post-MVP

> Requirements below describe capabilities, not integrations. Which discovery provider, booking
> partner, or media catalog satisfies a requirement is a technical and business-development
> decision — see [open-questions.md](open-questions.md).

### 5.1 MVP Dining Module (Must-Haves) [10, 11]

#### A. Core Voting Mechanism
* **Session Creation:** Organizers specify a title, voting deadline, and search location/radius [10].
* **Option Discovery:** The organizer can search restaurants near the session location and curate a shortlist into the voting pool [10, 11].
* **Co-Creation:** Group members can search and add their own restaurant suggestions to the voting pool [10, 11].
* **Live Vote State:** Vote tallies update without a manual refresh, and a visual status bar shows who has and hasn't voted [10, 11].
* **Anonymous Voting:** Participants can vote without their individual choices being attributed to them. This is a first-class mode, not an afterthought — it is the core relief for the indecisive-voter persona.
* **Veto Power:** Each voter can apply one "Veto" to an option they absolutely refuse to visit, removing it from the eligible list and preventing group deadlock. *(Exact semantics — vote refunds, withdrawal, anonymity, and the minimum surviving option count — are unresolved; see Q-8 in [open-questions.md](open-questions.md).)*

#### B. Restaurant Detail Cards
* Display name, high-resolution photo, cuisine tags, and price rating ($ to $$$$) [11].
* Link out to a map and reviews for the venue [11].

#### C. Resolution & Booking Loops
* **Winner Lock:** When the deadline passes, voting closes and the winning restaurant is declared, with no organizer action required [10, 11].
* **Instant Booking Action:** The result screen renders a primary call-to-action that takes the group toward an actual reservation [11].
* **Failsafe Option:** If the top choice is fully booked or closed, the runner-up (#2) is presented immediately with the same booking action [11].
* **Social Summary Copy:** Generates a one-click summary of the results (e.g., *"It's a Match! We are going to Osteria Mozza on Friday at 7:30 PM. Book here: [Link]"*) that organizers can paste back into their group chat [11].

---

### 5.2 Post-MVP Advanced Modules (Nice-to-Haves) [12, 13]

#### A. Advanced Consensus: Ranked-Choice Voting (RCV)
* Users rank options (#1, #2, #3) rather than picking one.
* The result must reflect overall group preference rather than a plurality artifact — a broadly-liked second choice should be able to beat a polarizing option with the most first-place votes. *(Which tabulation method delivers this is a technical decision.)*

#### B. Two-Phase Sequential Funnels (The Movie Showtime Use Case)
To prevent combinatorial cognitive overload, multi-variable decisions are handled in a structured two-stage funnel:
* **Phase 1: Content Consensus (The "What")**
  * Group votes on the movie they want to watch (e.g., *Dune* vs. *The Batman*).
  * The winning title is locked before logistics are discussed.
* **Phase 2: Logistics Consensus (The "When & Where")**
  * Local showtimes for the winning title are gathered and presented as a calendar grid.
  * Friends tap the showtime pills that fit their schedules (e.g., *Friday 7:15 PM* or *Saturday 4:00 PM*).
  * The showtime with the most votes wins, and the primary action button becomes a ticket-purchase action.

#### C. Additional Activity Modules
* **Travel/Lodging Module:** Photo carousels of rentals/hotels showing nightly price and available dates.
* **Custom Polling Module:** General opinion polls for custom activities (e.g., "Whose house are we pre-gaming at?"), where the organizer supplies the options as plain text and images rather than pulling them from a catalog [11].

---

## 6. Extensibility Requirement: Activity-Agnostic by Design

This is a product requirement, not an implementation note. The consensus engine is the core IP, and its value depends on being reusable.

1. **Nothing in session lifecycle, voting, or tallying may be dining-specific.** Adding a new activity type must not require changes to how sessions are created, how votes are cast, how deadlines lock, or how winners are declared.
2. **Each activity type supplies its own comparison attributes.** Dining compares cuisine, price level and rating; movies compare runtime, rating and format; lodging compares nightly price, beds and amenities. The engine must carry these without knowing what they mean.
3. **Each activity type supplies its own card presentation and its own terminal action** — "Book a table," "Get tickets," "Reserve" — over the same underlying result.
4. **A brand-new activity type must be addable without a data migration.**
5. **The custom/manual activity type is the floor:** if an organizer can vote on free-text options with uploaded images and no catalog behind them, the engine is sufficiently decoupled.

---

## 7. Success Metrics

### Primary Metric [13]
* **Time to Consensus (TTC):** Time elapsed from Session Creation to Winner Declaration/Action taken (Targeting under 5 minutes vs. 30+ minutes in group texts) [13].

### Secondary Metrics [13]
* **Friction Quotient:** Drop-off rate of invited guests on the web-link interface (Target: < 5%).
* **Booking Conversion Rate:** Percentage of completed sessions that result in a click on the primary "Book Now" or "Get Tickets" action button [13].
* **Virality Index (K-Factor):** Number of new organizers acquired via links shared by existing organizers (Target: K > 1.2).

---

## 8. Release Sequencing

Product-level ordering only. Engineering milestones, spikes, and schedules live in the technical docs.

```
  [ RELEASE 1: Dining MVP ]
  - Session creation with a hard deadline
  - Curated restaurant shortlist + member-added suggestions
  - Single-choice voting, anonymous mode, one veto per voter
  - Live vote state + who-hasn't-voted
  - Automatic winner lock, booking action, runner-up failsafe, paste-back summary
                │
                ▼
  [ RELEASE 2: Fairer Consensus ]
  - Ranked-choice voting
                │
                ▼
  [ RELEASE 3: Activity Expansion ]
  - Custom / manual polling module
  - Movie module (content selection)
                │
                ▼
  [ RELEASE 4: Sequential Protocols ]
  - Two-phase funnel: the "What" ➔ the "When & Where"
  - Travel / lodging module
```

Release 1 is the only committed scope. Everything after it is directional and subject to what
Release 1 teaches us about real Time-to-Consensus and guest drop-off.
