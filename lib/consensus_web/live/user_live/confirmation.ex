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
    <%!-- Back goes to `/users/log-in`, not `/`: someone standing on a magic link that
          turns out to be the wrong account needs the login screen, not the splash. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/users/log-in"}
      context="MAGIC LINK"
    >
      <div class="mx-auto flex w-full max-w-sm flex-1 flex-col gap-6 px-6 pb-10 pt-6">
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
          <%!-- Measured 312×19.5 with a 20px hit box, 12px under the 60px primary — a
                finger aiming at the primary and missing low lands here, and the wrong
                outcome is a *non*-remembered session with nothing on screen saying so.
                Grown to a real 44px box with `mt-1` on top of the form's `gap-3`, opening
                the gap to 16px so an overshoot lands on neither. No negative margin: the
                point is to push it away from the primary, not to keep it where it was.
                Identical treatment to `UserLive.Login`'s "Log in only this time"; this is
                the mandatory landing screen for every passwordless user and was missed
                when that one was fixed. --%>
          <button
            type="submit"
            phx-disable-with="Confirming…"
            class="mt-1 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
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
            <%!-- Same 20px-target correction as the confirm form above. --%>
            <button
              type="submit"
              phx-disable-with="Logging in…"
              class="mt-1 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
            >
              Log me in only this time
            </button>
          <% end %>
        </.form>

        <%!-- "*set* a password", not "change" it. This paragraph used to be unreachable in
              practice: a magic-link registration injected a placeholder password, so
              `clears_password?/1` was true and the `:if` suppressed it. D-045 removed the
              placeholder (`require_password: false` — see `UserLive.Registration`), so
              `hashed_password` is now genuinely NULL and this is what *every* magic-link
              registrant reads on their first sign-in — told they can "change" a password
              they have never had. `Settings` labels the field "New password", so "set" is
              also the verb of the screen it points at. --%>
        <p
          :if={!@user.confirmed_at and not @clears_password?}
          class="text-[12.5px] leading-[1.5] text-muted"
        >
          Confirming links this email address to your account. You can set a password later
          under Settings, or keep using the magic link.
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
