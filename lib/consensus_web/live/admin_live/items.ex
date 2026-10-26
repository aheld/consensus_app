defmodule ConsensusWeb.AdminLive.Items do
  @moduledoc """
  Admin → Items (D-060; docs/plans/item-details-and-catalog.md §4): every shared
  catalog row and every option in every group, and the levers to correct them.

  Two tabs on one LiveView, `?tab=catalog` (the default) and `?tab=items`, patched so
  the back button works:

    * **Catalog** — every `catalog_items` row, newest first, filterable by type,
      status and name. **Edit** (every field, raw coordinates allowed — this is the one
      place a person sees them), **Hide/Unhide** (effective on the next lookup: the
      catalog provider is never cached) and **Delete** (no group changes: every option
      keeps its own copy).
    * **All items** — every option across all groups, filterable by group status,
      "has details" and "shared". **Edit details** only, and **Share to catalog** (an
      admin-owned snapshot that leaves the organizer's own toggle alone). Admins cannot
      rename, reorder or delete another organizer's options: invariant 16's reasons
      bind them too, and a delete would cascade votes.

  Authorization is the router's twice over (the `:require_admin_user` plug and the
  `:require_admin` on_mount hook, invariant 1), and every write here is additionally an
  admin head match in `Consensus.Catalog` / `Consensus.Activities`, logged as an
  `[audit]` line. No sudo gate: nothing here changes a privilege or destroys an
  account (D-043's reasoning for `/admin/feedback`).

  Not built (follow-ups once the table needs them): merging duplicate rows, bulk
  actions, CSV export. No design frame: the layout is `AdminLive.Feedback`'s.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Catalog
  alias Consensus.Catalog.CatalogItem
  alias ConsensusWeb.ItemDetails
  alias ConsensusWeb.OrganizerLabel

  @catalog_fields ~w(name description source_url phone address category latitude longitude image_url osm_ref)a
  @detail_fields ~w(source_url phone address category latitude longitude)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Items")
     |> assign(:filters, %{})
     |> assign(:editing, nil)
     |> assign(:edit_form, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = if params["tab"] == "items", do: :items, else: :catalog

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:filters, %{})
     |> close_editor()
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    {:noreply, socket |> assign(:filters, parse_filters(socket.assigns.tab, params)) |> load()}
  end

  def handle_event("edit", %{"kind" => kind, "id" => raw_id}, socket) do
    case find(socket, kind, raw_id) do
      %CatalogItem{} = item ->
        {:noreply,
         open_editor(socket, {:catalog, item.id}, CatalogItem.admin_changeset(item, %{}))}

      %Activity{} = activity ->
        {:noreply,
         open_editor(socket, {:activity, activity.id}, Activity.details_changeset(activity, %{}))}

      nil ->
        {:noreply,
         put_flash(socket, :error, "That row is gone. The list is current now.") |> load()}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, close_editor(socket)}

  def handle_event("save", %{"item" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing do
        {:catalog, id} ->
          with %CatalogItem{} = item <- Catalog.get_item(id),
               do: Catalog.admin_update(scope, item, Map.take(params, strings(@catalog_fields)))

        {:activity, id} ->
          with %Activity{} = activity <- find(socket, "activity", to_string(id)),
               do:
                 Activities.admin_update_activity_details(
                   scope,
                   activity,
                   Map.take(params, strings(@detail_fields))
                 )

        nil ->
          nil
      end

    case result do
      {:ok, _saved} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> close_editor() |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :item))}

      _gone ->
        {:noreply, socket |> put_flash(:error, "Could not save that. Reload and try again.")}
    end
  end

  def handle_event("set_status", %{"id" => raw_id, "status" => status}, socket)
      when status in ["visible", "hidden"] do
    with %CatalogItem{} = item <- find(socket, "catalog", raw_id),
         {:ok, _item} <- Catalog.admin_set_status(socket.assigns.current_scope, item, status) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         if(status == "hidden", do: "Hidden from lookups.", else: "Visible again.")
       )
       |> load()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not change that row.") |> load()}
    end
  end

  def handle_event("delete", %{"id" => raw_id}, socket) do
    with %CatalogItem{} = item <- find(socket, "catalog", raw_id),
         {:ok, _deleted} <- Catalog.admin_delete(socket.assigns.current_scope, item) do
      {:noreply, socket |> put_flash(:info, "Deleted. No group's option changed.") |> load()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not delete that row.") |> load()}
    end
  end

  def handle_event("share", %{"id" => raw_id}, socket) do
    with %Activity{} = activity <- find(socket, "activity", raw_id),
         {:ok, _row} <- Catalog.admin_share(socket.assigns.current_scope, activity) do
      {:noreply, socket |> put_flash(:info, "In the catalog.") |> load()}
    else
      {:error, :hidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A hidden catalog row already matches it. Unhide that one instead."
         )}

      {:error, :nothing_to_find} ->
        {:noreply,
         put_flash(socket, :error, "Nothing to share: it has no website, address or location.")}

      _ ->
        {:noreply, socket |> put_flash(:error, "Could not share that.") |> load()}
    end
  end

  ## Loading

  defp load(%{assigns: %{tab: :catalog}} = socket) do
    assign(
      socket,
      :rows,
      Catalog.list_items_for_admin(socket.assigns.current_scope, socket.assigns.filters)
    )
  end

  defp load(%{assigns: %{tab: :items}} = socket) do
    assign(
      socket,
      :rows,
      Activities.list_all_activities_for_admin(
        socket.assigns.current_scope,
        socket.assigns.filters
      )
    )
  end

  # Every id arrives from the client: parsed, then looked up only among the rows this
  # screen is showing, never trusted as a bare `Repo.get/2` target.
  defp find(socket, kind, raw_id) do
    expected = if kind == "catalog", do: CatalogItem, else: Activity

    with {id, ""} <- Integer.parse(to_string(raw_id)) do
      Enum.find(socket.assigns.rows, &(is_struct(&1, expected) and &1.id == id))
    else
      _ -> nil
    end
  end

  defp parse_filters(:catalog, params) do
    %{
      activity_type: blank_to_nil(params["activity_type"]),
      status: blank_to_nil(params["status"]),
      query: blank_to_nil(params["query"])
    }
  end

  defp parse_filters(:items, params) do
    %{
      group_status: blank_to_nil(params["group_status"]),
      details: params["details"] == "true",
      shared: params["shared"] == "true"
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp open_editor(socket, editing, changeset) do
    socket |> assign(:editing, editing) |> assign(:edit_form, to_form(changeset, as: :item))
  end

  defp close_editor(socket), do: socket |> assign(:editing, nil) |> assign(:edit_form, nil)

  defp strings(fields), do: Enum.map(fields, &Atom.to_string/1)

  defp catalog_fields, do: @catalog_fields
  defp detail_fields, do: @detail_fields

  ## Presentation

  defp sharer(%CatalogItem{shared_by_user: %{username: username}}), do: username

  defp sharer(%CatalogItem{shared_by_anonymous_organizer_id: id}) when is_integer(id),
    do: "No account"

  defp sharer(_row), do: "—"

  defp source(%CatalogItem{osm_ref: ref}) when is_binary(ref) and ref != "", do: "OSM"
  defp source(_row), do: "Organizer"

  defp located?(%{latitude: lat, longitude: lon}), do: is_float(lat) and is_float(lon)

  defp details_summary(%Activity{} = activity) do
    [
      ItemDetails.category_text(activity.category),
      activity.address,
      activity.phone,
      located?(activity) && "📍"
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
    |> case do
      "" -> "No details"
      summary -> summary
    end
  end

  defp organizer(%Activity{group: group}),
    do: OrganizerLabel.label(Activities.organizer_custom_name(group), :start)

  defp editing?(editing, kind, id), do: editing == {kind, id}

  defp tab_class(true),
    do:
      "rounded-full border-2 border-ink bg-ink px-3.5 py-2 text-[12.5px] font-semibold text-white"

  defp tab_class(false),
    do:
      "rounded-full border-2 border-ink bg-white px-3.5 py-2 text-[12.5px] font-semibold text-ink hover:bg-yellow"

  defp action_button_class,
    do:
      "press-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-white px-3.5 py-3 text-[12.5px] font-semibold leading-none shadow-sticker-2 hover:bg-yellow"

  defp field_class,
    do:
      "w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-2.5 text-[16px] shadow-field focus:outline-none"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
      context="ADMIN"
    >
      <div class="mx-auto flex w-full flex-1 flex-col gap-6 px-6 pb-10 pt-6">
        <div class="flex flex-col gap-2">
          <h1 class="text-[27px] font-bold leading-[1.15] tracking-[-0.025em]">Items</h1>
          <p class="text-[13.5px] leading-[1.5] text-ink-soft">
            The shared catalog the lookup asks first, and every option in every group.
            Fix details here; names, order and the options themselves stay their
            organizers' — an option people voted on cannot change under them.
          </p>
          <div class="flex flex-wrap gap-x-4">
            <.link
              navigate={~p"/admin/users"}
              class="-my-3 inline-flex min-h-[44px] items-center text-[12.5px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
            >
              Go to Admin → Users
            </.link>
            <.link
              navigate={~p"/admin/feedback"}
              class="-my-3 inline-flex min-h-[44px] items-center text-[12.5px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
            >
              Go to Admin → Feedback
            </.link>
          </div>
        </div>

        <nav class="flex gap-2" aria-label="Items tabs">
          <.link
            patch={~p"/admin/items"}
            id="tab-catalog"
            aria-current={@tab == :catalog && "page"}
            class={tab_class(@tab == :catalog)}
          >
            Catalog
          </.link>
          <.link
            patch={~p"/admin/items?tab=items"}
            id="tab-items"
            aria-current={@tab == :items && "page"}
            class={tab_class(@tab == :items)}
          >
            All items
          </.link>
        </nav>

        <.form
          :if={@tab == :catalog}
          for={to_form(%{}, as: :filter)}
          id="catalog-filter"
          phx-change="filter"
          class="flex flex-col gap-2"
        >
          <input
            type="text"
            name="filter[query]"
            placeholder="Search names"
            class={field_class()}
          />
          <div class="flex gap-2">
            <select name="filter[activity_type]" class={field_class()} aria-label="Type">
              <option value="">Every type</option>
              <option :for={type <- Consensus.Discovery.available_types()} value={type}>
                {String.capitalize(type)}
              </option>
            </select>
            <select name="filter[status]" class={field_class()} aria-label="Status">
              <option value="">Any status</option>
              <option :for={status <- CatalogItem.statuses()} value={status}>
                {String.capitalize(status)}
              </option>
            </select>
          </div>
        </.form>

        <.form
          :if={@tab == :items}
          for={to_form(%{}, as: :filter)}
          id="items-filter"
          phx-change="filter"
          class="flex flex-wrap items-center gap-3"
        >
          <select name="filter[group_status]" class={field_class()} aria-label="Group status">
            <option value="">Any group status</option>
            <option :for={status <- Consensus.Activities.Group.statuses()} value={status}>
              {String.capitalize(to_string(status))}
            </option>
          </select>
          <label class="inline-flex min-h-[44px] items-center gap-2 text-[13px] font-semibold">
            <input type="checkbox" name="filter[details]" value="true" class="size-5" /> Has details
          </label>
          <label class="inline-flex min-h-[44px] items-center gap-2 text-[13px] font-semibold">
            <input type="checkbox" name="filter[shared]" value="true" class="size-5" /> Shared
          </label>
        </.form>

        <p
          :if={@rows == []}
          id="items-empty"
          class="rounded-2xl border-2 border-dashed border-ink px-4 py-5 text-center text-[13px] leading-[1.45] text-muted"
        >
          {if @tab == :catalog,
            do: "Nothing in the catalog matches. Organizers add to it with Let anyone find this.",
            else: "No options match."}
        </p>

        <ul :if={@tab == :catalog} id="catalog-rows" class="flex flex-col gap-2.5">
          <li :for={row <- @rows} id={"catalog-#{row.id}"}>
            <.sticker_card
              depth={2}
              tone={if row.status == "hidden", do: :canvas, else: :white}
              class="flex flex-col gap-2 p-3.5"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="min-w-0 break-words font-bold text-ink">{row.name}</span>
                <.pill :if={row.status == "hidden"} tone={:violet}>hidden</.pill>
              </div>
              <p class="font-mono text-[10.5px] uppercase tracking-[0.06em] text-muted">
                {row.activity_type} · {source(row)} · shared by {sharer(row)} · {row.use_count} {ngettext(
                  "use",
                  "uses",
                  row.use_count
                )} · {if located?(row), do: "located", else: "no location"}
              </p>
              <p :if={row.category || row.address} class="text-[12.5px] text-ink-soft">
                {[ItemDetails.category_text(row.category), row.address]
                |> Enum.reject(&is_nil/1)
                |> Enum.join(" · ")}
              </p>

              <.item_form
                :if={editing?(@editing, :catalog, row.id)}
                form={@edit_form}
                fields={catalog_fields()}
              />

              <div :if={!editing?(@editing, :catalog, row.id)} class="flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-kind="catalog"
                  phx-value-id={row.id}
                  class={action_button_class()}
                >
                  Edit
                </button>
                <button
                  type="button"
                  phx-click="set_status"
                  phx-value-id={row.id}
                  phx-value-status={if row.status == "hidden", do: "visible", else: "hidden"}
                  class={action_button_class()}
                >
                  {if row.status == "hidden", do: "Unhide", else: "Hide"}
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={row.id}
                  data-confirm={"Delete #{row.name} from the catalog? Every group keeps its own copy."}
                  class={action_button_class()}
                >
                  Delete
                </button>
              </div>
            </.sticker_card>
          </li>
        </ul>

        <ul :if={@tab == :items} id="item-rows" class="flex flex-col gap-2.5">
          <li :for={activity <- @rows} id={"item-#{activity.id}"}>
            <.sticker_card depth={2} tone={:white} class="flex flex-col gap-2 p-3.5">
              <div class="flex flex-wrap items-center gap-2">
                <span class="min-w-0 break-words font-bold text-ink">{activity.name}</span>
                <.pill :if={activity.shared_to_catalog_at} tone={:mint}>shared</.pill>
              </div>
              <%!-- The group title links nowhere: an admin has no organizer screen for
                    someone else's group, and inventing one is not this screen's job. --%>
              <p class="font-mono text-[10.5px] uppercase tracking-[0.06em] text-muted">
                {activity.group.title} · {activity.group.status} · {organizer(activity)}
              </p>
              <p class="text-[12.5px] text-ink-soft">{details_summary(activity)}</p>

              <.item_form
                :if={editing?(@editing, :activity, activity.id)}
                form={@edit_form}
                fields={detail_fields()}
              />

              <div :if={!editing?(@editing, :activity, activity.id)} class="flex flex-wrap gap-2">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-kind="activity"
                  phx-value-id={activity.id}
                  class={action_button_class()}
                >
                  Edit details
                </button>
                <button
                  type="button"
                  phx-click="share"
                  phx-value-id={activity.id}
                  class={action_button_class()}
                >
                  Share to catalog
                </button>
              </div>
            </.sticker_card>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :fields, :list, required: true

  # One inline form for whichever row is open — `AdminLive.Feedback`'s note pattern,
  # without its per-row drafts: one editor at a time, and Cancel is explicit. Raw
  # latitude/longitude are allowed here and nowhere else (§4). No `maxlength` on any
  # field (invariant 11); the changeset refuses, and the error renders inline.
  defp item_form(assigns) do
    ~H"""
    <.form for={@form} id="item-edit-form" phx-submit="save" class="flex flex-col gap-2.5">
      <.input
        :for={field <- @fields}
        field={@form[field]}
        type={if field == :description, do: "textarea", else: "text"}
        label={field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()}
        class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-2.5 text-[16px] shadow-field focus:outline-none"
      />
      <div class="flex gap-2">
        <button
          type="submit"
          class="press-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-tangerine px-4 py-3 text-[12.5px] font-bold text-white shadow-sticker-2"
        >
          Save
        </button>
        <button
          type="button"
          phx-click="cancel_edit"
          class="press-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-white px-3.5 py-3 text-[12.5px] font-semibold shadow-sticker-2 hover:bg-yellow"
        >
          Cancel
        </button>
      </div>
    </.form>
    """
  end
end
