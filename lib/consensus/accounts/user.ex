defmodule Consensus.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @min_password_length 12

  @doc "The minimum password length enforced for humans setting their own password."
  def min_password_length, do: @min_password_length

  schema "users" do
    field :email, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :is_admin, :boolean, default: false
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registration.

  Unlike `mix phx.gen.auth`'s default (magic-link-only) registration, this app also
  takes a password at sign-up so that the app is usable on a fresh deploy with no
  email provider configured. The `login_user_by_magic_link/1` safeguard against
  credential pre-stuffing described in `mix help phx.gen.auth` is preserved — see
  `Consensus.Accounts.login_user_by_magic_link/1` and docs/decisions.md.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :username, :password])
    |> validate_email(opts)
    |> validate_username(opts)
    |> validate_password(opts)
  end

  @doc """
  A user changeset for registering or changing the username.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the username, useful when displaying live validations.
      Defaults to `true`.
  """
  def username_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username])
    |> validate_username(opts)
  end

  defp validate_username(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:username])
      |> validate_length(:username, min: 3, max: 30)
      |> validate_format(:username, ~r/^[a-zA-Z0-9_-]+$/,
        message: "may only contain letters, numbers, underscores and hyphens"
      )

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:username, Consensus.Repo)
      |> unique_constraint(:username)
    else
      changeset
    end
  end

  @doc """
  A changeset for granting or revoking the admin role.

  Deliberately narrow: it casts nothing but `:is_admin`, so it can never be used to
  smuggle an email, username or password change through an admin-only endpoint.
  """
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:is_admin])
    |> validate_required([:is_admin])
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Consensus.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_length` - Enforces the `@min_password_length` minimum.
      Defaults to `true`. The **only** supported reason to set this to `false`
      is `Consensus.Seeds`, which has to be able to seed the documented
      bootstrap password even though it is deliberately below the minimum.
      See the security warning in README.md.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> maybe_validate_password_length(opts)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_validate_password_length(changeset, opts) do
    if Keyword.get(opts, :validate_length, true) do
      validate_length(changeset, :password, min: @min_password_length, max: 72)
    else
      validate_length(changeset, :password, min: 1, max: 72)
    end
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Confirms the account **and discards whatever password it currently has**.

  Used whenever an unconfirmed account that already holds a password is confirmed —
  unconditionally, with no exception for a session already authenticated as that user
  (D-017 removed that carve-out). Whoever controls the inbox is the rightful owner;
  the password may have been planted by someone who registered the address first, so
  it is destroyed rather than trusted. See
  `Consensus.Accounts.login_user_by_magic_link/1` and the "Mixing magic link and
  password registration" section of `mix help phx.gen.auth`.
  """
  def confirm_and_clear_password_changeset(user) do
    user
    |> confirm_changeset()
    |> put_change(:hashed_password, nil)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Consensus.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
