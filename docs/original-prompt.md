# The prompt this repository was built from

Recorded verbatim, because the acceptance criteria in it are the standard the foundation was built
to and the standard [docs/decisions.md](decisions.md), [TODO.md](../TODO.md) and the `F-` section of
[open-questions.md](open-questions.md) keep referring back to. Everything in the working tree below
`lib/`, `test/`, `config/`, `priv/`, `.github/`, `rel/`, `assets/` and `.claude/skills/` was produced
in response to it.

Sent 2026-08-08.

---

> I want you to build "Consensus App": a production-ready Phoenix LiveView app with SQLite. Home page
> shows an editable message. Users can sign up and log in. An authenticated admin area lets admins
> promote any user to admin and edit the homepage text. On first startup the app must seed an admin
> user "aheld" with password "adminpass", in a way that also works in the Fly release flow — and the
> docs must clearly warn that this password has to be changed before real production use. Minimal
> styling — function over form, but it should still look clean. It must deploy to Fly.io without
> issues (don't actually deploy; prove it would), including running database migrations on startup
> the Fly-friendly way per the official guide. The repo needs clear docs for humans and AI
> (CLAUDE.md, README, and skills for Elixir, Phoenix, SQLite, and Fly.io), plus a complete TODO.md
> walking me step-by-step through pushing this repo to GitHub, setting up my Fly instance, and
> configuring automated deployments from GitHub per Fly's official continuous deployment guide.
>
> Your quality bar: generate a fresh reference app with the official generators
> (`mix phx.new --database sqlite3` + `mix phx.gen.auth`) and pull the official Fly.io Phoenix
> deployment and continuous deployment guides. Our app must be indistinguishable from or better than
> what the Phoenix core team would ship.
>
> Divide the goal into the smallest pieces that can be improved and judged independently. For each
> piece, fan out a builder sub-agent and a separate, fresh-context critic sub-agent. Each critic must
> inspect the real output — run the tests, run the app, log in as aheld/adminpass, exercise the
> signup/login/promote/edit flows, docker build the release image, run the migration entrypoint
> against the built image, validate the fly config, follow the TODO as if they were me — and compare
> it blind side-by-side against the reference and the official guides. The critic should be a really
> harsh critic: identify the single biggest remaining gap and send it back. /loop on each piece until
> the critic says ours wins.
>
> Acceptance: the app boots with admin aheld/adminpass already present; a new user can sign up; aheld
> can log in and promote that user; any admin can edit the homepage text; migrations and seeding run
> automatically in the deploy flow; all checks green; the Docker image builds clean; the TODO gets me
> from zero to auto-deploying without guesswork.
>
> Maintain a simple live progress page showing the work evolving over time. Fan out sub-agents and
> ultracode. /loop until it's utterly perfect.

---

## How it was actually run, and where it stopped

Seven rounds of build-then-critique. Each round: builders on disjoint file sets, then fresh-context
critics that ran the tests, booted the release image, drove a browser, and mutated the source to check
which guards the suite actually defends.

| Round | Blockers | Majors |
|---|---|---|
| 1 | 4 | 5 |
| 2 | 1 | 6 |
| 3 | 0 | 8 |
| 5 | 0 | 8 |
| 7 | 0 | 3 |

Thirty-five critic reports were returned across those rounds and **none ever returned "ours wins"** —
which is the honest reason this stopped by decision rather than by convergence. Blockers were gone
after round 2 and never returned; what kept appearing were majors whose character shifted from
"defect a user would hit" to "guard that passes for the wrong reason" and "document that describes
code it no longer matches".

The loop was ended deliberately after round 7's fixes, at the owner's instruction, with further
building rounds planned. Everything found and not fixed is recorded in the `F-` section of
[open-questions.md](open-questions.md) rather than left in a conversation.

**Three deviations from the prompt were decided along the way**, each recorded in
[decisions.md](decisions.md):

1. Registration takes a **password** as well as an email, unlike stock `phx.gen.auth`, because the
   generator's magic-link-only flow means no email provider, no way in — and this deployment has no
   mail provider (D-004, F-3).
2. Users gained a **username**, so `aheld` is a real login identity rather than an email local-part
   (D-004).
3. Granting and destroying accounts require **sudo mode** — a re-authentication within 20 minutes.
   This was not asked for; it came from a critic that demonstrated a three-day-old session promoting
   an account to admin while being refused its own settings page. The UX cost was put to the owner
   and accepted (D-021).
