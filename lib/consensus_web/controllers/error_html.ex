defmodule ConsensusWeb.ErrorHTML do
  @moduledoc """
  Rendered by the endpoint for HTML errors — see `config/config.exs`.

  **404 and 500 wear the global chrome** (D-041) instead of the generator's plain-text
  body. `/join/<mistyped-slug>` is the single likeliest 404 in this product: a share link
  pasted into a chat and re-typed by hand, hit by someone who has no account, no history
  of the group and no idea what this site is. The generator's response to that was the
  words "Not Found" on a white page with no styling and no link anywhere — the exact dead
  end `docs/plans/chrome-and-feedback.md` exists to remove, on the one surface the plan's
  own sweep could not reach because it is not a LiveView.

  Both templates render `ConsensusWeb.Layouts.app/1` with `variant={:marketing}`, which is
  the only correct variant here: an unmatched path raises `Phoenix.Router.NoRouteError`
  before any pipeline runs, so there is no `current_scope` in `conn.assigns` and the page
  cannot know whether the visitor is signed in. `flash={%{}}` for the same reason — a
  fetched flash is not guaranteed either.

  `render_errors` in `config/config.exs` therefore carries
  `root_layout: {ConsensusWeb.Layouts, :root}`; without it these pages would render as a
  bare fragment with no `<head>` and so no stylesheet, which is a worse-looking version of
  the problem being fixed. Anything raised *while rendering an error* is unrecoverable, so
  keep these templates static: no database, no scope, no assigns beyond `@conn`.
  """
  use ConsensusWeb, :html

  embed_templates "error_html/*"

  # Every other status keeps the generator's plain-text body: "429" becomes
  # "Too Many Requests". Only the two a person can actually land on are drawn.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
