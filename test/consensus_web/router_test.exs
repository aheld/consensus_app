defmodule ConsensusWeb.RouterTest do
  @moduledoc """
  Shape assertions on the router itself.

  Every other admin test drives a request or a `live/2` mount, and both of those run the
  plug pipeline *and* the `on_mount` hook — so they only ever prove that *at least one*
  of the two guards fired. Either layer could be deleted and none of them would go red.
  `ConsensusWeb.UserAuthTest` covers each guard in isolation; these tests cover the third
  thing that can break, which is the router forgetting to wire one of them up.
  """

  use ExUnit.Case, async: true

  @admin_prefix "/admin"
  @router_source "lib/consensus_web/router.ex"

  defp admin_routes do
    Enum.filter(ConsensusWeb.Router.__routes__(), fn route ->
      route.path == @admin_prefix or String.starts_with?(route.path, @admin_prefix <> "/")
    end)
  end

  defp on_mount_ids(route) do
    case route.metadata[:phoenix_live_view] do
      {_view, _action, _opts, %{extra: %{on_mount: on_mounts}}} -> Enum.map(on_mounts, & &1.id)
      _ -> []
    end
  end

  test "the admin routes that are supposed to exist do" do
    paths = admin_routes() |> Enum.map(& &1.path) |> Enum.uniq()

    assert "/admin" in paths
    assert "/admin/users" in paths
    assert "/admin/home-page" in paths
    assert Enum.any?(paths, &String.starts_with?(&1, "/admin/dashboard"))
  end

  test "every admin LiveView mounts the :require_admin hook" do
    # A plug pipeline does not run for the LiveView websocket, so this hook — not the
    # plug — is what guards the socket once it is live.
    for route <- admin_routes(), route.metadata[:phoenix_live_view] do
      assert {ConsensusWeb.UserAuth, :require_admin} in on_mount_ids(route),
             """
             #{route.path} does not mount {ConsensusWeb.UserAuth, :require_admin}.
             on_mount was: #{inspect(on_mount_ids(route))}
             """
    end
  end

  test "no admin LiveView is left on a non-admin live_session" do
    for route <- admin_routes(), route.metadata[:phoenix_live_view] do
      refute {ConsensusWeb.UserAuth, :mount_current_scope} in on_mount_ids(route),
             "#{route.path} is on the public live_session"
    end
  end

  # `Phoenix.Router.__routes__/0` does not expose `pipe_through`, so the plug half of the
  # defence is asserted against the router source. Crude, but it is the only thing that
  # notices if someone removes `:require_admin_user` from a scope — and that removal
  # would leave every behavioural test still green, because the on_mount hook would
  # cover for it.
  test "every scope under /admin pipes through the admin plugs" do
    source = File.read!(@router_source)

    admin_scopes =
      Regex.scan(~r/scope\s+"\/admin".*?\n(.*?)\n\n/s, source, capture: :all_but_first)

    assert length(admin_scopes) >= 2,
           "expected at least the LiveView scope and the LiveDashboard scope under /admin"

    for [scope_head] <- admin_scopes do
      assert scope_head =~ ":require_authenticated_user",
             "an /admin scope does not pipe through :require_authenticated_user:\n#{scope_head}"

      assert scope_head =~ ":require_admin_user",
             "an /admin scope does not pipe through :require_admin_user:\n#{scope_head}"
    end
  end
end
