defmodule ConsensusWeb.UserLive.Registration do
  @moduledoc """
  Sign-up.

  The product offers two ways in, presented here as a deliberate choice rather than a
  form with an optional field:

    * **Username & password** — signs the new account in immediately by handing the
      form off to `ConsensusWeb.UserSessionController` (the `phx-trigger-action`
      pattern — a LiveView cannot write the session cookie itself). That is what makes
      the app usable on a fresh deploy that has no email provider configured yet.
    * **Email magic link** — no password is asked for, and none is stored:
      `Accounts.register_user/2` is called with `require_password: false`, so the row
      lands with `hashed_password` nil. The account is left unconfirmed and a login link
      is sent instead; opening it confirms the account and signs the person in
      (`Accounts.login_user_by_magic_link/1`, invariant 7), and a password can be set
      later from Settings. Invariant 6 is untouched — `User.registration_changeset/3`
      still casts exactly `[:email, :username, :password]`; only the `validate_required`
      on `:password` is lifted.

      **This used to inject a random placeholder password** to satisfy that
      `validate_required`. It made `hashed_password` non-nil, which is the *only* thing
      `ConsensusWeb.UserSessionController.clears_password?/1` reads — so every
      magic-link registration was greeted, on its first ever sign-in, with "the password
      that was set on this account has been removed — choose a new one under Settings",
      contradicting the screen it had just been shown and naming a password the person
      had never chosen. That controller's own comment says the warning must not cry
      wolf; it was crying wolf on 100% of the app's no-password signups. Do not
      reintroduce the placeholder.

  Neither path can ever set `is_admin`: everyone who registers is an organizer, and
  that is the absence of a role field, not the presence of one.

  ## After the magic-link path

  The account is created but the person cannot do anything with it until they open their
  inbox — an off-site next step. That used to be a flash plus a `push_navigate` to the
  log-in form, i.e. a strip over a screen that looks like a *different* form, with the
  account it just created nowhere on it. It is now a full-page state of this LiveView
  (`@sent_to`), per D-045. No route: a bookmarkable `/registered` would claim a send that
  never happened for whoever opened it.

  There is no enumeration concern on this path, unlike `UserLive.Login` — the account
  demonstrably exists, because this process just created it — so the copy here can be
  definite where the log-in screen's must hedge.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Accounts.User

  # How many times the sent screen will re-send the magic link. See `handle_event("resend", …)`.
  @max_resends 2

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
      back_confirm={@draft? && discard_prompt()}
      footer_confirm={@draft? && discard_prompt()}
    >
      <.check_your_email
        :if={@sent_to}
        id="registration-sent"
        heading="Account created — one tap left"
        address={@sent_to}
      >
        <:lede>
          You picked the no-password way in, so there is nothing to log in with yet. We
          sent a sign-in link to:
        </:lede>
        <:fallback>
          <p class="font-semibold text-ink">Nothing after a minute or two?</p>
          <%!-- **Branched on the same budget the button branches on.** Unbranched, this told
                the reader to "send it again" while `#registration-sent-resend-exhausted`
                40px below said that is as many as we will send — and while the control it
                named had just been removed from the screen. A screen instructing a press it
                has itself taken away is the same defect `UserLive.Login` carried on its own
                fallback; only the remedy differs between the two branches here, so the
                diagnosis stays put. --%>
          <%= if @resends_left > 0 do %>
            <p class="mt-1">
              Check the spam folder, then send it again — the account is already yours and
              resending is harmless.
            </p>
          <% else %>
            <p class="mt-1">
              Check the spam folder — the account is already yours either way, so nothing is
              lost while you look.
            </p>
          <% end %>
          <%!-- The address on a written row cannot be edited from here: this account is
                unconfirmed and password-less, so there is nobody to authenticate as in
                order to change it, and nothing in `/admin/users` can edit an address
                either (promote, demote and delete are the only levers). The first cut of
                this said "tell us and we will sort it out" and linked to `/feedback`,
                whose own confirmation screen says nothing is emailed to anyone — a
                remedy with no mechanism behind it, offered to someone who has just
                mistyped the only address they could be answered at. Registering again is
                the remedy that actually exists, so it is the one named, along with the
                one thing that will stop it working. --%>
          <%!-- **The reassurance here used to be false, in the one sentence written to
                stop the reader worrying.** It said "Nothing was confirmed to it and nobody
                can sign in with it" — twenty lines under "We sent a sign-in link to:" and
                that same address. `handle_event("save", …)` calls
                `Accounts.deliver_login_instructions/2` unconditionally, and
                `Accounts.login_user_by_magic_link/1` confirms the account and signs the
                holder in (invariant 7). Whoever owns a mistyped mailbox can take this
                account, under the username the registrant chose. Say the true thing, and
                say what to do about it. --%>
          <p class="mt-2">
            <span class="font-semibold text-ink">Is the address wrong?</span>
            That link works, so whoever owns that mailbox could take this account. Register
            again with the right address — you will need a different username, because
            <span class="font-semibold text-ink">{@created_user.username}</span>
            is taken now — and tell an admin about the wrong one.
          </p>
        </:fallback>
        <:actions>
          <%!-- Bounded. Each press mints a login token and sends mail to an address this
                app has not verified, so an unbounded button on an unauthenticated screen is
                a mail cannon aimed at any third party whose address someone types in. The
                enumeration argument that shapes `UserLive.Login`'s copy does not apply here
                — this path knows the account exists, it just created it — so the limit can
                be stated plainly rather than hidden. --%>
          <.button
            :if={@resends_left > 0}
            variant="primary"
            type="button"
            phx-click="resend"
            id="registration-sent-resend"
          >
            Send the link again
          </.button>
          <p
            :if={@resends_left == 0}
            id="registration-sent-resend-exhausted"
            class="text-center text-[13px] font-semibold text-ink"
          >
            That is as many as we will send. If the address was wrong, register again below
            with a different one.
          </p>
          <%!-- Its own 44px control, not an inline link inside the paragraph above.
                Measured there at 267.9×33.8 painted but wrapping into two 15px line boxes,
                so a tap at its geometric centre landed in the inter-line gap and hit the
                paragraph. Its two sibling sent-screens (`UserLive.Login`, `UserLive.Settings`)
                both give this same job a 312×44 secondary; registration was the outlier. --%>
          <.link
            navigate={~p"/users/register"}
            id="registration-sent-restart"
            class="-my-2 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
          >
            Register again — the address was wrong
          </.link>
          <.link
            navigate={~p"/users/log-in"}
            id="registration-sent-log-in"
            class="-my-2 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
          >
            Go to the log-in screen
          </.link>
        </:actions>
      </.check_your_email>

      <div
        :if={!@sent_to}
        class="mx-auto flex w-full max-w-sm flex-1 flex-col gap-6 px-6 pb-10 pt-6"
      >
        <div class="flex flex-col gap-2">
          <.eyebrow>Register</.eyebrow>
          <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em]">
            Create your account
          </h1>
          <p class="text-[14.5px] leading-[1.45] text-ink-soft">
            Already have one?
            <%!-- `inline-block py-[13px] -my-[13px]`: measured 41×19, under the 24px floor,
                  on the one link that recovers a person who tapped the wrong entry point.
                  The negative margin cancels the padding so the baseline and the paragraph
                  height do not move; `active:` because hover is no feedback on touch. --%>
            <%!-- The one exit the draft guard missed. With text typed into USERNAME,
                  `document.querySelectorAll('[data-confirm]')` returned 7 nodes — the
                  header `‹`, both footer faces, the three standing links and the credit —
                  and not this one, which sits directly above the form and is the single
                  most likely reason to leave this screen mid-typing. Same `@draft?`
                  expression `back_confirm` and `footer_confirm` use, worded for where it
                  actually goes. (`settings.ex` and `group_live/new.ex` are the other two
                  screens holding a draft; neither has an in-page nav link, so this was the
                  only gap.) --%>
            <.link
              navigate={~p"/users/log-in"}
              id="register-log-in-link"
              data-confirm={@draft? && "Log in instead? What you typed here isn't saved."}
              class="-my-[13px] inline-block py-[13px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine active:text-tangerine"
            >
              Log in
            </.link>
          </p>
        </div>

        <div role="group" aria-label="How do you want to sign up" class="flex flex-col gap-2">
          <.eyebrow>How do you want to sign up?</.eyebrow>
          <div class="flex gap-2">
            <.chip phx-click="choose_mode" phx-value-mode="password" selected={@mode == :password}>
              Username &amp; password
            </.chip>
            <.chip
              phx-click="choose_mode"
              phx-value-mode="magic_link"
              selected={@mode == :magic_link}
            >
              Email magic link
            </.chip>
          </div>
          <p class="text-[11.5px] leading-[1.4] text-muted">
            <%= if @mode == :password do %>
              A password signs you in immediately.
            <% else %>
              No password — we email you a one-tap sign-in link instead.
            <% end %>
          </p>
        </div>

        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          method="post"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          class="flex flex-col gap-4"
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

          <div :if={@mode == :password} class="flex flex-col gap-1.5">
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <p class="text-[11.5px] text-muted">
              At least {User.min_password_length()} characters.
            </p>
          </div>

          <div class="grid">
            <.button variant="primary" type="submit" phx-disable-with="Creating account…">
              {if @mode == :password, do: "Create account", else: "Send magic link"}
            </.button>
          </div>
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
     |> assign(:mode, :password)
     |> assign(:trigger_submit, false)
     |> assign(:sent_to, nil)
     |> assign(:created_user, nil)
     |> assign(:resends_left, @max_resends)
     |> assign(:draft?, false)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("choose_mode", %{"mode" => mode}, socket) do
    mode = if mode == "magic_link", do: :magic_link, else: :password
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params, changeset_opts(socket.assigns.mode)) do
      {:ok, user} ->
        # Best-effort: this is what lets the account become "confirmed" once an email
        # provider is configured. A mailer that is missing or down must not fail the
        # sign-up — `UserNotifier` logs the failure; see docs/decisions.md.
        _ = Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

        {:noreply, handle_registered(socket, user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    draft? = Enum.any?(~w(username email password), &present?(user_params[&1]))

    changeset =
      Accounts.change_user_registration(
        %User{},
        user_params,
        [validate_unique: false, hash_password: false] ++ changeset_opts(socket.assigns.mode)
      )

    {:noreply,
     socket
     |> assign(:draft?, draft?)
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  # Sends the same link `handle_registered/2` sent, to the account this process created.
  #
  # Bounded by `@max_resends`, and the guard is here rather than only on the button:
  # `disabled` (or an absent) control is a client-side hint and this event can be pushed
  # from a console at any rate the socket allows. Registration does not verify the address
  # before mailing it, so the thing being rate-limited is "send mail to an arbitrary
  # third party", not "annoy yourself".
  def handle_event("resend", _params, %{assigns: %{resends_left: left}} = socket)
      when left > 0 do
    _ =
      Accounts.deliver_login_instructions(
        socket.assigns.created_user,
        &url(~p"/users/log-in/#{&1}")
      )

    {:noreply,
     socket
     |> assign(:resends_left, left - 1)
     |> put_flash(:info, "Sent again.")}
  end

  def handle_event("resend", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "That is as many as we will send. Register again with a different address if this one is wrong."
     )}
  end

  # Password path: hand the (still populated) form over to the session controller so
  # the browser gets a signed session cookie — unchanged from before the two paths
  # existed.
  defp handle_registered(%{assigns: %{mode: :password}} = socket, user) do
    socket
    |> assign(:trigger_submit, true)
    |> assign_form(Accounts.change_user_registration(user))
  end

  # Magic-link path: no password was asked for and none was stored, so there is nothing
  # to sign in with. The account stays unconfirmed until the link is clicked, and
  # `Accounts.login_user_by_magic_link/1` confirms it then (invariant 7) without any
  # password to discard — which is what keeps the session controller's
  # "your password was removed" warning off this, the ordinary path.
  defp handle_registered(%{assigns: %{mode: :magic_link}} = socket, user) do
    socket
    |> assign(:created_user, user)
    |> assign(:sent_to, user.email)
    # The form is gone from the screen and the account is written, so there is no longer
    # anything unsaved to warn about — leaving the prompt armed here would fire on the
    # sent screen's own "Go to the log-in screen" link.
    |> assign(:draft?, false)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end

  # The one difference between the two modes at the changeset level. See the moduledoc:
  # a magic-link account is deliberately password-less, not password-placeholder-ed.
  defp changeset_opts(:magic_link), do: [require_password: false]
  defp changeset_opts(:password), do: []

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # The global footer and the header `‹` are both `navigate`s: tapping one remounts this
  # LiveView and the typing is gone, with no confirm and no undo (D-045). Armed only once
  # there is something to lose, the shape `JoinLive.Ballot` uses for `pill_confirm`.
  defp discard_prompt, do: "Leave without creating your account? What you typed isn't saved."
end
