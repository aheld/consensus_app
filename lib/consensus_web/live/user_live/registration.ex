defmodule ConsensusWeb.UserLive.Registration do
  @moduledoc """
  Sign-up.

  Unlike the stock `mix phx.gen.auth` registration, this form also takes a username and
  a password, and signs the new account in immediately by handing the form off to
  `ConsensusWeb.UserSessionController` (the `phx-trigger-action` pattern — a LiveView
  cannot write the session cookie itself). That is what makes the app usable on a fresh
  deploy that has no email provider configured yet. See docs/decisions.md.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          method="post"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            spellcheck="false"
            required
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />

          <p class="mt-1 text-xs text-base-content/60">
            At least {User.min_password_length()} characters.
          </p>

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full mt-4">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ConsensusWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:trigger_submit, false)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        # Best-effort: this is what lets the account become "confirmed" once an email
        # provider is configured, but it is not required to use the app, so a mailer
        # that is missing or down must not fail the sign-up. `UserNotifier` logs the
        # failure; see docs/decisions.md.
        _ = Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        # Hand the (still populated) form over to the session controller so the
        # browser gets a signed session cookie.
        {:noreply,
         socket
         |> assign(:trigger_submit, true)
         |> assign_form(Accounts.change_user_registration(user))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
