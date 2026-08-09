defmodule Consensus.Accounts.UserNotifier do
  @moduledoc """
  Transactional email.

  Every send is best-effort. This app is designed to be deployable with no mail
  provider at all — sign-up sets a password and logs the new account in, so nothing a
  person is waiting on depends on an email arriving. A misconfigured or unreachable
  mailer must therefore never take down the request that triggered it, and Swoosh
  adapters signal failure two different ways: an `{:error, _}` tuple, or a process
  exit (`Swoosh.Adapters.Local` does exactly that when its storage process is not
  running). `deliver/3` turns both into a logged `{:error, reason}`.
  """

  import Swoosh.Email
  require Logger

  alias Consensus.Mailer
  alias Consensus.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(sender())
      |> subject(subject)
      |> text_body(body)

    case safe_deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} ->
        Logger.error(
          "could not deliver #{inspect(subject)} to #{inspect(recipient)}: #{inspect(reason)}. " <>
            "Configure a mailer in config/runtime.exs — see the \"Configuring the mailer\" section."
        )

        {:error, reason}
    end
  end

  defp safe_deliver(email) do
    Mailer.deliver(email)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @default_sender {"Consensus", "onboarding@resend.dev"}

  @doc """
  The `From` this app sends as, as Swoosh's `{name, address}` tuple.

  Configurable because a real provider will not send as whatever it likes: Resend
  rejects a `From` whose domain you have not verified in its dashboard, so the address
  has to track the deployment rather than be baked into the source. `config/runtime.exs`
  sets it from `MAIL_FROM` / `MAIL_FROM_NAME` in production.

  The default is Resend's own `onboarding@resend.dev`, which is the one sender every
  Resend account may use without verifying a domain — so a first deploy delivers to the
  account owner instead of failing. It is deliberately *not* `contact@example.com`,
  which was the previous hardcoded value and could never have delivered anywhere.
  """
  def sender do
    case Application.get_env(:consensus, :mail_from) do
      {name, address} when is_binary(name) and is_binary(address) -> {name, address}
      address when is_binary(address) -> {elem(@default_sender, 0), address}
      _ -> @default_sender
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.

  Three bodies, matching the three cases `Consensus.Accounts.login_user_by_magic_link/1`
  distinguishes — and in the same order, so the email always describes what the link
  will actually do. **Keep the clauses in step with that function.**

  The middle clause is the one this app hits constantly and the generator does not
  have. Registration here takes a password, so `confirmed_at` stays `nil` on an
  account that already holds a credential; the generator's two-way split then sends
  those people a "Confirmation instructions" email closing with *"If you didn't create
  an account with us, please ignore this."* That advice is backwards in both directions
  it can be read:

    * The victim of credential pre-stuffing is by definition someone who did **not**
      create the account. Following the instruction leaves the squatter's password
      live on their address — it disarms the very defence the link exists to fire.
    * An honest person clicking "Log in with email" to get past a forgotten password
      is told they are confirming an account, with no warning that the password is
      about to be destroyed. `ConsensusWeb.UserLive.Confirmation` says so on screen;
      the email must not contradict it.

  So that case gets its own body: subject-lined for what was asked for, explicit that
  the password will be removed, and telling a surprised recipient to click *because*
  they did not create the account. Pinned line by line in
  `test/consensus/accounts/user_notifier_test.exs`.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil, hashed_password: hash} when not is_nil(hash) ->
        deliver_claim_account_instructions(user, url)

      %User{confirmed_at: nil} ->
        deliver_confirmation_instructions(user, url)

      _ ->
        deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  # Unconfirmed *and* already holding a password: the credential-pre-stuffing case.
  # Every line below is asserted in the test file — do not reword one without the other.
  defp deliver_claim_account_instructions(user, url) do
    deliver(user.email, "Log in to Consensus", """

    ==============================

    Hi #{user.email},

    You can log in by visiting the URL below:

    #{url}

    This account already has a password, and logging in with this link removes it.
    You will be signed in and can choose a new password under Settings.

    If you did not create this account, someone else registered your email address.
    Click the link anyway: it takes ownership of the account and disables the
    password they set. Do not ignore this email.

    ==============================
    """)
  end

  # Unconfirmed and passwordless — the generator's case, and its wording. Reachable
  # only for an account whose password has already been discarded.
  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
