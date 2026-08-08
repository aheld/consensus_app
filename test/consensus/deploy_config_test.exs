defmodule Consensus.DeployConfigTest do
  @moduledoc """
  Coherence checks over `fly.toml`.

  Nothing in Elixir reads this file at runtime, so it is not "config" in the usual
  sense — but it holds several values that must agree with *each other*, and every one
  of them is a two-place edit that nothing else checks. `fly.toml`'s own header says so
  out loud: "Two things you MUST change before the first deploy: 1. `app` ... Then make
  PHX_HOST match the hostname Fly gives you." Two stanzas, one invariant, no guard.

  The PHX_HOST one is the expensive mistake, because it fails silently and only in
  production:

    * `check_origin` defaults to `true` in prod and validates the browser's `Origin`
      header against the endpoint's `:url` host, which `config/runtime.exs` takes from
      `PHX_HOST`. If PHX_HOST is not the hostname the browser actually used, every
      LiveView socket upgrade answers 403.
    * Every user-facing page in this app is a LiveView, so that is a total loss of
      interactivity. Nothing else notices: `GET /` still answers 200, because LiveView
      static-renders on the dead-render pass before any socket exists, and `/health`
      still answers 200 because it is origin-free, session-free and outside the
      `:browser` pipeline.
    * `[[http_service.checks]]` polls exactly `/health`. So Fly reports the machine
      healthy, the deploy goes green, and the app is dead.

  The `docker` job in `.github/workflows/ci.yml` now completes a real websocket
  handshake and asserts 101, which catches an endpoint that rejects its own hostname.
  It cannot catch *this*, though: that step reads PHX_HOST out of `fly.toml` and feeds
  the very same value to the container, so `app` and PHX_HOST drifting apart is
  invisible to it. Hence these tests, which are cheap, need no database, and fail on a
  pull request minutes before the Docker job would not have failed at all.
  """

  use ExUnit.Case, async: true

  @fly_toml "fly.toml"

  setup_all do
    %{source: File.read!(@fly_toml)}
  end

  describe "fly.toml internal consistency" do
    test "PHX_HOST is the hostname Fly serves `app` at", %{source: source} do
      {app, app_line} = fetch_string!(source, "app")
      {phx_host, host_line} = fetch_string!(source, "PHX_HOST")

      expected = app <> ".fly.dev"

      assert phx_host == expected, """
      fly.toml contradicts itself. Fly serves an app at <app>.fly.dev, so these two
      lines have to agree and they do not:

          #{@fly_toml}:#{app_line}:  app = '#{app}'
          #{@fly_toml}:#{host_line}:  PHX_HOST = '#{phx_host}'

      Reconcile them by setting PHX_HOST = '#{expected}' on line #{host_line}, or by
      renaming `app` to '#{String.replace_suffix(phx_host, ".fly.dev", "")}' on line #{app_line}.

      This is not cosmetic. PHX_HOST becomes the endpoint's :url host, `check_origin`
      defaults to true in production, and every page in this app is a LiveView — so a
      mismatch 403s every socket upgrade and leaves the app completely non-interactive,
      while GET / and GET /health both keep answering 200 and Fly's health check
      (which polls /health) reports the machine healthy.

      If you are deliberately serving this app from a custom domain rather than
      *.fly.dev, that is a real decision: record it in docs/decisions.md and relax this
      test to match, rather than deleting it.
      """
    end

    test "PORT and http_service.internal_port are the same port", %{source: source} do
      {port, port_line} = fetch_string!(source, "PORT")
      {internal_port, internal_line} = fetch_bare!(source, "internal_port")

      assert port == internal_port, """
      fly.toml contradicts itself:

          #{@fly_toml}:#{port_line}:  PORT = '#{port}'
          #{@fly_toml}:#{internal_line}:  internal_port = #{internal_port}

      `PORT` is what config/runtime.exs binds the endpoint to; `internal_port` is where
      Fly Proxy sends traffic. If they differ, every request to the machine is refused
      and the health check never goes green.
      """
    end

    test "DATABASE_PATH is inside the mounted volume", %{source: source} do
      {database_path, db_line} = fetch_string!(source, "DATABASE_PATH")
      {destination, dest_line} = fetch_string!(source, "destination")

      assert String.starts_with?(database_path, destination <> "/"), """
      fly.toml contradicts itself:

          #{@fly_toml}:#{db_line}:  DATABASE_PATH = '#{database_path}'
          #{@fly_toml}:#{dest_line}:  destination = '#{destination}'

      The SQLite database must be a file inside the [[mounts]] destination. A path
      outside it lands on the container filesystem, which every deploy replaces — the
      app boots clean, migrates, seeds a fresh bootstrap admin, and silently discards
      every row from the previous release.

      (Consensus.BootCheck.run!/0 catches the specific case where the whole directory
      is on the root filesystem, but it inspects DATABASE_PATH at runtime and knows
      nothing about what fly.toml declares as the mount point.)
      """
    end
  end

  describe "the shape .github/workflows/ci.yml parses" do
    # The `docker` job extracts PHX_HOST from fly.toml with
    #
    #     sed -n "s/^[[:space:]]*PHX_HOST[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p"
    #
    # so it depends on single quotes, which is the style `fly launch` writes and the
    # style this file uses throughout. Reformatting to double quotes is valid TOML and
    # would still deploy, but the smoke step would extract nothing. It does bail out
    # with an explicit "could not read PHX_HOST" error rather than booting on an empty
    # value, so the failure is loud — but it fails in the slowest job in CI, after a
    # full image build. Failing here instead costs nothing.
    test "PHX_HOST is a single-quoted scalar on its own line", %{source: source} do
      assert source =~ ~r/^\s*PHX_HOST\s*=\s*'[^']+'/m, """
      The `docker` job in .github/workflows/ci.yml reads PHX_HOST out of fly.toml with a
      sed expression that expects a single-quoted value, e.g.

          PHX_HOST = 'consensus-app.fly.dev'

      fly.toml no longer matches that shape, so the smoke test would abort with
      "could not read PHX_HOST out of the [env] block in fly.toml". Either restore the
      single quotes or update the sed expression in ci.yml to match.
      """
    end
  end

  describe "the app stays single-machine and permanently running" do
    test "the availability trio keeps one machine up", %{source: source} do
      # CLAUDE.md invariant 4: these three move as a set. SQLite is a file on one
      # volume attached to one machine, so a stopped machine is not a cost saving —
      # it drops every LiveView websocket and takes the database offline. With
      # auto_start disabled it never comes back on its own.
      {auto_stop, stop_line} = fetch_string!(source, "auto_stop_machines")
      {auto_start, start_line} = fetch_bare!(source, "auto_start_machines")
      {min_running, min_line} = fetch_bare!(source, "min_machines_running")

      assert auto_stop == "off", """
      fly.toml line #{stop_line}: auto_stop_machines is '#{auto_stop}', expected 'off'.
      Stopping this machine takes the SQLite volume offline and drops every LiveView
      websocket. See CLAUDE.md invariant 4 and docs/decisions.md.
      """

      assert auto_start == "false", """
      fly.toml line #{start_line}: auto_start_machines is #{auto_start}, expected false.
      """

      assert String.to_integer(min_running) >= 1, """
      fly.toml line #{min_line}: min_machines_running is #{min_running}, expected at
      least 1. Zero means the only machine holding the database may be stopped.
      """
    end

    test "the deploy workflow still passes --ha=false" do
      # Without it, `flyctl deploy` provisions a SECOND machine for availability. The
      # second machine gets a different volume or none, so it serves a different
      # database. CLAUDE.md invariant 4: never scale past one.
      # Match the invocation, not the file. The flag is also named in a comment two
      # lines above it, so `workflow =~ "--ha=false"` stays true after the flag is
      # deleted from the command — a guard that passes for the wrong reason, which is
      # exactly what this describe block exists to prevent. Verified by mutation.
      run_line =
        workflow_lines()
        |> Enum.find(&Regex.match?(~r/^\s*-\s*run:\s*flyctl\s+deploy/, &1))

      assert run_line, """
      .github/workflows/fly-deploy.yml has no `- run: flyctl deploy ...` step. If the
      deploy moved to a different command, move this assertion with it.
      """

      assert run_line =~ "--ha=false", """
      The flyctl deploy invocation no longer passes --ha=false:

          #{String.trim(run_line)}

      That flag is what keeps this a single-machine app at deploy time. Without it Fly
      provisions a second machine for availability; the second machine gets a different
      volume or none, so it serves a different database. CLAUDE.md invariant 4.
      """
    end

    defp workflow_lines do
      ".github/workflows/fly-deploy.yml" |> File.read!() |> String.split("\n")
    end

    test "there is no [deploy] release_command" do
      # CLAUDE.md invariant 3. A Fly release machine has no volume mounted, so a
      # release_command would migrate a throwaway database and leave the real one
      # untouched. Migrations run from the supervision tree instead (D-009).
      refute Regex.match?(~r/^\s*release_command\s*=/m, File.read!("fly.toml")), """
      fly.toml declares a [deploy] release_command. A release machine has no volume, so
      it would migrate a database that is discarded moments later while the real one
      never gets the migration. See CLAUDE.md invariant 3 and docs/decisions.md D-009.
      """
    end
  end

  # Returns {value, line_number} for `key = 'value'`, or fails the test naming the key.
  defp fetch_string!(source, key) do
    fetch!(source, key, ~r/^\s*#{Regex.escape(key)}\s*=\s*'([^']*)'/)
  end

  # Same, for an unquoted scalar such as `internal_port = 8080`.
  defp fetch_bare!(source, key) do
    fetch!(source, key, ~r/^\s*#{Regex.escape(key)}\s*=\s*([^\s#]+)/)
  end

  defp fetch!(source, key, regex) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, number} ->
      case Regex.run(regex, line) do
        [_, value] -> {value, number}
        nil -> nil
      end
    end)
    |> case do
      nil -> flunk("could not find a `#{key} = ...` line in #{@fly_toml}")
      found -> found
    end
  end
end
