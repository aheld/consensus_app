defmodule ConsensusWeb.Layouts do
  @moduledoc """
  Layouts and the app shell.

  The design (see `docs/design/DESIGN-SPEC.md`) is phone-first and has **no persistent
  navigation bar** — every screen draws its own header, because the headers differ:
  the home screen has a wordmark and an avatar, the wizard steps have a back button and a
  progress bar, and the option editor has a close button. So `app/1` is only the canvas,
  the centred column and the flash group. Screens that want an account menu render
  `account_menu/1` themselves.
  """
  use ConsensusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

  `width` picks the column: `:phone` (the default) is the 440px column every design frame
  was drawn at; `:wide` is for the desktop organizer console, which is a genuinely
  different layout rather than the phone column stretched.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :width, :atom, values: [:phone, :wide], default: :phone
  attr :background, :string, default: "bg-surface", doc: "canvas behind the column"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class={["min-h-dvh", @background]}>
      <div class={[
        "mx-auto flex min-h-dvh w-full flex-col",
        @width == :phone && "max-w-[440px]",
        @width == :wide && "max-w-[1280px]"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The circular avatar the design puts in the top right of the home screen.

  Renders the first character of the username, so it is stable and needs no upload.
  """
  attr :user, :map, required: true
  attr :size, :integer, default: 34
  attr :class, :string, default: nil
  attr :rest, :global

  def avatar(assigns) do
    ~H"""
    <span
      class={[
        "grid shrink-0 place-items-center rounded-full border-2 border-ink bg-peach font-bold",
        @class
      ]}
      style={"width:#{@size}px;height:#{@size}px;font-size:#{round(@size * 0.38)}px"}
      aria-hidden="true"
      {@rest}
    >{initial(@user)}</span>
    """
  end

  defp initial(%{username: username}) when is_binary(username) and username != "",
    do: String.upcase(String.first(username))

  defp initial(_), do: "?"

  @doc """
  The account menu — avatar, name, settings, log out, and the admin link for administrators.

  A `<details>` element rather than a JS dropdown so it works before LiveView connects and
  closes on Escape without any of our own code.
  """
  attr :current_scope, :map, required: true

  def account_menu(assigns) do
    ~H"""
    <details :if={@current_scope && @current_scope.user} class="relative" id="account-menu">
      <summary class="grid cursor-pointer list-none place-items-center rounded-full [&::-webkit-details-marker]:hidden">
        <.avatar user={@current_scope.user} />
        <span class="sr-only">Account menu for {@current_scope.user.username}</span>
      </summary>
      <div class="absolute right-0 top-[42px] z-30 w-56 rounded-2xl border-2 border-ink bg-white p-2 shadow-sticker-3">
        <p class="truncate px-3 pb-2 pt-1 font-mono text-[11px] text-muted">
          {@current_scope.user.email}
        </p>
        <.link
          :if={admin?(@current_scope)}
          navigate={~p"/admin/users"}
          class="block rounded-xl px-3 py-2 text-sm font-semibold hover:bg-yellow"
        >
          Admin
        </.link>
        <.link
          href={~p"/users/settings"}
          class="block rounded-xl px-3 py-2 text-sm font-semibold hover:bg-yellow"
        >
          Settings
        </.link>
        <.link
          href={~p"/users/log-out"}
          method="delete"
          class="block rounded-xl px-3 py-2 text-sm font-semibold hover:bg-yellow"
        >
          Log out
        </.link>
      </div>
    </details>
    """
  end

  @doc """
  Returns true when the given scope belongs to a signed-in administrator.

  Safe to call with `nil`, which is what a public page passes before anyone logs in.
  """
  def admin?(%Consensus.Accounts.Scope{user: %Consensus.Accounts.User{is_admin: true}}), do: true
  def admin?(_scope), do: false

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
