# Prompt seed 5 — Assisted Add (v1)

> The Assisted Add frames live in section **5 - Assisted Add** of
> `Consensus - Create & Share.dc.html` in the linked Claude Design project. The product spec this
> builds is
> [docs/design/assisted-add-ux-brief.md](../design/assisted-add-ux-brief.md); the architecture it
> follows is [docs/research/activity-discovery.md](../research/activity-discovery.md) §4.

## Prompt seed

I want to run a Gauntlet Loop for this goal:

Continue to work on the consensus app as described by the PRD, and implement **Assisted Add v1**
on the `02 add options` screen, exactly as specified in `docs/design/assisted-add-ux-brief.md`.
Type a name, press Add, the card lands instantly; the app looks the name up in the background and,
on a match, offers a small dismissible "Is this it?" suggestion whose **Use this** attaches the
venue's website so the existing LinkPreview enrichment dresses the card. No autocomplete, no
Discover screen, silence on every failure. The architecture is
`docs/research/activity-discovery.md` §4 — URL-only results, provider registry as data
(invariant 12), Overpass as the first adapter — and research Stage 0 lands first.

Use this design
Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html

Focus on these files (the whole project is readable):
- `Consensus - Create & Share.dc.html`

Also read these files the selection imports:
- `icon.svg`
- `support.js`

Implement: focus on **5 - Assisted Add**

Possible references or quality bars:

The failure states are the feature: a dead or slow provider must be indistinguishable from the
feature not existing, and nothing may fire on keystrokes. The brief's state table is a checklist a
critic can drive one row at a time.

Choose the strongest concrete bar that an agent can actually inspect and compare its work against.
If I have not supplied one, propose a useful comp or measurement that plays the same role for this
task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the
prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one
sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want
the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the
goal into the smallest pieces that can be improved and judged independently. For each important
piece, it should fan out a builder and a separate critic with fresh context.

Each critic must inspect the real output, compare it directly with the bar — using a blind A/B
comparison when possible — identify the biggest remaining gap, and send it back for another round.
Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Each agent should use the appropriate Anthropic model to
optimize cost vs quality. Do not prescribe the architecture, exact decomposition, or a fixed
number of rounds. Keep the final prompt short, just like Matt's.

## Generated Prompt (Fable)

Continue building Consensus per the PRD. Implement **Assisted Add v1** on the `02 add options`
screen: the organizer types a restaurant name and presses Add, the card lands in the pool
instantly, and the app quietly looks the name up in the background. On a match, a small
dismissible "Is this it?" suggestion — venue name and street address, nothing else — appears
attached to the new card; tapping **Use this** attaches the venue's website and the existing
LinkPreview enrichment fills in the photo and description, exactly as a pasted link does today.
The product spec is `docs/design/assisted-add-ux-brief.md` and the architecture is
`docs/research/activity-discovery.md` §4 — both are binding. The brief's out-of-scope list is a
fence: no autocomplete, no Discover screen, no ratings, price bands, or photos on suggestion rows,
and the OpenStreetMap attribution renders wherever suggestions do. Land research Stage 0 first —
the invariant-12 source-grep test unconditionally, and the Fly-egress 403 measurement if
production access allows (it gates the feature's payoff; report what you find before building on
it).

Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html
Implement: **5 - Assisted Add** in `Consensus - Create & Share.dc.html`. Also read `icon.svg` and
`support.js`, which the selection imports. The whole project is readable. Review the frames
against the brief before writing code —
where they disagree, the brief's hard constraints win and the disagreement gets flagged, not
silently resolved.

Your quality bar is two-sided. **Pixels:** the design frames are ground truth. Render each
.dc.html in a browser and screenshot it; screenshot our running app in the same states; the critic
compares them blind and says which is the design — if it can tell, ours loses. **Behavior:** the
brief's state table is ground truth. The critic must drive every row with a stubbed provider —
match, multi-match, confirm, dismiss, the area prompt appearing exactly once and never again, and
the whole failure trio — then once against the real backend. The sharp edges: a run with a dead or
slow provider must be indistinguishable from the feature not existing (any flash, toast, error, or
forever-spinning shimmer is a loss), zero lookup requests may fire while typing (a keystroke that
triggers one is a loss), and deleting the feature must leave `02` working exactly as it does
today.

Divide the goal into the smallest pieces that can be improved and judged independently. For each
piece, fan out a builder sub-agent and a separate, fresh-context critic sub-agent. Each critic
must inspect the real output — run the app, drive the states, blind A/B the screenshots — be
really harsh, name the single biggest remaining gap, and send it back. `mix precommit` stays green
throughout, and the new states (including the silence states and the no-keystroke-requests rule)
get pinned by tests, not just demonstrated once.

Pick the appropriate Anthropic model for each agent to balance cost and quality. Maintain a simple
live progress page showing the work evolving over time. Fan out sub-agents and ultracode. /loop
until it's utterly perfect.
