I want to run a Gauntlet Loop for this goal:

Build out the consensus app in this repo to have the functioning flow of the home page and lead direction setup flow as descirbed in the 1a and 1b sections of the referenced design. Replace the existing home page and admin code in this repo as needed.

We can stop before implemeting any of the voting or results screen and just focus on the creation side.  Assume the user will need to create an account (username + password or email+ magic link) and be given a role of 'organizer'as the default role.  Do not  implement any features for other roles (voters, admins, etc)beyond the ability to designate other users as admins.

For the setup screen 01 under 1b, the chips show a future date when the votes close.  Always make on 5pm that evening, 5pm the following day, then the next Thursday at 12 and the final 'custom' should open a date time picker for the user to input.  Do not implement the custom option now. Just implement the first three options. 

Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html

Focus on these files (the whole project is readable):
- `Consensus - Create & Share.dc.html`

Also read these files the selection imports:
- `support.js`

Implement: `Consensus - Create & Share.dc.html` (but just the flows referenced above)

It should follow best practices and be production ready. I want to deploy this to fly.io.
Additionally the repo should have clear documentation, for both humans and AI and have the necessary skills for working with Elixr, Phoenix, SQLlite, Fly.io, etc. 


Possible references or quality bars:
I should be able to sign up as a new user and create a new activities to put into a new pool. I should be able to do this and the state should be preserved. I should not have to re-enter any information.  If I put in a url the system should reference an image and pull the title and description from the link, all three should then be editable.  Images can not be uploaded, only referenced via a url at this time.

I should then be able to login to a new session and see my activity groups.  Allow for the creation of multiple groups.

Activity groups can also be cancelled manually, or completed by everyone voting or the time limit expiring.  

Note that we do not need a very high quality bar on this phase.  There will be at least 2 more passes to complete the rest of the PRD, so the goal of this pass is get the onboarding and activity creation flows working end to end without errors. We will polish and improve the design in later passes.  Additionally ensure that the agents do not stall or hang.  Check on them every 30min if there has been no activity reported.

Choose the strongest concrete bar that an agent can actually inspect and compare its work against. If I have not supplied one, propose a useful comp or measurement that plays the same role for this task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the goal into the smallest pieces that can be improved and judged independently. For each important piece, it should fan out a builder and a separate critic with fresh context. 

Each critic must inspect the real output, compare it directly with the bar—using a blind A/B comparison when possible—identify the biggest remaining gap, and send it back for another round. Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Each agent should use the appropirate anthropic model to optimize cost vs quality. Do not prescribe the architecture, exact decomposition, or a fixed number of rounds. Keep the final prompt short, just like Matt's.
