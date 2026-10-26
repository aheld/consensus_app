defmodule ConsensusWeb.Router do
  use ConsensusWeb, :router

  import ConsensusWeb.UserAuth

  import ConsensusWeb.OrganizerAuth,
    only: [fetch_organizer_token: 2, ensure_organizer_identity: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConsensusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    # Read-only: copies the accountless organizer's signed cookie into the session so a
    # LiveView can see it (D-058). No database access; it never mints.
    plug :fetch_organizer_token
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check for Fly (see [[http_service.checks]] in fly.toml). Deliberately not in
  # the :browser pipeline — it needs no session, no CSRF token and no layout, and it must
  # stay excluded from force_ssl in config/prod.exs.
  scope "/", ConsensusWeb do
    get "/health", HealthController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", ConsensusWeb do
  #   pipe_through :api
  # end

  ## Admin routes
  #
  # Guarded twice on purpose: the pipeline plugs reject the initial HTTP request, and
  # the `:require_admin` on_mount hook rejects the LiveView websocket mount (a plug
  # pipeline does not run for the socket connection).

  scope "/admin", ConsensusWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    live_session :require_admin,
      on_mount: [{ConsensusWeb.UserAuth, :require_admin}] do
      live "/", AdminLive.Users, :index
      live "/users", AdminLive.Users, :index

      # The triage queue for what `ConsensusWeb.Chrome.footer/1`'s two faces collect
      # (D-043). Inside the admin scope above and the existing
      # `live_session :require_admin` — a live_session name is declared once — so it
      # inherits both guards without restating either.
      #
      # (Do not write the scope's own path literal in this comment: `router_test.exs`
      # finds the admin scopes by scanning this file for it, and a mention in a comment
      # is indistinguishable from a scope that pipes through nothing.)
      live "/feedback", AdminLive.Feedback, :index

      # The shared catalog and every option's details (D-060). Same scope and
      # live_session, so the same two guards.
      live "/items", AdminLive.Items, :index
    end
  end

  # LiveDashboard is mounted in every environment but only for admins, which is what
  # the generated comment recommends doing instead of leaving it on :dev_routes.
  # `live_dashboard/2` declares its own live_session, so it cannot be nested in the
  # one above — it takes the same on_mount hook directly.
  #
  # It is also the one route in this app that does **not** wear the global chrome
  # (D-041): it declares its own layout as well as its own live_session, so
  # `Layouts.app/1` never runs for it and there is no way to wrap it short of forking a
  # third-party LiveView. That is accepted rather than worked around. LiveDashboard has
  # no "back to your app" affordance to configure — `home_app:` only labels the app on
  # its own home page, verified in a browser — and nothing in `lib/` links here anyway:
  # the route is reachable only by typing the URL, and the way out is the browser's own
  # back button. Read "every screen" in D-041 as "every screen this app renders".
  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    import Phoenix.LiveDashboard.Router

    live_dashboard "/dashboard",
      metrics: ConsensusWeb.Telemetry,
      on_mount: [{ConsensusWeb.UserAuth, :require_admin}]
  end

  # Swoosh's mailbox preview shows the magic-link emails the app "sends" in development.
  if Application.compile_env(:consensus, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ConsensusWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ConsensusWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## The organizer's creation flow (D-058: no account required)
  #
  # Every one of these is a step in the wizard the design calls 01 → 02 → 02b → 03 → 04,
  # plus `05`, the organizer's live results. They share a live_session so that moving
  # between them is a `push_navigate` inside one connected socket rather than a full page
  # load, which is what makes the wizard feel like one screen.
  #
  # Since D-058 organizing costs no account, so this is a plain `:browser` scope and
  # **must never pipe through `:require_authenticated_user`** —
  # `test/consensus_web/organizing_needs_no_account_test.exs` reads this file and fails
  # if any of the seven routes moves back under it. The owner is a signed-in user *or*
  # an accountless organizer: `:mount_current_scope` runs first, then
  # `ConsensusWeb.OrganizerAuth`'s `:require_organizer` swaps in the anonymous scope when
  # no user is signed in, and bounces a visitor who is neither (to `/` on `/groups/new`,
  # to log-in with `return_to` on every other step). `@current_scope` is anonymous only
  # inside this live_session; everywhere else it stays user-or-nil.
  #
  # Only `GET /groups/new` mints an identity — the nested scope's
  # `:ensure_organizer_identity` writes the long-lived cookie before the LiveView mounts,
  # because a LiveView cannot. The other six only resolve one, so a crawler probing
  # `/groups/:id/*` never inserts a row. (A `scope` nested inside a `live_session`
  # contributes its `pipe_through` to the routes it holds and nothing else.)
  scope "/", ConsensusWeb do
    pipe_through [:browser]

    live_session :organizer,
      on_mount: [
        {ConsensusWeb.UserAuth, :mount_current_scope},
        {ConsensusWeb.OrganizerAuth, :require_organizer}
      ] do
      scope "/" do
        pipe_through [:ensure_organizer_identity]

        live "/groups/new", GroupLive.New, :new
      end

      live "/groups/:id/edit", GroupLive.New, :edit
      live "/groups/:id/options", GroupLive.Options, :index
      live "/groups/:id/options/:activity_id", GroupLive.Options, :edit_activity
      live "/groups/:id/review", GroupLive.Review, :show
      live "/groups/:id/share", GroupLive.Share, :show

      # Design frame `05` — the organizer's live-results screen. The participant-side
      # twin is `JoinLive.Results` below, under `/join/:slug/results`, which a guest
      # reaches instead.
      live "/groups/:id/results", GroupLive.Results, :show
    end
  end

  ## The recipient's public join flow
  #
  # No account, ever (CLAUDE.md product invariant 1 — voter friction is zero), so this
  # is a plain `:browser` scope, not `:require_authenticated_user`. `live_session
  # :participant` chains two `on_mount` hooks: `ConsensusWeb.UserAuth`'s existing
  # `:mount_current_scope` first, so a *signed-in* visitor still gets `@current_scope`
  # (frame `06`'s "join as yourself" affordance) without a second `:current_user`
  # live_session (not allowed — see above); then `ConsensusWeb.JoinAuth`'s
  # `:resolve_participant`, which resolves the session's participant token into
  # `@participant`, assigns `@group`, and applies the `/join`-tree status guards from
  # docs/plans/voting-loop.md (`:draft` bounces home with a flash, `:completed`/
  # `:cancelled` bounces to results).
  #
  # `POST /join/:slug/enter` is a plain controller route, not a LiveView — a LiveView
  # cannot write a session cookie, which is the whole reason `JoinController` exists.
  # It sits in the same scope, outside the `live_session` block, since it is not itself
  # a LiveView route.
  scope "/", ConsensusWeb do
    pipe_through :browser

    live_session :participant,
      on_mount: [
        {ConsensusWeb.UserAuth, :mount_current_scope},
        {ConsensusWeb.JoinAuth, :resolve_participant}
      ] do
      live "/join/:slug", JoinLive.Entry, :show
      live "/join/:slug/vote", JoinLive.Ballot, :show
      live "/join/:slug/results", JoinLive.Results, :show
    end

    post "/join/:slug/enter", JoinController, :enter
  end

  scope "/", ConsensusWeb do
    pipe_through [:browser]

    # `:mount_organizer_scope` is for `/`, which lists an accountless organizer's
    # sessions (D-058). It is read-only — it never mints and never touches
    # `@current_scope`, which stays user-or-nil on every page here — and only `HomeLive`
    # reads the `@organizer_scope` it assigns. It sits in the shared list because a route
    # cannot carry its own `on_mount`, and a `live_session` name is declared once.
    live_session :current_user,
      on_mount: [
        {ConsensusWeb.UserAuth, :mount_current_scope},
        {ConsensusWeb.OrganizerAuth, :mount_organizer_scope}
      ] do
      # `/` is two screens behind one route: the 00a splash for a signed-out visitor and
      # the 00 home list for a signed-in organizer. One route because the design treats
      # them as the same place, and because a bookmark must not 404 after logging out.
      live "/", HomeLive, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new

      # The standing pages the global footer links to (D-041). They live here, in
      # `:current_user`, because every one of them must render for a signed-out
      # visitor *and* pick up `@current_scope` when there is one — the footer is on
      # every screen in the app, so these are reachable from the splash, from the
      # wizard, and from a guest's ballot alike. A footer link that 404s is the exact
      # dead end this work exists to remove.
      live "/how-it-works", HowItWorksLive, :show
      live "/about", AboutLive, :show
      live "/privacy", PrivacyLive, :show

      # Where the footer's two faces land, carrying `?mood=happy` / `?mood=sad`.
      live "/feedback", FeedbackLive, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
