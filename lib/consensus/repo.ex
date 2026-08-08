defmodule Consensus.Repo do
  use Ecto.Repo,
    otp_app: :consensus,
    adapter: Ecto.Adapters.SQLite3
end
