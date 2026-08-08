defmodule ConsensusWeb.UserLive.Confirmation do
  @moduledoc """
  Handles a magic link.

  Confirming an account that already has a password always discards that password —
  see `Consensus.Accounts.login_user_by_magic_link/1`. This page says so before the
  button is pressed, rather than surprising the person afterwards.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Welcome {@user.email}</.header>
        </div>

        <div :if={@clears_password?} class="alert alert-warning mt-4">
          <.icon name="hero-exclamation-triangle" class="size-6 shrink-0" />
          <div>
            <p>This account already has a password, and confirming here will remove it.</p>
            <p class="text-sm">
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
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            class="btn btn-primary w-full"
          >
            Confirm and stay logged in
          </.button>
          <.button phx-disable-with="Confirming..." class="btn btn-primary btn-soft w-full mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              class="btn btn-primary w-full"
            >
              Keep me logged in on this device
            </.button>
            <.button phx-disable-with="Logging in..." class="btn btn-primary btn-soft w-full mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at and not @clears_password?} class="alert alert-outline mt-8">
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
