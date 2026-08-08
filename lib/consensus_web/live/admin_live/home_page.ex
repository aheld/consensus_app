defmodule ConsensusWeb.AdminLive.HomePage do
  @moduledoc """
  Admin → Home page. Edits the message shown on the public home page.

  Saving broadcasts over `Consensus.Content`, so every open copy of `/` updates live.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Content
  alias Consensus.Content.HomePage

  @impl true
  def mount(_params, _session, socket) do
    home_page = Content.get_home_page()

    {:ok,
     socket
     |> assign(:page_title, "Admin · Home page")
     |> assign(:home_page, home_page)
     |> assign_form(Content.change_home_page(home_page))}
  end

  @impl true
  def handle_event("validate", %{"home_page" => params}, socket) do
    changeset = Content.change_home_page(socket.assigns.home_page, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"home_page" => params}, socket) do
    case Content.update_home_page(socket.assigns.current_scope, params) do
      {:ok, home_page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Home page updated.")
         |> assign(:home_page, home_page)
         |> assign_form(Content.change_home_page(home_page))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your admin access was revoked.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset, as: "home_page"))
    |> assign(:message_length, message_length(changeset))
  end

  # Counted the way the server validates it: `String.length/1` is graphemes, which is what
  # `validate_length(:message, max: ...)` counts, and the changeset has already trimmed the
  # value, which is what actually gets stored. `cast/3` turns "" into nil, hence the clause.
  defp message_length(changeset) do
    case Ecto.Changeset.get_field(changeset, :message) do
      message when is_binary(message) -> String.length(message)
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Home page message
        <:subtitle>
          Shown to everyone at the root of the site. Plain text; line breaks are kept.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/admin/users"} class="btn btn-soft btn-sm">Users</.link>
        </:actions>
      </.header>

      <.form for={@form} id="home-page-form" phx-change="validate" phx-submit="save">
        <%!-- Deliberately no `maxlength`: the browser enforces it in UTF-16 code units while
              `Consensus.Content.HomePage` validates graphemes, so the two disagree on
              anything outside the BMP (one emoji is 1 grapheme but 2 code units) — and the
              browser's way of disagreeing is to truncate a paste silently, with the tail
              gone and nothing said. A server-side error the admin can read beats a limit
              they cannot see, so the counter below is the warning and the changeset is the
              enforcement. --%>
        <.input
          field={@form[:message]}
          type="textarea"
          label="Message"
          rows="10"
          aria-describedby="message-counter"
          phx-mounted={JS.focus()}
        />
        <p
          id="message-counter"
          class={[
            "mt-1 text-xs",
            if(@message_length > HomePage.max_message_length(),
              do: "text-error font-semibold",
              else: "text-base-content/60"
            )
          ]}
        >
          {@message_length} / {HomePage.max_message_length()} characters
        </p>
        <div class="mt-4 flex items-center gap-3">
          <.button phx-disable-with="Saving..." class="btn btn-primary">Save</.button>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">View home page</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
