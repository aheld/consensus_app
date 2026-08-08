defmodule ConsensusWeb.HomeLive do
  @moduledoc """
  The public home page.

  Renders the admin-editable message and subscribes to `Consensus.Content` so that an
  edit made in the admin area appears here without a refresh, in every open browser.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Content

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Content.subscribe_home_page()

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:home_page, Content.get_home_page())}
  end

  @impl true
  def handle_info({:home_page_updated, home_page}, socket) do
    {:noreply, assign(socket, :home_page, home_page)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Consensus
        <:subtitle>The message below is editable by any administrator.</:subtitle>
        <:actions>
          <.link
            :if={Layouts.admin?(@current_scope)}
            navigate={~p"/admin/home-page"}
            class="btn btn-soft btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
        </:actions>
      </.header>

      <div class="card border border-base-300 bg-base-100">
        <div class="card-body">
          <%!-- `pre-wrap` keeps the admin's own line breaks and indentation; `break-words`
                stops a pasted URL from forcing the whole page to scroll sideways.
                The tag is written on one line on purpose: with `pre-wrap`, any newline or
                indentation between the tags is part of the rendered text.

                `aria-live` because this paragraph is the one thing in the app that changes
                under a visitor who never navigates: an admin's save is pushed here over
                PubSub, and without a live region a screen-reader user is simply never told.
                `polite` and not `assertive`: the new text is worth hearing but never worth
                interrupting mid-sentence for — an assertive region would cut off whatever
                the reader is speaking, on a page whose whole point is prose. It matches the
                flash group, which is already `aria-live="polite"`. --%>
          <p
            id="home-message"
            class="whitespace-pre-wrap break-words text-base leading-relaxed"
            aria-live="polite"
            phx-no-format
          >{@home_page.message}</p>
        </div>
      </div>

      <p :if={@home_page.updated_at} class="text-xs text-base-content/60">
        Last updated {Calendar.strftime(@home_page.updated_at, "%Y-%m-%d %H:%M UTC")}
      </p>

      <p :if={is_nil(@current_scope) || is_nil(@current_scope.user)} class="text-sm">
        <.link navigate={~p"/users/register"} class="link link-primary">Create an account</.link>
        or <.link navigate={~p"/users/log-in"} class="link link-primary">log in</.link>
        to get started.
      </p>
    </Layouts.app>
    """
  end
end
