defmodule ConsensusWeb.CurrentPath do
  @moduledoc """
  An `on_mount` hook that keeps `@current_path` in sync with the address bar.

  Attached once, in `ConsensusWeb.live_view/0`, so **every** LiveView in this app has
  the assign without any `live_session` in the router having to remember it. Two things
  in the global chrome (D-041) need to know where the visitor is standing, and neither
  can work it out from the assigns it already has:

    * `ConsensusWeb.Chrome.header/1` suppresses the `⋯` menu entry that points at the
      page you are already on — the signed-out menu offering "Log in" *while you are on
      the log-in form* is a link to nowhere.
    * `ConsensusWeb.Chrome.footer/1` hangs `?return_to=` off the standing-page links, so
      "How it works" tapped from step 2 of the wizard comes back to step 2 rather than
      dumping you at `/`.

  It is a `:handle_params` hook rather than something read in `mount/3` because
  `live_patch` navigation (the wizard's `02` ↔ `02b`, for one) changes the URL without
  remounting. `Phoenix.LiveView.Lifecycle` runs attached `handle_params` hooks even for a
  LiveView that defines no `handle_params/3` of its own, so nothing else has to change.

  `assign_new/3` seeds `nil` at mount: a LiveView rendered outside a live route (or a
  component rendered straight into `render_component/2` in a test) still has the assign,
  and everything downstream treats `nil` as "no idea, use the default".
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_path, fn -> nil end)
      |> attach_hook(:current_path, :handle_params, &put_current_path/3)

    {:cont, socket}
  end

  defp put_current_path(_params, uri, socket) do
    {:cont, assign(socket, :current_path, path_with_query(uri))}
  end

  defp path_with_query(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: nil} -> nil
      %URI{path: path, query: nil} -> path
      %URI{path: path, query: query} -> path <> "?" <> query
    end
  end

  defp path_with_query(_uri), do: nil

  @doc """
  Returns `path` when it is safe to navigate to, and `nil` otherwise.

  `return_to` arrives as a query parameter, so it is attacker-controlled: anyone can
  hand out `/about?return_to=https://elsewhere.example`, and a `<.link navigate={...}>`
  built straight from it would be an open redirect wearing this app's chrome. Only a
  single-slash absolute path is accepted — `//host/x` and `/\host/x` are both read as
  protocol-relative by browsers and would leave the site, so they are rejected along
  with everything else.

  **A prefix check is not enough, and leaving it at one failed open into a 500.** Since
  D-045 this same function decides what `ConsensusWeb.UserAuth.store_return_to/2` writes
  into `:user_return_to`, which `log_in_user/3` then hands to
  `Phoenix.Controller.redirect/2` — and `redirect/2` refuses three shapes this filter used
  to pass (`@invalid_local_url_chars` in `Phoenix.Controller`: a `\\` anywhere, `/%09`, and
  a literal tab) by *raising* `ArgumentError`. So `?return_to=/%09//evil.example` was
  accepted here, carried through the log-in form, and turned a correct password into
  `500 Internal Server Error` with the browser still signed out: an attacker-supplied link
  that breaks authentication for the person who follows it. The reason those three are
  unsafe rather than merely odd is the reason the whole check exists — the WHATWG URL
  parser strips ASCII tab, LF and CR *before* resolving, so `/\t/evil.example` survives a
  prefix test and then resolves protocol-relative, off-site.

  Nothing this app legitimately produces contains whitespace, a C0/C1 control or a
  backslash — the footer builds `return_to` from a percent-encoded `URI`, and every other
  caller passes a `~p` literal — so all of them are refused outright. That is the same rule
  `Consensus.Feedback.Entry.safe_page_path/1` applies to the stored `page_path` it renders
  as an `href`; the two are kept separate deliberately, because they guard different sinks
  (a redirect here, an anchor there) and neither should quietly inherit the other's
  loosening.
  """
  # `"/%09"` is the percent-encoded tab `Phoenix.Controller` rejects by name; the character
  # class covers the literal tab, every other C0 control, space, DEL and C1.
  def safe_return_to("//" <> _rest), do: nil
  def safe_return_to("/\\" <> _rest), do: nil

  def safe_return_to("/" <> _rest = path) do
    cond do
      String.contains?(path, "\\") -> nil
      String.contains?(path, "/%09") -> nil
      String.match?(path, ~r/[\x00-\x20\x7F-\x9F]/) -> nil
      true -> path
    end
  end

  def safe_return_to(_other), do: nil

  @doc """
  Where a standing page's `‹` should go: the `return_to` it was handed, or `"/"`.

  The four pages the global footer links to (`/about`, `/how-it-works`, `/privacy`,
  `/feedback`) are reachable from *every* screen in the app, so a hardcoded `back={~p"/"}`
  drops an organizer standing on step 2 of the wizard onto the home list. The footer hangs
  the caller's own path off each link; this reads it back, and falls back to `/` when the
  page was reached some other way (a bookmark, a shared URL, a search result).
  """
  def return_to(%{"return_to" => value}), do: safe_return_to(value) || "/"
  def return_to(_params), do: "/"
end
