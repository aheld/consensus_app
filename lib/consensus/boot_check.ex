defmodule Consensus.BootCheck do
  @moduledoc """
  Preflight for the SQLite file, run before the repo starts.

  The two ways this app loses on Fly.io both fail *quietly* without these checks, and
  both produce a message that points somewhere unhelpful:

    * **The volume is not writable by the release.** The Dockerfile chowns `/data` to
      `nobody`, but a container runtime only copies that ownership onto a volume that
      is mounted *empty* — a restored snapshot, a `lost+found`, or a file written
      during a root `fly ssh console` session all defeat it. Ownership can also be
      split *within* the database: `journal_mode: :wal` (config/runtime.exs) means
      SQLite must open and write `-wal` and `-shm` sidecars beside the file named by
      `DATABASE_PATH`, and a root `cp`/`tar` restore takes those without touching a
      `consensus.db` that still looks perfectly healthy. All three are therefore
      probed. Ecto otherwise reports `database_open_failed` and a
      `DBConnection.ConnectionError` about connection pools, which sends the operator
      to look at `pool_size`.

    * **`DATABASE_PATH` is not inside the mount.** Nothing fails at all. The app boots,
      migrates, seeds a fresh administrator with the default password, and writes the
      database into the container's own filesystem, where the next deploy destroys it.
      This is the misconfiguration `fly.toml` calls fatal and it has no error message
      of its own.

  Both are checked here, before `Consensus.Repo` is in the supervision tree, and both
  are reported in terms of the thing the operator has to change.

  Also called by `Consensus.Release.migrate/0`, `Consensus.Release.seed/0` and
  `Consensus.Release.rollback/2`, which run in a fresh node via `bin/consensus eval` and
  would otherwise skip it — those are precisely the commands an operator reaches for
  when something is already wrong.
  """

  import Bitwise
  require Logger

  @probe ".consensus-write-probe"

  @doc """
  Runs every check against the configured repo, or returns `:ok` when there is nothing
  to check (no repo configuration).
  """
  def run! do
    case Application.get_env(:consensus, Consensus.Repo)[:database] do
      nil -> :ok
      database -> run!(database)
    end
  end

  @doc "Runs every check against an explicit database path."
  def run!(database) when is_binary(database) do
    directory = Path.dirname(database)

    with :ok <- ensure_directory(directory),
         :ok <- ensure_writable(directory),
         :ok <- ensure_database_writable(database) do
      check_mount(database, directory)
    else
      {:error, {path, reason}} -> raise permission_error(database, directory, path, reason)
    end
  end

  @doc """
  True when `directory` sits on the same filesystem as `/`, i.e. no volume is mounted
  there. Returns `false` if either path cannot be stat'd, so an unknown answer never
  becomes a false alarm.
  """
  def on_root_filesystem?(directory) do
    with {:ok, %File.Stat{major_device: dir_dev}} <- File.stat(directory),
         {:ok, %File.Stat{major_device: root_dev}} <- File.stat("/") do
      dir_dev == root_dev
    else
      _ -> false
    end
  end

  # Every check reports `{:error, {path, reason}}` so the message can name the path that
  # actually refused, rather than re-stating `DATABASE_PATH` and describing a file that
  # is perfectly healthy.
  defp ensure_directory(directory) do
    if File.dir?(directory) do
      :ok
    else
      case File.mkdir_p(directory) do
        :ok -> :ok
        {:error, reason} -> {:error, {directory, reason}}
      end
    end
  end

  defp ensure_writable(directory) do
    probe = Path.join(directory, @probe)

    with :ok <- File.write(probe, ""),
         :ok <- File.rm(probe) do
      :ok
    else
      {:error, reason} -> {:error, {directory, reason}}
    end
  end

  # The directory can be writable while a database file inside it is not — which is
  # exactly what happens when someone writes into the volume as root over
  # `fly ssh console`. Checking the directory alone would miss it.
  #
  # It has to be the whole WAL set, not just `DATABASE_PATH`. `config/runtime.exs` pins
  # `journal_mode: :wal`, so SQLite opens and writes `-wal` and `-shm` sidecars beside
  # the database and cannot start without write access to all three. Their ownership can
  # differ from the database's, which is what a `DATABASE_PATH`-only probe walks straight
  # past on its way to five `unable to open database file` lines and a
  # `DBConnection.ConnectionError` about pool size. Verified against the release image.
  #
  # Note for whoever edits this next: running `sqlite3` as root over `fly ssh console` is
  # *not* how you get there. SQLite fchowns a journal it creates to match the database
  # file's owner precisely so a root maintenance session cannot strand the daemon — also
  # verified. The reachable causes are a root `cp`/`tar`/snapshot restore that preserves
  # its own ownership, a non-SQLite root process writing a sidecar path, or root having
  # created the database in the first place.
  defp ensure_database_writable(database) do
    database
    |> wal_set()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.open(path, [:append]) do
        {:ok, io} ->
          File.close(io)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
  end

  # Only the members that exist: on a first boot none of them do, and on a cleanly shut
  # down database the sidecars are checkpointed away.
  defp wal_set(database) do
    Enum.filter([database, database <> "-wal", database <> "-shm"], &File.exists?/1)
  end

  defp check_mount(database, directory) do
    cond do
      not on_root_filesystem?(directory) ->
        :ok

      fly?() ->
        # On Fly there is no legitimate reason for DATABASE_PATH to sit outside the
        # mount, and the database is empty by definition at this point, so failing the
        # deploy costs nothing and saves the operator from discovering it later.
        raise mount_error(database, directory)

      true ->
        Logger.warning(mount_error(database, directory))
        :ok
    end
  end

  defp fly?, do: System.get_env("FLY_APP_NAME") not in [nil, ""]

  defp permission_error(database, directory, failed_path, reason) do
    """
    Cannot write the SQLite database (#{inspect(reason)}).

    #{facts(database, directory, failed_path)}
    On Fly.io this means the mounted volume, or one of the database files on it, belongs
    to root: the volume was restored from a snapshot, or written to during a
    `fly ssh console` session as root. Check the refused path above rather than assuming
    it is the database — the `-wal` and `-shm` sidecars can be owned by root while
    #{Path.basename(database)} itself still looks correct, and SQLite needs all three.
    Fix the lot and restart the machine:

      fly ssh console -u root -C "chown -R 65534:0 /data"

    See TODO.md, "Troubleshooting".
    """
  end

  # `refused` is the line that matters and is always present. `directory` is dropped
  # when it *is* the refused path, so the report never states the same fact twice.
  defp facts(database, directory, failed_path) do
    [
      "  refused       : #{failed_path} — #{describe(failed_path)}",
      "  DATABASE_PATH : #{database}",
      if(failed_path != directory, do: "  directory     : #{directory} — #{describe(directory)}"),
      "  database files: #{describe_wal_set(database)}",
      "  release user  : nobody (uid 65534) — see the Dockerfile"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("", &(&1 <> "\n"))
  end

  defp describe_wal_set(database) do
    case wal_set(database) do
      [] -> "none yet"
      paths -> Enum.map_join(paths, "", &"\n      #{&1} — #{describe(&1)}")
    end
  end

  defp mount_error(database, directory) do
    """
    #{directory} is not a mount point — it is part of the container filesystem.

      DATABASE_PATH : #{database}

    Everything will appear to work: the app boots, migrates, and seeds an administrator.
    The database is then destroyed by the next deploy, along with every account in it.

    On Fly.io, `[[mounts]] destination` in fly.toml must be a prefix of `[env]
    DATABASE_PATH`, and the volume named in `[[mounts]] source` must exist in this
    app's region. Check `fly volumes list`.

    Locally, this is what a `docker run` with no `-v` looks like, and it is harmless
    for a quick look at the image.
    """
  end

  defp describe(path) do
    case File.stat(path) do
      {:ok, %File.Stat{uid: uid, gid: gid, mode: mode, type: type}} ->
        "#{type}, uid #{uid}:gid #{gid}, mode #{Integer.to_string(mode &&& 0o777, 8)}"

      {:error, reason} ->
        "cannot stat (#{inspect(reason)})"
    end
  end
end
