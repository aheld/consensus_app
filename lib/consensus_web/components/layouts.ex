defmodule ConsensusWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ConsensusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar flex-wrap gap-y-1 border-b border-base-300 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex w-fit items-center gap-2 text-lg font-semibold">
          <img src={~p"/images/logo.svg"} width="28" alt="" /> Consensus
        </.link>
      </div>

      <%!-- `min-w-0` rather than the generator's `flex-none`: `flex-none` is
            `flex: 0 0 auto`, which sizes this group to the nav list's max-content width
            and refuses to shrink, so at 375px a signed-in admin (Admin · name · Settings ·
            Log out · theme toggle = 396px of items) pushed the document to 411px and the
            toggle's dark segment off-screen. Shrinking here is what lets the `flex-wrap`
            on the header and on the `<ul>` below actually fire; with `flex-none` both were
            dead code. Guarded by "the navbar is allowed to wrap on a narrow screen" in
            test/consensus_web/live/home_live_test.exs. --%>
      <div id="user-nav" class="min-w-0">
        <ul class="flex flex-wrap items-center justify-end gap-1 px-1">
          <li :if={admin?(@current_scope)}>
            <.link navigate={~p"/admin/users"} class="btn btn-ghost btn-sm">Admin</.link>
          </li>
          <%= if @current_scope && @current_scope.user do %>
            <li class="px-2 text-sm opacity-70" title={@current_scope.user.email}>
              {@current_scope.user.username}
            </li>
            <li>
              <.link href={~p"/users/settings"} class="btn btn-ghost btn-sm">Settings</.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Log out
              </.link>
            </li>
          <% else %>
            <li>
              <.link href={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
            </li>
            <li>
              <.link href={~p"/users/register"} class="btn btn-primary btn-sm">Register</.link>
            </li>
          <% end %>
          <li class="ml-2">
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-3xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
