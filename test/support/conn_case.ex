defmodule ConsensusWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ConsensusWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ConsensusWeb.Endpoint

      use ConsensusWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ConsensusWeb.ConnCase
    end
  end

  setup tags do
    Consensus.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = Consensus.AccountsFixtures.user_fixture()
    scope = Consensus.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Setup helper that gives the conn an organizer with no account (D-058).

      setup :create_anonymous_organizer

  The accountless twin of `register_and_log_in_user/1`: mints an identity through the
  real write path and puts its token on the conn the way a browser would carry it. It
  stores `:conn`, `:anonymous_organizer`, the raw `:organizer_token` and the anonymous
  `:scope` in the test context.
  """
  def create_anonymous_organizer(%{conn: conn}) do
    {raw_token, organizer} = Consensus.ActivitiesFixtures.anonymous_organizer_fixture()

    %{
      conn: put_organizer_token(conn, raw_token),
      anonymous_organizer: organizer,
      organizer_token: raw_token,
      scope: Consensus.Accounts.Scope.for_anonymous_organizer(organizer)
    }
  end

  @doc """
  Puts an organizer token on the `conn` as the signed cookie a browser would send.

  A request cookie rather than a session key, because that is what a real browser
  carries: `ConsensusWeb.OrganizerAuth.fetch_organizer_token/2` verifies it and mirrors
  it into the session on the dead render, and the connected mount then reads it from
  the session like any other LiveView — so both halves of `live/2` see the identity.
  Signed with the endpoint's own secret, so a tampered value is still refused.
  """
  def put_organizer_token(conn, raw_token) do
    conn
    |> Map.put(:secret_key_base, ConsensusWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(ConsensusWeb.OrganizerAuth.cookie_name(), raw_token, sign: true)
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Consensus.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Consensus.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
