defmodule ConsensusWeb.UserLive.Confirmation do
  @moduledoc """
  Handles a magic link.

  Confirming an account that already has a password always discards that password —
  see `Consensus.Accounts.login_user_by_magic_link/1`. This page says so before the
  button is pressed, rather than surprising the person afterwards, and the warning is
  visually louder than the button it warns about.
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

        <h1 class="break-words text-[27px] font-bold leading-[1.15] tracking-[-0.025em]">
          Welcome, {@user.email}
        </h1>

        <div
          :if={@clears_password?}
          id="password-clears-warning"
          role="alert"
          class="flex items-start gap-3 rounded-2xl border-2 border-ink bg-tangerine p-4 text-white shadow-sticker-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <div class="flex flex-col gap-1.5">
            <p class="text-[13.5px] font-bold leading-[1.35]">
              This account already has a password, and confirming here will remove it.
            </p>
            <p class="text-[12px] leading-[1.45] text-white/90">
              That is deliberate: whoever can read this inbox owns the account, and the
              existing password may have been set by someone else before the address was
              proven. You will be signed in and can choose a new password under Settings.
            </p>
          </div>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
          class="flex flex-col gap-3"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <div class="grid">
            <.button
              variant="primary"
              type="submit"
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Confirming…"
            >
              Confirm and stay logged in
            </.button>
          </div>
          <button
            type="submit"
            phx-disable-with="Confirming…"
            class="text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink"
          >
            Confirm and log in only this time
          </button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
          class="flex flex-col gap-3"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <div class="grid">
              <.button variant="primary" type="submit" phx-disable-with="Logging in…">
                Log in
              </.button>
            </div>
          <% else %>
            <div class="grid">
              <.button
                variant="primary"
                type="submit"
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Logging in…"
              >
                Keep me logged in on this device
              </.button>
            </div>
            <button
              type="submit"
              phx-disable-with="Logging in…"
              class="text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink"
            >
              Log me in only this time
            </button>
          <% end %>
        </.form>

        <p
          :if={!@user.confirmed_at and not @clears_password?}
          class="text-[12.5px] leading-[1.5] text-muted"
        >
          Confirming links this email address to your account. You can change your password
          any time from the user settings.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok,
       assign(socket,
         page_title: "Confirm your account",
         user: user,
         form: form,
         trigger_submit: false,
         clears_password?: clears_password?(user)
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end

  # Confirming an unconfirmed account that already has a password always discards that
  # password — there is no signed-in exception. Mirrors the first clause of
  # `Consensus.Accounts.login_user_by_magic_link/1`; keep the two in step.
  defp clears_password?(user) do
    is_nil(user.confirmed_at) and not is_nil(user.hashed_password)
  end
end
