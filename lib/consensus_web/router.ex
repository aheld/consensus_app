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
      live "/home-page", AdminLive.HomePage, :edit
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
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ConsensusWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ConsensusWeb.UserAuth, :mount_current_scope}] do
      live "/", HomeLive, :show
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
