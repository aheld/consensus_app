defmodule Consensus.Accounts.UserNotifierTest do
  @moduledoc """
  Two things are guarded here: *what* the login email says, and that failing to send
  it can never take a request down.

  **The copy.** `deliver_login_instructions/2` picks one of three bodies from the
  account's state, mirroring the three clauses of
  `Consensus.Accounts.login_user_by_magic_link/1`. Getting that split wrong is silent —
  the wrong email still sends, still renders, and still contains a working link — so
  the bodies are pinned line by line, the way `ConsensusWeb.UserLive.ConfirmationTest`
  pins the on-screen warning. The specific defect: with the generator's two-way split,
  every ordinary account here (registered with a password, so `confirmed_at` stays
  `nil`) received a "Confirmation instructions" email ending *"If you didn't create an
  account with us, please ignore this"* — advice that, followed by the victim of
  credential pre-stuffing, leaves the squatter's password live on their address.

  **The delivery.** The app must stay usable with no working mail provider.
  Regression guard for a real production defect: `config/prod.exs` sets
  `config :swoosh, local: false`, which stops Swoosh from starting
  `Swoosh.Adapters.Local.Storage.Memory` — while `config/config.exs` still names
  `Swoosh.Adapters.Local` as the adapter. In a release that combination made every
  delivery *exit*, which took the calling LiveView down with it, so sign-up crashed.
  `config/runtime.exs` now pins `Swoosh.Adapters.Logger` for `:prod`, and
  `UserNotifier` refuses to let a mailer failure escape by either route — an
  `{:error, _}` tuple or a process exit.
  """

  use Consensus.DataCase, async: false

  import Consensus.AccountsFixtures
  import ExUnit.CaptureLog

  alias Consensus.Accounts
  alias Consensus.Accounts.UserNotifier

  defmodule ExitingAdapter do
    @moduledoc "Stands in for Swoosh.Adapters.Local with no storage process running."
    use Swoosh.Adapter

    def deliver(_email, _config) do
      exit(
        {:noproc, {GenServer, :call, [{:global, Swoosh.Adapters.Local.Storage.Memory}, :push]}}
      )
    end
  end

  defmodule FailingAdapter do
    @moduledoc "Stands in for a provider that is reachable but rejects the message."
    use Swoosh.Adapter

    def deliver(_email, _config), do: {:error, {401, "unauthorized"}}
  end

  setup do
    original = Application.get_env(:consensus, Consensus.Mailer)
    on_exit(fn -> Application.put_env(:consensus, Consensus.Mailer, original) end)
    %{user: user_fixture()}
  end

  defp use_adapter(adapter, extra \\ []) do
    Application.put_env(:consensus, Consensus.Mailer, [adapter: adapter] ++ extra)
  end

  describe "deliver_login_instructions/2 body selection" do
    # `Accounts.login_user_by_magic_link/1` splits three ways, so the email must too:
    # the body has to describe what the link the recipient is about to click will
    # actually do. These tests pin the copy line by line, the way
    # `ConsensusWeb.UserLive.ConfirmationTest` pins the on-screen warning, because the
    # failure mode is silent — every one of these emails "sends fine".
    @url "https://example.com/users/log-in/TOKEN"

    test "confirmed account: the generator's plain magic-link email", %{user: user} do
      assert user.confirmed_at

      assert {:ok, email} = UserNotifier.deliver_login_instructions(user, @url)

      assert email.subject == "Log in instructions"
      assert email.text_body =~ "You can log into your account by visiting the URL below:"
      assert email.text_body =~ @url
      assert email.text_body =~ "If you didn't request this email, please ignore this."
    end

    test "unconfirmed and passwordless: the generator's confirmation email" do
      # The generator's magic-link-first signup. Registration in this app always sets a
      # password, so build the state directly — the notifier is a pure function of the
      # struct, and this clause exists to keep parity with the generator.
      user = %{unconfirmed_user_fixture() | hashed_password: nil}
      refute user.confirmed_at

      assert {:ok, email} = UserNotifier.deliver_login_instructions(user, @url)

      assert email.subject == "Confirmation instructions"
      assert email.text_body =~ "You can confirm your account by visiting the URL below:"
      assert email.text_body =~ @url
      assert email.text_body =~ "If you didn't create an account with us, please ignore this."
    end

    test "unconfirmed but holding a password: its own body, and it does NOT say ignore me" do
      # The case this app hits every time someone who registered normally clicks
      # "Log in with email" — and the case where the recipient may be the victim of
      # credential pre-stuffing rather than the person who registered.
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      assert user.hashed_password

      assert {:ok, email} = UserNotifier.deliver_login_instructions(user, @url)

      # (a) subject-lined for what was asked for, not for "confirmation"
      assert email.subject == "Log in to Consensus"
      assert email.text_body =~ "You can log in by visiting the URL below:"
      assert email.text_body =~ @url

      # (b) the password loss is stated before the link is clicked, matching the
      #     on-screen warning in `ConsensusWeb.UserLive.Confirmation`
      assert email.text_body =~
               "This account already has a password, and logging in with this link removes it."

      assert email.text_body =~
               "You will be signed in and can choose a new password under Settings."

      # (c) the opposite of "if you didn't create an account, ignore this" — following
      #     that advice is exactly what leaves a squatter's password live on the address
      assert email.text_body =~
               "If you did not create this account, someone else registered your email address."

      assert email.text_body =~ "it takes ownership of the account and disables the"
      assert email.text_body =~ "Do not ignore this email."
      refute email.text_body =~ "ignore this."
      refute email.text_body =~ "confirm your account"
    end

    test "no login email sent to an account that holds a password ever says to ignore it" do
      # The single assertion that catches a regression in either direction: a body
      # swapped back to the generator's two-way split, or new copy that reintroduces
      # the disarming sentence.
      for user <- [unconfirmed_user_fixture(), user_fixture()] do
        assert user.hashed_password
        assert {:ok, email} = UserNotifier.deliver_login_instructions(user, @url)

        refute email.text_body =~ "If you didn't create an account with us, please ignore this."
      end
    end
  end

  describe "when the mailer exits" do
    test "the caller gets an error instead of being taken down", %{user: user} do
      use_adapter(ExitingAdapter)

      log =
        capture_log(fn ->
          assert {:error, {:exit, _}} =
                   UserNotifier.deliver_login_instructions(user, "https://example.com/x")
        end)

      assert log =~ "could not deliver"
      assert log =~ "Configure a mailer"
    end

    test "sign-up still succeeds and the new account can log in" do
      use_adapter(ExitingAdapter)
      attrs = valid_user_attributes()

      capture_log(fn ->
        assert {:ok, user} = Accounts.register_user(attrs)
        assert {:error, _} = Accounts.deliver_login_instructions(user, & &1)
        assert Accounts.get_user_by_login_and_password(user.username, valid_user_password())
      end)
    end
  end

  describe "when the provider rejects the message" do
    test "the error is logged and returned", %{user: user} do
      use_adapter(FailingAdapter)

      log =
        capture_log(fn ->
          assert {:error, {401, "unauthorized"}} =
                   UserNotifier.deliver_login_instructions(user, "https://example.com/x")
        end)

      assert log =~ "could not deliver"
    end
  end

  describe "with the Logger adapter (the production default when no provider is configured)" do
    test "delivery succeeds and the magic link does not reach the log", %{user: user} do
      # Production uses `level: :info`; config/test.exs pins the Logger to :warning,
      # so the adapter has to log above that for this test to observe anything.
      use_adapter(Swoosh.Adapters.Logger, level: :warning)

      log =
        capture_log(fn ->
          assert {:ok, email} =
                   UserNotifier.deliver_login_instructions(
                     user,
                     "https://example.com/SECRET-TOKEN"
                   )

          assert email.to == [{"", user.email}]
        end)

      assert log =~ user.email
      refute log =~ "SECRET-TOKEN"
    end
  end
end
