# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` (and therefore `mix setup`) runs it for you.
#
# The real work lives in `Consensus.Seeds` so that the exact same idempotent code path
# runs here, from the supervision tree when the app boots as a release on Fly.io, and
# from `Consensus.Release.seed/0` when an operator runs it by hand. Keep it that way —
# seeding logic that only exists in this file will not run in production.

{:ok, %{admin: admin}} = Consensus.Seeds.run!()

case admin do
  nil ->
    IO.puts("""

    Seeded. This database already had an administrator, so none was created.
    """)

  admin ->
    IO.puts("""

    Seeded.

      admin username: #{admin.username}
      admin email:    #{admin.email}
      admin password: #{if Consensus.Seeds.default_password_in_use?(), do: "adminpass  <-- CHANGE THIS", else: "(set from ADMIN_PASSWORD)"}

    Log in at http://localhost:4000/users/log-in
    """)
end
