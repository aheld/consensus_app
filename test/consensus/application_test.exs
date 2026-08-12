defmodule Consensus.ApplicationTest do
  @moduledoc """
  Structural tests for the boot path.

  This app has no `[deploy] release_command` (docs/decisions.md D-009): the supervision
  tree is the *only* thing that migrates a release, and the `Consensus.Seeds` child is
  the only thing that gives a fresh deploy an administrator (D-010). None of that is
  reachable from a request, so nothing else in the suite notices when it breaks — a
  RELEASE_NAME boot against a fresh volume answers `no such table: users` with 240 tests
  still green. Assert the shape directly, the way
  `test/consensus_web/router_test.exs` asserts the router.

  Not `async` and not `DataCase`: these tests mutate `RELEASE_NAME` and application
  environment, and they never touch the repo.
  """
  use ExUnit.Case, async: false

  alias Consensus.Application, as: App

  setup do
    original_release_name = System.get_env("RELEASE_NAME")
    original_seed_on_boot = Application.fetch_env!(:consensus, :seed_on_boot)
    original_repo_config = Application.fetch_env!(:consensus, Consensus.Repo)

    on_exit(fn ->
      case original_release_name do
        nil -> System.delete_env("RELEASE_NAME")
        name -> System.put_env("RELEASE_NAME", name)
      end

      Application.put_env(:consensus, :seed_on_boot, original_seed_on_boot)
      Application.put_env(:consensus, Consensus.Repo, original_repo_config)
    end)

    :ok
  end

  describe "children/0" do
    test "migrates and seeds, in that order, before the endpoint accepts traffic" do
      children = App.children()

      repo = index_of(children, &(&1 == Consensus.Repo))
      migrator = index_of(children, &match?({Ecto.Migrator, _}, &1))
      seeds = index_of(children, &match?({Consensus.Seeds, _}, &1))
      endpoint = index_of(children, &(&1 == ConsensusWeb.Endpoint))

      assert migrator,
             "Ecto.Migrator is not in the supervision tree — nothing will migrate a release"

      assert seeds,
             "Consensus.Seeds is not in the supervision tree — a fresh deploy gets no admin"

      assert repo < migrator, "Ecto.Migrator must start after Consensus.Repo"

      assert seeds == migrator + 1,
             "Consensus.Seeds must be the child directly after Ecto.Migrator, so the " <>
               "schema is current before it runs"

      assert migrator < endpoint,
             "Ecto.Migrator must start before ConsensusWeb.Endpoint accepts traffic"

      assert seeds < endpoint,
             "Consensus.Seeds must start before ConsensusWeb.Endpoint accepts traffic"
    end

    test "starts the link preview cache after the repo and before the endpoint" do
      children = App.children()

      repo = index_of(children, &(&1 == Consensus.Repo))
      cache = index_of(children, &(&1 == Consensus.LinkPreview.Cache))
      endpoint = index_of(children, &(&1 == ConsensusWeb.Endpoint))

      assert cache,
             "Consensus.LinkPreview.Cache is not in the supervision tree — " <>
               "Consensus.LinkPreview.fetch/1 would have nowhere to cache into"

      assert repo < cache, "Consensus.LinkPreview.Cache must start after Consensus.Repo"

      assert cache < endpoint,
             "Consensus.LinkPreview.Cache must start before ConsensusWeb.Endpoint accepts traffic"
    end

    # Deliberate extension for the Discovery core (docs/research/activity-discovery.md
    # §4.5): a second instance of the parameterised Consensus.LinkPreview.Cache, wrapped
    # by Consensus.Discovery.Cache, whose start also validates the provider registry.
    # The Migrator/Seeds adjacency and endpoint-last assertions above are untouched —
    # the new child sits in the same after-repo/before-endpoint range as its sibling.
    test "starts the discovery cache after the repo and before the endpoint" do
      children = App.children()

      repo = index_of(children, &(&1 == Consensus.Repo))
      cache = index_of(children, &(&1 == Consensus.Discovery.Cache))
      endpoint = index_of(children, &(&1 == ConsensusWeb.Endpoint))

      assert cache,
             "Consensus.Discovery.Cache is not in the supervision tree — " <>
               "Consensus.Discovery.search/3 and the geocoder would have nowhere to " <>
               "cache into, and nothing would validate the provider registry at boot"

      assert repo < cache, "Consensus.Discovery.Cache must start after Consensus.Repo"

      assert cache < endpoint,
             "Consensus.Discovery.Cache must start before ConsensusWeb.Endpoint accepts traffic"
    end

    test "passes the configured repos and the current skip decisions through" do
      System.delete_env("RELEASE_NAME")
      Application.put_env(:consensus, :seed_on_boot, false)

      children = App.children()

      assert {Ecto.Migrator, migrator_opts} = Enum.find(children, &match?({Ecto.Migrator, _}, &1))
      assert migrator_opts[:repos] == Application.fetch_env!(:consensus, :ecto_repos)
      assert migrator_opts[:skip] == true

      assert {Consensus.Seeds, seed_opts} = Enum.find(children, &match?({Consensus.Seeds, _}, &1))
      assert seed_opts[:skip] == true

      System.put_env("RELEASE_NAME", "consensus")
      Application.put_env(:consensus, :seed_on_boot, true)

      children = App.children()

      assert {Ecto.Migrator, migrator_opts} = Enum.find(children, &match?({Ecto.Migrator, _}, &1))
      assert migrator_opts[:skip] == false

      assert {Consensus.Seeds, seed_opts} = Enum.find(children, &match?({Consensus.Seeds, _}, &1))
      assert seed_opts[:skip] == false
    end
  end

  describe "skip_migrations?/0" do
    test "skips outside a release" do
      System.delete_env("RELEASE_NAME")
      assert App.skip_migrations?() == true
    end

    test "does not skip inside a release" do
      System.put_env("RELEASE_NAME", "consensus")
      assert App.skip_migrations?() == false
    end

    test "any non-empty RELEASE_NAME counts as a release" do
      System.put_env("RELEASE_NAME", "anything")
      assert App.skip_migrations?() == false
    end
  end

  describe "skip_seeds?/0" do
    test "follows skip_migrations?/0 when :seed_on_boot is unset" do
      Application.delete_env(:consensus, :seed_on_boot)

      System.delete_env("RELEASE_NAME")
      assert App.skip_seeds?() == true

      System.put_env("RELEASE_NAME", "consensus")
      assert App.skip_seeds?() == false
    end

    test ":seed_on_boot false wins over a release boot" do
      Application.put_env(:consensus, :seed_on_boot, false)
      System.put_env("RELEASE_NAME", "consensus")

      assert App.skip_migrations?() == false
      assert App.skip_seeds?() == true
    end

    test ":seed_on_boot true wins outside a release" do
      Application.put_env(:consensus, :seed_on_boot, true)
      System.delete_env("RELEASE_NAME")

      assert App.skip_migrations?() == true
      assert App.skip_seeds?() == false
    end

    test "the test environment is pinned to never seed" do
      # config/test.exs pins this. If it ever flips, every `Accounts.list_users/0`
      # assertion in the suite silently gains a bootstrap admin.
      assert Application.fetch_env!(:consensus, :seed_on_boot) == false
    end
  end

  describe "start/2" do
    @tag :tmp_dir
    test "runs the boot preflight before building the tree", %{tmp_dir: tmp} do
      # Point DATABASE_PATH inside a regular file. `Consensus.BootCheck` cannot create
      # that directory, so a preflight that actually runs raises here. A preflight that
      # is merely referenced and never called falls through to `Supervisor.start_link/2`
      # and returns `{:error, {:already_started, _}}` instead — which is the mutation
      # this test exists to kill.
      blocker = Path.join(tmp, "not-a-directory")
      File.write!(blocker, "")

      System.put_env("RELEASE_NAME", "consensus")

      Application.put_env(
        :consensus,
        Consensus.Repo,
        Keyword.put(
          Application.fetch_env!(:consensus, Consensus.Repo),
          :database,
          Path.join(blocker, "consensus.db")
        )
      )

      error =
        assert_raise RuntimeError, fn ->
          Consensus.Application.start(:normal, [])
        end

      assert error.message =~ "Cannot write the SQLite database"
      assert error.message =~ "chown -R 65534:0 /data"
    end

    @tag :tmp_dir
    test "does not run the preflight outside a release", %{tmp_dir: tmp} do
      blocker = Path.join(tmp, "not-a-directory")
      File.write!(blocker, "")

      System.delete_env("RELEASE_NAME")

      Application.put_env(
        :consensus,
        Consensus.Repo,
        Keyword.put(
          Application.fetch_env!(:consensus, Consensus.Repo),
          :database,
          Path.join(blocker, "consensus.db")
        )
      )

      # The app is already running, so this stops at the named supervisor rather than
      # starting a second tree. What matters is that it got that far without raising:
      # `mix phx.server` and `mix test` manage their own schema and must not be
      # subjected to the volume preflight.
      assert {:error, {:already_started, _pid}} = Consensus.Application.start(:normal, [])
    end
  end

  defp index_of(children, fun), do: Enum.find_index(children, fun)
end
