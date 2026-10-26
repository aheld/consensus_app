# Docs

This directory is the written memory of **Consensus**, a group-decision app (an organizer shares a link, friends vote, a deadline closes the vote and a winner is declared). The app is a Phoenix LiveView / SQLite service deployed to Fly.io. The code is in `lib/`; this directory records *why* it looks the way it does.

It is written for two readers at once: a person deciding whether to trust a decision, and an AI agent that starts every session with no memory and has to be told what is settled. Most of the structure below exists because the second reader needs it.

> **Two live artifacts to open first**
>
> - **Product requirements:** [PRD.md](PRD.md). Start here.
> - **Designs (GitHub Pages):** <https://aheld.github.io/consensus_app/>. The design frames, served straight from [design/site/](design/site/).

---

## Start here: the PRD

[PRD.md](PRD.md) says **what** the product must do and **why**. By design it contains no stack, schema, vendor or algorithm decisions; those were extracted into the technical documents so product and engineering arguments don't blur.

Read it for the personas, the "link-share" distribution model that makes voter friction zero, and the functional requirements. Since v3.1 every requirement carries a build **status**, and each one the build deliberately changed is corrected in place with the decision that changed it. Nothing was quietly deleted: an unbuilt requirement still reads as a requirement.

Then, in this order:

1. **[decisions.md](decisions.md)** is the technical source of truth: 60 ADR-style entries (D-001 to D-060). Where it and any other document disagree, it wins. Entries are *amended in place* when a later decision changes them, so a reader who stops at the first answer never gets a stale one.
2. **[open-questions.md](open-questions.md)** is what is still undecided, plus a section of known gaps in code that has already shipped.
3. **[plans/](plans/)** has one plan per feature, written before the code.

The authority order is `decisions.md` > `PRD.md` > the two unratified drafts below.

---

## Map

```
docs/
├── PRD.md                      Product source of truth. Start here.
├── decisions.md                Technical source of truth (D-001 … D-060).
├── open-questions.md           What is still undecided; known gaps in shipped code.
│
├── plans/                      One plan per feature, written before implementation.
├── prompts/                    The prompts that started each build, and the design prompts.
├── design/                     Design source of truth, specs, and the Pages site.
│   └── site/                   What GitHub Pages serves.
├── build-log/                  Frozen records of how features were built.
├── research/                   Reviewed research behind specific decisions.
├── walkthrough.md + walkthrough/   A screen-by-screen audit with 123 screenshots.
│
├── original-prompt.md          The prompt the repo was first built from, verbatim.
├── sqlite-capacity-review.md   Adversarial review of the database choice (led to D-038).
├── fly-official-guides.md      Extract of Fly.io's docs, kept so agents cite rather than recall.
├── technical-roadmap-v1-draft.md   NOT ratified. First-pass stack proposal. Reference only.
└── prd-technical-extracts.md       NOT ratified. Technical content removed from the PRD. Reference only.
```

| Folder / file | What it is | Read it when |
|---|---|---|
| [plans/](plans/) | Eight feature plans, from [creation-flow.md](plans/creation-flow.md) to [item-details-and-catalog.md](plans/item-details-and-catalog.md). Each ties the work to a PRD requirement, names the data model, API surface, failure modes and verification, and cites the `D-00N` entries it must not contradict. The convention is in [plans/README.md](plans/README.md). | You want to see how a feature was scoped before it was built. |
| [prompts/](prompts/) | The "prompt seeds" (`prompt-seed-0` to `prompt-seed-5`) that kicked off each build, and a design prompt. See [How AI was used](#how-ai-was-used). | You want the actual instructions the AI was given. |
| [design/](design/) | [DESIGN-SPEC.md](design/DESIGN-SPEC.md) (tokens, rules, per-screen notes and the owner's rulings on each returned frame), [IMPORT-NOTES.md](design/IMPORT-NOTES.md), and the product brief for the assisted add. `design/site/` holds the exported design files published to Pages. | You want the visual rules, or the design as it stood at a given turn. |
| [build-log/](build-log/) | Point-in-time records of builds: acceptance scripts, builder and critic verdicts, what was rejected. Not maintained; if one contradicts `decisions.md`, the log is stale. See [build-log/README.md](build-log/README.md). | You want to know what was tried and thrown away. |
| [research/](research/) | [activity-discovery.md](research/activity-discovery.md), the reviewed source-and-licence research. Its licence findings are why no commercial places API may ever be proposed on price alone. | You are about to propose a data provider. |
| [walkthrough.md](walkthrough.md) | An audit of 85 screens at phone size with a pass/fail standard ("is the next step on screen and unambiguous?"). | You want evidence of the UX, not claims about it. |

Two files here are **not ratified** ([technical-roadmap-v1-draft.md](technical-roadmap-v1-draft.md), [prd-technical-extracts.md](prd-technical-extracts.md)). They contradict each other in places and are kept as reference only. Do not implement from them.

### The design site

<https://aheld.github.io/consensus_app/> publishes `design/site/` with no build step: the frames exported from the project's Claude Design file (Create & Share, All Vetoed, Tie, Item Details, User Flow, Social Preview). A workflow publishes it on any push to `main` that touches that directory, and does not gate on the app's CI (D-057). Note that `design/site/` is the current export; the hand-exported copies at the top of `design/` and in `design/screens/` are older (see the note in [design/IMPORT-NOTES.md](design/IMPORT-NOTES.md)).

---

## How AI was used

The short version: **the human owned intent, taste and the final call; agents did the building, and other agents tried to break what was built.** Every handoff between those roles is a file in this directory.

### 1. Intent goes in as a prompt, and the prompts are kept

[original-prompt.md](original-prompt.md) is the first one, verbatim, with an account of how it ran: seven rounds of build-then-critique, 35 critic reports, none of which ever returned "ours wins". The loop was stopped by the owner's decision, not by convergence, and the leftovers went into `open-questions.md` rather than staying in a chat. It also records three deviations from the prompt that were put to the owner and decided.

Each later build began with a **prompt seed** in [prompts/](prompts/), written by the owner and structured the same way:

- a goal, in product language;
- a **bar**: something an agent can inspect and compare against (a design frame, a state table, a reference app), with instructions to propose one if none is given;
- the shape of the process: split the goal into the smallest independently judgeable pieces; for each, a **builder** and a separate **critic with fresh context**; critics inspect real output (run the tests, boot the app, drive a browser), compare against the bar with a **blind A/B** where possible, name the single biggest remaining gap and send it back; loop until the output wins or the owner stops it;
- a live progress page, so the owner can watch.

The seeds deliberately state a goal and a bar and leave the approach to the lead agent.

### 2. Decisions are written down so the next session doesn't relitigate them

Agents don't remember. Anything settled mid-conversation is appended to `decisions.md`, and the repo's working agreements require that a new decision which changes an older one **edits the older entry in the same change**. An entry left saying "settled" after the code moved on is a wrong answer delivered with authority, which is worse than silence. `CLAUDE.md` at the repo root carries the invariants that tests alone don't defend.

### 3. Critics are adversarial, and some of their findings changed the product

Reviews were run to find what the suite *wasn't* guarding, including by mutating the source to see which tests failed. Examples recorded here:

- a critic showed a three-day-old session promoting an account to admin while being refused its own settings page; the owner accepted the UX cost and it became sudo mode (D-021);
- [sqlite-capacity-review.md](sqlite-capacity-review.md) examined the database choice at the owner's stated scale and produced D-038;
- the assisted-add build log records the SSRF and injection findings and the blind A/B trajectory.

### 4. Cost is a design input

[plans/item-details-and-catalog.md](plans/item-details-and-catalog.md) §11 assigns a model and effort level to every stage and every subagent, with the rationale. It exists because a 150-agent review that inherited the most expensive model consumed 87% of the owner's usage and hit the session limit mid-run. Invariant-heavy stages run on the stronger model; mechanical sweeps run on the cheapest; nothing inherits the session default.

### 5. Design is handed off through prompts, with the human as courier

Design lives in a Claude Design project, not in the repo. Two directions of handoff exist, and they are different:

- **Design to code:** the seed prompts tell the build agent to import the design project over MCP and implement a named section of it. The agent reads the frame; it doesn't guess.
- **Code to design:** the agent can't run a prompt in the design tool, so the plan *writes the prompt for the owner to paste*. The latest plan below is the worked example.

---

## The latest plan: item details and a shared catalog

[plans/item-details-and-catalog.md](plans/item-details-and-catalog.md) (decision **D-060**). Approved and built 2026-10-25.

**What it builds, in three parts**

1. **Details on every option.** A website, phone, address, map location and category, filled in when the organizer taps "Use this" on a lookup suggestion, and editable afterwards.
2. **A shared catalog searched before OpenStreetMap's Nominatim.** An off-by-default "Let anyone find this" toggle snapshots an option into a shared table. The lookup asks the catalog first and sends no Nominatim request on a hit (a volunteer service limited to one request a second).
3. **An admin items view** at `/admin/items`, where an admin can edit, hide or delete catalog rows and fix any option's details, but never rename, reorder or delete another organizer's options.

**Why:** PRD invariant 5 says a session should end in an action, not a summary. A winner card with a phone number and a Directions link *is* the action; before this, the app stored none of that.

**Decisions worth a product owner's attention**

- It **reverses an earlier decision** (D-052's rule that only a URL may be kept from a data provider). The guarantee moved from "the schema has nowhere to put it" to a per-provider allowlist checked at boot. The earlier entries were amended in place.
- Details stay editable *after* the vote opens, while name, description and order stay frozen. A wrong phone number matters most on the winner card, and fixing it changes nothing anyone voted on.
- The shared description is a real privacy trade-off. Seven owner questions were settled explicitly in the plan (§9); the sharing copy was required to name the word "description" so organizers aren't surprised.

**How it handed work to Claude Design**

The plan treats design as a blocking dependency and says so up front. §12 defines four **pause points** where the build stops and waits for the owner:

| Pause | When | What the agent does |
|---|---|---|
| **A** | Before any code | Prints the design prompt in a paste-ready block and ends the turn. Stage 1 (schema, no UI) proceeds while the owner runs it. |
| **B** | After stage 1, if no frame yet | Says what's done, asks for the frame, writes no template code. |
| **C** | Frame review finds a conflict | Lists each conflict with the plan section or invariant it breaks and a recommendation; never picks silently. |
| **D** | A state the frame doesn't draw | Builds it if it's a direct combination of drawn parts; stops and offers a follow-up prompt if it needs new visual vocabulary or copy. |

The prompt itself (§12.2) is worth reading as a handoff artifact. It specifies seven labelled panels (`t7-a` to `t7-g`) and, instead of describing taste, lists **hard constraints with their origin**: inputs at 16px or larger because iOS zooms the page otherwise (a shipped bug), one forward action per screen, no ratings or prices because the licence forbids displaying them, no map embed, and guests never see anything about the sharing toggle. It ends by asking the designer to annotate every departure from those constraints.

When the frame came back, §12.3 gave a ten-point review checklist. Where a point failed, it went to the owner as a ruling. The result is recorded in [DESIGN-SPEC.md](design/DESIGN-SPEC.md) under the `t7` heading: seven rulings, for example that the frame's new winner card was **not** built because it implied a ranking the voting model doesn't have, and that the "Website" button was dropped because the existing forward action already opened that link. Build deviations from the frame are listed beside them. The frame itself is on the design site: [item-details.dc.html](https://aheld.github.io/consensus_app/item-details.dc.html).

**Where it stopped:** stages 1-5 and 7 were built; the optional stage 6 (reading details from a pasted link's structured data) was not. The status block at the top of the plan keeps the earlier states and the places stage 1 deviated from the text.

---

## Caveats

- **Dates drift.** `build-log/` and the older design exports are frozen snapshots. Trust `decisions.md`, the code and the tests over them.
- **Plans are intent, not the record.** A plan describes what was approved. Where the build differed, the plan's status block and `decisions.md` say so; the item-details plan's header does this at length.
- **The design project isn't in the repo.** It requires a signed-in account. `design/site/` is the public, exported copy.
