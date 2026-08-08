defmodule ConsensusWeb.HomeLiveTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  alias Consensus.Content

  # The rendered body of `<p id="home-message">`, verbatim. Asserting on this rather
  # than on a Tailwind class name is what catches whitespace the template itself
  # introduces — under `whitespace-pre-wrap` a newline in the HEEx source is a newline
  # on screen, and a class-string assertion cannot see it.
  defp rendered_message(html) do
    case Regex.run(~r|id="home-message"[^>]*>(.*?)</p>|s, html) do
      [_, body] -> body
      nil -> flunk(~s|no <p id="home-message"> element in the rendered page|)
    end
  end

  defp escaped(message) do
    message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # The opening tag of `<p id="home-message">`, attributes and all.
  defp home_message_tag(html) do
    case Regex.run(~r|<p id="home-message"[^>]*>|, html) do
      [tag] -> tag
      nil -> flunk(~s|no <p id="home-message"> element in the rendered page|)
    end
  end

  defp class_of(html, regex, what) do
    case Regex.run(regex, html) do
      [_, class] -> class
      nil -> flunk("no #{what} in the rendered page")
    end
  end

  describe "the public home page" do
    test "renders the default message on an unseeded database", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Consensus"
      assert html =~ "An admin can edit this message"
    end

    test "renders the stored message", %{conn: conn} do
      Content.ensure_home_page!()

      {:ok, _} =
        Content.update_home_page(admin_scope_fixture(), %{message: "Pizza, 7pm, Luigi's."})

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Pizza, 7pm, Luigi&#39;s."
    end

    test "the paragraph body is the stored message and nothing else", %{conn: conn} do
      {:ok, _} =
        Content.update_home_page(admin_scope_fixture(), %{
          message: "Exactly this.\n\n  Indented on purpose.\nQuoted \"like so\" & <angled>."
        })

      {:ok, _lv, html} = live(conn, ~p"/")

      # `whitespace-pre-wrap` renders every character between the tags, so the only
      # honest assertion is byte equality: the paragraph body must be the escaped
      # stored message exactly, with no template indentation or newline of its own.
      assert rendered_message(html) == escaped(Content.get_home_page().message)
    end

    test "the default message reaches the browser exactly as stored", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      # The unseeded fallback and the seeded row are the same string, and it is the
      # first prose a fresh install shows anyone. Its line structure is asserted in
      # test/consensus/content_test.exs; this asserts the page does not add to it.
      assert rendered_message(html) == escaped(Content.default_message())
    end

    test "is reachable without logging in and offers sign-up links", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)

      assert html =~ ~p"/users/register"
      assert html =~ ~p"/users/log-in"
    end

    test "shows no admin affordances to an anonymous visitor", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ ~p"/admin/home-page"
    end

    test "shows no admin affordances to a plain member", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(user_fixture()) |> live(~p"/")

      refute html =~ ~p"/admin/home-page"
      refute html =~ ~p"/admin/users"
    end

    test "shows the edit link and admin nav to an admin", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(admin_fixture()) |> live(~p"/")

      assert html =~ ~p"/admin/home-page"
      assert html =~ ~p"/admin/users"
    end

    test "a long unbroken string cannot force the page to scroll sideways", %{conn: conn} do
      {:ok, _} =
        Content.update_home_page(admin_scope_fixture(), %{
          message: "https://example.com/" <> String.duplicate("a", 300)
        })

      {:ok, _lv, html} = live(conn, ~p"/")

      # `pre-line` would leave the URL on one unbreakable line; `pre-wrap break-words`
      # keeps the admin's formatting and still wraps.
      assert html =~ "whitespace-pre-wrap"
      assert html =~ "break-words"
    end

    test "escapes HTML in the message", %{conn: conn} do
      {:ok, _} =
        Content.update_home_page(admin_scope_fixture(), %{
          message: "<script>alert('xss')</script>"
        })

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "the navbar is allowed to wrap on a narrow screen" do
    # Honest about what this is: a LiveView test renders HTML and has no layout engine, so
    # it cannot assert that the page fits 375px. What it can pin is the CSS that decides
    # whether it can. Measured in Chrome at 375px signed in as an admin, before and after:
    #
    #   flex-none  ->  documentElement.scrollWidth 411, <ul> 396px, header 85px,
    #                  the theme toggle's dark segment 33px off the right edge
    #   min-w-0    ->  documentElement.scrollWidth 375, <ul> 343px, header 117px,
    #                  nothing overflowing the viewport
    #
    # `flex-none` is `flex: 0 0 auto`: it sizes the group to the list's max-content width
    # and forbids shrinking, which makes every `flex-wrap` around it unreachable. So the
    # three assertions below are one contract — the wrap classes only do anything while the
    # group can shrink, and shrinking only helps while the wrap classes are there. Any of
    # the three going missing puts the toggle back off-screen.
    test "the nav group can shrink and both wrap classes survive", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(admin_fixture()) |> live(~p"/")

      nav_group =
        class_of(html, ~r|<div id="user-nav"[^>]*class="([^"]*)"|, ~s(<div id="user-nav">))

      header = class_of(html, ~r|<header[^>]*class="([^"]*)"|, "<header>")
      list = class_of(html, ~r|<div id="user-nav".*?<ul[^>]*class="([^"]*)"|s, "the nav <ul>")

      refute nav_group =~ "flex-none",
             "flex-none pins the nav group at its max-content width, so the navbar can " <>
               "never wrap and a signed-in admin gets a sideways scrollbar at 375px"

      assert nav_group =~ "min-w-0"
      assert header =~ "flex-wrap"
      assert list =~ "flex-wrap"
    end
  end

  describe "live updates" do
    test "an edit reaches an already-open home page without a refresh", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")
      refute html =~ "Everyone, the plan changed"

      {:ok, _} =
        Content.update_home_page(admin_scope_fixture(), %{message: "Everyone, the plan changed"})

      assert render(lv) =~ "Everyone, the plan changed"
    end

    # The update above is pushed, not requested: nothing the visitor did caused it, so a
    # screen reader has no reason to revisit the paragraph and, without a live region,
    # simply never mentions that the page now says something else. `polite` rather than
    # `assertive` because the new message is worth hearing at the next pause and never
    # worth cutting off the sentence being read.
    test "the message is a polite live region so a pushed edit is announced", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert home_message_tag(html) =~ ~s(aria-live="polite")
    end
  end
end
