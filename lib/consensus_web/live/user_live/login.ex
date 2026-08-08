defmodule ConsensusWeb.UserLive.Login do
  use ConsensusWeb, :live_view

  alias Consensus.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                Don't have an account? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-brand hover:underline"
                  phx-no-format
                >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider">or</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:login]}
            type="text"
            label="Email or username"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # A failed password log-in redirects here with the identifier that was typed in
    # the `:login` flash (`ConsensusWeb.UserSessionController`). Both forms must come
    # back filled in, as they do in the generator — blanking the field after a wrong
    # password makes the person retype it.
    #
    # The generator carries one value because both of its fields are the email. Here
    # the password form's field is `login`, which accepts an email address *or* a
    # username, while the magic-link field is `type="email"` and addresses a mailbox.
    # So a typed username repopulates `login` only: putting it in `email` would hand
    # an email input a value the browser rejects on submit.
    typed_login = Phoenix.Flash.get(socket.assigns.flash, :login)

    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        email_or_nil(typed_login) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    login = typed_login || email

    form = to_form(%{"email" => email, "login" => login}, as: "user")

    {:ok, assign(socket, page_title: "Log in", form: form, trigger_submit: false)}
  end

  defp email_or_nil(nil), do: nil

  defp email_or_nil(login) do
    if String.contains?(login, "@"), do: login, else: nil
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:consensus, Consensus.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
