defmodule Consensus.BootCheckTest do
  @moduledoc """
  Exercises the boot preflight against real directories under a per-test tmp path.

  Everything here is a check whose *absence* is silent: an unwritable volume surfaces
  as eleven `database_open_failed` lines and a `DBConnection.ConnectionError` about
  connection pools, and a `DATABASE_PATH` outside the mount produces no error at all —
  the app boots, seeds a fresh administrator, and the next deploy destroys it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Consensus.BootCheck

  @moduletag :tmp_dir

  setup do
    original_fly_app_name = System.get_env("FLY_APP_NAME")
    original_repo_config = Application.fetch_env!(:consensus, Consensus.Repo)

    on_exit(fn ->
      case original_fly_app_name do
        nil -> System.delete_env("FLY_APP_NAME")
        name -> System.put_env("FLY_APP_NAME", name)
      end

      Application.put_env(:consensus, Consensus.Repo, original_repo_config)
    end)

    :ok
  end

  describe "run!/1 — the directory" do
    test "creates the directory when it does not exist yet", %{tmp_dir: tmp} do
      directory = Path.join(tmp, "data")
      refute File.dir?(directory)

      capture_log(fn ->
        assert :ok = BootCheck.run!(Path.join(directory, "consensus.db"))
      end)

      assert File.dir?(directory)
    end

    test "returns :ok for a writable directory", %{tmp_dir: tmp} do
      capture_log(fn ->
        assert :ok = BootCheck.run!(Path.join(tmp, "consensus.db"))
      end)
    end

    test "raises when the directory denies writes, naming the ownership and the fix", %{
      tmp_dir: tmp
    } do
      directory = Path.join(tmp, "data")
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o500)
      on_exit(fn -> File.chmod(directory, 0o700) end)

      # 0o500 does not deny writes to uid 0. The `not-a-directory` test below covers the
      # same failure in a way that holds for root, so nothing is lost when this is
      # inapplicable.
      if write_denied?(directory) do
        %File.Stat{uid: uid, gid: gid} = File.stat!(directory)

        error =
          assert_raise RuntimeError, fn ->
            BootCheck.run!(Path.join(directory, "consensus.db"))
          end

        assert error.message =~ "Cannot write the SQLite database"
        assert error.message =~ "uid #{uid}:gid #{gid}"
        assert error.message =~ "mode 500"
        assert error.message =~ Path.join(directory, "consensus.db")
        assert error.message =~ ~s(fly ssh console -u root -C "chown -R 65534:0 /data")
      end
    end

    test "raises when the directory cannot be created at all", %{tmp_dir: tmp} do
      # DATABASE_PATH pointing inside a regular file: `mkdir_p` cannot fix this for any
      # user, root included.
      blocker = Path.join(tmp, "not-a-directory")
      File.write!(blocker, "")

      error =
        assert_raise RuntimeError, fn ->
          BootCheck.run!(Path.join(blocker, "consensus.db"))
        end

      assert error.message =~ "Cannot write the SQLite database"
      assert error.message =~ ~s(fly ssh console -u root -C "chown -R 65534:0 /data")
    end
  end

  describe "run!/1 — the database file" do
    test "raises when the directory is writable but the database file is not", %{tmp_dir: tmp} do
      # What a `fly ssh console` session as root leaves behind: the volume is still
      # owned by nobody, the file inside it is not. A directory-only check misses it.
      database = Path.join(tmp, "consensus.db")
      File.write!(database, "")
      File.chmod!(database, 0o400)
      on_exit(fn -> File.chmod(database, 0o600) end)

      if append_denied?(database) do
        error = assert_raise RuntimeError, fn -> BootCheck.run!(database) end

        assert error.message =~ "Cannot write the SQLite database"
        assert error.message =~ "refused       : #{database}"
        assert error.message =~ "mode 400"
      end
    end

    # `journal_mode: :wal` (config/runtime.exs) means SQLite must open and write these
    # too, and they belong to whichever process created them. A root
    # `sqlite3 /data/consensus.db ...` over `fly ssh console` leaves the database itself
    # owned by `nobody` and the sidecars owned by root, which is exactly the shape a
    # DATABASE_PATH-only probe passes and the boot then dies on.
    for suffix <- ["-wal", "-shm"] do
      test "raises when the #{suffix} sidecar is not writable, naming the sidecar", %{
        tmp_dir: tmp
      } do
        database = Path.join(tmp, "consensus.db")
        sidecar = database <> unquote(suffix)
        File.write!(database, "")
        File.write!(sidecar, "")
        File.chmod!(sidecar, 0o400)
        on_exit(fn -> File.chmod(sidecar, 0o600) end)

        # The database itself is untouched: a probe that only looked here would pass.
        refute append_denied?(database)

        if append_denied?(sidecar) do
          error = assert_raise RuntimeError, fn -> BootCheck.run!(database) end

          assert error.message =~ "Cannot write the SQLite database"
          # The path that actually refused, not the healthy file beside it.
          assert error.message =~ "refused       : #{sidecar}"
          assert error.message =~ ~s(fly ssh console -u root -C "chown -R 65534:0 /data")

          # And the whole set is listed, so the operator can see which member is wrong.
          assert error.message =~ "#{database} — regular"
          assert error.message =~ "#{sidecar} — regular"
        end
      end
    end

    test "tolerates writable sidecars", %{tmp_dir: tmp} do
      database = Path.join(tmp, "consensus.db")
      File.write!(database, "")
      File.write!(database <> "-wal", "")
      File.write!(database <> "-shm", "")

      capture_log(fn -> assert :ok = BootCheck.run!(database) end)
    end

    test "tolerates a database file that does not exist yet", %{tmp_dir: tmp} do
      capture_log(fn ->
        assert :ok = BootCheck.run!(Path.join(tmp, "brand-new.db"))
      end)
    end
  end

  describe "run!/1 — the mount" do
    test "warns when the directory is not a separate mount", %{tmp_dir: tmp} do
      # ExUnit's tmp_dir lives under the project, which is on the root filesystem both
      # here and in CI — the same shape as a `docker run` with no `-v`.
      assert BootCheck.on_root_filesystem?(tmp)

      log =
        capture_log(fn ->
          assert :ok = BootCheck.run!(Path.join(tmp, "consensus.db"))
        end)

      assert log =~ "is not a mount point"
      assert log =~ "destroyed by the next deploy"
      assert log =~ Path.join(tmp, "consensus.db")
    end

    test "raises instead of warning when it happens on Fly", %{tmp_dir: tmp} do
      System.put_env("FLY_APP_NAME", "consensus")

      error =
        assert_raise RuntimeError, fn ->
          BootCheck.run!(Path.join(tmp, "consensus.db"))
        end

      assert error.message =~ "is not a mount point"
      assert error.message =~ "fly volumes list"
    end
  end

  describe "on_root_filesystem?/1" do
    test "is true for the root filesystem itself" do
      assert BootCheck.on_root_filesystem?("/")
    end

    test "is false for a path that cannot be stat'd", %{tmp_dir: tmp} do
      refute BootCheck.on_root_filesystem?(Path.join(tmp, "no/such/path"))
    end
  end

  describe "run!/0" do
    test "checks the configured database", %{tmp_dir: tmp} do
      directory = Path.join(tmp, "configured")

      Application.put_env(
        :consensus,
        Consensus.Repo,
        Keyword.put(
          Application.fetch_env!(:consensus, Consensus.Repo),
          :database,
          Path.join(directory, "consensus.db")
        )
      )

      capture_log(fn -> assert :ok = BootCheck.run!() end)
      assert File.dir?(directory)
    end

    test "is a no-op when there is no repo configuration" do
      Application.put_env(
        :consensus,
        Consensus.Repo,
        Keyword.delete(Application.fetch_env!(:consensus, Consensus.Repo), :database)
      )

      assert :ok = BootCheck.run!()
    end
  end

  defp write_denied?(directory) do
    probe = Path.join(directory, ".write-denied-probe")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        false

      {:error, _} ->
        true
    end
  end

  defp append_denied?(database) do
    case File.open(database, [:append]) do
      {:ok, io} ->
        File.close(io)
        false

      {:error, _} ->
        true
    end
  end
end
