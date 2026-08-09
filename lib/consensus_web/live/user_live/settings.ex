defmodule ConsensusWeb.UserLive.Settings do
  @moduledoc """
  Account settings — username, email and password, each its own form.

  Requires sudo mode (`on_mount {ConsensusWeb.UserAuth, {:require_sudo_mode, path}}`, a
  10-minute window — see `Consensus.Accounts.sudo_mode?/2` and CLAUDE.md invariant 5).

  ## Changing the email address

  Nothing changes when the form is submitted: a confirmation link goes to the **new**
  address and the change only lands when that link is opened. The next real step is
  therefore off-site, and it used to be a flash on a settings page that still showed the
  old address in the field — the reader's obvious conclusion being that it had not worked.
  It is now a full-page state of this LiveView (`@email_sent_to`), per D-045, offering the
  two things the flash could not: send it again, and go back and fix a typo.

  Deliberately not a route. `/users/settings` is behind sudo mode, and a bookmarkable
  confirmation URL would render "check your email" to whoever opened it, naming an address
  no send ever went to.
  """

  use ConsensusWeb, :live_view

  # The tuple form carries the return trip: a sudo bounce from here lands on the log-in
  # form with `?return_to=/users/settings`, so the password form brings the person back to
  # the screen they were thrown out of rather than to `UserAuth.signed_in_path/1`.
  #
  # This module serves **two** routes — `/users/settings` and
  # `/users/settings/confirm-email/:token` — and the hook is declared once, at module level,
  # so the path here is a base rather than the whole answer. `UserAuth`'s
  # `{:require_sudo_mode, _}` clause appends the `:token` param when it is present, because
  # the confirm-email route is the one that matters: that link is emailed and therefore read
  # later, so exceeding the 10-minute window is the ordinary case and a static return path
  # threw the token away.
  on_mount {ConsensusWeb.UserAuth, {:require_sudo_mode, "/users/settings"}}

  alias Consensus.Accounts

  # How many change-address links this screen will send **per mount, across every control
  # on it**. See `deliver_email_change/3` for why this is bounded even though the flow is
  # sudo-gated, and why `update_email` shares the budget rather than the resend button
  # carrying it alone.
  @max_sends 4

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
      back_confirm={draft?(assigns) && discard_prompt()}
      footer_confirm={draft?(assigns) && discard_prompt()}
    >
      <.check_your_email
        :if={@email_sent_to}
        id="email-change-sent"
        heading={if @email_send_refused?, do: "Nothing was sent", else: "Confirm the new address"}
        address={@email_sent_to}
        sent?={!@email_send_refused?}
      >
        <:lede>
          <%!-- Branched on whether this screen's arrival actually mailed anything, the way
                `login.ex`'s lede branches on its own budget and for the same reason: the
                unconditional sentence was false on a send the cap refused. Because
                `update_email` shares the budget with `resend_email_change`, "go back and
                try a different address" — which this page used to offer as the remedy —
                lands here having sent nothing, and the screen then asserted a link was on
                its way to an address no mail ever went to. `@email_send_refused?` is the
                fact, not `@sends_left`: the reader may have arrived on the last send, in
                which case the budget is spent *and* a link really is out. --%>
          <%= if @email_send_refused? do %>
            No link was sent. Your address has <span class="font-semibold text-ink">not</span>
            changed, and this page will not send any more links. Reload it to start again.
            The address you typed was:
          <% else %>
            Your address has <span class="font-semibold text-ink">not</span>
            changed yet. It changes when you open the link we just sent to:
          <% end %>
        </:lede>
        <:fallback>
          <%!-- **Branched on `@email_send_refused?`, exactly like the lede above, and this
                block is why the lede alone was not enough.** With the budget spent, the
                unbranched version said three false things directly under "No link was
                sent": *check the spam folder at the new address*, *the link went to a
                mailbox you don't own*, and *a fresh link cancels the one already out*. All
                three describe a message that was never created, on the screen whose whole
                job is telling someone what did and did not happen to their account. The
                `@sends_left == 0` branch that used to carry the second half of it is not
                the same condition: the budget can be spent on a send that really went out
                (the reader arrived on the last one), which is the case that still gets the
                spam-folder advice. --%>
          <%= if @email_send_refused? do %>
            <p class="font-semibold text-ink">There is nothing to wait for.</p>
            <p class="mt-1">
              No message went to the address above, so no link will arrive and nothing is
              outstanding. Your account is untouched and you are still signed in with <span class="font-mono text-[11.5px]">{@current_email}</span>. Reloading this
              page is the only thing that gets you another send.
            </p>
          <% else %>
            <p class="font-semibold text-ink">Nothing after a minute or two?</p>
            <%!-- "The next link cancels this one" is a claim about
                `Accounts.deliver_user_update_email_instructions/3`, which now deletes every
                outstanding `change:<current_email>` token before inserting the new one. It
                did not until D-045: an unopened link stayed armed for seven days, so a
                typo'd address held a working token that moves this account's email onto a
                stranger's mailbox — and this screen said, on the recovery path built for
                exactly that moment, that it "simply expires unused". A false safety claim
                on an account-recovery path is the worst place in the app to be reassuring
                and wrong, so the code was changed rather than the sentence softened. Keep
                the two in step. --%>
            <%!-- The remedy is branched on the budget for the same reason the lede is: with
                the budget spent, "go back and change it, and send a fresh link" is an
                instruction that silently sends nothing. Reloading is the one thing that
                actually restores the budget — it is per-mount. --%>
            <p class="mt-1">
              Check the spam folder at the new address. If the address above has a typo in
              it, the link went to a mailbox you don't own —
              <%= if @sends_left > 0 do %>
                go back and change it, and send a fresh link to the right address: sending a
                new one cancels the one already out.
              <% else %>
                reload this page and start again, which is what gets you another send from
                here; a fresh link cancels the one already out.
              <% end %>
              You are still signed in with
              <span class="font-mono text-[11.5px]">{@current_email}</span>
              either way.
            </p>
          <% end %>
        </:fallback>
        <:actions>
          <.button
            :if={@sends_left > 0}
            variant="primary"
            type="button"
            phx-click="resend_email_change"
          >
            Send it again
          </.button>
          <%!-- Same split as the fallback: "that's the *last one* we'll send" and "check
                the spam folder" are both claims about a message, and on the refused branch
                there is no message. Only the remedy is common to the two. --%>
          <p
            :if={@sends_left == 0}
            id="email-change-resend-exhausted"
            class="text-center text-[13px] font-semibold text-ink-soft"
          >
            <%= if @email_send_refused? do %>
              This page has already sent every link it will send. Reload it to start again —
              going back and retyping the address will not send one from here.
            <% else %>
              That's the last one we'll send from this page. Check the spam folder, or reload
              this page to start again — going back and retyping the address will not send
              another from here.
            <% end %>
          </p>
          <button
            type="button"
            phx-click="back_to_settings"
            id="email-change-back"
            class="-my-2 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
          >
            Back to settings — the address was wrong
          </button>
        </:actions>
      </.check_your_email>

      <div
        :if={!@email_sent_to}
        class="mx-auto flex w-full max-w-sm flex-1 flex-col gap-6 px-6 pb-10 pt-6"
      >
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
            <%!-- Sentence case, like every other button verb in this app ("Create
                  account", "Send magic link", "Cast your vote", "Close now") — including
                  the two on this file's own success state. This screen carried Title Case
                  from the generator and so spoke two conventions four lines apart. --%>
            <.button type="submit" phx-disable-with="Saving…">Change username</.button>
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
          <%!-- Labelled for what pressing it does. "Change Email" changed nothing —
                `handle_event("update_email", …)` only delivers a link — and the state it
                produced had to open by bolding a negation ("Your address has **not**
                changed yet") to walk its own button's verb back. Now the button and the
                screen it produces ("Confirm the new address") agree. --%>
          <div class="grid">
            <.button type="submit" phx-disable-with="Sending…">Send a confirmation link</.button>
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
              Save password
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
      |> assign(:email_sent_to, nil)
      |> assign(:sends_left, @max_sends)
      # Whether the *most recent* arrival at the "check your email" state actually mailed
      # anything. Distinct from `sends_left == 0`, which is true on the last successful
      # send as well — see the lede's comment.
      |> assign(:email_send_refused?, false)
      |> assign(:username_draft?, false)
      |> assign(:email_draft?, false)
      |> assign(:password_draft?, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_username", %{"user" => user_params}, socket) do
    username_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_username(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> assign(
       :username_draft?,
       differs?(user_params["username"], socket.assigns.current_scope.user.username)
     )
     |> assign(:username_form, username_form)}
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
         |> assign(:username_draft?, false)
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

    {:noreply,
     socket
     |> assign(:email_draft?, differs?(user_params["email"], socket.assigns.current_email))
     |> assign(:email_form, email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        applied = Ecto.Changeset.apply_action!(changeset, :insert)

        socket = deliver_email_change(socket, applied, user.email)

        {:noreply,
         socket
         |> assign(:email_sent_to, applied.email)
         # The form is off the screen; nothing typed is now at risk of a footer tap.
         |> assign(:email_draft?, false)
         # A leftover green **Sent again.** from an earlier resend survives the round trip
         # through `back_to_settings` and repaints directly above "No link was sent." — two
         # sentences about the same account, 40px apart, saying opposite things. The flash
         # is true of the *previous* address and irrelevant to this screen either way, so
         # the refused branch drops it rather than trying to qualify it.
         |> then(&if(&1.assigns.email_send_refused?, do: clear_flash(&1), else: &1))}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  # A branch, not `true = Accounts.sudo_mode?(user)`. This screen's whole purpose is to be
  # left open while the reader goes to their inbox and comes back, so a long idle is the
  # *ordinary* path here — and a `MatchError` renders as "This page hit an error.
  # Attempting to reconnect." under a tangerine primary button. Same remedy
  # `ConsensusWeb.UserSessionController.update_password/2` already applies to the
  # generator's version of this line, now with the D-045 return trip on the end so the
  # re-auth comes back to this screen instead of dropping the person on `signed_in_path/1`.
  # Bounded like the other two resend buttons (`login.ex`, `registration.ex`) — the budget
  # and the reasoning live on `deliver_email_change/3`. The cap is a clause head, not just
  # a `:if` on the button, because a `phx-click` can be pushed at any socket the visitor can
  # mount.
  def handle_event("resend_email_change", _params, %{assigns: %{sends_left: left}} = socket)
      when left > 0 do
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      applied =
        user
        |> Accounts.change_user_email(%{"email" => socket.assigns.email_sent_to})
        |> Ecto.Changeset.apply_action!(:insert)

      {:noreply,
       socket |> deliver_email_change(applied, user.email) |> put_flash(:info, "Sent again.")}
    else
      {:noreply,
       socket
       |> put_flash(:error, "For security, log in again to change your email address.")
       |> push_navigate(to: ~p"/users/log-in?#{[return_to: ~p"/users/settings"]}")}
    end
  end

  # Exhausted. Sends nothing.
  def handle_event("resend_email_change", _params, socket) do
    {:noreply, socket}
  end

  # Back to the three forms, with the typed address still in the email field, because the
  # only reason to press this is to correct it.
  #
  # `email_draft?` has to be recomputed, not left as the `false` `update_email` set: the
  # field comes back holding the address that was typed and not saved, so the draft guard
  # would be disarmed on a form that demonstrably has something to lose — and typing that
  # very same string from scratch arms it. It is the same `differs?/2` the `validate_email`
  # handler uses, against the same stored address.
  def handle_event("back_to_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(:email_sent_to, nil)
     |> assign(
       :email_draft?,
       differs?(socket.assigns.email_sent_to, socket.assigns.current_email)
     )}
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    draft? =
      present?(user_params["password"]) or present?(user_params["password_confirmation"])

    {:noreply,
     socket
     |> assign(:password_draft?, draft?)
     |> assign(:password_form, password_form)}
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

  # The one place a change-address link is sent from this screen, and the one place the
  # per-mount budget is spent, so no future control can add a send that escapes the cap.
  #
  # This is the mildest of the app's three mail buttons — it is sudo-gated, and the address
  # is one the signed-in owner just typed — but it still mints mail on each press, and the
  # recipient is *not* necessarily an address they control: this is the flow for changing
  # **to** a new address, so a mistyped or hostile value lands in somebody else's inbox.
  # `update_email` shares the budget with `resend_email_change` for the same reason
  # `submit_magic` shares `login.ex`'s: both handlers send, an event can be pushed at any
  # socket the visitor can mount, and a cap on one of two identical primitives is not a cap.
  defp deliver_email_change(%{assigns: %{sends_left: left}} = socket, applied_user, current_email)
       when left > 0 do
    Accounts.deliver_user_update_email_instructions(
      applied_user,
      current_email,
      &url(~p"/users/settings/confirm-email/#{&1}")
    )

    socket
    |> assign(:sends_left, left - 1)
    |> assign(:email_send_refused?, false)
  end

  defp deliver_email_change(socket, _applied_user, _current_email),
    do: assign(socket, :email_send_refused?, true)

  @doc false
  def max_sends, do: @max_sends

  # -- the unsaved-draft guard (D-045) -------------------------------------------------

  # Three independent forms, so three independent answers to "is there anything here to
  # lose". One boolean recomputed by whichever handler fired last would clear the other
  # two forms' drafts on every keystroke.
  defp draft?(assigns),
    do: assigns.username_draft? or assigns.email_draft? or assigns.password_draft?

  defp discard_prompt,
    do: "Leave without saving? The changes you typed here haven't been applied."

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # Username and email arrive pre-filled with what is already stored, so "non-empty" is
  # not the question here — "different from what is saved" is.
  defp differs?(typed, stored) when is_binary(typed), do: String.trim(typed) != stored
  defp differs?(_typed, _stored), do: false
end
