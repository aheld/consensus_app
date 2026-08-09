defmodule ConsensusWeb.UserLive.Login do
  @moduledoc """
  Log in — by magic link, or by username-or-email and password.

  Both forms post to the same `ConsensusWeb.UserSessionController`. The magic-link
  form never discloses whether the address is registered (see `submit_magic/2`); the
  password form accepts either an email address or a username in one field.

  ## The magic-link screen after the send

  Sending a magic link used to `put_flash` and `push_navigate` back to *this same form*:
  a transient strip over a screen that still looked exactly like the one just acted on,
  and the next real step is off-site — go and open your email. That reads as "nothing
  happened", and D-045 makes it a full-page state of this LiveView (`@send_state`) instead
  of a route: a success screen with its own URL is a page a reader can bookmark and come
  back to out of context, claiming a link was sent when none was.

  ## `@send_state` has exactly three values, and that is the point

  This screen has three honest outcomes and it used to be able to render only two, which
  is how it came to tell a lie:

    * `nil` — nothing has been submitted on this mount. The form is shown.
    * `{:sent, address}` — a `login` token was minted and mailed to `address`.
    * `{:refused, address}` — `address` was submitted **after the per-mount budget was
      spent**, so nothing was minted and nothing was mailed.

  The third case used to collapse into the second: `deliver_magic_link/2`'s refused clause
  assigned the same `@sent_to` the sending clause did, so submitting a *corrected* address
  past the cap rendered the full "Check your email" panel — heading, spam-folder advice
  and all — for an address that received nothing. Measured against the real LiveView:
  `users_tokens where context = 'login'` before = 4, after = 4, with `id="magic-link-sent"`
  and the never-mailed address both in the returned HTML. That is worse than the unbounded
  send the cap replaced, because the person who mistyped their address, corrected it and
  pressed send is told a link is on its way and will wait forever.

  It is **one** assign rather than an address plus a `refused?` flag so the impossible
  fourth combination cannot be constructed. `deliver_magic_link/2` is its only writer.
  (`{:refused, _}` additionally implies `@sends_left == 0`, because that clause only
  matches an exhausted budget — the template relies on that and nothing else may write it.)

  **The enumeration property is preserved and must stay preserved.** The screen renders
  from the address that was *typed into this browser* — `deliver_magic_link/2` stores it
  unconditionally, on exactly the same code path, whether or not
  `Accounts.get_user_by_email/1` found anything — and which of the three states is reached
  is a function of presses in this browser, never of the address. So a registered and an
  unregistered address produce byte-identical output in all three: same heading, same
  hedged sentence, same controls, same timing, same exhaustion count. Do not add a "we
  couldn't find that address" state, a different heading for a known address, or a
  delivery receipt.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts

  # How many magic links this screen will send **per mount, across every control on it**.
  # See the `deliver_magic_link/2` clauses for why a cap and the enumeration property are
  # not in tension.
  #
  # The budget is shared by `submit_magic` and `resend_magic` on purpose. Capping only the
  # resend button left the cap trivially bypassable: `submit_magic` mints a login token and
  # mails an attacker-chosen address exactly like `resend_magic` does, and over an open
  # socket pushing one costs no more than pushing the other — so a limit on one of the two
  # is not a limit. Four is one initial send plus three, which is more correction attempts
  # than the "Use a different address" loop realistically needs.
  @max_sends 4

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `:app`, not `:marketing`: this is one of the app's own screens a signed-out
          person is standing on, and its `⋯` offers "Log in / Start something" (plan
          ruling 4). The wordmark link that used to head this column is now the global
          header's, and the way back is its `‹`. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
    >
      <%!-- Every string below is a pure function of the address that was typed *into this
            browser* and of how many times this browser has pressed send. Nothing here is
            conditioned on whether an account exists — see the moduledoc. "If … is in our
            system" is the same non-committal sentence the flash carried, kept verbatim for
            exactly that reason.

            **The `id` is part of the honesty, not decoration.** `#magic-link-sent` means a
            link was minted and mailed; a refusal renders `#magic-link-not-sent` instead, so
            "did this page claim to have sent something?" is answerable by address rather
            than by reading the copy. `sent?={false}` additionally suppresses the component's
            own dev-mailbox card, whose "the message is waiting in the local mailbox" is
            exactly as false as the spam-folder advice when no message was ever created —
            the same flag `UserLive.Settings` passes on the same branch. --%>
      <.check_your_email
        :if={@send_state}
        id={if sent?(@send_state), do: "magic-link-sent", else: "magic-link-not-sent"}
        heading={if sent?(@send_state), do: "Check your email", else: "Nothing was sent"}
        address={typed_address(@send_state)}
        sent?={sent?(@send_state)}
      >
        <:lede>
          <%!-- Branched on what happened, never on the address — which of the three states
                this is depends only on presses in this browser, so a registered and an
                unregistered address reach the same one at the same count with the same
                bytes. The branch exists because the first sentence is false on a send the
                cap refused: the screen used to say a link was on its way to an address that
                had received nothing. --%>
          <%= if sent?(@send_state) do %>
            If that address is in our system, a sign-in link is on its way to it. Open the
            email and tap the link — it signs you in on whichever device you open it on.
          <% else %>
            No link was sent. This page has already sent as many as it will, and reloading
            it is the only thing that gets you another. Anything it sent earlier still
            works — open the most recent email and tap that link. The address you typed was:
          <% end %>
        </:lede>
        <:fallback>
          <%= if sent?(@send_state) do %>
            <p class="font-semibold text-ink">Nothing after a minute or two?</p>
            <%!-- Says what to do, in the reader's terms. It used to end by explaining its
                  own drafting ("we can't tell you which, which is why the sentence above
                  hedges") — the copy stepping out of the app's voice to narrate itself. The
                  enumeration property is a property of the *code path*, unchanged and
                  pinned by `login_test.exs`; it does not need announcing to be true. --%>
            <%!-- **The tail is branched on the budget, because the control it named is
                  gone.** With the budget spent this paragraph told the reader to "send it
                  again" 40px under `#magic-link-resend-exhausted` saying that is the last
                  one we will send, and directly under the place the Send-it-again button
                  had just been removed from: the screen instructing a press it had itself
                  taken away. Only the remedy differs; the diagnosis is the same either
                  way. --%>
            <p class="mt-1">
              Check the spam folder first. If nothing arrives, the address probably has a
              typo in it, or no account here —
              <%= if @sends_left > 0 do %>
                send it again, or use a different address.
              <% else %>
                use the way out below.
              <% end %>
            </p>
          <% else %>
            <p class="font-semibold text-ink">There is nothing to wait for.</p>
            <p class="mt-1">
              No message was created for the address above, so none will arrive and there is
              no spam folder to check. Nothing about any account changed.
            </p>
          <% end %>
        </:fallback>
        <:actions>
          <.button
            :if={@sends_left > 0}
            variant="primary"
            type="button"
            phx-click="resend_magic"
          >
            Send it again
          </.button>
          <%!-- Replaces the button rather than disabling it, and says the same thing for
                every address — a registered and an unregistered one exhaust the cap at the
                same count with the same line, so nothing here is observable by address.
                Split on which of the two exhausted states this is: "that's the last one
                we'll send" and "check the spam folder" are both claims about a message, and
                on the refused branch there is no message. Same split `UserLive.Settings`
                makes on its own `#email-change-resend-exhausted`. --%>
          <p
            :if={@sends_left == 0}
            id="magic-link-resend-exhausted"
            class="text-center text-[13px] font-semibold text-ink-soft"
          >
            <%= if sent?(@send_state) do %>
              That's the last one we'll send from this page. Whatever it already sent is
              still valid.
            <% else %>
              This page has already sent every link it will send. Retyping the address here
              will not send another.
            <% end %>
          </p>
          <%!-- **One secondary control in every state, with one label and a mechanism that
                always keeps it.** While there is budget left it is a `phx-click` back to the
                form, which is the point of offering it — correcting a typo. With the budget
                spent that same button led back to a form whose magic-link submit silently
                refused, which is the loop this whole item is about; there it is a real HTTP
                navigation instead, so the LiveView remounts and the per-mount budget is
                fresh. That is exactly the "reload this page" the copy has always
                prescribed — no cheaper, so the cap costs an attacker the same as before —
                and the password form is on the far side either way. --%>
          <button
            :if={@sends_left > 0}
            type="button"
            phx-click="edit_email"
            id="magic-link-edit-email"
            class={way_out_class()}
          >
            Use a different address, or log in with a password
          </button>
          <.link
            :if={@sends_left == 0}
            href={~p"/users/log-in"}
            id="magic-link-start-over"
            class={way_out_class()}
          >
            Use a different address, or log in with a password
          </.link>
        </:actions>
      </.check_your_email>

      <div
        :if={!@send_state}
        class="mx-auto flex w-full max-w-sm flex-1 flex-col gap-6 px-6 pb-10 pt-6"
      >
        <div class="flex flex-col gap-2">
          <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em]">Log in</h1>
          <p class="text-[14.5px] leading-[1.45] text-ink-soft">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Don't have an account?
              <%!-- `inline-block py-[13px] -my-[13px]`: measured 41×19, under the 24px
                    floor, on the one link that recovers a person who tapped the wrong
                    entry point of the two this app has. The negative margin cancels the
                    padding so the baseline does not move and the paragraph keeps its
                    height; `active:` because a hover colour is no feedback at all on
                    touch. Same shape as `#register-log-in-link`. --%>
              <.link
                navigate={~p"/users/register"}
                id="login-register-link"
                class="-my-[13px] inline-block py-[13px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine active:text-tangerine"
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
            <p class="font-bold">Development build — nothing is really sent.</p>
            <%!-- The link body is on one line and the full stop is welded to the closing
                  tag: broken across lines the anchor's text node carries the surrounding
                  whitespace and the screen reads "the local mailbox ." with the underline
                  overhanging the word (CLAUDE.md invariant 11 / D-026, the same trap
                  `core_components.ex`'s `check_your_email/1` was corrected for). The wording
                  matches that component's dev notice too — one tap apart, they used to say
                  "You are running the local mail adapter" and "Development build — nothing
                  is really sent" respectively, which is implementation jargon beside plain
                  English for the same fact. --%>
            <%!-- Present tense about the *adapter*, not past tense about a message. This
                  card renders on the **form**, before anything has been submitted, so
                  "The message is waiting in the local mailbox" — the wording
                  `check_your_email/1` uses, correctly, on the screen that only appears
                  after a send — asserted a message that does not exist yet. Same fact,
                  stated as the standing condition it is. --%>
            <p>
              Mail goes to <.link
                href="/dev/mailbox"
                class="font-semibold underline decoration-2 underline-offset-2"
              >the local mailbox</.link>, not to a real inbox.
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
            <%!-- Labelled for what pressing it does, the standard `settings.ex` applies to
                  its own buttons: nothing here logs anyone in — the press mints a token,
                  mails it, and swaps this screen for "Check your email". "Send magic link"
                  is also the label `registration.ex` already gives the identical action,
                  so the same press no longer has two names one tap apart. --%>
            <.button variant="primary" type="submit">
              Send magic link
            </.button>
          </div>
          <%!-- The counterpart to the password form's promise below. This form posts no
                `return_to` on purpose (the link is designed to be opened wherever the
                mailbox is, which may be a different device), so it cannot complete the
                trip — and the promise used to sit in the shared header paragraph directly
                above *this* button, which made it read as a promise about the one form
                that does not keep it. --%>
          <p :if={@return_to} class="text-[11.5px] leading-[1.35] text-muted">
            A magic link signs you in wherever you open it — it won't bring you back to
            what you were doing here.
          </p>
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
          <%!-- The re-authentication return trip (D-045). Only this form carries it: the
                magic-link form above is handled in the LiveView and its link is designed to
                be opened wherever the mailbox is, which may be a different device — see the
                moduledoc. `UserAuth.store_return_to/2` validates it server-side; a hidden
                field is client-supplied by definition and is treated as such. --%>
          <input :if={@return_to} type="hidden" name="user[return_to]" value={@return_to} />
          <%!-- The promise, rendered inside the only form that keeps it and naming that
                form the way `AdminLive.Users`' flash already does. Deliberately no path
                echo: an attacker can put anything in `?return_to=`, and while it is
                validated to an internal path and HEEx escapes it, printing a stranger's
                string on the log-in screen buys nothing. --%>
          <p :if={@return_to} class="text-[13px] font-semibold leading-[1.35] text-ink">
            Logging in with your password brings you straight back to where you were.
          </p>
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
          <%!-- Measured 312×19.5 with a 20px hit box, 12px under the 60px "stay logged
                in" button: a finger aiming here and missing high lands on the *other*
                branch, and the wrong outcome is a persistent session on what may be a
                shared device, with nothing on screen saying so. Grown to a real 44px box
                (no negative margin here — the point is to push it *away* from the primary
                button, not to keep it where it was), with `mt-1` on top of the form's
                `gap-3` opening the gap to 16px so an overshoot lands on neither. --%>
          <button
            type="submit"
            class="mt-1 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
          >
            Log in only this time
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
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

    {:ok,
     assign(socket,
       page_title: "Log in",
       form: form,
       trigger_submit: false,
       send_state: nil,
       sends_left: @max_sends,
       return_to: ConsensusWeb.CurrentPath.safe_return_to(params["return_to"])
     )}
  end

  # The three states, read back. `@send_state` is the only assign that says which one this
  # is; see the moduledoc for why it is one assign and not an address plus a flag.
  defp sent?({:sent, _address}), do: true
  defp sent?(_send_state), do: false

  defp typed_address({_outcome, address}), do: address
  defp typed_address(nil), do: nil

  # The 44px secondary shared by the two forms of the one way out — same label, same look,
  # different mechanism (see the call site).
  defp way_out_class do
    "-my-2 inline-flex min-h-[44px] items-center justify-center text-center text-[13px] " <>
      "font-semibold text-muted underline decoration-2 underline-offset-2 hover:text-ink active:text-ink"
  end

  defp email_or_nil(nil), do: nil

  defp email_or_nil(login) do
    if String.contains?(login, "@"), do: login, else: nil
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  # On the same budget as the resend button, and for the same reason: this handler mints a
  # `login` token and mails whatever address is in the payload, and an event can be pushed
  # at any socket a visitor can mount, so a cap that only covered the *button* was not a cap
  # at all. `deliver_magic_link/2` is the single place the budget is spent.
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    {:noreply, deliver_magic_link(socket, email)}
  end

  # Re-enters the identical branch with the identical argument. There is deliberately no
  # "we already sent one" state and no rate-limit *message*: either would be observable
  # behaviour that differs by address, which is the enumeration leak this screen exists
  # to avoid re-introducing.
  #
  # It is bounded all the same, and the two concerns do not conflict — see
  # `deliver_magic_link/2`, which holds the budget and the reasoning. Unbounded, this was an
  # inbox-flooding primitive: the endpoint is unauthenticated, the recipient is whatever the
  # visitor typed, and each press mints a real sign-in link carrying this app's From:
  # domain. Measured before the cap: 13 live `login` tokens to one address from one sitting.
  def handle_event("resend_magic", _params, %{assigns: %{sends_left: left}} = socket)
      when left > 0 do
    {:noreply,
     socket
     |> deliver_magic_link(typed_address(socket.assigns.send_state))
     |> put_flash(:info, "Sent again.")}
  end

  # Exhausted, and reached only by a forged press — the button is gone at this point. It
  # goes through the same `deliver_magic_link/2` as everything else rather than returning
  # the socket untouched, so a refusal is *visible* as a refusal: the screen flips from
  # "Check your email" to "Nothing was sent" for the same address instead of appearing to
  # have resent. Sends nothing, and says nothing that varies by address.
  def handle_event("resend_magic", _params, socket) do
    {:noreply, deliver_magic_link(socket, typed_address(socket.assigns.send_state))}
  end

  # Back to the form, with the address still in it — the whole point of offering this is
  # correcting a typo, so blanking the field would make the person retype the very thing
  # they came back to fix. `@form` was built at mount and never saw the submission, so it
  # is re-seeded from `@send_state` here; `login` keeps whatever was typed into the password
  # form, which may be a username and must not be overwritten with an address.
  def handle_event("edit_email", _params, socket) do
    email = typed_address(socket.assigns.send_state)
    login = socket.assigns.form.params["login"] || email
    form = to_form(%{"email" => email, "login" => login}, as: "user")

    {:noreply, socket |> assign(:send_state, nil) |> assign(:form, form)}
  end

  # The one place a magic link is sent from this screen, and the one place the per-mount
  # budget is spent — so no future control can add a send that escapes the cap.
  #
  # The guard is a clause head rather than only a `:if` on the button, because a `phx-click`
  # can be pushed at any socket the visitor can mount — the same reason the sudo-mode
  # `disabled` attributes in `AdminLive.Users` are a courtesy and `Consensus.Accounts` is
  # the enforcement (CLAUDE.md invariant 5).
  #
  # **The two clauses reach two different states, and that is the whole of item 1's fix.**
  # The refused clause used to assign the same `@sent_to` the sending clause did, so the
  # screen rendered "Check your email" over an address nothing had been mailed to. It now
  # says `{:refused, email}` and the template draws a different panel from it.
  #
  # `email` is stored on the same line in both, whatever happened: whether an account
  # exists, and whether the budget allowed a send, are both invisible from here. The budget
  # is a function of presses in *this* browser, not of the address, so a registered and an
  # unregistered address reach the same state at the same count with byte-identical output.
  # Note that the refused clause never calls `Accounts.get_user_by_email/1` at all, so it
  # cannot be timed either.
  defp deliver_magic_link(%{assigns: %{sends_left: left}} = socket, email) when left > 0 do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    socket |> assign(:send_state, {:sent, email}) |> assign(:sends_left, left - 1)
  end

  # `clear_flash/2` for the same reason `UserLive.Settings` clears one on its own refused
  # branch (D-048 §2), and it was caught in a browser rather than by the suite: the previous
  # press flashes a green **Sent again.**, the flash group is `sticky` and outlives a
  # re-render, so the refusal painted "Nothing was sent" directly under a card asserting that
  # something had been. Only `:info` — an error flash on this screen would still be true.
  defp deliver_magic_link(socket, email) do
    socket |> clear_flash(:info) |> assign(:send_state, {:refused, email})
  end

  @doc false
  def max_sends, do: @max_sends

  defp local_mail_adapter? do
    Application.get_env(:consensus, Consensus.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
