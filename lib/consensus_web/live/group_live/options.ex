defmodule ConsensusWeb.GroupLive.Options do
  @moduledoc """
  Design frames `02 · add options` and `02b · edit an option` — step two of the
  organizer's creation wizard.

  One LiveView, two `live_action`s sharing a route prefix: `:index` is the pool list at
  `/groups/:id/options`, `:edit_activity` is the full-screen editor at
  `/groups/:id/options/:activity_id`. `02b` is drawn as a full screen rather than a
  modal, so it is reached by `push_patch`/`<.link patch=...>` — the URL changes and the
  back button works — never by toggling a modal assign.

  Every write goes through `Consensus.Activities` with `@current_scope`, which is how
  ownership is enforced: `@group` comes from `Activities.get_group!/2` (scoped to the
  organizer, raises `Ecto.NoResultsError` for anyone else's group or a bad id), and an
  `:activity_id` route param is only ever resolved by searching *that* group's own
  preloaded `:activities` — never a bare `Repo.get/2` on the client-supplied id.

  A pasted link enriches an activity in the background: `add_activity/3` (or, on
  refetch, nothing) creates/updates the row with a provisional name immediately, then a
  `start_async` keyed by `{:link_preview, activity_id, provisional_name}` or
  `{:refetch, activity_id}` calls `Consensus.LinkPreview.fetch/1`. Keying by activity id
  means adding a second link cannot clobber an in-flight fetch for a different row (`If
  there is an in-flight task with the same name, the later start_async wins` —
  `Phoenix.LiveView.start_async/3`).

  The provenance line under each linked option is derived, never asserted: it reports
  what the stored `%Activity{}` fields actually hold (a photo, a description, both, or
  neither), not the fact that a fetch merely ran — a fetch that resolved but found
  nothing must not read the same as one that found everything. `@fetching` is the only
  ephemeral (non-DB) socket state; a *failed* fetch is deliberately not tracked in an
  assign at all, because that would revert to "no details yet" — read as untried — on
  the next remount. Instead a failure is inferred from the row itself: `source_url` set,
  `metadata_fetched_at` still nil, and not currently in `@fetching`. That combination
  can only arise once a fetch has actually been attempted (`add_link_activity/3` starts
  one unconditionally the moment the row is created), so it survives a refresh or a
  fresh log-in without a migration or an extra column.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.LinkPreview

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, parse_id(id))

    {:ok,
     socket
     |> assign(:group, group)
     |> assign(:add_form, fresh_add_form())
     |> assign(:add_reset, 0)
     |> assign(:fetching, MapSet.new())
     |> assign(:editing_activity, nil)
     |> assign(:edit_form, nil)
     |> assign(:image_form, nil)
     |> assign(:replacing_image, false)
     |> stream(:activities, group.activities)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Add the options")
    |> assign(:editing_activity, nil)
    |> assign(:edit_form, nil)
    |> assign(:image_form, nil)
    |> assign(:replacing_image, false)
  end

  defp apply_action(socket, :edit_activity, %{"activity_id" => raw_id}) do
    case find_activity(socket.assigns.group, raw_id) do
      nil ->
        socket
        |> put_flash(:error, "Could not find that option.")
        |> push_patch(to: ~p"/groups/#{socket.assigns.group}/options")

      activity ->
        socket
        |> assign(:page_title, "Edit option")
        |> assign(:editing_activity, activity)
        |> assign(:edit_form, to_form(Activity.changeset(activity, %{}), as: :activity))
        |> assign(:image_form, image_url_form(activity))
        |> assign(:replacing_image, false)
    end
  end

  ## Events — :index

  @impl true
  def handle_event("add_activity", %{"add_option" => %{"query" => raw}}, socket) do
    case String.trim(raw) do
      "" ->
        {:noreply, socket}

      trimmed ->
        case parse_pasted_url(trimmed) do
          {:ok, url, host} -> add_link_activity(socket, url, host)
          :error -> add_named_activity(socket, trimmed)
        end
    end
  end

  def handle_event("delete_activity", %{"id" => raw_id}, socket) do
    case find_activity(socket.assigns.group, raw_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Could not find that option.")}

      activity ->
        case Activities.delete_activity(socket.assigns.current_scope, activity) do
          {:ok, _deleted} ->
            {:noreply, reload_and_reset(socket, activity.id)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not remove that option.")}
        end
    end
  end

  ## Events — :edit_activity

  def handle_event("validate", %{"activity" => params}, socket) do
    changeset =
      socket.assigns.editing_activity
      |> Activity.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset, as: :activity))}
  end

  def handle_event("save", %{"activity" => params}, socket) do
    case Activities.update_activity(
           socket.assigns.current_scope,
           socket.assigns.editing_activity,
           params
         ) do
      {:ok, activity} ->
        {:noreply,
         socket
         |> put_activity_assign(activity)
         |> stream_insert(:activities, activity)
         |> put_flash(:info, "#{activity.name} saved.")
         |> push_patch(to: ~p"/groups/#{socket.assigns.group}/options")}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :activity))}
    end
  end

  def handle_event("remove_option", _params, socket) do
    activity = socket.assigns.editing_activity

    case Activities.delete_activity(socket.assigns.current_scope, activity) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> reload_and_reset(deleted.id)
         |> put_flash(:info, "#{deleted.name} removed.")
         |> push_patch(to: ~p"/groups/#{socket.assigns.group}/options")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove that option.")}
    end
  end

  def handle_event("toggle_replace_image", _params, socket) do
    activity = socket.assigns.editing_activity

    {:noreply,
     socket
     |> assign(:replacing_image, !socket.assigns.replacing_image)
     |> assign(:image_form, image_url_form(activity))}
  end

  def handle_event("remove_image", _params, socket) do
    case Activities.update_activity(
           socket.assigns.current_scope,
           socket.assigns.editing_activity,
           %{
             image_url: nil
           }
         ) do
      {:ok, activity} ->
        {:noreply,
         socket
         |> put_activity_assign(activity)
         |> assign(:editing_activity, activity)
         |> stream_insert(:activities, activity)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove that image.")}
    end
  end

  def handle_event("save_image_url", %{"image" => %{"url" => raw}}, socket) do
    case String.trim(raw) do
      "" ->
        {:noreply, assign(socket, :replacing_image, false)}

      url ->
        case Activities.update_activity(
               socket.assigns.current_scope,
               socket.assigns.editing_activity,
               %{
                 image_url: url
               }
             ) do
          {:ok, activity} ->
            {:noreply,
             socket
             |> put_activity_assign(activity)
             |> assign(:editing_activity, activity)
             |> assign(:replacing_image, false)
             |> stream_insert(:activities, activity)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "That doesn't look like a valid image URL.")}
        end
    end
  end

  def handle_event("refetch", _params, socket) do
    activity = socket.assigns.editing_activity

    socket =
      socket
      |> mark_fetching(activity.id)
      |> start_async({:refetch, activity.id}, fn -> LinkPreview.fetch(activity.source_url) end)

    {:noreply, socket}
  end

  ## Async — link preview

  @impl true
  def handle_async({:link_preview, activity_id, provisional_name}, {:ok, {:ok, preview}}, socket) do
    {:noreply, apply_preview(socket, activity_id, preview, provisional_name)}
  end

  def handle_async(
        {:link_preview, activity_id, _provisional_name},
        {:ok, {:error, _reason}},
        socket
      ) do
    {:noreply, unmark_fetching(socket, activity_id)}
  end

  def handle_async({:link_preview, activity_id, _provisional_name}, {:exit, _reason}, socket) do
    {:noreply, unmark_fetching(socket, activity_id)}
  end

  def handle_async({:refetch, activity_id}, {:ok, {:ok, preview}}, socket) do
    {:noreply, apply_preview(socket, activity_id, preview, :never)}
  end

  def handle_async({:refetch, activity_id}, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket |> unmark_fetching(activity_id) |> put_flash(:error, "Couldn't refetch that link.")}
  end

  def handle_async({:refetch, activity_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket |> unmark_fetching(activity_id) |> put_flash(:error, "Couldn't refetch that link.")}
  end

  ## Add flow

  defp add_named_activity(socket, name) do
    case Activities.add_activity(socket.assigns.current_scope, socket.assigns.group, %{name: name}) do
      {:ok, activity} -> {:noreply, insert_activity(socket, activity)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not add that option.")}
    end
  end

  defp add_link_activity(socket, url, host) do
    attrs = %{name: host, source_url: url}

    case Activities.add_activity(socket.assigns.current_scope, socket.assigns.group, attrs) do
      {:ok, activity} ->
        socket =
          socket
          |> insert_activity(activity)
          |> mark_fetching(activity.id)
          |> start_async({:link_preview, activity.id, host}, fn -> LinkPreview.fetch(url) end)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not add that option.")}
    end
  end

  defp insert_activity(socket, activity) do
    socket
    |> put_activity_assign(activity)
    |> assign(:add_form, fresh_add_form())
    |> update(:add_reset, &(&1 + 1))
    |> stream_insert(:activities, activity)
  end

  ## Async result application

  # `name_strategy` is either the id-th activity's name at the moment the fetch
  # started — only overwrite the name if nobody has touched it since — or the atom
  # `:never`, used by refetch: an explicit organizer action on the edit screen, where
  # overwriting whatever they've typed as the name would be surprising. Refetch only
  # ever "overwrites the three fields" (description, image, timestamp) per the spec.
  defp apply_preview(socket, activity_id, preview, name_strategy) do
    case Enum.find(socket.assigns.group.activities, &(&1.id == activity_id)) do
      nil ->
        unmark_fetching(socket, activity_id)

      activity ->
        attrs =
          %{
            description: preview.description,
            image_url: preview.image_url,
            metadata_fetched_at: preview.fetched_at
          }
          |> maybe_put_name(activity, name_strategy, preview.title)

        case Activities.update_activity(socket.assigns.current_scope, activity, attrs) do
          {:ok, updated} ->
            socket
            |> put_activity_assign(updated)
            |> unmark_fetching(activity_id)
            |> maybe_update_editing_activity(updated)
            |> stream_insert(:activities, updated)

          {:error, _changeset} ->
            unmark_fetching(socket, activity_id)
        end
    end
  end

  defp maybe_put_name(attrs, _activity, :never, _title), do: attrs

  defp maybe_put_name(attrs, %Activity{name: name}, provisional_name, title)
       when name == provisional_name and is_binary(title) and title != "" do
    Map.put(attrs, :name, title)
  end

  defp maybe_put_name(attrs, _activity, _provisional_name, _title), do: attrs

  # Refreshing `:editing_activity` alone is not enough: the NAME/DESCRIPTION `<.form>`
  # is bound to `@edit_form`, built once from the activity at the moment `handle_params`
  # ran, so a refetch (or a same-session add-flow completion — see the "does not
  # overwrite" test) that lands while the edit screen is open must re-derive both forms
  # from the fresh row or the textarea keeps showing what was there before the fetch.
  defp maybe_update_editing_activity(socket, %Activity{id: id} = updated) do
    case socket.assigns.editing_activity do
      %Activity{id: ^id} ->
        socket
        |> assign(:editing_activity, updated)
        |> assign(:edit_form, to_form(Activity.changeset(updated, %{}), as: :activity))
        |> assign(:image_form, image_url_form(updated))

      _ ->
        socket
    end
  end

  ## Group/stream/fetch-state bookkeeping

  defp put_activity_assign(socket, %Activity{} = activity) do
    assign(socket, :group, put_activity(socket.assigns.group, activity))
  end

  defp put_activity(%Group{activities: activities} = group, %Activity{} = activity) do
    updated =
      if Enum.any?(activities, &(&1.id == activity.id)) do
        Enum.map(activities, fn a -> if a.id == activity.id, do: activity, else: a end)
      else
        activities ++ [activity]
      end

    %{group | activities: updated}
  end

  # A delete renumbers every remaining activity's position, so the simplest correct
  # thing is a fresh, still-scoped read (`get_group!/2`) and a full stream reset —
  # patching individual positions here would just re-derive what the context already
  # computed.
  defp reload_and_reset(socket, removed_id) do
    group = Activities.get_group!(socket.assigns.current_scope, socket.assigns.group.id)

    socket
    |> assign(:group, group)
    |> assign(:fetching, MapSet.delete(socket.assigns.fetching, removed_id))
    |> stream(:activities, group.activities, reset: true)
  end

  defp mark_fetching(socket, activity_id) do
    socket
    |> assign(:fetching, MapSet.put(socket.assigns.fetching, activity_id))
    |> restream(activity_id)
  end

  # Clears the in-flight flag whether the fetch succeeded, failed or crashed — a
  # `%Activity{}` still carrying `source_url` but no `metadata_fetched_at` once it is
  # no longer `@fetching` is exactly the durable "tried and failed" signal (see the
  # moduledoc), so there is nothing else to record here. Always re-streams: the row's
  # provenance line depends on `@fetching` membership, which just changed.
  defp unmark_fetching(socket, activity_id) do
    socket
    |> assign(:fetching, MapSet.delete(socket.assigns.fetching, activity_id))
    |> restream(activity_id)
  end

  defp restream(socket, activity_id) do
    case Enum.find(socket.assigns.group.activities, &(&1.id == activity_id)) do
      nil -> socket
      activity -> stream_insert(socket, :activities, activity)
    end
  end

  ## Lookups / parsing

  defp parse_id(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> -1
    end
  end

  defp find_activity(%Group{activities: activities}, raw_id) when is_binary(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> Enum.find(activities, &(&1.id == id))
      _ -> nil
    end
  end

  defp parse_pasted_url(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, URI.to_string(uri), host}

      _ ->
        :error
    end
  end

  ## Forms

  defp fresh_add_form, do: to_form(%{"query" => ""}, as: :add_option)

  defp image_url_form(%Activity{image_url: image_url}) do
    to_form(%{"url" => image_url || ""}, as: :image)
  end

  defp description_length(form) do
    form[:description].value |> to_string() |> String.length()
  end

  ## Provenance line ("typed by you · no details yet", "fetching details…", ...)
  #
  # Derived from what the row actually holds, never from the fact that a fetch ran —
  # see the moduledoc. `metadata_fetched_at` is the only signal that a fetch ever
  # *succeeded*; whether it found a photo, a description, both or neither is read
  # straight off `image_url`/`description`, so a page with no og:description can never
  # be reported as having one.

  defp provenance_text(%Activity{source_url: nil}, _fetching) do
    "typed by you · no details yet"
  end

  defp provenance_text(%Activity{id: id} = activity, fetching) do
    cond do
      MapSet.member?(fetching, id) -> "fetching details…"
      is_nil(activity.metadata_fetched_at) -> "link added · couldn't read that page"
      true -> "link added · " <> resolved_summary(activity, "pulled")
    end
  end

  # Shared by the pool row ("pulled") and the 02b source-link caption ("auto-filled") —
  # same presence check, different verb to match each screen's existing copy.
  defp resolved_summary(%Activity{image_url: image_url, description: description}, verb) do
    cond do
      present?(image_url) and present?(description) -> "photo + description #{verb}"
      present?(image_url) -> "photo #{verb}"
      present?(description) -> "description #{verb}"
      true -> "nothing useful found"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp added_by_you_count(%Group{activities: activities}, current_scope) do
    Enum.count(activities, &(&1.added_by_id == current_scope.user.id))
  end

  ## Button styling — hand-rolled rather than `<.button>` because these need either a
  ## permanent (not hover-only) yellow fill that variant doesn't offer, or a `flex-1`
  ## that overriding `class` on `<.button>` would otherwise have to fully replicate
  ## anyway (see the `design-system` skill: passing `class` replaces the component's
  ## default entirely, it does not merge). `primary_button_class/1` intentionally
  ## copies `CoreComponents.button/1`'s `variant="primary"` classes so the one
  ## tangerine action on each of these two screens still matches the rest of the app.

  defp primary_button_class(extra \\ nil) do
    [
      "inline-flex items-center justify-center gap-2 rounded-2xl border-2 border-ink p-4",
      "font-bold text-base transition-colors",
      "disabled:cursor-not-allowed disabled:opacity-[45%] disabled:shadow-none",
      "bg-tangerine text-white shadow-sticker-4 press-4",
      extra
    ]
  end

  defp yellow_button_class do
    [
      "inline-flex shrink-0 items-center justify-center gap-1.5 rounded-2xl border-2 border-ink",
      "bg-yellow px-4 py-3 text-[14px] font-bold text-ink shadow-sticker-2 press-2"
    ]
  end

  defp edit_pill_class do
    [
      "inline-flex items-center gap-1 rounded-full border-2 border-ink bg-yellow",
      "px-2.5 py-1 text-[10.5px] font-semibold text-ink shadow-sticker-2 press-2"
    ]
  end

  @impl true
  def render(%{live_action: :edit_activity, editing_activity: activity} = assigns)
      when not is_nil(activity) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between gap-3 border-b-2 border-ink px-5 py-3">
        <div class="flex items-center gap-2.5">
          <.link
            patch={~p"/groups/#{@group}/options"}
            aria-label="Close"
            class="grid size-[34px] shrink-0 place-items-center rounded-full border-2 border-ink text-base font-semibold hover:bg-yellow"
          >
            <span aria-hidden="true">✕</span>
          </.link>
          <h1 class="text-[15px] font-bold text-ink">Edit option</h1>
        </div>
        <button
          type="button"
          phx-click="remove_option"
          data-confirm={"Remove #{@editing_activity.name}? This can't be undone."}
          aria-label={"Remove #{@editing_activity.name}"}
          class="text-[12.5px] font-semibold text-tangerine hover:underline"
        >
          Remove
        </button>
      </div>

      <div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-5 py-4">
        <div class="flex flex-col gap-2">
          <div class="flex items-baseline justify-between">
            <.eyebrow>Photo</.eyebrow>
            <span class="font-mono text-[10px] text-muted">OPTIONAL</span>
          </div>

          <.photo_frame src={@editing_activity.image_url} alt={@editing_activity.name}>
            <span
              :if={@editing_activity.metadata_fetched_at}
              class="absolute left-2.5 top-2.5 rounded-full bg-ink px-2.5 py-1 font-mono text-[9.5px] text-white"
            >
              PULLED FROM LINK
            </span>
            <div class="absolute bottom-2.5 right-2.5 flex gap-1.5">
              <button
                type="button"
                phx-click="toggle_replace_image"
                class="rounded-2xl border-2 border-ink bg-white px-2.5 py-1.5 text-[11px] font-semibold hover:bg-yellow"
              >
                Replace
              </button>
              <button
                type="button"
                phx-click="remove_image"
                disabled={is_nil(@editing_activity.image_url)}
                class="rounded-2xl border-2 border-ink bg-white px-2.5 py-1.5 text-[11px] font-semibold hover:bg-yellow disabled:cursor-not-allowed disabled:opacity-45"
              >
                Remove
              </button>
            </div>
          </.photo_frame>

          <.form
            :if={@replacing_image}
            for={@image_form}
            id="image-url-form"
            phx-submit="save_image_url"
            class="flex gap-2"
          >
            <div class="flex-1">
              <.input
                field={@image_form[:url]}
                type="text"
                placeholder="https://…"
                class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[13px] shadow-field focus:outline-none"
              />
            </div>
            <button type="submit" class={yellow_button_class()}>Set</button>
          </.form>
        </div>

        <.form
          for={@edit_form}
          id="edit-option-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-4"
        >
          <div class="flex flex-col gap-1.5">
            <.eyebrow>Name</.eyebrow>
            <.input
              field={@edit_form[:name]}
              type="text"
              class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[15px] font-bold shadow-field focus:outline-none"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <div class="flex items-baseline justify-between">
              <.eyebrow>Description</.eyebrow>
              <span
                class={[
                  "font-mono text-[10px]",
                  if(description_length(@edit_form) > Activity.max_description_length(),
                    do: "font-semibold text-tangerine",
                    else: "text-muted"
                  )
                ]}
                aria-live="polite"
              >
                {description_length(@edit_form)}/{Activity.max_description_length()}
              </span>
            </div>
            <.input
              field={@edit_form[:description]}
              type="textarea"
              class="min-h-[74px] w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[13.5px] leading-[1.45] shadow-field focus:outline-none"
            />
            <p class="text-[11px] text-muted">Everyone sees this when they rank.</p>
          </div>
        </.form>

        <div
          :if={@editing_activity.source_url}
          class="flex items-center gap-2.5 rounded-2xl border-2 border-dashed border-ink/35 bg-surface px-3.5 py-3"
        >
          <span aria-hidden="true">🔗</span>
          <div class="min-w-0 flex-1">
            <p class="truncate text-[11.5px] font-medium">{@editing_activity.source_url}</p>
            <p class="font-mono text-[10.5px] text-muted">
              {source_link_note(@editing_activity, @fetching)}
            </p>
          </div>
          <button
            type="button"
            phx-click="refetch"
            disabled={MapSet.member?(@fetching, @editing_activity.id)}
            class="shrink-0 text-[11px] font-semibold text-muted hover:text-tangerine disabled:cursor-not-allowed disabled:opacity-60"
          >
            {if MapSet.member?(@fetching, @editing_activity.id), do: "Refetching…", else: "Refetch"}
          </button>
        </div>
      </div>

      <div class="flex items-center gap-2.5 border-t-2 border-ink bg-white px-5 py-4">
        <.link
          patch={~p"/groups/#{@group}/options"}
          class="rounded-2xl border-2 border-ink bg-white px-4 py-3.5 text-[14px] font-bold text-ink shadow-sticker-2 press-2 hover:bg-yellow"
        >
          Cancel
        </.link>
        <button
          type="submit"
          form="edit-option-form"
          class={primary_button_class("flex-1 text-center")}
        >
          Save option
        </button>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex min-h-0 flex-1 flex-col gap-4 px-5 pt-4">
        <.step_progress total={3} current={2} back={~p"/groups/#{@group}/edit"} />

        <h1 class="text-[29px] font-bold leading-[1.08] tracking-[-0.025em] text-ink">
          Add the<br />options
        </h1>

        <div class="flex flex-col gap-2">
          <.eyebrow>Activity type</.eyebrow>
          <div class="flex items-center gap-2 overflow-x-auto pb-1">
            <.chip selected tone={:ink} class="shrink-0">
              {String.capitalize(@group.activity_type)}
              <span class="text-[11px] font-medium opacity-75" aria-hidden="true">›</span>
            </.chip>
            <.chip disabled>Bars</.chip>
            <.chip disabled>Movies</.chip>
          </div>
          <p class="text-[11.5px] leading-[1.4] text-muted">
            Restaurants first. More types as we grow.
          </p>
        </div>

        <div class="flex flex-col gap-2">
          <.eyebrow>Type a name or paste a link</.eyebrow>
          <.form for={@add_form} id="add-option-form" phx-submit="add_activity" class="flex gap-2">
            <div class="flex-1">
              <.input
                id={"add-option-query-#{@add_reset}"}
                field={@add_form[:query]}
                type="text"
                placeholder="Restaurant name or a link"
                class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[14px] font-medium shadow-field placeholder:text-faint focus:outline-none"
              />
            </div>
            <button type="submit" class={yellow_button_class()}>Add</button>
          </.form>
        </div>

        <div
          id="pool-list"
          phx-update="stream"
          class="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto pb-2"
        >
          <.sticker_card
            :for={{dom_id, activity} <- @streams.activities}
            id={dom_id}
            depth={2}
            class="flex items-center gap-2.5 px-2.5 py-2.5"
          >
            <.position_badge n={activity.position} />
            <div class="min-w-0 flex-1">
              <p class="truncate text-[14px] font-bold text-ink">{activity.name}</p>
              <p class="font-mono text-[10.5px] text-muted">
                {provenance_text(activity, @fetching)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-1.5">
              <.link
                patch={~p"/groups/#{@group}/options/#{activity.id}"}
                aria-label={"Edit #{activity.name}"}
                class={edit_pill_class()}
              >
                ✎ Edit
              </.link>
              <button
                type="button"
                phx-click="delete_activity"
                phx-value-id={activity.id}
                data-confirm={"Remove #{activity.name} from the pool?"}
                aria-label={"Remove #{activity.name}"}
                class="text-muted hover:text-tangerine"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </.sticker_card>
        </div>
      </div>

      <div class="flex items-center gap-3 border-t-2 border-ink bg-white px-5 py-4">
        <div class="flex flex-1 flex-col gap-0.5">
          <span class="text-[15px] font-bold text-ink">
            {length(@group.activities)} in the pool
          </span>
          <span class="text-[11px] text-muted">
            {added_by_you_count(@group, @current_scope)} added by you
          </span>
        </div>
        <button
          :if={@group.activities == []}
          type="button"
          disabled
          id="review-cta"
          class={primary_button_class()}
        >
          Review →
        </button>
        <.link
          :if={@group.activities != []}
          navigate={~p"/groups/#{@group}/review"}
          id="review-cta"
          class={primary_button_class()}
        >
          Review →
        </.link>
      </div>
    </Layouts.app>
    """
  end

  defp source_link_note(%Activity{id: id} = activity, fetching) do
    cond do
      MapSet.member?(fetching, id) -> "fetching details…"
      is_nil(activity.metadata_fetched_at) -> "couldn't read that page"
      true -> resolved_summary(activity, "auto-filled")
    end
  end
end
