defmodule Consensus.Audit do
  @moduledoc """
  The `[audit]` log line for admin writes outside `Consensus.Accounts` — the shared
  catalog and option details on `/admin/items` (D-060). Same shape as
  `Consensus.Accounts`' own private `audit/4` (CLAUDE.md invariant 5), so
  `fly logs | grep audit` stays the one record of what admins changed:

      [audit] catalog_hide actor_id=1 actor="aheld" target_id=42
      [audit] catalog_delete REFUSED :unauthorized actor_id=7 actor="ex-admin" target_id=42

  Ids first because usernames are mutable. `log/4` returns its input unchanged, so it
  sits at the end of a pipeline.
  """

  require Logger

  alias Consensus.Accounts.User

  @spec log(result, String.t(), User.t(), integer() | nil) :: result when result: term()
  def log(result, action, %User{} = actor, target_id) do
    who = "actor_id=#{actor.id} actor=#{inspect(actor.username)} target_id=#{target_id}"

    case result do
      {:ok, _} -> Logger.info("[audit] #{action} #{who}")
      {:error, reason} -> Logger.warning("[audit] #{action} REFUSED #{inspect(reason)} #{who}")
      _other -> :ok
    end

    result
  end
end
