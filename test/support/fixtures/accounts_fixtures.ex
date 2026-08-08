defmodule Consensus.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Consensus.Accounts` context.
  """

  import Ecto.Query

  alias Consensus.Accounts
  alias Consensus.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def unique_username, do: "user#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      username: unique_username(),
      password: valid_user_password()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    # Registration always sets a password and a magic link always discards the password
    # on an unconfirmed account (`Accounts.login_user_by_magic_link/1`), so the fixture
    # sets it again afterwards. Confirmed fixtures are therefore password-authenticable
    # with `valid_user_password/0`, which is what most callers assume.
    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    set_password(user)
  end

  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    # `set_admin/3` requires an admin actor, which is a chicken-and-egg problem for the
    # very first admin. Fixtures write the role directly; every code path that a person
    # can reach goes through `Accounts.set_admin/3`.
    {:ok, admin} =
      user
      |> Consensus.Accounts.User.admin_changeset(%{is_admin: true})
      |> Consensus.Repo.update()

    admin
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  @doc """
  A scope as the application actually builds one — including `authenticated_at`.

  `ConsensusWeb.UserAuth.fetch_current_scope_for_user/2` stamps `:authenticated_at` onto
  the user from the session token, so no `%Scope{}` reaching a context function in the
  running app ever carries `nil` there. A fixture that omitted it was not representative,
  and it silently put every scope *out* of sudo mode — which matters now that
  `Accounts.set_admin/3` and `Accounts.delete_user/2` require sudo mode.

  Pass `authenticated_at:` to build a deliberately stale scope; see
  `stale_scope/1` for the common case.
  """
  def user_scope_fixture(user, opts \\ []) do
    authenticated_at = Keyword.get(opts, :authenticated_at, DateTime.utc_now(:second))
    Scope.for_user(%{user | authenticated_at: authenticated_at})
  end

  def admin_scope_fixture(attrs \\ %{}) do
    attrs |> admin_fixture() |> user_scope_fixture()
  end

  @doc """
  The same scope, authenticated long enough ago to be out of sudo mode.

  Models a borrowed laptop or a lifted remember-me cookie: authenticated, still an
  admin, but no longer fresh.
  """
  def stale_scope(%Scope{user: user}), do: stale_scope(user)

  def stale_scope(user) do
    user_scope_fixture(user, authenticated_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Consensus.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Consensus.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Consensus.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
