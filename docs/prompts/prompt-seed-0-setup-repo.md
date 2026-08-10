I want to run a Gauntlet Loop for this goal:

I want to build a starter app using the Phoenix Framework called 'consensus app'. It should use LiveView and sqlite.

The app should just display a message on the home screen and allow for new signups.
There should also be an admin application, protected by authentication that lets me designate any user as admin, only admin users have access to the admin pages. The admin should also allow for editing of the homepage text.

It should follow best practices and be production ready. I want to deploy this to fly.io.
Additionally the repo should have clear documentation, for both humans and AI and have the necessary skills for working with Elixr, Phoenix, SQLlite, Fly.io, etc.  It should also have a



Possible references or quality bars:
I should be able to sign up as a new user, then login as an existing admin user and make that user an admin.

any admin user should be able to edit the text on the homepage.

It should have minimal styling as the focus is on functionality, ease of use and deployment. I want it to look good, but function is more important.

Deployment documentation - note that we do not need to deploy this, just that it will deploy without issues.
https://phoenix.hexdocs.pm/fly.html
https://fly.io/docs/elixir/getting-started/

Choose the strongest concrete bar that an agent can actually inspect and compare its work against. If I have not supplied one, propose a useful comp or measurement that plays the same role for this task that real Call of Duty screenshots played for Matt Shumer's Claude of Duty game (read the prompt: https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md). Explain the bar in one sentence.

Then write a prompt for Claude Code in the style of Matt's prompt (minimal is better here, we want the agent to decide the specifics!).

Give the lead agent the goal and the bar, but let it choose the approach. Tell it to divide the goal into the smallest pieces that can be improved and judged independently. For each important piece, it should fan out a builder and a separate critic with fresh context.

Each critic must inspect the real output, compare it directly with the bar—using a blind A/B comparison when possible—identify the biggest remaining gap, and send it back for another round. Keep looping until our output wins or I stop the run.

Have the lead agent maintain a simple live progress page that shows the work evolving over time.

Have it use subagents and ultracode. Do not prescribe the architecture, exact decomposition, or a fixed number of rounds. Keep the final prompt short, just like Matt's.


----
I want you to build "Consensus App": a production-ready Phoenix LiveView app with SQLite. Home page shows an editable message. Users can sign up and log in. An authenticated admin area lets admins promote any user to admin and edit the homepage text. On first startup the app must seed an admin user "aheld" with password "adminpass", in a way that also works in the Fly release flow — and the docs must clearly warn that this password has to be changed before real production use. Minimal styling — function over form, but it should still look clean. It must deploy to Fly.io without issues (don't actually deploy; prove it would), including running database migrations on startup the Fly-friendly way per the official guide. The repo needs clear docs for humans and AI (CLAUDE.md, README, and skills for Elixir, Phoenix, SQLite, and Fly.io), plus a complete TODO.md walking me step-by-step through pushing this repo to GitHub, setting up my Fly instance, and configuring automated deployments from GitHub per Fly's official continuous deployment guide.

Your quality bar: generate a fresh reference app with the official generators (`mix phx.new --database sqlite3` + `mix phx.gen.auth`) and pull the official Fly.io Phoenix deployment and continuous deployment guides. Our app must be indistinguishable from or better than what the Phoenix core team would ship.

Divide the goal into the smallest pieces that can be improved and judged independently. For each piece, fan out a builder sub-agent and a separate, fresh-context critic sub-agent. Each critic must inspect the real output — run the tests, run the app, log in as aheld/adminpass, exercise the signup/login/promote/edit flows, docker build the release image, run the migration entrypoint against the built image, validate the fly config, follow the TODO as if they were me — and compare it blind side-by-side against the reference and the official guides. The critic should be a really harsh critic: identify the single biggest remaining gap and send it back. /loop on each piece until the critic says ours wins.

Acceptance: the app boots with admin aheld/adminpass already present; a new user can sign up; aheld can log in and promote that user; any admin can edit the homepage text; migrations and seeding run automatically in the deploy flow; all checks green; the Docker image builds clean; the TODO gets me from zero to auto-deploying without guesswork.

Maintain a simple live progress page showing the work evolving over time. Fan out sub-agents and ultracode. /loop until it's utterly perfect.