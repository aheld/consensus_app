defmodule ConsensusWeb.Router do
  use ConsensusWeb, :router

  import ConsensusWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConsensusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
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
    end
  end

  # LiveDashboard is mounted in every environment but only for admins, which is what
  # the generated comment recommends doing instead of leaving it on :dev_routes.
  # `live_dashboard/2` declares its own live_session, so it cannot be nested in the
  # one above — it takes the same on_mount hook directly.
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

      # The organizer's creation flow. Every one of these is a step in the wizard the
      # design calls 01 → 02 → 02b → 03 → 04; they share a live_session so that moving
      # between them is a `push_navigate` inside one connected socket rather than a full
      # page load, which is what makes the wizard feel like one screen.
      live "/groups/new", GroupLive.New, :new
      live "/groups/:id/edit", GroupLive.New, :edit
      live "/groups/:id/options", GroupLive.Options, :index
      live "/groups/:id/options/:activity_id", GroupLive.Options, :edit_activity
      live "/groups/:id/review", GroupLive.Review, :show
      live "/groups/:id/share", GroupLive.Share, :show

      # Design frame `05` — the organizer's live-results screen. In the existing
      # `:require_authenticated_user` live_session (not a new one — AGENTS.md: a
      # live_session name is declared once) because only the organizer, signed in,
      # reaches it; the participant-side twin of this screen is `JoinLive.Results`
      # below, under `/join/:slug/results`, which a guest with no account reaches
      # instead.
      live "/groups/:id/results", GroupLive.Results, :show
    end

    post "/users/update-password", UserSessionController, :update_password
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

    live_session :current_user,
      on_mount: [{ConsensusWeb.UserAuth, :mount_current_scope}] do
      # `/` is two screens behind one route: the 00a splash for a signed-out visitor and
      # the 00 home list for a signed-in organizer. One route because the design treats
      # them as the same place, and because a bookmark must not 404 after logging out.
      live "/", HomeLive, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
