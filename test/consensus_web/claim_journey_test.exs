defmodule ConsensusWeb.ClaimJourneyTest do
  @moduledoc """
  The anonymous sibling of `ConsensusWeb.JourneyTest` (D-058, plan §9 "claim end to end"):

      a cold browser → /groups/new → create (with a name) → options → publish → share
      → register → `/` lists the session as the account's

  One browser, one `conn`, nothing carried between steps but what a browser carries —
  the session cookie and the organizer cookie. Like its sibling it is deliberately one
  test for the walk itself, because the claim is a seam between two halves of the app
  (the accountless wizard and the log-in) that each have their own files and neither of
  which can see the other.

  The second test is the stale-tab half of §6.3: a wizard tab left open with the
  anonymous scope must stop being able to write once a log-in has moved its session to
  an account.
  """
  # `async: false`: the claim's disconnect is a real PubSub broadcast on a topic derived
  # from the token, and the second test asserts a mounted LiveView receives it.
  use ConsensusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Consensus.Accounts
  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias ConsensusWeb.OrganizerAuth

  @cookie OrganizerAuth.cookie_name()

  test "an organizer with no account builds a session, signs up, and finds it saved", %{
    conn: conn
  } do
    ## 1. A cold browser opens step 1. The plain GET is what mints the identity and
    ##    writes the cookie; every later request carries it, as a browser would.

    conn = get(conn, ~p"/groups/new")
    assert html_response(conn, 200)
    assert %{max_age: max_age} = conn.resp_cookies[@cookie]
    assert max_age > 0

    {:ok, setup, html} = live(conn, ~p"/groups/new")
    assert html =~ "organizer[display_name]", "the accountless name field is missing"

    ## 2. Step 1 — title, a chip, and the optional name, in one submit.

    setup
    |> element(~s{button[phx-click="select_deadline"]}, "Tomorrow 5pm")
    |> render_click()

    {:ok, options, _html} =
      setup
      |> form("#group-form",
        group: %{"title" => "Dinner Friday?"},
        organizer: %{"display_name" => "Sarah"}
      )
      |> render_submit()
      |> follow_redirect(conn)

    [group] = anonymous_groups(conn)
    assert group.title == "Dinner Friday?"
    assert group.organizer_id == nil
    assert Activities.organizer_custom_name(group) == "Sarah"

    ## 3. Step 2 — two typed options.

    for name <- ["Guisados", "Zahav"] do
      options |> form("#add-option-form", add_option: %{"query" => name}) |> render_submit()
    end

    assert Activities.count_activities(group) == 2

    ## 4. Step 3 → 4 — publish, and the share link is real.

    {:ok, review, _html} = live(conn, ~p"/groups/#{group.id}/review")

    {:ok, _share, html} =
      review
      |> element(~s{[phx-click="publish"]})
      |> render_click()
      |> follow_redirect(conn, ~p"/groups/#{group.id}/share")

    [group] = anonymous_groups(conn)
    assert group.status == :voting
    assert html =~ group.slug

    ## 5. Register. The form posts to the session controller, which signs in — and that
    ##    log-in is the claim.

    {:ok, register, _html} = live(conn, ~p"/users/register")

    register
    |> form("#registration_form",
      user: %{
        "username" => "sarah",
        "email" => "sarah@example.com",
        "password" => "a very long password"
      }
    )
    |> render_submit()

    conn =
      post(conn, ~p"/users/log-in?_action=registered",
        user: %{"login" => "sarah", "password" => "a very long password"}
      )

    assert redirected_to(conn) == ~p"/"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Account created successfully! 1 session saved to your account."

    assert %{max_age: 0} = conn.resp_cookies[@cookie]

    user = Accounts.get_user_by_login_and_password("sarah", "a very long password")
    assert [saved] = Activities.list_groups(Scope.for_user(user))
    assert saved.id == group.id
    assert saved.anonymous_organizer_id == nil

    ## 6. `/` lists it as the account's, and the organizer screens open on the account.

    {:ok, _home, html} = live(conn, ~p"/")
    assert html =~ "Dinner Friday?", "the claimed session is not on the account's home list"

    {:ok, _results, html} = live(conn, ~p"/groups/#{group.id}/results")
    assert html =~ "Dinner Friday?"

    # Guests now see the account's name (plan §6.3 edge case 4).
    assert Activities.organizer_custom_name(Activities.get_group_by_slug(group.slug)) == "sarah"
  end

  test "a tab left open with the anonymous scope stops writing once the claim lands", %{
    conn: conn
  } do
    conn = get(conn, ~p"/groups/new")
    raw_token = organizer_token(conn)
    scope = Scope.for_anonymous_organizer(Activities.get_anonymous_organizer_by_token(raw_token))
    group = Consensus.ActivitiesFixtures.group_fixture(scope)
    Consensus.ActivitiesFixtures.activity_fixture(group)

    {:ok, review, _html} = live(conn, ~p"/groups/#{group.id}/review")

    # Another tab of the same browser logs in.
    user = Consensus.AccountsFixtures.user_fixture()

    login =
      post(conn, ~p"/users/log-in",
        user: %{
          "login" => user.username,
          "password" => Consensus.AccountsFixtures.valid_user_password()
        }
      )

    assert Phoenix.Flash.get(login.assigns.flash, :info) =~ "1 session saved"

    # The open tab is told, and leaves for a full request that re-runs the plugs.
    assert_redirect(review, ~p"/groups/#{group.id}/review")

    # And the scope it was holding authorizes nothing any more: the group's owner moved,
    # so the anonymous head no longer matches.
    moved = Activities.get_group!(Scope.for_user(user), group.id)

    assert_raise FunctionClauseError, fn -> Activities.publish_group(scope, moved) end
    assert_raise FunctionClauseError, fn -> Activities.cancel_group(scope, moved) end

    # The same browser, back on that route, reaches it as the account.
    {:ok, _review, html} = live(login, ~p"/groups/#{group.id}/review")
    assert html =~ group.title
  end

  # The organizer's groups, read through the identity the browser's cookie resolves to.
  defp anonymous_groups(conn) do
    conn
    |> organizer_token()
    |> Activities.get_anonymous_organizer_by_token()
    |> Scope.for_anonymous_organizer()
    |> Activities.list_groups()
  end

  defp organizer_token(conn) do
    conn
    |> recycle()
    |> Map.put(:secret_key_base, ConsensusWeb.Endpoint.config(:secret_key_base))
    |> Plug.Conn.fetch_cookies(signed: [@cookie])
    |> Map.fetch!(:cookies)
    |> Map.fetch!(@cookie)
  end
end
