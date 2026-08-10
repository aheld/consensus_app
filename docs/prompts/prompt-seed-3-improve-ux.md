I want to run a Gauntlet Loop for this goal:

Continue to work on consensus app as desribed by the PRD.

The design has been updated to add a header and footer, implement that across the site.  For non-auth users (the vote screens after a shared link) they will get the same footer, but a simplified header with a brief call to action to make thier own.

Addtionally, look at 1c, the 'swipe deck' and add that as an option.  Keey the default as is, but add a toggle button to both screens allowing a user to switch between the existing one and the swipe option.

the footer also has an icon to request feedback with a happy/sad face.  That can be replaced with emoji, decide. clicking the faces take the user to a data entry page that the user can fill out.  pass which face the user selected (happy or sad) and capture that in the feedback as well  Build a simple admin interface that lets me mark the feedback as 'read'.  Add an admin 'notes' to the feedback so I can document actions taken.  this is private and will not trigger any actions or commuinication.

also build the 'how it works' (1b screen 00b )page and ensure that is linked from the footer.

in the data entry screen for restaraunts - put in a line saying 'restaurant search coming soon'



note that the design should have already been imported, but here are instructions to get the latest header and footer
    Use the claude_design MCP (https://api.anthropic.com/v1/design/mcp, auth via /design-login) to import this project:
    https://claude.ai/design/p/867b0685-278c-4ce4-ae2c-bce2135705af?file=Consensus+-+Create+%26+Share.dc.html


It should follow best practices and be production ready. This is deploying to fly.io on github commits to main and can be seen at https://dinner.isourthing.com/


Possible references or quality bars:

the user should not get stuck or confused after taking an action.  Also review the login flows, for example, after a magic link is sent the user stays on that screen and it is not obvious what to do.  Some of the flash messages should be converted to full page 'success' messages where there is no further action on the site (as when a user must check thier email inbox)

run an end to end test and document the flow and experience at each step for human review.

Choose the strongest concrete bar that an agent can actually inspect and compare its work against. If I have not supplied one, propose a useful comp or measurement that plays the same role for this task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the goal into the smallest pieces that can be improved and judged independently. For each important piece, it should fan out a builder and a separate critic with fresh context. 

Each critic must inspect the real output, compare it directly with the bar—using a blind A/B comparison when possible—identify the biggest remaining gap, and send it back for another round. Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Each agent should use the appropirate anthropic model to optimize cost vs quality. Do not prescribe the architecture, exact decomposition, or a fixed number of rounds. Keep the final prompt short, just like Matt's.
