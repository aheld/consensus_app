defmodule ConsensusWeb.JourneyTest do
  @moduledoc """
  The acceptance test for the creation side, end to end, as one person doing one thing:

      sign up → create a group → add options (typed and by pasting a link)
      → edit an option → review and publish → get the share link
      → log out → log back in → everything is still there

  It is deliberately **one test**. Each screen already has its own file covering its own
  branches; this one exists to catch the failures that only appear between screens — a
  wizard step that navigates somewhere that does not exist, a value that is displayed but
  never written, a draft that cannot be resumed. Those are invisible to per-screen tests
  by construction, because each of those mounts the screen with fixtures instead of
  arriving from the step before.

  The log-out/log-back-in leg is the point of the whole thing. "Never make me re-enter
  anything" is a product requirement, and the only honest way to test it is to throw the
  session away and come back with a new one: a new `conn`, a new session token, a new
  LiveView process, and nothing carried over but what reached SQLite.
  """
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Consensus.Accounts
  alias Consensus.LinkPreviewStub

  # RFC 5737 TEST-NET-1. Never routable, and `Consensus.LinkPreview`'s guard skips DNS for
  # a literal IP, so nothing here can touch the network even if the stub were missed.
  @link_url "http://192.0.2.10/osteria-mozza"

  @pulled_html """
  <html><head>
    <meta property="og:title" content="Osteria Mozza">
    <meta property="og:description" content="Handmade pasta on Highland. Book ahead.">
    <meta property="og:image" content="http://192.0.2.10/mozza.jpg">
  </head></html>
  """

  setup do
    Consensus.LinkPreview.Cache.flush()

    LinkPreviewStub.stub(fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "text/html; charset=utf-8"}],
         body: @pulled_html,
         url: @link_url
       }}
    end)

    :ok
  end

  test "an organizer signs up, builds a session, logs out, and finds it all still there", %{
    conn: conn
  } do
    ## 1. A cold visitor lands on the splash and registers with a username and password.

    {:ok, home, html} = live(conn, ~p"/")
    assert html =~ "Decide"
    assert html =~ "Get started"

    {:ok, register, _html} =
      home
      |> element(~s{a[href="/users/register"]}, "Get started")
      |> render_click()
      |> follow_redirect(conn, ~p"/users/register")

    register
    |> form("#registration_form",
      user: %{
        "username" => "sarah",
        "email" => "sarah@example.com",
        "password" => "a very long password"
      }
    )
    |> render_submit()

    # Registration posts to the session controller, which is what actually signs you in.
    conn =
      post(conn, ~p"/users/log-in?_action=registered",
        user: %{"login" => "sarah", "password" => "a very long password"}
      )

    assert redirected_to(conn) == ~p"/"
    user = Accounts.get_user_by_login_and_password("sarah", "a very long password")
    assert user, "registration did not create a usable account"

    ## 2. The home screen is empty, and offers the one forward action.

    {:ok, home, html} = live(conn, ~p"/")
    assert html =~ "Start something"
    assert html =~ "Nothing yet"

    # The home screen renders the "Start something" link twice — once in the desktop rail,
    # once in the phone header — with one hidden by a breakpoint class rather than by being
    # absent, so an unqualified selector is ambiguous here even though only one is ever
    # visible. Checked at both 390px and 1280px: the inactive copy has a zero-size rect and
    # is not focusable, so this is a test-selector problem, not a markup defect. Assert the
    # affordance exists, then navigate.
    assert has_element?(home, ~s{a[href="/groups/new"]})
    {:ok, setup, _html} = live(conn, ~p"/groups/new")

    ## 3. Step 1 — title and a deadline chip. Both are required, and the chips are computed.

    setup
    |> element(~s{button[phx-click="select_deadline"]}, "Tomorrow 5pm")
    |> render_click()

    {:ok, options, _html} =
      setup
      |> form("#group-form", group: %{"title" => "Dinner Friday?"})
      |> render_submit()
      |> follow_redirect(conn)

    group = one_group(user)
    assert group.title == "Dinner Friday?"
    assert group.status == :draft
    assert group.deadline_at, "the chip selection never reached the database"

    ## 4. Step 2 — one option typed by hand, one pasted as a link.

    options
    |> form("#add-option-form", add_option: %{"query" => "Guisados"})
    |> render_submit()

    options
    |> form("#add-option-form", add_option: %{"query" => @link_url})
    |> render_submit()

    # The pasted row appears immediately with a provisional name and fills in from the
    # async fetch. `render_async/1` waits for that to land rather than sleeping.
    html = render_async(options)
    assert html =~ "Guisados"
    assert html =~ "Osteria Mozza", "the pasted link never resolved into a name"

    [first, second] = one_group(user).activities
    assert first.name == "Guisados"
    assert first.position == 1
    assert second.name == "Osteria Mozza"
    assert second.position == 2
    assert second.source_url == @link_url
    assert second.image_url == "http://192.0.2.10/mozza.jpg"
    assert second.description =~ "Handmade pasta"
    assert second.metadata_fetched_at

    ## 5. Step 2b — the pulled details are editable, and an edit sticks.

    {:ok, editor, html} = live(conn, ~p"/groups/#{group.id}/options/#{second.id}")
    assert html =~ "Osteria Mozza", "the editor did not prefill the stored name"
    assert html =~ "Handmade pasta"

    editor
    |> form("#edit-option-form",
      activity: %{"name" => "Osteria Mozza (Highland)", "description" => "Book ahead."}
    )
    |> render_submit()

    ## 6. Step 3 — review, then publish, which is what makes the share link real.

    {:ok, review, html} = live(conn, ~p"/groups/#{group.id}/review")
    assert html =~ "Osteria Mozza (Highland)"
    assert html =~ "Guisados"

    {:ok, _share, html} =
      review
      |> element(~s{[phx-click="publish"]})
      |> render_click()
      |> follow_redirect(conn, ~p"/groups/#{group.id}/share")

    group = one_group(user)
    assert group.status == :voting
    assert html =~ group.slug, "the share screen does not show the join link"

    ## 7. Log out. This is a real session teardown, not a reassignment.

    conn = delete(conn, ~p"/users/log-out")
    assert redirected_to(conn) == ~p"/"

    {:ok, _lv, html} = live(build_conn(), ~p"/")
    assert html =~ "Decide", "logging out did not return the visitor to the splash"
    refute html =~ "Dinner Friday?"

    ## 8. Log back in with a brand-new connection, and find everything.

    conn =
      build_conn()
      |> post(~p"/users/log-in",
        user: %{"login" => "sarah", "password" => "a very long password"}
      )

    assert redirected_to(conn) == ~p"/"

    {:ok, _home, html} = live(conn, ~p"/")
    assert html =~ "Dinner Friday?", "the session did not survive logging out and back in"
    assert html =~ "VOTING"

    {:ok, _review, html} = live(conn, ~p"/groups/#{group.id}/review")
    assert html =~ "Guisados"
    assert html =~ "Osteria Mozza (Highland)", "the edited name did not survive"
    assert html =~ "Book ahead.", "the edited description did not survive"

    assert html =~ "http://192.0.2.10/mozza.jpg",
           "the image URL pulled from the pasted link did not survive"

    # The pool froze when the vote opened (D-037): the option editor that step 5 used is
    # no longer reachable for this group, because a delete there would cascade into
    # ballots. The review screen above is where the organizer sees the pool now, and it
    # is the one that had to still carry the pasted image.
    assert {:error, {:live_redirect, %{to: locked_to}}} =
             live(conn, ~p"/groups/#{group.id}/options/#{second.id}")

    assert locked_to == ~p"/groups/#{group.id}/review"

    ## 9. Nothing was re-entered anywhere, and nothing leaked into another organizer's world.

    other = Consensus.AccountsFixtures.user_fixture()
    assert Consensus.Activities.list_groups(scope_for(other)) == []
  end

  defp one_group(user) do
    assert [group] = Consensus.Activities.list_groups(scope_for(user))
    group
  end

  defp scope_for(user), do: Consensus.Accounts.Scope.for_user(user)
end
