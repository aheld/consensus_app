defmodule ConsensusWeb.SocialPreviewTest do
  @moduledoc """
  Pins the `<head>` social block both as a component and route by route.

  The component half alone is not enough, for the same reason `chrome_test.exs` gives:
  `ConsensusWeb.SocialPreview.meta_tags/1` can be perfectly correct while no screen passes
  it anything, and the one screen that actually gets pasted into a group chat is
  `/join/:slug`. The route half is also the only half that renders through
  `root.html.heex`, which is where a bracket-access typo would live.
  """

  # Nothing here issues DDL — safe under `max_cases: 1` (D-033).
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Consensus.AccountsFixtures
  import Consensus.VotingFixtures

  alias ConsensusWeb.SocialPreview

  # `[^>]*` around the attribute rather than a fixed shape: `render_component/2` injects a
  # `phx-r` root marker that a full-page render does not, so a regex pinned to
  # `<meta name="..."` matches in one half of this file and silently returns `nil` in the
  # other. `[^>]` cannot cross the tag boundary, so this stays anchored to one tag.
  defp meta(html, attr, key) do
    case Regex.run(~r/<meta[^>]*\s#{attr}="#{Regex.escape(key)}"[^>]*\scontent="([^"]*)"/, html) do
      [_, content] -> unescape(content)
      nil -> nil
    end
  end

  defp og(html, property), do: meta(html, "property", property)
  defp twitter(html, name), do: meta(html, "name", name)

  defp canonical(html) do
    case Regex.run(~r/<link[^>]*\srel="canonical"[^>]*\shref="([^"]*)"/, html) do
      [_, href] -> unescape(href)
      nil -> nil
    end
  end

  # What comes out of the document is HEEx-escaped; expectations here are written in plain
  # text. Unescape rather than re-escape the expectation — a group title is free text and
  # `Dinner & drinks?` should be asserted as itself. `&amp;` last, or `&amp;lt;` decodes
  # into `<`.
  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  describe "the component's defaults" do
    test "a screen that says nothing still renders a complete, valid card" do
      html = render_component(&SocialPreview.meta_tags/1, %{})
      defaults = SocialPreview.defaults()

      assert og(html, "og:title") == defaults.title
      assert og(html, "og:description") == defaults.description
      assert og(html, "og:site_name") == "Consensus"
      assert og(html, "og:type") == "website"

      # Every unfurler resolves `og:image` from its own host, so a root-relative path is
      # simply dropped and the card renders imageless. This assertion is the whole feature.
      assert og(html, "og:image") == SocialPreview.image_url()
      assert og(html, "og:image") =~ ~r{\Ahttps?://}
      assert og(html, "og:image") =~ defaults.image_path

      # Without the declared size, Facebook and LinkedIn render the first fetch as a
      # thumbnail and only upgrade to the large card once their own crawler has measured it.
      assert og(html, "og:image:width") == "1200"
      assert og(html, "og:image:height") == "630"
      refute og(html, "og:image:alt") in [nil, ""]

      # `summary_large_image` is what makes it full-bleed rather than a 120px square.
      assert twitter(html, "twitter:card") == "summary_large_image"
    end

    test "the plain description meta mirrors og:description" do
      html = render_component(&SocialPreview.meta_tags/1, %{description: "A short line."})

      assert meta(html, "name", "description") == "A short line."
      assert og(html, "og:description") == "A short line."
    end
  end

  describe "clamping" do
    test "a long title is truncated with an ellipsis rather than by the platform" do
      html = render_component(&SocialPreview.meta_tags/1, %{title: String.duplicate("ab", 80)})
      title = og(html, "og:title")

      assert String.length(title) == 70
      assert String.ends_with?(title, "…")
    end

    test "a long description is truncated too" do
      html =
        render_component(&SocialPreview.meta_tags/1, %{description: String.duplicate("word ", 90)})

      assert String.length(og(html, "og:description")) == 200
    end

    test "newlines and runs of whitespace collapse to single spaces" do
      html = render_component(&SocialPreview.meta_tags/1, %{title: "  Dinner\n\n  Friday?  "})

      assert og(html, "og:title") == "Dinner Friday?"
    end

    test "a title exactly at the limit is left alone" do
      exact = String.duplicate("x", 70)
      html = render_component(&SocialPreview.meta_tags/1, %{title: exact})

      assert og(html, "og:title") == exact
    end
  end

  describe "the canonical URL" do
    test "defaults to the site root when there is no current path" do
      html = render_component(&SocialPreview.meta_tags/1, %{})

      assert canonical(html) == ConsensusWeb.Endpoint.url()
      assert og(html, "og:url") == ConsensusWeb.Endpoint.url()
    end

    test "is derived from current_path, with the query string dropped" do
      # Every standing page is reachable as `/about?return_to=<wherever the footer was
      # tapped>`. Honouring the query would mint one canonical — and one sticky unfurl
      # cache entry — per originating screen.
      html =
        render_component(&SocialPreview.meta_tags/1, %{
          current_path: "/about?return_to=%2Fgroups%2F3%2Foptions"
        })

      assert canonical(html) == ConsensusWeb.Endpoint.url() <> "/about"
    end

    test "an explicit url wins over current_path" do
      html =
        render_component(&SocialPreview.meta_tags/1, %{
          url: "https://example.test/join/abc",
          current_path: "/join/abc"
        })

      assert canonical(html) == "https://example.test/join/abc"
    end
  end

  describe "the image is actually served" do
    test "GET on the og:image path returns 200 and a PNG", %{conn: conn} do
      path = URI.parse(SocialPreview.image_url()).path

      conn = get(conn, path)

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    end
  end

  describe "route by route" do
    test "/ carries the app-wide default card", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      defaults = SocialPreview.defaults()

      assert og(html, "og:title") == defaults.title
      assert og(html, "og:description") == defaults.description
      assert canonical(html) == ConsensusWeb.Endpoint.url() <> "/"
    end

    test "/join/:slug names the group, the spot count and the organizer", %{conn: conn} do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 3)

      html = conn |> get(~p"/join/#{group.slug}") |> html_response(200)

      # Frame `1d-0`'s chat card: "<title> · N spots".
      assert og(html, "og:title") == "#{group.title} · 3 spots"
      assert og(html, "og:description") =~ scope.user.username
      assert og(html, "og:description") =~ "3 spots"
      assert og(html, "og:description") =~ "No app, no account."

      # The canonical must be the join link itself — this is the URL being pasted.
      assert canonical(html) == ConsensusWeb.Endpoint.url() <> "/join/#{group.slug}"
      assert og(html, "og:url") == canonical(html)
    end

    test "/join/:slug leaves the deadline out of the card", %{conn: conn} do
      # There is no timezone on a dead render (D-031 — local time arrives as a LiveView
      # connect param and a crawler never connects), and a chat client caches an unfurl for
      # hours, so a countdown would be pinned wrong with no way to correct it. The page
      # itself still shows one.
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 3)

      html = conn |> get(~p"/join/#{group.slug}") |> html_response(200)

      refute og(html, "og:description") =~ "closes"
      assert html =~ "closes"
    end

    test "/join/:slug/results names the vote but never the tally", %{conn: conn} do
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 3)

      html = conn |> get(~p"/join/#{group.slug}/results") |> html_response(200)

      assert og(html, "og:title") == "#{group.title} · results"
      assert og(html, "og:description") =~ scope.user.username
      assert canonical(html) == ConsensusWeb.Endpoint.url() <> "/join/#{group.slug}/results"
    end

    test "the standing pages each carry their own card and their own canonical", %{conn: conn} do
      for {path, expected_title} <- [
            {"/about", "About Consensus"},
            {"/privacy", "Privacy · Consensus"},
            {"/how-it-works", "How Consensus works"},
            {"/feedback", "Send feedback · Consensus"}
          ] do
        html = conn |> get(path) |> html_response(200)

        assert og(html, "og:title") == expected_title,
               "#{path} did not carry its own og:title"

        assert canonical(html) == ConsensusWeb.Endpoint.url() <> path,
               "#{path} did not canonicalise to itself"
      end
    end

    test "a standing page reached with ?return_to= still canonicalises to itself", %{conn: conn} do
      html = conn |> get("/about?return_to=%2Fgroups%2F3%2Foptions") |> html_response(200)

      assert canonical(html) == ConsensusWeb.Endpoint.url() <> "/about"
    end

    test "a LiveView that renders through the live socket still served the card first", %{
      conn: conn
    } do
      # Belt and braces on the thing that would silently break the feature: the tags live in
      # `root.html.heex`, so they exist only on the dead render. That is the render an
      # unfurler gets, and `live/2` asserts the dead render happened and then connected.
      scope = user_scope_fixture()
      {group, _activities} = voting_group_fixture(scope, 3)

      {:ok, _view, _html} = live(conn, ~p"/join/#{group.slug}")
    end
  end
end
