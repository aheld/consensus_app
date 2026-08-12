# Product Requirements Document (PRD)
## Universal Group Consensus & Activity Voting Platform

**Project Codename:** Consensus  
**Target Market:** Friend groups (5–8 people) planning dinner outings and group activities 1–2 days in advance [1]  
**Document Version:** 3.1 (product-only; technical implementation content extracted)  
**Reconciled against the build:** 2026-08-11, decision log D-001 … D-054

> **Scope of this document.** This PRD defines *what* the product must do and *why*. It deliberately
> contains no stack, schema, vendor, or algorithm decisions. Technical content that previously lived
> here is preserved in [prd-technical-extracts.md](prd-technical-extracts.md); settled technical
> decisions live in [decisions.md](decisions.md) and unresolved ones in
> [open-questions.md](open-questions.md).
>
> **What v3.1 changed.** Most of Release 1 has been built and deployed, and building it settled
> several things this document had left open — and disproved a few it stated as fact. Every
> requirement in §5.1 now carries a **status**, and each requirement the build deliberately
> *changed* is corrected in place with the decision that changed it. Nothing has been quietly
> deleted: a requirement that was not built still reads as a requirement, marked as unbuilt.
>
> Where this document and [decisions.md](decisions.md) disagree, **`decisions.md` is correct** —
> it records what was actually chosen. This file records what we are trying to build.

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
│ Jessica "The Planner" │ Endless delays;        │ Hard deadlines that   │
│ (Age 29) [3]          │ sold-out listings [3]  │ close by themselves   │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Alex "The Foodie"     │ Suggestions get lost;  │ Rich visual cards in  │
│ (Age 30) [4]          │ quiet default picks [4]│ the venue's own words │
├───────────────────────┼────────────────────────┼───────────────────────┤
│ Rachel "Quiet Voter"  │ catching up on 200+    │ Instant plan summary  │
│ (Age 27) [5]          │ missed messages [5]    │ with deep ticket links│
└───────────────────────┴────────────────────────┴───────────────────────┘
```

### 1. Sarah "The Organizer" (28, Marketing Manager) [1]
* **Profile:** Coordinates friend hangouts via multiple daily group chats [1].
* **Frustrations:** Spends 30+ minutes in group chats gathering input; gets blamed when restaurant picks fail; manages restaurant availability manually [1].
* **Platform Relief:** Sarah generates a session link in 10 seconds. The app tracks who has joined and who has voted, closes voting at a set deadline, declares the winner, and presents booking links [10, 11].
* **Built.** All of it except the booking link, which resolves to the venue's own page rather than a reservation platform (§5.1 C). One correction to the promise above: the app can only track people who have **opened the link and given a name** — there is no invitee roster, because inviting is a paste into a group chat we never see. "Who hasn't voted" therefore means "who showed up and hasn't voted yet", and the nudge control that would act on it is drawn but not built.

### 2. Aaron "The Indecisive One" (50+, Software Engineer) [2]
* **Profile:** Easygoing, likes most foods, but struggles with decisions and commitment [2].
* **Frustrations:** Feels pressured when asked "where do you want to eat?"; hates vetoing options out loud; gets overwhelmed by massive lists [2].
* **Platform Relief:** The app uses micro-interactions (e.g., swiping or list voting) and anonymous voting options [11, 12], eliminating the social pressure of committing or vetoing in public group text threads [2].
* **Built, and stronger than specified.** Both micro-interactions ship as two views of the *same* ballot — a grid of option cards (the default) and a swipe deck — with a switch between them that carries the selections across (D-044). Anonymity is not an option Aaron has to find and trust: it is the only mode there is, and the engine cannot produce the attribution even if a screen asked for it (D-035). What the app *does* show publicly is that Aaron voted — see §5.1 A.

### 3. Jessica "The Planner" (29, Teacher) [3]
* **Profile:** Highly organized, hates last-minute changes or open-ended plans [3].
* **Frustrations:** Group decisions drag on for days; friends suggest fully-booked or closed venues; cannot plan her week due to lack of confirmation [3].
* **Platform Relief:** Every session is bound to a hard, organizer-defined **decision deadline** [10]. Options are checked for availability so the group is not asked to vote on sold-out showtimes or fully-booked restaurants.
* **Half built, and the other half is now doubtful.** The deadline is real and closes the session with no organizer action (§5.1 C), and the organizer can also close it early. **Availability checking is not built and has no credible path at MVP**: real-time table and showtime availability comes only from the commercial platforms whose licence terms D-052 rejected outright, and the freely-licensed data the app uses carries no availability at all. Treat this bullet as an aspiration with an unsolved sourcing problem, not as pending work — and do not let it re-enter Release 1 scope without answering D-052 §2 first.

### 4. Alex "The Foodie" (30, Graphic Designer) [4]
* **Profile:** Passionate about discovery, has strong opinions but doesn't want to dominate [4].
* **Frustrations:** Great suggestions get lost in text noise; people don't click links he shares; groups default to "safe" options [4].
* **Platform Relief:** Rich interactive visual cards showcase a high-resolution photo and the venue's own description, ensuring his premium recommendations are presented beautifully and get noticed [11].
* **Built, with one promise permanently withdrawn.** Alex pastes a link, or types a name and lets the app find the link, and the card fills in with the venue's photo, title and description read from the venue's own page. **Ratings, price levels and expert highlights are not coming** — see §5.1 B: they are not unbuilt, they are unbuildable under the licence terms of every provider that has them (D-052 §2). What Alex gets instead is the venue's own words and a link straight to it, which is closer to "people don't click the links I share" than a star rating was anyway.

### 5. Rachel "The Quiet Voter" (27, Nurse) [5]
* **Profile:** Works irregular shifts, belongs to multiple active friend groups [5].
* **Frustrations:** Misses live discussions; catches up to find 200+ unread text messages; misses changes in plans [5].
* **Platform Relief:** Rachel opens the shared session link, sees the exact curated list of options, casts her vote in 10 seconds, and receives an automatic winner notification with reservation/ticketing details without reading group chat logs [5, 6, 11]. *(How a notification reaches an account-less guest is unresolved — see Q-7 in [open-questions.md](open-questions.md).)*
* **Built up to the notification, which is still the open question.** Rachel's link, her ballot and her results screen all work; the same URL she voted at becomes the results page, so re-tapping the link in the chat thread is the delivery channel. Nothing is *pushed* to her, and Q-7 remains open — but the fallback it names (the organizer pastes a generated summary back into the chat) is built and is one tap on the results screen.

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

> **Deviation as built — requirement 1 is not met, and the reversal was deliberate.** Organizing
> requires an account today: sign-up by password or by magic link, then the session is created and
> owned by that account. Requirement 2's "optional" therefore reads backwards against the build —
> what is optional for the *participant* is mandatory for the *organizer*. Two reasons it went that
> way and one reason it should not spread: a session that outlives a closed tab needs an owner to
> come back to, and an account is what makes "my sessions" a screen at all; but participant access
> is the non-negotiable half of this section and it is met exactly as written. Whether an organizer
> should be able to run one anonymous session with no account is a real open product question and
> has never been decided — record it before building it.

### The Link-Share Model
Instead of trying to replace WhatsApp or iMessage, **Consensus** rides on top of them. Sharing a session link into a group chat must render a rich, self-explanatory preview card — enough that a recipient understands what they're being asked and by whom before tapping:

> 🗳️ **Dinner Friday? · 5 spots**  
> Sarah called this vote. Tap, pick what you'd be happy with, done in 10 seconds.  
> 🔗 `https://dinner.isourthing.com/join/session_abc123`

**Built — with the clock deliberately removed from the card (D-050).** The example above used to
carry *"Votes close Thursday at 6:00 PM"* and that line cannot be in a shared card, for two
independent reasons either of which is sufficient. A chat client **caches an unfurled card for
hours to days**, so a countdown written into it is wrong shortly after and can never be corrected;
and the card is rendered for a crawler that never opens a live connection, so it has no way to know
the reader's timezone and would print the deadline in the wrong one. **The rule this leaves behind:
nothing that changes faster than a chat client's cache goes in the shared card** — not the
deadline, not the tally, not the leader. The card names the vote and who called it; the page behind
it is live.

---

## 5. Functional Requirements: MVP vs. Post-MVP

> Requirements below describe capabilities, not integrations. Which discovery provider, booking
> partner, or media catalog satisfies a requirement is a technical and business-development
> decision — settled ones in [decisions.md](decisions.md), open ones in
> [open-questions.md](open-questions.md).
>
> **One of those has since become a product constraint rather than a vendor choice, and it reaches
> back into the requirements below.** The place-data question was answered (D-052) by rejecting
> every commercial provider **on its licence terms, not its price** — each of them forbids storing
> the very fields a durable result page is made of. That is why §5.1 B no longer promises ratings
> and price bands: it is not a sourcing gap waiting on budget, and it will not be reopened by
> finding a cheaper API.

### 5.1 MVP Dining Module (Must-Haves) [10, 11]

**Status of this section as of 2026-08-11.** ✅ built as specified · ✳️ built, specification
changed · ⛔ not built · 🔶 product question still open.

| Requirement | Status | Governed by |
|---|---|---|
| Session Creation | ✳️ title + deadline; no radius, and location is asked only when it is needed | D-029, D-052 |
| ↳ custom deadline picker | ✅ **built after v3.1's first draft** | D-055 |
| Option Discovery | ✳️ shipped as *lookup*, not browse | D-030, D-052 |
| Co-Creation | ⛔ not built | — |
| The ballot: approval voting, grid **and** swipe deck | ✳️ **mechanism specified in v3.1; v3.0's release plan said "single-choice"** | D-044 |
| Live Vote State | ✅ | D-034 |
| Anonymous Voting | ✳️ unconditional, and its scope is narrower than "anonymous" implies | D-035, D-049 |
| Veto Power | ✳️ semantics settled except the floor | D-034, D-036, D-051 |
| Ballot is final once cast | ✳️ **new rule, not in v3.0** | D-036 |
| Pool freezes when voting opens | ✳️ **new rule, not in v3.0** | D-037 |
| Detail cards | ✳️ photo + the venue's own words; ratings and price permanently withdrawn | D-052 |
| Winner Lock | ✳️ plus two endings that are *not* a winner | D-029, D-051 |
| Instant Booking Action | ✳️ links to the venue's own page, not a reservation platform | Q-5 open |
| Failsafe Option | ✅ | D-051 |
| Social Summary Copy | ✅ | D-051 |

#### A. Core Voting Mechanism
* **Session Creation:** Organizers specify a title and a voting deadline [10].
  * ✳️ **The search location/radius is gone from session setup.** A radius was never built and is
    not planned: it implies a map-and-distance product the free, permissively-licensed data behind
    the lookup cannot support (D-052). A *neighbourhood* is asked for at most once, in the middle
    of adding options, and only when the app actually needs it to look something up — and it is
    stored on the session, not on the organizer, because a neighbourhood is a property of the
    dinner rather than the person. If the organizer never triggers a lookup, they are never asked.
  * ✅ **The deadline is genuinely organizer-defined.** Three presets — tonight, tomorrow, and the
    coming Thursday — cover the common case in one tap, and `Custom…` opens a date-and-time picker
    for everything else. This was the most visible unbuilt control in the creation flow when v3.1
    was first drafted (it shipped as a dashed, disabled chip), and it bound Jessica the Planner
    hardest; building it required answering the timezone question D-031 had parked, which D-055
    did. The deadline is now read in the organizer's actual zone rather than a fixed offset, so a
    date on the far side of a daylight-saving change lands on the hour they picked.
  * ✳️ **A session is a draft from the first keystroke.** Step 1 creates it; nothing is ever
    re-entered after a closed tab, a dropped connection or a sleeping phone (D-029). The organizer
    can also **cancel** a live session, which is an ending the original spec did not have.
* **Option Discovery:** The organizer curates the shortlist by naming the options or pasting links,
  and the app finds the rest [10, 11].
  * ✳️ **What shipped is lookup, not discovery.** The organizer types a name or pastes a URL. A
    pasted URL is fetched server-side and fills in the photo, title and description. A *typed* name
    fires one search after the Add button is pressed — never per keystroke — and, if it matches,
    offers a dismissible **"Is this it?"** row; one tap adopts the venue's canonical name and pulls
    in its page (D-052).
  * ✳️ **A browse-and-choose discovery screen is deferred, not cancelled.** v1 assumes the
    organizer already knows the candidates, which is the actual dinner-planning case. Every failure
    of the lookup — no match, rate limit, timeout — renders as *silence*: the option is exactly the
    plain card that typing produced, and the organizer never learns a search ran. That is what
    makes the whole feature deletable and what keeps a flaky free backend from looking broken.
* **Co-Creation:** Group members can search and add their own restaurant suggestions to the voting
  pool [10, 11].
  * ⛔ **Not built.** Nothing lets a recipient add an option to somebody else's pool. This is the
    largest unbuilt piece of Release 1 and it is the one that most directly serves Alex the Foodie
    — a friend with a strong opinion can currently only vote on a list somebody else wrote.
* **The Ballot: approval voting, in either of two presentations** *(specified for the first time in
  v3.1 — v3.0 named a mechanism only in the release plan, and named the wrong one)*. A voter marks
  **every option they would be happy with** — *"tap all you'd be happy with, pick as many as you
  like"* — rather than choosing exactly one. Approval is the right floor for this product: it is
  the mechanism that most directly relieves the indecisive-voter persona, who does not want to be
  made to choose, and it removes the plurality artifact (a polarizing option winning on 3 of 8
  first-choices) without any of ranked-choice's explaining. Ranked-choice remains the Post-MVP
  upgrade (§5.2 A), not a correction of this.
  * ✳️ **Both interaction styles ship, and they are the same ballot** (D-044, closing the
    swipe-vs-list question the spec left open). A grid of option cards is the default; a swipe deck
    is one tap away; the selections and your place in the deck survive switching between them. The
    deck's gestures are approve and pass only — **a veto is always a deliberate button press**,
    never a flick, because it is one-per-voter and it removes the option for everyone.
* **Live Vote State:** Vote tallies update without a manual refresh, and a visual status bar shows
  who has and hasn't voted [10, 11].
  * ✅ Built, and verified with two live browser sessions: a guest's ballot appears in the
    organizer's already-open tab with no reload.
  * ✳️ One precision the spec did not have: **there is no invitee roster**, because inviting is a
    paste into a chat we never see. The status row shows everyone who opened the link and gave a
    name, and which of them have voted. "Hasn't voted" cannot mean "was invited and didn't show".
* **Anonymous Voting:** Participants can vote without their individual choices being attributed to
  them. This is a first-class mode, not an afterthought — it is the core relief for the
  indecisive-voter persona.
  * ✳️ **It is not a mode at all: it is the only behaviour, and it is structural.** The engine has
    no way to map a participant to what they picked, in any configuration — so it cannot leak
    through a screen somebody forgot to guard (D-035). A toggle was specified, built, and removed,
    because it persisted an organizer's choice and then changed nothing: a switch that silently
    does nothing is worse than no switch, since the organizer who flips it has told their friends
    something false.
  * ✳️ **The precise claim, because "anonymous" over-promises (D-049).** *Anyone with the link can
    see who has voted. Nobody sees what anyone picked — not even the organizer.* Both halves are
    checkable and both must be said together. The guest list, including full typed names, is
    visible to anyone holding the share link. **Any privacy claim in this product names who can see
    what; never a single adjective.**
* **Veto Power:** Each voter can apply one "Veto" to an option they absolutely refuse to visit,
  removing it from the eligible list and preventing group deadlock.
  * ✳️ **Four of the five open semantics are settled** (Q-8 in
    [open-questions.md](open-questions.md) is annotated in place): approvals already cast on a
    now-vetoed option are never deleted — the option is shown struck through, carrying its count; a
    voter cannot withdraw a veto after submitting, because the whole ballot is final; the veto is
    as anonymous as every other mark, so even the "everything was vetoed" screen shows veto
    *counts* and never names; and vetoes eliminating the entire pool is a real, rendered outcome
    rather than a crash or a silent fallback to the least-vetoed option.
  * 🔶 **Still open: the floor.** Nothing caps vetoes in aggregate, so a group with as many voters
    as options can veto everything, and any one person can unilaterally kill any single option.
    Whether to block a veto at two surviving options — or to keep instant removal and let the
    all-vetoed ending stand as an honest result — is undecided.
* **A cast ballot is final** *(new in v3.1 — D-036)*. There is no "change my vote". This is a
  product rule, not a limitation: a changeable vote can be moved to whatever is winning once the
  live tally is visible, and the entire product runs on a hard deadline precisely so that the state
  at close is the state everyone agreed to. The cost is that a mis-tap has no recovery, which is
  why the ballot has to make the selected state unmistakable before the send.
* **The option pool freezes the moment voting opens** *(new in v3.1 — D-037)*. After publishing,
  the organizer cannot add, edit, reorder or remove an option. This is not workflow taste: deleting
  an option people had already voted on destroyed their votes while their ballot stayed locked, so
  their submission was permanently short a choice and nothing said so. Reordering silently changed
  who was winning; renaming changed what people had agreed to. The review step before publishing
  exists so the pool gets its last look.

#### B. Restaurant Detail Cards
* Display name, a high-resolution photo, and the venue's own short description [11].
* Link out to the venue's own page [11]. *(v3.0 said "a map and reviews". Neither is built: there
  is no map anywhere in the product, and "reviews" meant a review aggregator, which is the same
  licence problem as the ratings below. A map link is a legitimate small addition and nobody has
  ruled it out — it is simply unbuilt and unrequested, not withdrawn.)*
* ✳️ **Cuisine tags, star ratings and price bands ($ to $$$$) are withdrawn from the MVP, and this
  is a permanent product constraint rather than a backlog item (D-052 §2).** Every commercial
  place-data provider evaluated — the five obvious ones — forbids *storing* precisely these fields;
  each caps retention at hours, or bans server-side caching by name, or exempts only an opaque ID
  from its caching ban. A results page that survives the session is this product's payoff (§6), so
  those terms are architectural incompatibilities, not price lines or cache settings. The freely
  licensed data the app does use carries no rating or price band at all.
* ✳️ **What replaces them:** the venue's own photo, title and description, read from the venue's
  own page — which is both richer and more honest than a third-party star average, and links
  straight to the place instead of to a review aggregator. **Anyone proposing "just use Google or
  Yelp for the ratings" owes an answer to the licence analysis, not a budget.**
* ✳️ Images are referenced by URL, never uploaded or re-hosted. A card whose photo disappears
  degrades to a placeholder; it never errors.

#### C. Resolution & Booking Loops
* **Winner Lock:** When the deadline passes, voting closes and the winning restaurant is declared,
  with no organizer action required [10, 11].
  * ✅ Built. Closing needs nobody to be watching — a session whose deadline passed unobserved is
    closed the next time anyone looks, which is indistinguishable from a timer to every observer
    and cannot drift (D-029). The organizer can additionally **close early**.
* **Endings that are not a winner** *(new in v3.1 — D-051)*. The original spec assumed a winner
  always exists. Two endings prove otherwise, and both are now designed screens rather than a muted
  one-line apology:
  * **Everything was vetoed.** The session says so plainly, lists what died and how many vetoes
    each took, and gives the organizer two ways out: reopen the pool for a second round — the share
    link and everyone's name survive, so nobody re-joins — or let the app pick one of the vetoed
    options at random. The random pick is announced as exactly that, in the winner card *and* in
    the summary pasted back to the chat; a coin flip is never laundered into an earned win.
  * **A dead heat at the top.** No winner is declared. The organizer either taps one of the tied
    options and locks it in, or asks the app to break the tie at random — and either way the result
    screen and the pasted summary name *who or what* broke the tie. Guests see the standoff and a
    line saying who they are waiting on; they never see the buttons.
  * Neither ending fires automatically. Nothing resolves a session without a human pressing a
    button that says what it does.
* **Instant Booking Action:** The result screen renders a primary call-to-action that takes the
  group toward an actual reservation [11].
  * ✳️ **Built as a link to the winning venue's own page** — the same link the option carries.
    A deep link into a reservation platform is **not** built and Q-5 is still open: neither major
    platform offers a public booking deep-link at hobby tier, and D-052's licence findings make an
    integration less likely rather than more. If the winning option has no link, the card carries
    no CTA. Run the spike before re-committing "reservation" as the wording of this requirement.
* **Failsafe Option:** If the top choice is fully booked or closed, the runner-up (#2) is presented
  immediately with the same booking action [11].
  * ✅ Built. On a tie it is labelled *Also tied* rather than *Runner-up*, because claiming it came
    second when it drew is the same quiet dishonesty as declaring a winner out of a dead heat.
* **Social Summary Copy:** Generates a one-click summary of the results (e.g., *"It's a Match! We
  are going to Osteria Mozza on Friday at 7:30 PM. Book here: [Link]"*) that organizers can paste
  back into their group chat [11].
  * ✅ Built, on both the organizer's and the participant's results screen. The generated string
    carries the honest version of whatever happened — an ordinary win, a tie and who broke it, or a
    random rescue — because the pasted summary is the one artifact the group actually reads.

---

### 5.2 Post-MVP Advanced Modules (Nice-to-Haves) [12, 13]

#### A. Advanced Consensus: Ranked-Choice Voting (RCV)
* Users rank options (#1, #2, #3) rather than approving any number of them (§5.1 A).
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
2. **Each activity type supplies its own comparison attributes.** Movies compare runtime, rating and format; lodging compares nightly price, beds and amenities. The engine must carry these without knowing what they mean. *(Dining's attributes were originally listed here as cuisine, price level and rating. As built, dining compares a photo and the venue's own description — see §5.1 B for why those three specifically cannot be carried. The requirement is unchanged; the example was wrong.)*
3. **Each activity type supplies its own card presentation and its own terminal action** — "Book a table," "Get tickets," "Reserve" — over the same underlying result.
4. **A brand-new activity type must be addable without a data migration.**
5. **The custom/manual activity type is the floor:** if an organizer can vote on free-text options with images and no catalog behind them, the engine is sufficiently decoupled.

> **Status: met, and now machine-checked rather than asserted (D-052 §10).** Requirement 1 used to
> be a promise a reviewer had to police by reading. A test now greps the whole application for the
> activity type and fails the build if any code branches on its value — so "nothing in voting,
> tallying or session lifecycle is dining-specific" is checkable, not aspirational. Requirement 5 is
> effectively already shipped: the manual path (type a name, no catalog) is the *default* way an
> option enters the pool, and the lookup is a strictly optional enrichment on top of it. Deleting
> the lookup entirely would leave a working product. Requirement 4 is unproven — no second activity
> type has been added yet, so "no data migration" has never been tested against reality. Note also
> that the images in requirement 5 are *referenced*, never uploaded (§5.1 B).

---

## 7. Success Metrics

### Primary Metric [13]
* **Time to Consensus (TTC):** Time elapsed from Session Creation to Winner Declaration/Action taken (Targeting under 5 minutes vs. 30+ minutes in group texts) [13].

### Secondary Metrics [13]
* **Friction Quotient:** Drop-off rate of invited guests on the web-link interface (Target: < 5%).
* **Booking Conversion Rate:** Percentage of completed sessions that result in a click on the primary "Book Now" or "Get Tickets" action button [13].
* **Virality Index (K-Factor):** Number of new organizers acquired via links shared by existing organizers (Target: K > 1.2).

> **None of these four are instrumented.** Nothing in the product measures elapsed time to
> consensus, guest drop-off, CTA clicks or organizer acquisition — there is no analytics of any
> kind, and every number above is currently unknowable. This is worth stating plainly because the
> release plan below says Release 1 is judged on "what Release 1 teaches us about real
> Time-to-Consensus and guest drop-off", and today it can teach us nothing. Deciding what to
> measure and where it is stored is an open technical *and* privacy question — the product's
> stated position is that guests are not tracked and not asked for anything beyond a name, so
> instrumentation has to be designed against that, not bolted past it.

---

## 8. Release Sequencing

Product-level ordering only. Engineering milestones, spikes, and schedules live in the technical docs.

```
  [ RELEASE 1: Dining MVP ]                                      mostly shipped
  - Session creation with a hard deadline                        ✅ presets + a custom picker
  - Curated restaurant shortlist                                 ✅
  - Member-added suggestions                                     ⛔ not built
  - Approval voting, always anonymous, one veto per voter        ✅
  - Live vote state + who has joined and voted                   ✅
  - Automatic winner lock                                        ✅
  - Endings that are not a winner (all vetoed, dead heat)        ✅ (added, not in v3.0)
  - Booking action, runner-up failsafe, paste-back summary       ✳️ CTA links to the venue itself
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

**Where Release 1 actually stands (2026-08-11).** The whole loop is live in production and has been
driven end to end in real browser sessions: an organizer signs up, builds a pool by typing names and
pasting links, publishes, and a guest opens the link cold, gives a name and votes — with the tally
appearing in the organizer's already-open tab and the guest's ballot locked afterwards. **Three
things stand between this and "Release 1 complete", in the order they matter:**

1. **Member-added suggestions (co-creation).** The only unbuilt must-have. It is what turns a
   curated list into a group's list, and it is Alex the Foodie's entire relief.
2. **Any measurement at all.** Both success metrics that gate Release 2 are currently unknowable
   (§7).

*(A custom deadline was the second item here when v3.1 was drafted. It shipped the same day —
D-055 — so the list is down to two.)*

Two things above the line were *added* rather than found missing, and both came from building it:
the endings that are not a winner, and the ballot being final. Neither was in v3.0. Release 2's
trigger should be read against this list, not against the diagram.
