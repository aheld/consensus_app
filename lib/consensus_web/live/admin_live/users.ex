defmodule ConsensusWeb.AdminLive.Users do
  @moduledoc """
  Admin → Users. Lists every account and grants or revokes the admin role.

  Authorization is enforced by the router (`:require_admin_user` plug plus the
  `:require_admin` on_mount hook); this module assumes an admin scope.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Seeds

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Users")
     |> assign_sudo_mode()
     |> assign_default_password_warning()
     |> load_users()}
  end

  @impl true
  def handle_event("set_admin", %{"id" => id, "admin" => admin}, socket)
      when is_binary(id) and is_binary(admin) do
    # Everything here arrives from the client, so it is parsed rather than trusted:
    # a non-numeric or out-of-range id would otherwise raise inside Ecto and take the
    # LiveView process down. Authorization is re-checked in `Accounts.set_admin/3`
    # against the database, not against this socket's (possibly stale) scope.
    with {user_id, ""} <- Integer.parse(id),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      set_admin(socket, user, admin == "true")
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not find that user.")}
    end
  end

  def handle_event("set_admin", _params, socket) do
    {:noreply, put_flash(socket, :error, "Could not update that user.")}
  end

  def handle_event("delete_user", %{"id" => id}, socket) when is_binary(id) do
    with {user_id, ""} <- Integer.parse(id),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      delete_user(socket, user)
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not find that user.")}
    end
  end

  def handle_event("delete_user", _params, socket) do
    {:noreply, put_flash(socket, :error, "Could not delete that user.")}
  end

  defp delete_user(socket, user) do
    case Accounts.delete_user(socket.assigns.current_scope, user) do
      {:ok, {deleted, tokens_to_disconnect}} ->
        # The row is gone but the sockets holding it are not: a LiveView the deleted
        # person already has open would keep running on a scope with no account behind
        # it until something made it remount. Same reasoning as demotion below.
        ConsensusWeb.UserAuth.disconnect_sessions(tokens_to_disconnect)

        {:noreply,
         socket
         |> put_flash(:info, "#{deleted.username} was deleted.")
         |> assign_default_password_warning()
         |> load_users()}

      {:error, :sudo_required} ->
        {:noreply, require_sudo(socket, "delete an account")}

      {:error, :is_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, "Demote an admin before deleting their account.")
         |> load_users()}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "You cannot delete your own account here.")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your admin access was revoked.")
         |> push_navigate(to: ~p"/")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not delete that user. Please try again.")
         |> load_users()}
    end
  end

  defp set_admin(socket, user, make_admin?) do
    case Accounts.set_admin(socket.assigns.current_scope, user, make_admin?) do
      {:ok, {updated, tokens_to_disconnect}} ->
        # A LiveView that is already mounted keeps the scope it mounted with, so a
        # demoted admin would otherwise still be able to act from an open tab.
        # Disconnecting forces a remount, which re-reads the role.
        ConsensusWeb.UserAuth.disconnect_sessions(tokens_to_disconnect)

        flash =
          if updated.is_admin,
            do: "#{updated.username} is now an admin.",
            else: "#{updated.username} is no longer an admin."

        {:noreply,
         socket
         |> put_flash(:info, flash)
         |> assign_default_password_warning()
         |> load_users()}

      {:error, :sudo_required} ->
        {:noreply, require_sudo(socket, "change who is an admin")}

      {:error, :last_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, "You cannot remove the last admin — promote someone else first.")
         |> load_users()}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your admin access was revoked.")
         |> push_navigate(to: ~p"/")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update that user. Please try again.")
         |> load_users()}
    end
  end

  # Promoting and deleting accounts are account-takeover-grade actions, so `Accounts`
  # holds them to the same freshness bar `mix phx.gen.auth` puts on renaming your own
  # account. A session that is authenticated but stale gets sent to re-authenticate
  # rather than a bare failure.
  #
  # The return trip is manual on purpose: `user_return_to` is written by a plug on GET
  # requests, and this navigation originates in the LiveView, so there is no conn to
  # store it on. The flash therefore says where to come back to.
  defp require_sudo(socket, action) do
    socket
    |> put_flash(
      :error,
      "For security, log in again to #{action}. You will come back to Admin → Users."
    )
    |> push_navigate(to: ~p"/users/log-in")
  end

  # Sudo mode is a property of the session token this LiveView mounted with, so it is
  # read once, at mount. This assign decides only whether the UI *offers* an action it
  # already knows would bounce; it is not the enforcement. `Accounts.set_admin/3` and
  # `Accounts.delete_user/2` re-check freshness on every write, so a forged event from a
  # stale session is refused whatever the client renders. Disabling is a courtesy, and
  # deleting the `disabled` attributes would be a UX regression, not a security one.
  defp assign_sudo_mode(socket) do
    assign(socket, :sudo?, Accounts.sudo_mode?(socket.assigns.current_scope.user))
  end

  defp stale_session_hint do
    "For security, log in again to change roles or delete accounts."
  end

  # One bcrypt verification per admin, so it is recomputed only on mount and after a
  # role change — never per render.
  defp assign_default_password_warning(socket) do
    assign(socket, :default_password_admins, Seeds.admins_with_default_password())
  end

  defp load_users(socket) do
    users = Accounts.list_users()

    socket
    |> assign(:users, users)
    |> assign(:admin_count, Enum.count(users, & &1.is_admin))
  end

  # The cascade has to be in the confirmation, because it is not recoverable and it is not
  # obvious from the button. `activity_groups.organizer_id` is `ON DELETE CASCADE`, so
  # deleting an account takes every voting session that person organized — and every option
  # inside those sessions — with it. "Frees their email address" described this action
  # completely only while `users` was the last thing anything pointed at.
  defp delete_confirmation(user) do
    "Permanently delete #{user.username}? This also deletes every voting session they " <>
      "organized, and the options in them. Their email address and username become " <>
      "available again. This cannot be undone."
  end

  defp admin_password_warning([admin]) do
    "The #{admin.username} account is still using the default password."
  end

  defp admin_password_warning(admins) do
    names = admins |> Enum.map(& &1.username) |> Enum.join(", ")
    "These accounts are still using the default password: #{names}."
  end

  # Built from the same boolean as the `disabled` attribute, rather than a Tailwind
  # `disabled:` variant, on purpose: a `disabled:opacity-*` class is present in the
  # static markup whether or not the button is actually disabled (the browser decides
  # via the `:disabled` pseudo-class), which would put the literal substring
  # "disabled" in every row regardless of state. The test suite asserts on that exact
  # substring to tell a disabled button from a live one, so the two states need two
  # different class lists, not one class list with a conditional variant inside it.
  defp action_button_class(false) do
    "press-2 rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold shadow-sticker-2 hover:bg-yellow"
  end

  defp action_button_class(true) do
    "cursor-not-allowed rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold text-faint opacity-[45%]"
  end

  defp delete_button_class(false) do
    "text-[12px] font-semibold text-muted hover:text-tangerine"
  end

  defp delete_button_class(true) do
    "cursor-not-allowed text-[12px] font-semibold text-faint opacity-[45%]"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} background="bg-canvas">
      <div class="mx-auto flex w-full max-w-2xl flex-1 flex-col gap-6 px-6 pb-10 pt-6">
        <div class="flex items-center justify-between gap-4">
          <.link
            navigate={~p"/"}
            class="font-mono text-[11px] font-semibold uppercase tracking-[0.1em] text-ink-soft transition-colors hover:text-ink"
          >
            Consensus
          </.link>
          <.button navigate={~p"/"}>Back to app</.button>
        </div>

        <div class="flex flex-col gap-2">
          <.eyebrow>Admin</.eyebrow>
          <h1 class="text-[27px] font-bold leading-[1.15] tracking-[-0.025em]">Users</h1>
          <p class="text-[13.5px] leading-[1.5] text-ink-soft">
            Designate who can manage this app — the only role this product has. {length(@users)} {ngettext(
              "account",
              "accounts",
              length(@users)
            )}, {@admin_count} admin.
            Deleting an account frees its email address — the only way back in for someone who
            forgot their password on a deployment with no mail provider.
          </p>
        </div>

        <div
          :if={@default_password_admins != []}
          role="alert"
          class="flex items-start gap-3 rounded-2xl border-2 border-ink bg-yellow p-4 shadow-sticker-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          <div class="flex flex-col gap-1 text-[13px] leading-[1.4] text-ink">
            <p class="font-bold">
              {admin_password_warning(@default_password_admins)}
            </p>
            <p>
              Anyone who can reach this site can sign in as an administrator. <.link
                navigate={~p"/users/settings"}
                class="font-semibold underline decoration-2 underline-offset-2"
              >
                Change it now
              </.link>.
            </p>
          </div>
        </div>

        <div
          :if={!@sudo?}
          id="sudo-notice"
          role="status"
          class="flex items-start gap-3 rounded-2xl border-2 border-ink bg-violet-tint p-4 shadow-sticker-3"
        >
          <.icon name="hero-lock-closed" class="size-5 shrink-0 text-violet" />
          <p class="text-[13px] leading-[1.4] text-ink">
            {stale_session_hint()}
            <.link
              navigate={~p"/users/log-in"}
              class="font-semibold underline decoration-2 underline-offset-2"
            >
              Log in again
            </.link>.
          </p>
        </div>

        <.table id="users" rows={@users}>
          <:col :let={user} label="Username">
            <span class="font-bold text-ink">{user.username}</span>
            <.pill :if={user.id == @current_scope.user.id} tone={:mint_soft} class="ml-1">
              you
            </.pill>
          </:col>
          <:col :let={user} label="Email">
            <span class="text-[13px] text-ink-soft">{user.email}</span>
          </:col>
          <:col :let={user} label="Role">
            <.pill tone={if user.is_admin, do: :violet, else: :mint_soft}>
              {if user.is_admin, do: "admin", else: "member"}
            </.pill>
          </:col>
          <:col :let={user} label="Confirmed">
            {if user.confirmed_at, do: "yes", else: "no"}
          </:col>
          <:col :let={user} label="Joined">
            {Calendar.strftime(user.inserted_at, "%Y-%m-%d")}
          </:col>
          <:action :let={user}>
            <div class="flex flex-wrap items-center gap-2">
              <button
                :if={!user.is_admin}
                type="button"
                phx-click="set_admin"
                phx-value-id={user.id}
                phx-value-admin="true"
                disabled={!@sudo?}
                title={!@sudo? && stale_session_hint()}
                data-confirm={"Make #{user.username} an admin?"}
                class={action_button_class(!@sudo?)}
              >
                Promote
              </button>
              <button
                :if={user.is_admin}
                type="button"
                phx-click="set_admin"
                phx-value-id={user.id}
                phx-value-admin="false"
                disabled={@admin_count <= 1 or !@sudo?}
                title={!@sudo? && stale_session_hint()}
                data-confirm={"Remove admin from #{user.username}?"}
                class={action_button_class(@admin_count <= 1 or !@sudo?)}
              >
                Demote
              </button>
              <button
                :if={!user.is_admin and user.id != @current_scope.user.id}
                type="button"
                phx-click="delete_user"
                phx-value-id={user.id}
                disabled={!@sudo?}
                title={!@sudo? && stale_session_hint()}
                data-confirm={delete_confirmation(user)}
                class={delete_button_class(!@sudo?)}
              >
                Delete
              </button>
            </div>
          </:action>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
