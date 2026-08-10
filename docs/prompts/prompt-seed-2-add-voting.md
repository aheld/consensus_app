I want to run a Gauntlet Loop for this goal:

Complete the basic functionality of the consensus app as desribed by the PRD, just the MVP and basics.

Once a user has created a pool of options they should be able to create a share link, send that to other users, and they can vote.

Users can just enter thier name and vote or they can login and vote as a known user.  We need to capture if they

Add in the feature to actually load a link and use the links's preview image, name and description in the activity description. 
Additionally, the activity should be editable in the creation flow at every step.  Its ok to navigate to the edit back and back, consider how to make a pleasant UX.

Voting should be live and dynamic in case multiple people have the app open.  Once you vote we can consider that locked in and unchangable for now.

note that the design should have already been imported, but here are instructions if it is missing details
    Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
    https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html

    Focus on these files (the whole project is readable):
    - `Consensus - Create & Share.dc.html`

    Also read these files the selection imports:
    - `support.js`

    Implement: `Consensus - Create & Share.dc.html` 

It should follow best practices and be production ready. I want to deploy this to fly.io.
Additionally the repo should have clear documentation, for both humans and AI and have the necessary skills for working with Elixr, Phoenix, SQLlite, Fly.io, etc. 


Possible references or quality bars:

Note that we do not need a very high quality bar on this phase.  There will be at least 1 more passe to refine the app and the PRD, so the goal of this pass is to be able to test out the full end to end flow. Additionally ensure that the agents do not stall or hang.  Check on them every 30min if there has been no activity reported.

Choose the strongest concrete bar that an agent can actually inspect and compare its work against. If I have not supplied one, propose a useful comp or measurement that plays the same role for this task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the goal into the smallest pieces that can be improved and judged independently. For each important piece, it should fan out a builder and a separate critic with fresh context. 

Each critic must inspect the real output, compare it directly with the bar—using a blind A/B comparison when possible—identify the biggest remaining gap, and send it back for another round. Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Each agent should use the appropirate anthropic model to optimize cost vs quality. Do not prescribe the architecture, exact decomposition, or a fixed number of rounds. Keep the final prompt short, just like Matt's.
