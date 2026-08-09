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
     # The count is the whole point of the cross-link: without it an admin who never taps
     # it never learns anything is waiting, and `/admin/feedback` is not in the header's
     # `⋯` menu yet (that menu is in `ConsensusWeb.Chrome`, D-043).
     |> assign(:unread_feedback, Consensus.Feedback.count_unread())
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
  # **The return trip is real now (D-045), and the flash may promise it again.** It could
  # not before: `user_return_to` was only ever written by `maybe_store_return_to/1`, a plug
  # on GET requests, and this navigation originates in a LiveView with no conn to write —
  # so `UserAuth.log_in_user/3` fell through to `signed_in_path/1`, which for an
  # already-authenticated conn is `/users/settings`. The copy said "You will come back to
  # Admin → Users." and the app delivered Account settings. That was corrected once by
  # *removing* the promise; it is corrected properly here by building it, which is what
  # `UserAuth.store_return_to/2` and the hidden `user[return_to]` field on
  # `ConsensusWeb.UserLive.Login`'s password form are for.
  #
  # **Only the password form completes the trip**, and the copy says so rather than
  # over-claiming again. A magic link is delivered to a mailbox, which is routinely opened
  # on a different device from the one holding this tab, so "come back to where you were"
  # is not a thing that route can honour. `UserLive.Login` renders the promise on the form
  # that keeps it, so the two cannot drift apart on screen.
  defp require_sudo(socket, action) do
    socket
    |> put_flash(
      :error,
      "For security, log in again to #{action}. Signing in with your password brings you " <>
        "straight back to Admin → Users."
    )
    |> push_navigate(to: ~p"/users/log-in?#{[return_to: ~p"/admin/users"]}")
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
  #
  # `min-h-[44px]` and `inline-flex items-center`, not vertical padding alone: 12px of
  # line-height plus `py-1.5` plus two 2px borders measured **34px**, against the 44px
  # pills on `/admin/feedback` — two sibling admin screens, built weeks apart, with
  # different button metrics for the same kind of row action. 44 is the phone touch floor
  # every other control in this work was held to, and one of the three buttons in this row
  # deletes an account and everything it cascades to, so this is the screen where the
  # larger target is worth the row height.
  defp action_button_class(false) do
    "press-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold leading-none shadow-sticker-2 hover:bg-yellow"
  end

  defp action_button_class(true) do
    "inline-flex min-h-[44px] cursor-not-allowed items-center rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold leading-none text-faint opacity-[45%]"
  end

  # The same 44px pill geometry as Promote/Demote above. Measured at 360×640 it was
  # **37.3×18** against Promote's 77.6×34, starting 8.0px to Promote's right with its whole
  # vertical band sitting inside Promote's — a destructive, irreversible action rendered as
  # the smallest and least visible thing in the row. Its only styling was
  # `text-[12px] text-muted hover:text-tangerine`, and `hover:` does not exist on touch, so
  # on a phone nothing distinguished it from body text and nothing acknowledged a tap. The
  # `data-confirm` naming the cascade is the only reason that was survivable.
  #
  # `ml-2` on top of the row's `gap-2` puts 16px between it and Promote, so a miss is a
  # miss rather than a promotion. Tangerine is the *press* state, not the fill: the house
  # rule gives a screen one tangerine forward action, and this is neither forward nor
  # alone. `active:` beside `hover:` for the same reason `Chrome.header/1`'s circles carry
  # it — a phone has no hover.
  defp delete_button_class(false) do
    "press-2 ml-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold leading-none text-ink-soft shadow-sticker-2 transition-colors hover:bg-tangerine hover:text-white active:bg-tangerine active:text-white"
  end

  defp delete_button_class(true) do
    "ml-2 inline-flex min-h-[44px] cursor-not-allowed items-center rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold leading-none text-faint opacity-[45%]"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The wordmark link and the "Back to app" button that used to head this column
          are both gone (D-041): the global header's `‹` is the way back and its wordmark
          is the brand, and leaving either in place would be the second back affordance
          plan ruling 1 exists to prevent. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
      context="ADMIN"
    >
      <%!-- No `max-w-2xl`: `Layouts.app`'s `:phone` column already caps this at 440px, so
            the wider cap only ever described a width this screen cannot have. --%>
      <div class="mx-auto flex w-full flex-1 flex-col gap-6 px-6 pb-10 pt-6">
        <%!-- No `<.eyebrow>Admin</.eyebrow>` here: the header's context slot already
              says ADMIN, in the same uppercase DM Mono, 110px above. The h1 says which
              admin screen this is, and that is the part the header does not carry. --%>
        <div class="flex flex-col gap-2">
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
          <%!-- The other admin screen. It is not in the header's `⋯` menu — that lives
                in `ConsensusWeb.Chrome`, which the feedback piece does not own — so the
                two admin screens link to each other directly (D-043). --%>
          <.link
            navigate={~p"/admin/feedback"}
            id="admin-feedback-link"
            class="-my-3 inline-flex min-h-[44px] w-fit items-center text-[12.5px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine active:text-tangerine"
          >
            Go to Admin → Feedback{if @unread_feedback > 0,
              do: " (#{@unread_feedback} unread)",
              else: ""}
          </.link>
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
              <%!-- The link body sits on one line and the full stop is welded to the
                    closing tag. Broken across lines, the anchor's text node carries the
                    surrounding whitespace and the screen reads "Change it now ." with the
                    underline running past the word — the whitespace-significant-string trap
                    of CLAUDE.md invariant 11 / D-026. --%>
              <%!-- `-my-[13px] inline-block py-[13px]` takes the hit box from a measured
                    88×16 to 88×44 without moving the baseline or growing the paragraph —
                    the same numbers, for the same reason, as `#login-register-link` and
                    `#register-log-in-link` (18px of line box + 26px of padding). `py-2`
                    was tried first and measured 34.2. 16px tall
                    is under WCAG 2.5.8 AA's 24px floor, let alone the 44px platform
                    minimum, and this is not a tertiary link: it is the single remediation
                    control inside a live security warning about a shipped default
                    password. Every other sub-44 link in the app was swept and this one was
                    missed. --%>
              Anyone who can reach this site can sign in as an administrator. <.link
                navigate={~p"/users/settings"}
                id="default-password-fix"
                class="-my-[13px] inline-block py-[13px] font-semibold underline decoration-2 underline-offset-2"
              >Change it now</.link>.
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
            <%!-- The same destination `require_sudo/2`'s flash uses, and it has to be:
                  this notice is the **only** affordance a stale admin can reach. Every
                  Promote/Demote/Delete on the page renders `disabled` in exactly this
                  state, so the `handle_event` branch that carries the return trip is
                  unreachable from a fresh mount. Left as a bare `/users/log-in`, the one
                  path a person can actually take stored no `user_return_to` (the pipeline
                  answers 200 and never halts, so `maybe_store_return_to/1` never runs) and
                  `signed_in_path/1` delivered them to Account settings — measured. --%>
            <.link
              navigate={~p"/users/log-in?#{[return_to: ~p"/admin/users"]}"}
              id="sudo-notice-log-in"
              class="font-semibold underline decoration-2 underline-offset-2"
            >
              Log in again</.link>.
          </p>
        </div>

        <%!-- Row cards, not `<.table>`. This column is `max-w-[440px]` (`Layouts.app`'s
              `:phone` width, which is every width this screen has), and the five-column
              table measured 678px inside a 372px `overflow-x-auto` box: Promote, Demote and
              Delete — the three controls this screen exists for — were entirely off-screen,
              announced by nothing but a 4px scrollbar stub. The table could not fit at any
              viewport, so this is not a breakpoint, it is the layout. `<.table>` itself
              stays in `CoreComponents` for a future `width={:wide}` screen; it just has no
              caller. Same information, one card per account: identity, then the two
              metadata lines, then the actions on their own row where they wrap instead of
              overflowing. --%>
        <ul id="users" class="flex flex-col gap-2.5">
          <li :for={user <- @users} id={"user-#{user.id}"}>
            <.sticker_card depth={2} class="flex flex-col gap-2.5 p-3.5">
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class="font-bold text-ink">{user.username}</span>
                <.pill :if={user.id == @current_scope.user.id} tone={:mint_soft}>you</.pill>
                <.pill tone={if user.is_admin, do: :violet, else: :mint_soft}>
                  {if user.is_admin, do: "admin", else: "member"}
                </.pill>
              </div>

              <p class="break-all text-[13px] leading-snug text-ink-soft">{user.email}</p>

              <p class="font-mono text-[10.5px] uppercase tracking-[0.06em] text-muted">
                Joined {Calendar.strftime(user.inserted_at, "%Y-%m-%d")} · {if user.confirmed_at,
                  do: "confirmed",
                  else: "unconfirmed"}
              </p>

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
            </.sticker_card>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
