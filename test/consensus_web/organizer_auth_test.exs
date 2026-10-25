defmodule ConsensusWeb.OrganizerAuthTest do
  # `async: false` for the busy-mint case only: it creates a TEMP TRIGGER, and a test that
  # issues DDL must share the sandbox connection rather than hold its own (the elixir
  # skill's `async:` table). Under `max_cases: 1` (D-033) the flag costs nothing.
  use ConsensusWeb.ConnCase, async: false

  alias Consensus.Accounts.Scope
  alias Consensus.Activities.AnonymousOrganizer
  alias Consensus.Repo
  alias ConsensusWeb.GroupLive
  alias ConsensusWeb.OrganizerAuth
  alias Phoenix.LiveView

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  @cookie OrganizerAuth.cookie_name()
  @ninety_days 90 * 24 * 60 * 60

  # Runs the real `:browser` pipeline for `path` — session, the user-scope fetch and
  # `fetch_organizer_token/2` — and stops before any route, so a plug can be called on
  # exactly the conn the router would hand it. The LiveView itself never runs.
  defp through_browser(conn, path) do
    conn
    |> bypass_through(ConsensusWeb.Router, [:browser])
    |> get(path)
  end

  defp organizer_count, do: Repo.aggregate(AnonymousOrganizer, :count)

  # The token a response's organizer cookie carries, verified the way the next request
  # will verify it (the stored `value` is the signed form, not the token).
  defp resp_token(conn) do
    conn
    |> recycle()
    |> Map.put(:secret_key_base, conn.secret_key_base)
    |> Plug.Conn.fetch_cookies(signed: [@cookie])
    |> Map.fetch!(:cookies)
    |> Map.get(@cookie)
  end

  defp redirected_to_log_in?(conn),
    do: conn.status == 302 and String.starts_with?(redirected_to(conn), "/users/log-in")

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(:second), -days, :day)

  defp socket(view, live_action, assigns) do
    %LiveView.Socket{
      endpoint: ConsensusWeb.Endpoint,
      view: view,
      assigns: Map.merge(%{__changed__: %{}, flash: %{}, live_action: live_action}, assigns)
    }
  end

  describe "the cookie" do
    test "is named __Host- in prod, so a sibling subdomain cannot plant one" do
      prod = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
      name = prod[:consensus][:organizer_cookie]

      assert "__Host-" <> _ = name
    end

    test "is plain in test, where there is no TLS to make it Secure" do
      assert @cookie == "_consensus_organizer"
      refute OrganizerAuth.cookie_options()[:secure]
    end

    test "lasts 90 days, signed, http-only and Lax" do
      options = OrganizerAuth.cookie_options()

      assert options[:max_age] == @ninety_days
      assert options[:sign]
      assert options[:http_only]
      assert options[:same_site] == "Lax"
    end
  end

  describe "fetch_organizer_token/2" do
    test "mirrors the signed cookie into the session", %{conn: conn} do
      conn = conn |> put_organizer_token("raw-token") |> through_browser("/")

      assert get_session(conn, "organizer_token") == "raw-token"
    end

    test "ignores an unsigned cookie", %{conn: conn} do
      conn = conn |> put_req_cookie(@cookie, "forged") |> through_browser("/")

      refute get_session(conn, "organizer_token")
    end

    test "leaves the session alone without a cookie, and writes nothing", %{conn: conn} do
      before = organizer_count()
      conn = through_browser(conn, "/")

      refute get_session(conn, "organizer_token")
      refute get_session(conn, :live_socket_id)
      refute conn.resp_cookies[@cookie]
      assert organizer_count() == before
    end

    # The row's 90 days slide with use (the resolver touches `last_seen_at`); the cookie's
    # must too, or an organizer active every week loses every session on day 91.
    test "re-issues the cookie with a fresh 90 days on every :browser request", %{conn: conn} do
      for path <- ["/", "/about", "/groups/new"] do
        conn = conn |> put_organizer_token("raw-token") |> through_browser(path)

        assert %{max_age: @ninety_days, http_only: true, same_site: "Lax"} =
                 conn.resp_cookies[@cookie]

        assert resp_token(conn) == "raw-token"
      end
    end

    test "the re-issued cookie verifies on the next request", %{conn: conn} do
      first = conn |> put_organizer_token("raw-token") |> through_browser("/")

      next =
        first
        |> recycle()
        |> through_browser("/")

      assert get_session(next, "organizer_token") == "raw-token"
    end

    test "gives an accountless browser its disconnect topic, derived from the token", %{
      conn: conn
    } do
      conn = conn |> put_organizer_token("raw-token") |> through_browser("/")

      assert get_session(conn, :live_socket_id) == OrganizerAuth.live_socket_id("raw-token")
    end

    # The session cookie has no `__Host-` prefix, so a sibling subdomain can plant one; a
    # session copy that outlived its cookie must not be an identity.
    test "drops a session copy of the token, and its topic, when the cookie is absent", %{
      conn: conn
    } do
      conn =
        conn
        |> init_test_session(%{
          "organizer_token" => "planted-token",
          "live_socket_id" => OrganizerAuth.live_socket_id("planted-token")
        })
        |> through_browser("/")

      refute get_session(conn, "organizer_token")
      refute get_session(conn, :live_socket_id)
      refute conn.resp_cookies[@cookie]
    end

    test "leaves a disconnect topic that is not an organizer's alone", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"live_socket_id" => "users_sessions:someone"})
        |> through_browser("/")

      assert get_session(conn, :live_socket_id) == "users_sessions:someone"
    end

    test "never overwrites a signed-in user's own disconnect topic", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> put_organizer_token("raw-token")
        |> through_browser("/")

      assert %Scope{user: %{}} = conn.assigns.current_scope
      refute get_session(conn, :live_socket_id) == OrganizerAuth.live_socket_id("raw-token")
    end
  end

  describe "read_organizer_cookie/1 and delete_organizer_cookie/1 (the claim's two halves)" do
    test "reads the verified token, and nil for a forged or absent cookie", %{conn: conn} do
      signed = conn |> put_organizer_token("raw-token") |> through_browser("/")
      assert OrganizerAuth.read_organizer_cookie(signed) == "raw-token"

      forged = conn |> put_req_cookie(@cookie, "forged") |> through_browser("/")
      assert OrganizerAuth.read_organizer_cookie(forged) == nil

      assert OrganizerAuth.read_organizer_cookie(through_browser(conn, "/")) == nil
    end

    test "never reads the session copy, which a sibling subdomain could plant", %{conn: conn} do
      planted =
        conn
        |> init_test_session(%{"organizer_token" => "planted"})
        |> Plug.Conn.fetch_session()

      assert OrganizerAuth.read_organizer_cookie(planted) == nil
    end

    test "expires the cookie with its own options and drops the session copy and topic", %{
      conn: conn
    } do
      conn =
        conn
        |> put_organizer_token("raw-token")
        |> through_browser("/")
        |> OrganizerAuth.delete_organizer_cookie()

      assert %{max_age: 0, http_only: true, same_site: "Lax"} = conn.resp_cookies[@cookie]
      refute get_session(conn, "organizer_token")
      refute get_session(conn, :live_socket_id)
    end

    test "leaves a signed-in user's own disconnect topic in place", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{"live_socket_id" => "users_sessions:someone"})
        |> through_browser("/")
        |> OrganizerAuth.delete_organizer_cookie()

      assert get_session(conn, :live_socket_id) == "users_sessions:someone"
    end
  end

  describe "live_socket_id/1" do
    test "is the organizer_sessions topic over the token's digest, never the raw token" do
      topic = OrganizerAuth.live_socket_id("raw-token")

      assert topic ==
               "organizer_sessions:" <>
                 Base.url_encode64(:crypto.hash(:sha256, "raw-token"), padding: false)

      refute topic =~ "raw-token"
      refute topic == OrganizerAuth.live_socket_id("other-token")
    end
  end

  describe "a returning organizer on /groups/:id/* (session cookie gone, organizer cookie kept)" do
    setup :create_anonymous_organizer

    # The common return trip — `/` → a group card → a wizard step — never passes
    # `GET /groups/new`, so the topic the claim broadcasts on has to arrive here too.
    test "the dead render puts the claim's disconnect topic in the session", %{
      conn: conn,
      organizer_token: raw_token,
      scope: scope
    } do
      group = group_fixture(scope)

      for path <- [
            ~p"/groups/#{group.id}/review",
            ~p"/groups/#{group.id}/options",
            ~p"/groups/#{group.id}/results"
          ] do
        conn = get(conn, path)

        refute redirected_to_log_in?(conn)
        assert get_session(conn, :live_socket_id) == OrganizerAuth.live_socket_id(raw_token)
        assert %{max_age: @ninety_days} = conn.resp_cookies[@cookie]
        assert resp_token(conn) == raw_token
      end
    end
  end

  describe "ensure_organizer_identity/2 — the first-ever visit to /groups/new" do
    test "mints one identity and writes the signed 90-day cookie", %{conn: conn} do
      before = organizer_count()

      conn = conn |> through_browser("/groups/new") |> OrganizerAuth.ensure_organizer_identity([])

      refute conn.halted
      assert organizer_count() == before + 1

      assert %{max_age: @ninety_days, http_only: true, same_site: "Lax"} =
               conn.resp_cookies[@cookie]

      raw_token = get_session(conn, "organizer_token")
      assert is_binary(raw_token) and byte_size(raw_token) == 32

      assert %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}} =
               conn.assigns.current_scope

      assert Consensus.Activities.get_anonymous_organizer_by_token(raw_token).id == id
      assert get_session(conn, :live_socket_id) == OrganizerAuth.live_socket_id(raw_token)
    end

    test "the minted cookie verifies on the next request", %{conn: conn} do
      minted =
        conn |> through_browser("/groups/new") |> OrganizerAuth.ensure_organizer_identity([])

      raw_token = get_session(minted, "organizer_token")

      next =
        minted
        |> recycle()
        |> through_browser("/groups/new")

      assert get_session(next, "organizer_token") == raw_token
    end
  end

  describe "ensure_organizer_identity/2 — a busy database" do
    # The mint is an insert on the single writer. Refused, `GET /groups/new` — the front
    # door of the product — must answer with somewhere to go, not a 500. Forced with
    # SQLite's own busy message from a TEMP trigger (DDL, hence `async: false` above).
    @tag :capture_log
    test "sends the visitor home with a 'busy' flash, minting and writing nothing", %{
      conn: conn
    } do
      before = organizer_count()

      Repo.query!("""
      CREATE TEMP TRIGGER d058_busy_mint BEFORE INSERT ON anonymous_organizers
      BEGIN SELECT RAISE(ABORT, 'database is locked'); END
      """)

      conn = get(conn, ~p"/groups/new")
      Repo.query!("DROP TRIGGER d058_busy_mint")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Consensus is busy"
      assert organizer_count() == before
      refute conn.resp_cookies[@cookie]
      refute get_session(conn, "organizer_token")

      # And the retry, with the database free again, mints and renders step 1.
      conn = get(recycle(conn), ~p"/groups/new")
      assert html_response(conn, 200)
      assert organizer_count() == before + 1
    end
  end

  describe "ensure_organizer_identity/2 — when there is already an identity" do
    test "a signed-in user mints nothing", %{conn: conn} do
      before = organizer_count()

      conn =
        conn
        |> log_in_user(user_fixture())
        |> through_browser("/groups/new")
        |> OrganizerAuth.ensure_organizer_identity([])

      assert organizer_count() == before
      refute conn.resp_cookies[@cookie]
      refute get_session(conn, "organizer_token")
      assert %Scope{user: %{}} = conn.assigns.current_scope
    end

    test "a token that still resolves mints nothing", %{conn: conn} do
      {raw_token, organizer} = anonymous_organizer_fixture()
      before = organizer_count()

      conn =
        conn
        |> put_organizer_token(raw_token)
        |> through_browser("/groups/new")
        |> OrganizerAuth.ensure_organizer_identity([])

      assert organizer_count() == before
      assert resp_token(conn) == raw_token
      assert get_session(conn, "organizer_token") == raw_token
      assert get_session(conn, :live_socket_id) == OrganizerAuth.live_socket_id(raw_token)
      assert conn.assigns.current_scope == nil
      assert Consensus.Activities.get_anonymous_organizer_by_token(raw_token).id == organizer.id
    end

    for {label, attrs} <- [
          {"idle past 90 days", quote(do: %{last_seen_at: days_ago(91)})},
          {"already claimed", quote(do: %{claimed_at: days_ago(1)})}
        ] do
      test "a token #{label} is replaced by a fresh identity", %{conn: conn} do
        {raw_token, dead} = anonymous_organizer_fixture(unquote(attrs))
        before = organizer_count()

        conn =
          conn
          |> put_organizer_token(raw_token)
          |> through_browser("/groups/new")
          |> OrganizerAuth.ensure_organizer_identity([])

        assert organizer_count() == before + 1
        assert %{max_age: @ninety_days} = conn.resp_cookies[@cookie]
        assert get_session(conn, "organizer_token") != raw_token

        assert %Scope{anonymous_organizer: %AnonymousOrganizer{id: id}} =
                 conn.assigns.current_scope

        assert id != dead.id
      end
    end
  end

  describe "a planted session with no organizer cookie" do
    # An attacker's validly signed session, set from a sibling subdomain into a browser
    # that has no organizer cookie of its own.
    setup %{conn: conn} do
      {raw_token, organizer} = anonymous_organizer_fixture()
      group = group_fixture(Scope.for_anonymous_organizer(organizer))

      %{
        planted: init_test_session(conn, %{"organizer_token" => raw_token}),
        raw_token: raw_token,
        organizer: organizer,
        group: group
      }
    end

    test "GET /groups/new mints the victim their own identity", %{
      planted: conn,
      raw_token: raw_token,
      organizer: organizer
    } do
      before = organizer_count()

      conn = get(conn, ~p"/groups/new")

      assert html_response(conn, 200)
      assert organizer_count() == before + 1

      minted = get_session(conn, "organizer_token")
      assert minted != raw_token
      assert resp_token(conn) == minted
      assert Consensus.Activities.get_anonymous_organizer_by_token(minted).id != organizer.id
    end

    test "a wizard step is bounced, not resolved to the planted identity", %{
      planted: conn,
      group: group
    } do
      conn = get(conn, ~p"/groups/#{group}/options")

      assert redirected_to(conn) ==
               ~p"/users/log-in?#{[return_to: "/groups/#{group.id}/options"]}"

      refute get_session(conn, "organizer_token")
    end
  end

  describe "a stranger on /groups/:id/*" do
    test "mints no identity and is sent to log-in, carrying return_to", %{conn: conn} do
      before = organizer_count()

      conn = get(conn, ~p"/groups/123/results")

      assert redirected_to(conn) == ~p"/users/log-in?#{[return_to: "/groups/123/results"]}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "log in to reach it"
      assert organizer_count() == before
      refute conn.resp_cookies[@cookie]
    end

    test "an expired token is not replaced off /groups/new", %{conn: conn} do
      {raw_token, _dead} = anonymous_organizer_fixture(%{last_seen_at: days_ago(91)})
      before = organizer_count()

      conn = conn |> put_organizer_token(raw_token) |> get(~p"/groups/123/options")

      assert redirected_to(conn) == ~p"/users/log-in?#{[return_to: "/groups/123/options"]}"
      assert organizer_count() == before
      # Slid as-is (`fetch_organizer_token/2` reads no database), never swapped for a fresh one.
      assert resp_token(conn) == raw_token
    end
  end

  describe "on_mount :require_organizer" do
    test "leaves a signed-in user's scope alone" do
      scope = user_scope_fixture()
      socket = socket(GroupLive.Review, :show, %{current_scope: scope})

      assert {:cont, socket} =
               OrganizerAuth.on_mount(:require_organizer, %{"id" => "1"}, %{}, socket)

      assert socket.assigns.current_scope == scope
    end

    test "replaces a nil scope with the anonymous one the session's token resolves to" do
      {raw_token, organizer} = anonymous_organizer_fixture()
      socket = socket(GroupLive.Review, :show, %{current_scope: nil})

      assert {:cont, socket} =
               OrganizerAuth.on_mount(
                 :require_organizer,
                 %{"id" => "1"},
                 %{"organizer_token" => raw_token},
                 socket
               )

      assert %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}} =
               socket.assigns.current_scope

      assert id == organizer.id
    end

    test "on /groups/new with no identity, halts home and asks for cookies" do
      socket = socket(GroupLive.New, :new, %{current_scope: nil})

      assert {:halt, socket} = OrganizerAuth.on_mount(:require_organizer, %{}, %{}, socket)

      assert socket.redirected == {:redirect, %{to: "/", status: 302}}
      assert socket.assigns.flash["error"] =~ "Allow cookies for this site"
    end

    # The connected mount replays the session signed at dead render. One that held an
    # identity which has since stopped resolving — a log-out or a claim in another tab —
    # is a stale tab, not blocked cookies: a full request lets the plugs sort it out.
    test "on /groups/new with an identity that went stale, reloads it without the cookies flash" do
      {claimed_token, _organizer} = anonymous_organizer_fixture(%{claimed_at: days_ago(1)})

      for session <- [
            %{"organizer_token" => claimed_token},
            %{"organizer_token" => "unknown"},
            %{"user_token" => "logged-out"}
          ] do
        socket = socket(GroupLive.New, :new, %{current_scope: nil})

        assert {:halt, socket} =
                 OrganizerAuth.on_mount(:require_organizer, %{}, session, socket)

        assert socket.redirected == {:redirect, %{to: "/groups/new", status: 302}}
        refute socket.assigns.flash["error"]
      end
    end

    test "on every other step with no identity, halts to log-in with that step as return_to" do
      for {view, action, params, path} <- [
            {GroupLive.New, :edit, %{"id" => "7"}, "/groups/7/edit"},
            {GroupLive.Options, :index, %{"id" => "7"}, "/groups/7/options"},
            {GroupLive.Options, :edit_activity, %{"id" => "7", "activity_id" => "9"},
             "/groups/7/options/9"},
            {GroupLive.Review, :show, %{"id" => "7"}, "/groups/7/review"},
            {GroupLive.Share, :show, %{"id" => "7"}, "/groups/7/share"},
            {GroupLive.Results, :show, %{"id" => "7"}, "/groups/7/results"}
          ] do
        socket = socket(view, action, %{current_scope: nil})

        assert {:halt, socket} =
                 OrganizerAuth.on_mount(
                   :require_organizer,
                   params,
                   %{"organizer_token" => "unknown"},
                   socket
                 )

        assert socket.redirected ==
                 {:redirect, %{to: ~p"/users/log-in?#{[return_to: path]}", status: 302}}

        assert socket.assigns.flash["error"] =~ "If this session is yours"
        assert ConsensusWeb.CurrentPath.safe_return_to(path) == path
      end
    end
  end

  # Plan §6.3: after a claim, a tab still mounted with the anonymous scope must stop being
  # able to write. The hook subscribes the LiveView process itself, so this holds even for
  # a socket whose session cookie never carried the organizer `live_socket_id`.
  describe "a mounted anonymous tab when the claim broadcasts" do
    setup :create_anonymous_organizer

    test "every wizard step redirects to its own route", %{
      conn: conn,
      organizer_token: raw_token,
      scope: scope
    } do
      draft = group_fixture(scope)
      # `04 share` and `05 results` bounce a draft (D-045), so they get a published one.
      {published, _activities} = Consensus.VotingFixtures.voting_group_fixture(scope)

      for path <- [
            ~p"/groups/new",
            ~p"/groups/#{draft.id}/edit",
            ~p"/groups/#{draft.id}/options",
            ~p"/groups/#{draft.id}/review",
            ~p"/groups/#{published.id}/share",
            ~p"/groups/#{published.id}/results"
          ] do
        {:ok, lv, _html} = live(conn, path)

        ConsensusWeb.Endpoint.broadcast(
          OrganizerAuth.live_socket_id(raw_token),
          "disconnect",
          %{}
        )

        assert_redirect(lv, path)
      end
    end

    test "ignores another organizer's claim", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/review")

      ConsensusWeb.Endpoint.broadcast(
        OrganizerAuth.live_socket_id("someone-else"),
        "disconnect",
        %{}
      )

      assert render(lv) =~ group.title
    end

    test "a signed-in organizer's tab does not subscribe, organizer cookie or not", %{
      conn: conn,
      organizer_token: raw_token
    } do
      user = user_fixture()
      group = group_fixture(Scope.for_user(user))
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/review")

      ConsensusWeb.Endpoint.broadcast(OrganizerAuth.live_socket_id(raw_token), "disconnect", %{})
      assert render(lv) =~ group.title
    end
  end

  describe "on_mount :mount_organizer_scope" do
    test "assigns the anonymous scope for a live token, without touching @current_scope" do
      {raw_token, organizer} = anonymous_organizer_fixture()
      socket = socket(ConsensusWeb.HomeLive, :show, %{current_scope: nil})

      assert {:cont, socket} =
               OrganizerAuth.on_mount(
                 :mount_organizer_scope,
                 %{},
                 %{"organizer_token" => raw_token},
                 socket
               )

      assert socket.assigns.organizer_scope.anonymous_organizer.id == organizer.id
      assert socket.assigns.current_scope == nil
    end

    test "is nil for a signed-in user, and for a browser with no identity — and never mints" do
      {raw_token, _organizer} = anonymous_organizer_fixture()
      before = organizer_count()

      for {current_scope, session} <- [
            {user_scope_fixture(), %{"organizer_token" => raw_token}},
            {nil, %{}},
            {nil, %{"organizer_token" => "unknown"}}
          ] do
        socket = socket(ConsensusWeb.HomeLive, :show, %{current_scope: current_scope})

        assert {:cont, socket} =
                 OrganizerAuth.on_mount(:mount_organizer_scope, %{}, session, socket)

        assert socket.assigns.organizer_scope == nil
      end

      assert organizer_count() == before
    end
  end

  describe "ConnCase.create_anonymous_organizer/1" do
    setup :create_anonymous_organizer

    test "puts a token on the conn that the :browser pipeline resolves", %{
      conn: conn,
      organizer_token: raw_token,
      anonymous_organizer: organizer,
      scope: scope
    } do
      conn = through_browser(conn, "/")

      assert get_session(conn, "organizer_token") == raw_token
      assert scope.anonymous_organizer.id == organizer.id
    end
  end
end
