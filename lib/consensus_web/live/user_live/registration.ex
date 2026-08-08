defmodule ConsensusWeb.UserLive.Registration do
  @moduledoc """
  Sign-up.

  The product offers two ways in, presented here as a deliberate choice rather than a
  form with an optional field:

    * **Username & password** — signs the new account in immediately by handing the
      form off to `ConsensusWeb.UserSessionController` (the `phx-trigger-action`
      pattern — a LiveView cannot write the session cookie itself). That is what makes
      the app usable on a fresh deploy that has no email provider configured yet.
    * **Email magic link** — no password is asked for. `Accounts.register_user/1` and
      `User.registration_changeset/3` are unchanged (invariant 6: the changeset casts
      exactly `[:email, :username, :password]` and still requires one), so a random
      value is generated here purely to satisfy that constraint — it is never shown,
      never logged, and never used to sign anyone in. The account is left unconfirmed
      and a login link is sent instead. Clicking that link discards the placeholder
      unconditionally, the same as any account that mixed magic-link and password
      registration (`Accounts.login_user_by_magic_link/1`, invariant 7).

  Neither path can ever set `is_admin`: everyone who registers is an organizer, and
  that is the absence of a role field, not the presence of one.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Accounts.User

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
          <.eyebrow>Register</.eyebrow>
          <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em]">
            Create your account
          </h1>
          <p class="text-[14.5px] leading-[1.45] text-ink-soft">
            Already have one?
            <.link
              navigate={~p"/users/log-in"}
              class="font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
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
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("choose_mode", %{"mode" => mode}, socket) do
    mode = if mode == "magic_link", do: :magic_link, else: :password
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    user_params = with_placeholder_password(socket.assigns.mode, user_params)

    case Accounts.register_user(user_params) do
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
    user_params = with_placeholder_password(socket.assigns.mode, user_params)

    changeset =
      Accounts.change_user_registration(%User{}, user_params,
        validate_unique: false,
        hash_password: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Password path: hand the (still populated) form over to the session controller so
  # the browser gets a signed session cookie — unchanged from before the two paths
  # existed.
  defp handle_registered(%{assigns: %{mode: :password}} = socket, user) do
    socket
    |> assign(:trigger_submit, true)
    |> assign_form(Accounts.change_user_registration(user))
  end

  # Magic-link path: no password was asked for, so there is nothing to sign in with —
  # the placeholder generated below never leaves this process and is never bound to
  # `@form`. The account stays unconfirmed until the link is clicked, and
  # `Accounts.login_user_by_magic_link/1` discards that placeholder unconditionally
  # the moment it does (invariant 7).
  defp handle_registered(%{assigns: %{mode: :magic_link}} = socket, user) do
    socket
    |> put_flash(
      :info,
      "Account created. We sent a sign-in link to #{user.email} — click it to finish."
    )
    |> push_navigate(to: ~p"/users/log-in")
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end

  # The changeset requires a password (invariant 6 keeps `registration_changeset/3`
  # itself unchanged), but the magic-link path never shows one. A random value
  # satisfies the constraint without ever being displayed, stored anywhere but its own
  # hash, or usable to log in.
  defp with_placeholder_password(:magic_link, params),
    do: Map.put(params, "password", random_password())

  defp with_placeholder_password(:password, params), do: params

  defp random_password, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
end
