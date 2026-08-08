defmodule ConsensusWeb.UserLive.Settings do
  @moduledoc """
  Account settings — username, email and password, each its own form.

  Requires sudo mode (`on_mount {ConsensusWeb.UserAuth, :require_sudo_mode}`, a
  10-minute window — see `Consensus.Accounts.sudo_mode?/2` and CLAUDE.md invariant 5).
  """

  use ConsensusWeb, :live_view

  on_mount {ConsensusWeb.UserAuth, :require_sudo_mode}

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
          <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em]">
            Account settings
          </h1>
          <p class="text-[14.5px] leading-[1.45] text-ink-soft">
            Manage your username, email address and password.
          </p>
        </div>

        <.form
          for={@username_form}
          id="username_form"
          phx-submit="update_username"
          phx-change="validate_username"
          class="flex flex-col gap-3"
        >
          <.input
            field={@username_form[:username]}
            type="text"
            label="Username"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <div class="grid">
            <.button type="submit" phx-disable-with="Saving…">Change Username</.button>
          </div>
        </.form>

        <div class="h-0.5 rounded-full bg-ink-12" />

        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
          class="flex flex-col gap-3"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            spellcheck="false"
            required
          />
          <div class="grid">
            <.button type="submit" phx-disable-with="Changing…">Change Email</.button>
          </div>
        </.form>

        <div class="h-0.5 rounded-full bg-ink-12" />

        <.form
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
          class="flex flex-col gap-3"
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_user_email"
            spellcheck="false"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            spellcheck="false"
          />
          <div class="grid">
            <.button variant="primary" type="submit" phx-disable-with="Saving…">
              Save Password
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:current_email, user.email)
      |> assign(
        :username_form,
        to_form(Accounts.change_user_username(user, %{}, validate_unique: false))
      )
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_username", %{"user" => user_params}, socket) do
    username_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_username(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, username_form: username_form)}
  end

  def handle_event("update_username", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.update_user_username(user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Username changed to #{user.username}.")
         |> assign(:current_scope, Consensus.Accounts.Scope.for_user(user))
         |> assign(:username_form, to_form(Accounts.change_user_username(user)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :username_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
