defmodule ConsensusWeb.OrganizingNeedsNoAccountTest do
  @moduledoc """
  Source pin for D-058: organizing a session requires no account.

  The decision is one sentence and the code that carries it is one block of
  `router.ex`: the seven wizard routes (`01 → 02 → 02b → 03 → 04 → 05`) live in a
  scope that does **not** pipe through `:require_authenticated_user`. Nothing at
  runtime notices if that reverts. Move one of them back under the authenticated
  scope "for an unrelated reason" — tidying the router, adding a sibling route —
  and every test written by a signed-in fixture stays green, because a signed-in
  fixture passes the plug either way. The PRD's organizer-access requirement would
  be gone again with the suite reporting nothing. So we pin the *source*, in the
  idiom of `test/consensus/activity_type_invariant_test.exs` (D-052 Stage 0a) and
  `deploy_config_test.exs`: read the file, assert the shape, fail with
  instructions.

  Unlike those two this is not a regex over lines. `router.ex` is parsed with
  `Code.string_to_quoted/2` and the AST is walked the way `Phoenix.Router` itself
  evaluates it: `scope` blocks nest and inherit their parent's path and pipes,
  `pipe_through` accumulates onto the scope it sits in for every route defined
  after it, `live_session` and `if` blocks are transparent, and a `pipe_through`
  name that is itself a `pipeline` is expanded into the plugs it declares (so a
  new `pipeline :organizer do plug :require_authenticated_user end` cannot hide the
  plug one level down). Reformatting, reflowing a `pipe_through` list or nesting a
  `scope` inside a `live_session` — which the plan does for `/groups/new` — cannot
  fool it.

  Three checks, so the pin cannot pass vacuously:

    1. every one of the seven paths is *found* by the walk — deleting or renaming a
       route fails here rather than silently dropping out of check 3;
    2. every one of the seven is a real route in `ConsensusWeb.Router.__routes__/0`,
       which also proves the walk's path arithmetic agrees with Phoenix's;
    3. none of them sits under an effective pipe list carrying
       `:require_authenticated_user`, and none mounts
       `{ConsensusWeb.UserAuth, :require_authenticated}` — the socket-side twin,
       read from `__routes__/0` because `on_mount` *is* exposed there (only
       `pipe_through` is not; see `router_test.exs`).

  Landed red, before the routes moved (plan Stage 2): it fails until Stage 4
  builds `live_session :organizer`.
  """

  use ExUnit.Case, async: true

  @router_source "lib/consensus_web/router.ex"

  # The organizer's creation flow, design frames 01 through 05. D-058 decision 1.
  @wizard_paths [
    "/groups/new",
    "/groups/:id/edit",
    "/groups/:id/options",
    "/groups/:id/options/:activity_id",
    "/groups/:id/review",
    "/groups/:id/share",
    "/groups/:id/results"
  ]

  @forbidden_plug :require_authenticated_user
  @forbidden_on_mount {ConsensusWeb.UserAuth, :require_authenticated}

  # The router macros that define a route at a path. `pipe_through` is captured at
  # definition time, which is why the walk is sequential.
  @route_macros [:live, :get, :post, :put, :patch, :delete, :options, :head, :forward]

  setup_all do
    %{report: wizard_route_report(File.read!(@router_source))}
  end

  test "the walk finds every wizard route in router.ex", %{report: report} do
    missing = @wizard_paths -- Enum.map(report.routes, & &1.path)

    assert missing == [], """
    These wizard routes were not found in #{@router_source}:

    #{Enum.map_join(missing, "\n", &"    #{&1}")}

    If a route was renamed, update @wizard_paths in this file in the same commit —
    and confirm the new path is still reachable without an account (D-058). If it
    was deleted, the wizard has lost a step; that is a decision for docs/plans, not
    something to make this test stop checking.
    """
  end

  test "every wizard route exists in the compiled router" do
    compiled = ConsensusWeb.Router.__routes__() |> Enum.map(& &1.path) |> Enum.uniq()
    missing = @wizard_paths -- compiled

    assert missing == [], """
    These wizard routes are not in ConsensusWeb.Router.__routes__/0:

    #{Enum.map_join(missing, "\n", &"    #{&1}")}

    Either the route is gone, or the source walk in this file computes paths
    differently from Phoenix and the sibling test is checking the wrong thing.
    """
  end

  test "no wizard route pipes through :require_authenticated_user", %{report: report} do
    offenders = report.offenders

    assert offenders == [], """
    D-058: organizing requires no account. These wizard routes sit in a scope whose
    effective pipe_through carries :#{@forbidden_plug}:

    #{Enum.map_join(offenders, "\n", &format_offender/1)}

    A visitor with no account must be able to name a session, add options, publish
    and watch the results. The wizard belongs in `live_session :organizer` under a
    plain [:browser] scope (docs/plans/accountless-organizer.md §4.1) — not in the
    authenticated block beside /users/settings. Move the route; do not edit this
    test.
    """
  end

  test "no wizard LiveView mounts the :require_authenticated hook" do
    offenders =
      for route <- ConsensusWeb.Router.__routes__(),
          route.path in @wizard_paths,
          @forbidden_on_mount in on_mount_ids(route) do
        "    #{route.path}  (on_mount: #{inspect(on_mount_ids(route))})"
      end

    assert offenders == [], """
    D-058: these wizard routes mount #{inspect(@forbidden_on_mount)}, which bounces a
    visitor with no account to the log-in page on the websocket mount even when the
    plug pipeline lets them through:

    #{Enum.join(offenders, "\n")}

    The wizard's live_session should mount {ConsensusWeb.UserAuth, :mount_current_scope}
    and the organizer-identity hook instead (plan §4.1).
    """
  end

  # The walk is checked against small routers written here, so the moduledoc's claims —
  # pipeline indirection, nesting under a live_session — are tested now, while the pin
  # against the real router is still red, rather than first exercised at Stage 4.
  describe "wizard_route_report/1 against fixture routers" do
    test "a plain :browser scope with a live_session reports no offenders" do
      report = wizard_route_report(fixture_router("pipe_through [:browser]"))

      assert @wizard_paths -- Enum.map(report.routes, & &1.path) == []
      assert report.offenders == []
    end

    test "the plug hidden one level down in a custom pipeline is still found" do
      report =
        "pipe_through [:browser, :organizer]"
        |> fixture_router()
        |> wizard_route_report()

      assert offender_paths(report) == Enum.sort(@wizard_paths)
      assert Enum.all?(report.offenders, &(&1.carriers == [:organizer]))
    end

    test "a reflowed pipe_through list is read the same as a one-line one" do
      report =
        """
        pipe_through [
              :browser,
              :require_authenticated_user
            ]
        """
        |> fixture_router()
        |> wizard_route_report()

      assert offender_paths(report) == Enum.sort(@wizard_paths)
      assert Enum.all?(report.offenders, &(&1.carriers == [:require_authenticated_user]))
    end

    test "a scope nested inside a live_session inherits the outer scope's pipes" do
      source = """
      defmodule Fixture.Router do
        use ConsensusWeb, :router

        scope "/", ConsensusWeb do
          pipe_through [:browser, :require_authenticated_user]

          live_session :organizer, on_mount: [{ConsensusWeb.UserAuth, :mount_current_scope}] do
            scope "/groups" do
              live "/new", GroupLive.New, :new
            end
          end
        end

        scope "/", ConsensusWeb do
          pipe_through [:browser]

          live_session :organizer_rest do
            scope "/groups/:id" do
              live "/review", GroupLive.Review, :show
            end
          end
        end
      end
      """

      report = wizard_route_report(source)

      assert "/groups/:id/review" in Enum.map(report.routes, & &1.path)
      assert offender_paths(report) == ["/groups/new"]
    end
  end

  # The seven wizard routes in one live_session under a scope whose `pipe_through` line
  # is the argument, beside an `:organizer` pipeline that carries the forbidden plug.
  defp fixture_router(pipe_through) do
    """
    defmodule Fixture.Router do
      use ConsensusWeb, :router

      pipeline :browser do
        plug :accepts, ["html"]
      end

      pipeline :organizer do
        plug :fetch_session
        plug :require_authenticated_user
      end

      scope "/", ConsensusWeb do
        #{pipe_through}

        live_session :organizer, on_mount: [{ConsensusWeb.UserAuth, :mount_current_scope}] do
          live "/groups/new", GroupLive.New, :new
          live "/groups/:id/edit", GroupLive.New, :edit
          live "/groups/:id/options", GroupLive.Options, :index
          live "/groups/:id/options/:activity_id", GroupLive.Options, :edit_activity
          live "/groups/:id/review", GroupLive.Review, :show
          live "/groups/:id/share", GroupLive.Share, :show
          live "/groups/:id/results", GroupLive.Results, :show
        end
      end
    end
    """
  end

  defp offender_paths(report), do: report.offenders |> Enum.map(& &1.path) |> Enum.sort()

  @doc false
  # Public, and takes the source rather than reading the file, so the pin itself can
  # be checked against an edited router without touching the real one — e.g. that it
  # reports zero offenders once the seven routes are moved under a plain :browser
  # scope. Returns every route the walk found, plus the wizard routes that offend.
  def wizard_route_report(source) when is_binary(source) do
    {:ok, ast} = Code.string_to_quoted(source, file: @router_source, columns: true)

    pipelines = collect_pipelines(ast)
    {_frame, routes} = walk(ast, %{path: "", pipes: []}, [])
    routes = Enum.reverse(routes)

    offenders =
      for route <- routes,
          route.path in @wizard_paths,
          carriers = carriers(route.pipes, pipelines),
          carriers != [] do
        Map.put(route, :carriers, carriers)
      end

    %{routes: routes, offenders: offenders}
  end

  ## The walk

  # `scope` opens a frame that inherits the parent's path and pipes; whatever its
  # body does to the frame is discarded when the block ends, exactly as in Phoenix.
  defp walk({:scope, _meta, args}, frame, acc) when is_list(args) do
    {path, block} = scope_parts(args)
    inner = %{frame | path: join_path(frame.path, path)}
    {_inner, acc} = walk(block, inner, acc)
    {frame, acc}
  end

  defp walk({:pipe_through, _meta, [pipes]}, frame, acc) do
    {%{frame | pipes: frame.pipes ++ List.wrap(pipes)}, acc}
  end

  # Pipelines are collected separately; a `plug` inside one is not a route.
  defp walk({:pipeline, _meta, _args}, frame, acc), do: {frame, acc}

  defp walk({macro, meta, [path | _]}, frame, acc)
       when macro in @route_macros and is_binary(path) do
    route = %{
      path: join_path(frame.path, path),
      macro: macro,
      line: meta[:line],
      pipes: frame.pipes
    }

    {frame, [route | acc]}
  end

  defp walk({:__block__, _meta, exprs}, frame, acc), do: walk_sequence(exprs, frame, acc)

  # Anything else carrying a `do` block — `defmodule`, `live_session`, `if` — is
  # transparent: its body runs in the enclosing scope, so `pipe_through` inside it
  # sticks to that scope (that is how Phoenix behaves, too).
  defp walk({_call, _meta, args}, frame, acc) when is_list(args) do
    case List.last(args) do
      [{:do, _} | _] = blocks ->
        Enum.reduce(blocks, {frame, acc}, fn {_key, block}, {frame, acc} ->
          walk(block, frame, acc)
        end)

      _ ->
        {frame, acc}
    end
  end

  defp walk(_other, frame, acc), do: {frame, acc}

  defp walk_sequence(exprs, frame, acc) do
    Enum.reduce(exprs, {frame, acc}, fn expr, {frame, acc} -> walk(expr, frame, acc) end)
  end

  # `scope "/p", Alias, opts do`, `scope "/p" do`, `scope Alias do` — the path is the
  # first argument only when it is a string; the block is always the last.
  defp scope_parts(args) do
    path = with [path | _] when is_binary(path) <- args, do: path, else: (_ -> "")
    [{:do, block} | _] = List.last(args)
    {path, block}
  end

  defp join_path(prefix, path) do
    joined =
      (prefix <> "/" <> path)
      |> String.replace(~r{/+}, "/")
      |> String.trim_trailing("/")

    if joined == "", do: "/", else: joined
  end

  ## Pipelines

  defp collect_pipelines(ast) do
    {_ast, pipelines} =
      Macro.prewalk(ast, %{}, fn
        {:pipeline, _meta, [name, [do: block]]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, plugs_in(block))}

        node, acc ->
          {node, acc}
      end)

    pipelines
  end

  defp plugs_in(block) do
    {_ast, plugs} =
      Macro.prewalk(block, [], fn
        {:plug, _meta, [plug | _]} = node, acc -> {node, [plug | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(plugs)
  end

  # The pipe_through entries whose expansion reaches the forbidden plug: the entry
  # itself when it *is* the plug, or a pipeline that declares it at any depth.
  defp carriers(pipes, pipelines) do
    Enum.filter(pipes, &(@forbidden_plug in expand(&1, pipelines, MapSet.new())))
  end

  defp expand(pipe, pipelines, seen) do
    cond do
      MapSet.member?(seen, pipe) ->
        []

      Map.has_key?(pipelines, pipe) ->
        seen = MapSet.put(seen, pipe)
        [pipe | Enum.flat_map(pipelines[pipe], &expand(&1, pipelines, seen))]

      true ->
        [pipe]
    end
  end

  ## Reporting

  defp format_offender(route) do
    "    #{route.path}  (#{@router_source}:#{route.line}, `#{route.macro}`)\n" <>
      "        pipe_through #{inspect(route.pipes)} — carried by " <>
      Enum.map_join(route.carriers, ", ", &inspect/1)
  end

  defp on_mount_ids(route) do
    case route.metadata[:phoenix_live_view] do
      {_view, _action, _opts, %{extra: %{on_mount: on_mounts}}} -> Enum.map(on_mounts, & &1.id)
      _ -> []
    end
  end
end
