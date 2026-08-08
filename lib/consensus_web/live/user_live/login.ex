defmodule ConsensusWeb.UserLive.Login do
  @moduledoc """
  Log in — by magic link, or by username-or-email and password.

  Both forms post to the same `ConsensusWeb.UserSessionController`. The magic-link
  form never discloses whether the address is registered (see `submit_magic/2`); the
  password form accepts either an email address or a username in one field.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} background="bg-canvas">
      <div class="mx-auto flex w-full max-w-sm flex-1 flex-col gap-6 px-6 pb-10 pt-6">
        <.link
          navigate={~p"/"}
          class="self-start font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-ink-soft transition-colors hover:text-ink"
        >
          Consensus
        </.link>

        <div class="flex flex-col gap-2">
          <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em]">Log in</h1>
          <p class="text-[14.5px] leading-[1.45] text-ink-soft">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Don't have an account?
              <.link
                navigate={~p"/users/register"}
                class="font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
              >
                Sign up
              </.link>
            <% end %>
          </p>
        </div>

        <div
          :if={local_mail_adapter?()}
          class="flex items-start gap-3 rounded-2xl border-2 border-ink bg-violet-tint p-4 shadow-sticker-2"
        >
          <.icon name="hero-information-circle" class="size-5 shrink-0 text-violet" />
          <div class="flex flex-col gap-1 text-[13px] leading-[1.4] text-ink">
            <p class="font-bold">You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link
                href="/dev/mailbox"
                class="font-semibold underline decoration-2 underline-offset-2"
              >
                the mailbox page
              </.link>.
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="flex flex-col gap-3"
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
          <div class="grid">
            <.button variant="primary" type="submit">
              Log in with email <span aria-hidden="true">→</span>
            </.button>
          </div>
        </.form>

        <div class="flex items-center gap-3" aria-hidden="true">
          <span class="h-0.5 flex-1 rounded-full bg-ink-12"></span>
          <span class="font-mono text-[10.5px] font-semibold uppercase tracking-[0.06em] text-muted">
            or
          </span>
          <span class="h-0.5 flex-1 rounded-full bg-ink-12"></span>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="flex flex-col gap-3"
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
          <div class="grid">
            <.button type="submit" name={@form[:remember_me].name} value="true">
              Log in and stay logged in <span aria-hidden="true">→</span>
            </.button>
          </div>
          <button
            type="submit"
            class="text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink"
          >
            Log in only this time
          </button>
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
