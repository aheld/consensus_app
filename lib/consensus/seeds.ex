defmodule Consensus.Seeds do
  @moduledoc """
  First-boot seeding: the bootstrap administrator and the home page row.

  `run!/0` is idempotent, so it is safe to run on every single boot. It is invoked
  from three places, all of which end up here:

    * `Consensus.Application` — as a supervision-tree child placed immediately after
      `Ecto.Migrator`, so a release (Fly.io, `bin/server`, the Docker image) migrates
      and then seeds before the endpoint accepts traffic.
    * `priv/repo/seeds.exs` — so `mix ecto.setup` / `mix setup` seeds a dev database.
    * `Consensus.Release.seed/0` — so an operator can seed by hand over `fly ssh console`.

  ## The bootstrap password

  The default credentials are `aheld` / `adminpass`. `adminpass` is **shorter than the
  12-character minimum this app enforces on everybody else** — seeding deliberately
  bypasses that check so the documented default works out of the box (see
  `Consensus.Accounts.User.min_password_length/0`).
  Change it before the app is reachable by anyone but you. The
  app tells you so: it logs a warning on every boot and shows a banner in the admin area
  for as long as the default is still in place. See README.md.

  All three values can be overridden with the `ADMIN_USERNAME`, `ADMIN_EMAIL` and
  `ADMIN_PASSWORD` environment variables (on Fly.io: `fly secrets set ADMIN_PASSWORD=...`
  *before* the first deploy). The waiver above covers the built-in `adminpass` and
  nothing else: an `ADMIN_PASSWORD` you set is held to the full minimum, because waiving
  it there would silently accept a one-character production admin password.
  """

  require Logger

  alias Consensus.Accounts
  alias Consensus.Accounts.User

  @default_username "aheld"
  @default_email "aheld@example.com"
  @default_password "adminpass"

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # Inert, and kept only so this spec reads like every other one-shot child:
      # `start_link/1` returns `:ignore`, so the supervisor never holds a process here
      # and no `restart` value it could hold would ever be consulted.
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Supervision-tree entry point.

  Runs the seeds synchronously and returns `:ignore`, so nothing is left in the tree —
  the same pattern `Ecto.Migrator` uses as a child. Pass `skip: true` to do nothing.
  """
  def start_link(opts \\ []) do
    if not Keyword.get(opts, :skip, false) do
      run!()
    end

    :ignore
  end

  @doc """
  Creates a bootstrap admin **if this deployment has no administrator at all**.

  Idempotent, and it never modifies an existing user. The condition is deliberately
  "are there zero admins?" rather than "does the user `aheld` exist?": an operator's
  first act is often to rename that account or change its email, and keying off the
  username would then treat the next boot as a first boot and quietly recreate an
  account with the documented default password. Checking the *role* means the
  bootstrap account is created exactly once in the life of a database.

  Returns `{:ok, %{admin: admin_or_nil}}`; `admin` is `nil` when the deployment already
  had one.
  """
  def run! do
    admin = ensure_admin()
    warn_about_default_passwords()
    {:ok, %{admin: admin}}
  end

  @doc "The bootstrap admin's username (`ADMIN_USERNAME`, default `#{@default_username}`)."
  def admin_username, do: System.get_env("ADMIN_USERNAME") || @default_username

  @doc "The bootstrap admin's email (`ADMIN_EMAIL`, default `#{@default_email}`)."
  def admin_email, do: System.get_env("ADMIN_EMAIL") || @default_email

  @doc "The bootstrap admin's password (`ADMIN_PASSWORD`, default `#{@default_password}`)."
  def admin_password, do: System.get_env("ADMIN_PASSWORD") || @default_password

  @doc """
  Returns every admin who still has the built-in default password.

  Costs one bcrypt verification per admin, so call it on admin pages, not on every
  request. Note that it checks the *password*, not the username — renaming the
  bootstrap account does not make it safe.
  """
  def admins_with_default_password do
    Enum.filter(Accounts.list_admins(), &User.valid_password?(&1, @default_password))
  end

  @doc "True when any administrator can be signed in as with the documented default."
  def default_password_in_use?, do: admins_with_default_password() != []

  defp ensure_admin do
    if Accounts.count_admins() > 0 do
      # Already administered. Do not create a second bootstrap account, and do not
      # touch the existing one — its username, email, password and role are whatever
      # its owner decided.
      nil
    else
      create_bootstrap_admin()
    end
  end

  defp create_bootstrap_admin do
    password = admin_password()

    attrs = %{
      username: admin_username(),
      email: admin_email(),
      password: password,
      is_admin: true,
      # The bootstrap admin cannot click a link in an email that nobody sent,
      # so it starts out confirmed.
      confirmed_at: DateTime.utc_now(:second)
    }

    # The length minimum is waived for the documented `adminpass` default and for
    # nothing else. An operator who sets ADMIN_PASSWORD is held to the same 12-character
    # rule as every other account — waiving it for them would silently accept a
    # one-character production admin password.
    opts = if password == @default_password, do: [validate_length: false], else: []

    case Accounts.create_user(attrs, opts) do
      {:ok, user} ->
        Logger.info("[seeds] created bootstrap admin #{inspect(user.username)}")
        user

      {:error, changeset} ->
        report_seed_failure(changeset)
    end
  end

  # The two branches have genuinely different causes, so they must not share a message:
  # on an empty database nothing can be "already taken", and saying so sends the operator
  # looking for a collision that cannot exist.
  defp report_seed_failure(changeset) do
    if Accounts.count_users() == 0 do
      # Nothing exists yet, so this is a genuine first boot and the configuration is
      # simply wrong. Fail loudly: the deploy should not be reported as successful.
      raise first_boot_failure(changeset)
    else
      # There are accounts but none of them is an admin. Refusing to boot would leave
      # nobody able to `fly ssh console` in and repair it, so log loudly and carry on.
      Logger.error("[seeds] " <> collision_failure(changeset))
      nil
    end
  end

  defp first_boot_failure(changeset) do
    """
    could not seed the bootstrap admin user.

    #{inspect(changeset.errors)}

    This database has no accounts at all, so no name or address can be in use by one:
    the value in ADMIN_USERNAME, ADMIN_EMAIL or ADMIN_PASSWORD is itself invalid.
    In order of how often it is the cause:

      * ADMIN_PASSWORD shorter than #{User.min_password_length()} characters. The minimum
        is waived for the built-in default #{inspect(@default_password)} and for nothing
        else, so a password you set is held to the full length.
      * ADMIN_EMAIL is not a valid email address.
      * ADMIN_USERNAME is under 3 or over 30 characters, or contains something other
        than letters, numbers, underscores and hyphens.

    Fix the value and restart, e.g. `fly secrets set ADMIN_PASSWORD=...` (which restarts
    the machine for you). Nothing has been created, so nothing needs cleaning up first.
    """
  end

  defp collision_failure(changeset) do
    """
    could not seed the bootstrap admin user.

    #{inspect(changeset.errors)}

    This database already holds accounts but no administrator. The likeliest cause is
    that ADMIN_EMAIL or ADMIN_USERNAME is already taken by one of them. Point them at
    unused values and restart, or promote an existing account by hand:

      fly ssh console -C "/app/bin/consensus remote"

    Booting anyway: refusing would leave nobody able to get in and repair it.
    """
  end

  defp warn_about_default_passwords do
    for %User{} = admin <- admins_with_default_password() do
      Logger.warning("""
      [seeds] the admin account #{inspect(admin.username)} is using the default password \
      #{inspect(@default_password)}. Anyone who can reach this app can take it over. \
      Log in and change it under "Settings", or set ADMIN_PASSWORD before the first boot.\
      """)
    end

    :ok
  end
end
