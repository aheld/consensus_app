## Prompt seed, written by me
I want to run a Gauntlet Loop for this goal:

Continue to work on consensus app as described by the PRD, but add these two related features.

In the case where ALL the options have been vetoed we want an entertaining completion screen.  The user should be able to add new options to the existing choices or let the app select one.  Once the app selects one, undo that activities veto and revert to the normal ending screen.

Use this design
Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+All+Vetoed.dc.html

Focus on these files (the whole project is readable):
- `Consensus - All Vetoed.dc.html`

Also read these files the selection imports:
- `icon.svg`
- `support.js`


For the case of tie, use this design
Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Tie.dc.html

Focus on these files (the whole project is readable):
- `Consensus - Tie.dc.html`

Also read these files the selection imports:
- `icon.svg`
- `support.js`

Implement: `Consensus - Tie.dc.html`

review both designs first and look for a common way to handle these cases in the code

Possible references or quality bars:

Choose the strongest concrete bar that an agent can actually inspect and compare its work against. If I have not supplied one, propose a useful comp or measurement that plays the same role for this task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the goal into the smallest pieces that can be improved and judged independently. For each important piece, it should fan out a builder and a separate critic with fresh context. 

Each critic must inspect the real output, compare it directly with the bar—using a blind A/B comparison when possible—identify the biggest remaining gap, and send it back for another round. Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Each agent should use the appropirate anthropic model to optimize cost vs quality. Do not prescribe the architecture, exact decomposition, or a fixed number of rounds. Keep the final prompt short, just like Matt's.


## Generated Prompt (Fable)

Continue building Consensus App per the PRD. Add two related endgame features. When ALL options have been vetoed, show an entertaining completion screen where the user can either add new options to the existing choices or let the app pick one — and when the app picks, undo that option's veto and revert to the normal ending screen. When voting ends in a tie, show the tie screen.

Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+All+Vetoed.dc.html
Implement: `Consensus - All Vetoed.dc.html` and `Consensus - Tie.dc.html`. Also read `icon.svg` and `support.js`, which the selections import. The whole project is readable. Review both designs before writing code and find a common way to handle both cases.

Your quality bar: the design files are ground truth. Render each .dc.html in a browser and screenshot it. Screenshot our running app in the same states. The critic must compare them side by side blind and say which one is the design — if it can tell, ours loses.

Divide the goal into the smallest pieces that can be improved and judged independently. For each piece, fan out a builder sub-agent and a separate, fresh-context critic sub-agent. Each critic must inspect the real output — run the app, drive it into the all-vetoed and tie states, exercise add-option, app-pick, veto-undo, and the return to the normal ending — and blind A/B the screenshots against the design renders. The critic should be a really harsh critic: identify the single biggest remaining gap and send it back. /loop on each piece until ours is indistinguishable and every behavior works.

Pick the appropriate Anthropic model for each agent to balance cost and quality. Maintain a simple live progress page showing the work evolving over time. Fan out sub-agents and ultracode. /loop until it's utterly perfect.