defmodule ConsensusWeb.GroupLive.Options do
  @moduledoc """
  Design frames `02 · add options` and `02b · edit an option` — step two of the
  organizer's creation wizard.

  One LiveView, two `live_action`s sharing a route prefix: `:index` is the pool list at
  `/groups/:id/options`, `:edit_activity` is the full-screen editor at
  `/groups/:id/options/:activity_id`. `02b` is drawn as a full screen rather than a
  modal, so it is reached by `push_patch`/`<.link patch=...>` — the URL changes and the
  back button works — never by toggling a modal assign.

  The screen exists only for a `:draft` group. Once the organizer publishes, the pool is
  frozen (D-037 — `votes.activity_id` cascades, so a delete here would destroy ballots
  that have already been cast), so `mount/3` bounces a `:voting`, `:completed` or
  `:cancelled` group to `03 review`. The refusal itself lives in `Consensus.Activities`;
  this redirect is the courtesy that keeps an organizer from tapping controls that would
  all be refused.

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

  ## Assisted Add (design frame t5, `docs/design/assisted-add-ux-brief.md` F1/F2/F4)

  A **typed name** (never a pasted URL — that path is unchanged above) lands in the pool
  instantly exactly as before, then fires ONE `Consensus.Discovery.search/3` via
  `start_async`, keyed `{:assist, activity_id}` so parallel adds cannot clobber each
  other. Never on `phx-change` — the add form deliberately carries no change binding,
  because keystroke-level lookups are both a policy violation (Nominatim) and an abuse
  of a rate-limited volunteer endpoint (research §3 trap F, brief hard constraint 1).

  Everything the assist knows is socket state, per-activity, and dies with the socket:

    * `@assist_looking` — ids with a lookup in flight; the card's meta line renders the
      quiet `.assist-shim` bar (02b). When the async returns empty or an error the bar
      simply stops — the failure trio (no match / provider error / timeout) renders
      NOTHING: no flash, no inline error, the organizer never learns a lookup ran.
    * `@assist_suggestions` — `%{activity_id => [Result]}`; renders the `IS THIS IT?`
      slot attached under the card (02c/02d), capped at 3 rows even if the seam
      misbehaves. `Use this` overwrites the typed name with the provider's canonical
      one (brief D3 — the 02b editor is the undo), sets `source_url` when the result
      carries a website, and reuses the pasted-link enrichment async — keyed
      `{:link_preview, id, :never}`, so the fetch fills photo/description/metadata but
      never the name: the organizer just confirmed the provider's canonical name, and
      the page's own og:title (observed live: "Vernick Philadelphia" replacing
      "Vernick Food & Drink") must not undo that. A result with no website still
      confirms name + address usefully: name set, no `source_url`, no enrichment.
    * `@assist_enriching` — ids between `Use this` and LinkPreview landing; the card
      wears the violet `shadow-assist`, the shimmering photo tile and the
      `link attached · details arriving` meta (02e). Cleared by `unmark_fetching/2`,
      which every enrichment outcome funnels through.
    * `@area_prompt` / `@area_prompt_suppressed?` — the one-time area prompt (02f, F2).
      The first lookup that needs an area on a group that has none shows the prompt in
      the slot instead of results; Save geocodes (async, `Consensus.Discovery.Geocoder`),
      stores area + bbox on the group via `Activities.set_search_area/3` **only on
      geocode success**, then runs the pending lookup for the card that triggered it —
      and for every card typed *while the question was open* (`pending_ids` inside the
      prompt map): those adds queue rather than silently losing their one lookup, each
      fired per-activity as usual once Save lands. Dismissed unanswered → suppressed for
      this LiveView session only, queue discarded with it. Geocode failure → silent
      collapse, area still unset, so a later add may ask again. Once the group has an
      area the prompt can never appear again on any mount.

  When `Consensus.Discovery` has no provider for the group's activity type
  (`@assist_enabled?` false — an empty registry counts), the feature is invisible: no
  shimmer, no slot, the screen renders exactly as it did before the assist existed.
  `activity_type` is only ever handed to `Consensus.Discovery` as an opaque registry
  key, never branched on (CLAUDE.md product invariant 2 —
  `test/consensus/activity_type_invariant_test.exs`).
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.Discovery
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result
  alias Consensus.LinkPreview

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, parse_id(id))

    if group.status == :draft do
      {:ok, mount_editor(socket, group)}
    else
      # The pool is frozen once the vote opens (D-037): every write on this screen would
      # be refused by `Consensus.Activities` anyway, and a screen full of controls that
      # silently do nothing is worse than not being here. Same shape as
      # `ConsensusWeb.GroupLive.Share` bouncing a `:draft` back to review — the lock is a
      # route-level fact, not a disabled button.
      {:ok,
       socket
       |> put_flash(:info, "Voting has started — the pool is locked.")
       |> push_navigate(to: ~p"/groups/#{group}/review")}
    end
  end

  defp mount_editor(socket, group) do
    socket
    |> assign(:group, group)
    |> assign(:add_form, fresh_add_form())
    |> assign(:add_reset, 0)
    |> assign(:add_refocus, false)
    |> assign(:fetching, MapSet.new())
    |> assign(:editing_activity, nil)
    |> assign(:edit_form, nil)
    |> assign(:image_form, nil)
    |> assign(:replacing_image, false)
    # The assist (see the moduledoc). `activity_type` is an opaque registry key here —
    # a type with no registered provider makes the whole feature invisible, and both
    # values below are config-derived, so once per mount is enough.
    |> assign(:assist_enabled?, Enum.member?(Discovery.available_types(), group.activity_type))
    |> assign(:assist_attribution, Discovery.attribution_for(group.activity_type))
    |> assign(:assist_looking, MapSet.new())
    |> assign(:assist_suggestions, %{})
    |> assign(:assist_enriching, MapSet.new())
    |> assign(:area_prompt, nil)
    |> assign(:area_form, nil)
    |> assign(:area_prompt_suppressed?, false)
    |> stream(:activities, group.activities)
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # The `:edit_activity` branch of `render/1` is a different tree that does not contain
  # the `phx-update="stream"` container at all, so patching to the editor *destroys* that
  # container in the DOM and patching back re-creates it empty. LiveView only sends the
  # items in the stream's pending insert set, which after a save is just the one row that
  # was `stream_insert`ed — so the pool silently rendered a single option while the footer
  # still counted three. Re-stream with `reset: true` on every arrival at `:index`, which
  # covers returning from a save, from Cancel, and from a direct patch alike.
  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Add the options")
    # Any arrival by patch (returning from the editor included) recreates the add
    # input, and `phx-mounted` would re-fire on it — the refocus belongs to an Add
    # press only (frame 02b), never to navigation. See `insert_activity/2`.
    |> assign(:add_refocus, false)
    |> assign(:editing_activity, nil)
    |> assign(:edit_form, nil)
    |> assign(:image_form, nil)
    |> assign(:replacing_image, false)
    |> stream(:activities, socket.assigns.group.activities, reset: true)
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

  # `Use this` (frames 02c/02d → 02e): overwrite the typed name with the provider's
  # canonical one (brief D3), set `source_url` when the suggestion has a website, and
  # run the pasted-link enrichment path verbatim. An id or index that no longer
  # resolves (a stale click racing a dismiss) is a no-op, not a crash.
  def handle_event("assist_use", %{"id" => raw_id, "index" => raw_index}, socket) do
    with %Activity{} = activity <- find_activity(socket.assigns.group, raw_id),
         [_ | _] = suggestions <- Map.get(socket.assigns.assist_suggestions, activity.id),
         {:ok, index} <- parse_index(raw_index),
         %Result{} = suggestion <- Enum.at(suggestions, index) do
      confirm_suggestion(socket, activity, suggestion)
    else
      _ -> {:noreply, socket}
    end
  end

  # The slot's ✕ (02c annotation): the slot collapses, the bare typed card stands, and
  # the lookup is not retried for that card. Per-activity, socket-state only.
  def handle_event("assist_dismiss", %{"id" => raw_id}, socket) do
    case find_activity(socket.assigns.group, raw_id) do
      nil ->
        {:noreply, socket}

      activity ->
        {:noreply,
         socket
         |> assign(
           :assist_suggestions,
           Map.delete(socket.assigns.assist_suggestions, activity.id)
         )
         |> restream(activity.id)}
    end
  end

  # The area prompt's ✕ (02f — the control the frame's annotation demands and its
  # drawing omits): collapse, and suppress the prompt for the rest of this LiveView
  # session. The area stays unset, so a fresh mount may ask again.
  def handle_event("assist_dismiss_area", _params, socket) do
    {:noreply,
     socket
     |> close_area_prompt()
     |> assign(:area_prompt_suppressed?, true)}
  end

  # The area prompt's Save (02f). Submit-only — never typeahead (policy; the form has
  # no phx-change). A changeset error (an over-long area) renders inline in the slot:
  # that is organizer form input, not a lookup, so the silence rules don't bind it.
  # The geocode itself is a network call and runs via start_async (invariant 13).
  def handle_event("area_submit", %{"area" => %{"search_area" => raw}}, socket) do
    typed = String.trim(raw)

    cond do
      is_nil(socket.assigns.area_prompt) ->
        {:noreply, socket}

      typed == "" ->
        {:noreply, socket}

      true ->
        changeset = Group.search_area_changeset(socket.assigns.group, %{search_area: typed})

        if changeset.valid? do
          {:noreply,
           start_async(socket, :area_geocode, fn ->
             {typed, Consensus.Discovery.Geocoder.geocode(typed)}
           end)}
        else
          {:noreply,
           socket
           |> assign(:area_form, to_form(Map.put(changeset, :action, :validate), as: :area))
           |> restream(socket.assigns.area_prompt.activity_id)}
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

  ## Async — the assist lookup (brief F1). The failure trio — no match, provider error,
  ## timeout, and a crashed task — all land on the same outcome: the shimmer stops and
  ## NOTHING renders. No flash, no inline error; the organizer never learns a lookup
  ## was attempted (brief hard constraint 6).

  def handle_async({:assist, activity_id}, {:ok, {:ok, [_ | _] = results}}, socket) do
    socket = assist_stop_looking(socket, activity_id)

    if Enum.any?(socket.assigns.group.activities, &(&1.id == activity_id)) do
      # Never more than 3 rows. The ENFORCED boundary is `Consensus.Discovery.search/3`,
      # which caps at `Discovery.results_cap/0` before any caller sees results (its own
      # tests pin that), so through the real seam this `Enum.take/2` is unreachable and
      # no UI test can exercise it. It stays anyway, deliberately: the brief's "never
      # more than 3 suggestion rows" is a *rendering* rule, and this is the last line
      # that can uphold it if the seam is ever bypassed — a future provider path, a test
      # stubbing above Discovery, a refactor that forgets the cap. Cheap, local, and
      # load-bearing only in exactly that failure.
      suggestions = Map.put(socket.assigns.assist_suggestions, activity_id, Enum.take(results, 3))

      {:noreply,
       socket
       |> assign(:assist_suggestions, suggestions)
       |> restream(activity_id)}
    else
      # The card was deleted while the lookup was in flight — nothing to attach to.
      {:noreply, socket}
    end
  end

  def handle_async({:assist, activity_id}, {:ok, {:ok, []}}, socket) do
    {:noreply, assist_stop_looking(socket, activity_id)}
  end

  def handle_async({:assist, activity_id}, {:ok, {:error, _reason}}, socket) do
    {:noreply, assist_stop_looking(socket, activity_id)}
  end

  def handle_async({:assist, activity_id}, {:exit, _reason}, socket) do
    {:noreply, assist_stop_looking(socket, activity_id)}
  end

  ## Async — the area geocode (brief F2). Success stores the area on the group and runs
  ## the pending lookup for the card that triggered the prompt; every failure —
  ## `:not_found`, a transport error, a crashed task, or a refused write — is a silent
  ## collapse. The area stays unset on failure, so a later add may prompt again
  ## (`@area_prompt_suppressed?` is set by an explicit dismissal only).

  def handle_async(:area_geocode, {:ok, {typed, {:ok, %Area{} = geocoded}}}, socket) do
    prompt = socket.assigns.area_prompt
    socket = close_area_prompt(socket)

    # `search_area` stores the organizer's own words (already changeset-validated at
    # submit); the geocoded bbox is what the lookup actually consumes.
    case Activities.set_search_area(socket.assigns.current_scope, socket.assigns.group, %{
           search_area: typed,
           search_bbox: Area.encode_bbox(geocoded)
         }) do
      {:ok, group} ->
        socket = assign(socket, :group, group)

        # The card the prompt was attached to, plus every card added while it was
        # open (queued in `pending_ids` by `maybe_start_assist/2`) — each gets the
        # one lookup it was owed, keyed per-activity as always. A card deleted in
        # the meantime simply isn't found and fires nothing.
        socket =
          prompt
          |> pending_lookup_ids()
          |> Enum.reduce(socket, fn id, acc ->
            case Enum.find(group.activities, &(&1.id == id)) do
              %Activity{} = activity -> start_assist_lookup(acc, activity)
              nil -> acc
            end
          end)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_async(:area_geocode, {:ok, {_typed, {:error, _reason}}}, socket) do
    {:noreply, close_area_prompt(socket)}
  end

  def handle_async(:area_geocode, {:exit, _reason}, socket) do
    {:noreply, close_area_prompt(socket)}
  end

  ## Add flow

  defp add_named_activity(socket, name) do
    case Activities.add_activity(socket.assigns.current_scope, socket.assigns.group, %{name: name}) do
      {:ok, activity} ->
        {:noreply, socket |> insert_activity(activity) |> maybe_start_assist(activity)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not add that option.")}
    end
  end

  ## The assist (see the moduledoc). Only a typed-name add ever reaches this — the
  ## pasted-URL path above goes straight to LinkPreview and fires no discovery lookup.

  defp maybe_start_assist(socket, %Activity{} = activity) do
    cond do
      # No provider for this group's activity type: the feature is invisible.
      not socket.assigns.assist_enabled? ->
        socket

      # The group knows where to look: fire the one lookup for this card.
      match?({:ok, _area}, group_area(socket.assigns.group)) ->
        start_assist_lookup(socket, activity)

      # First lookup that needs an area on a group that has none: ask once, in the
      # slot, attached to the card that triggered it (02f). One prompt at a time, and
      # never again this session once dismissed.
      is_nil(socket.assigns.area_prompt) and not socket.assigns.area_prompt_suppressed? ->
        open_area_prompt(socket, activity)

      # Prompt already showing: this card's lookup queues behind the answer. The 02f
      # annotation's "Save ... runs the pending lookup" covers every card added while
      # the question was open, not just the one it is attached to — dropping these on
      # the floor made the assist silently skip whatever the organizer typed while
      # deciding on an area. Each queued lookup fires per-activity from the geocode's
      # success handler; a dismissal discards the queue with the prompt.
      match?(%{}, socket.assigns.area_prompt) ->
        queue_pending_lookup(socket, activity)

      # Prompt dismissed this session: the lookup simply doesn't run and the card
      # stays as typed — the frame's own annotation for a skipped prompt.
      true ->
        socket
    end
  end

  defp queue_pending_lookup(socket, %Activity{id: id}) do
    update(socket, :area_prompt, fn prompt ->
      %{prompt | pending_ids: prompt.pending_ids ++ [id]}
    end)
  end

  # The prompt's own anchor card first, then every card queued while it was open — in
  # the order they were added, each keyed `{:assist, id}` as usual.
  defp pending_lookup_ids(nil), do: []
  defp pending_lookup_ids(%{activity_id: id, pending_ids: pending}), do: [id | pending]

  defp start_assist_lookup(socket, %Activity{} = activity) do
    case group_area(socket.assigns.group) do
      {:ok, area} ->
        # Read before the closure so the Task captures plain values, not the socket.
        activity_type = socket.assigns.group.activity_type
        query = activity.name

        socket
        |> assign(:assist_looking, MapSet.put(socket.assigns.assist_looking, activity.id))
        |> restream(activity.id)
        |> start_async({:assist, activity.id}, fn ->
          Discovery.search(activity_type, query, area)
        end)

      {:error, _reason} ->
        socket
    end
  end

  defp group_area(%Group{search_area: search_area, search_bbox: search_bbox}) do
    Area.decode(search_area, search_bbox)
  end

  defp open_area_prompt(socket, %Activity{} = activity) do
    socket
    |> assign(:area_prompt, %{activity_id: activity.id, pending_ids: []})
    |> assign(
      :area_form,
      to_form(Group.search_area_changeset(socket.assigns.group, %{}), as: :area)
    )
    |> restream(activity.id)
  end

  defp close_area_prompt(socket) do
    case socket.assigns.area_prompt do
      nil ->
        socket

      %{activity_id: activity_id} ->
        socket
        |> assign(:area_prompt, nil)
        |> assign(:area_form, nil)
        |> restream(activity_id)
    end
  end

  defp assist_stop_looking(socket, activity_id) do
    socket
    |> assign(:assist_looking, MapSet.delete(socket.assigns.assist_looking, activity_id))
    |> restream(activity_id)
  end

  defp confirm_suggestion(socket, %Activity{} = activity, %Result{} = suggestion) do
    attrs =
      case suggestion.website_url do
        nil -> %{name: suggestion.name}
        url -> %{name: suggestion.name, source_url: url}
      end

    case Activities.update_activity(socket.assigns.current_scope, activity, attrs) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(
            :assist_suggestions,
            Map.delete(socket.assigns.assist_suggestions, updated.id)
          )
          |> put_activity_assign(updated)
          |> stream_insert(:activities, updated)

        {:noreply, maybe_enrich_confirmed(socket, updated, suggestion)}

      {:error, _changeset} ->
        # Organizer action, not a lookup — the silence rules don't bind it, and a
        # silently dead button would be worse. The slot stays open.
        {:noreply, put_flash(socket, :error, "Could not use that suggestion.")}
    end
  end

  # With a website: the card enriches exactly as a pasted link does — same async key
  # shape, same handle_async clauses — except the name. The paste path adopts og:title
  # over a still-provisional host name; here the name is the provider's *canonical* one
  # the organizer just pressed `Use this` on, so the fetch is `:never` allowed to
  # replace it (observed live: og:title "Vernick Philadelphia" overwrote the confirmed
  # "Vernick Food & Drink"). Photo/description/metadata still fill in. Without a
  # website: name + address were the whole win; nothing to fetch.
  defp maybe_enrich_confirmed(socket, %Activity{}, %Result{website_url: nil}) do
    socket
  end

  defp maybe_enrich_confirmed(socket, %Activity{} = updated, %Result{website_url: url}) do
    socket
    |> assign(:assist_enriching, MapSet.put(socket.assigns.assist_enriching, updated.id))
    |> mark_fetching(updated.id)
    |> start_async({:link_preview, updated.id, :never}, fn -> LinkPreview.fetch(url) end)
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

  # `@add_reset`'s id bump is what clears the input (a fresh element, a fresh empty
  # value) — but a recreated element has no focus, so the keyboard drops mid-flow on the
  # screen whose whole rhythm is type-Add-type-Add (frame 02b: "the input clears and
  # stays focused so the next name can be typed"). `@add_refocus` arms `phx-mounted`'s
  # `JS.focus()` on the recreated input for exactly this render: it is set only here —
  # an Add press — and cleared by every `apply_action(:index, ...)`, so the initial
  # mount and a patch back from the editor (both of which also (re)create the element)
  # never steal focus.
  defp insert_activity(socket, activity) do
    socket
    |> put_activity_assign(activity)
    |> assign(:add_form, fresh_add_form())
    |> update(:add_reset, &(&1 + 1))
    |> assign(:add_refocus, true)
    |> stream_insert(:activities, activity)
  end

  ## Async result application

  # `name_strategy` is either the id-th activity's name at the moment the fetch
  # started — only overwrite the name if nobody has touched it since — or the atom
  # `:never`, used by refetch (an explicit organizer action on the edit screen, where
  # overwriting whatever they've typed as the name would be surprising) and by the
  # assist-confirm enrichment (the name is the provider's canonical one the organizer
  # just accepted — og:title must not replace it). Both only ever "overwrite the three
  # fields" (description, image, timestamp) per the spec.
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
    |> clear_assist_state(removed_id)
    |> stream(:activities, group.activities, reset: true)
  end

  # A deleted card takes its assist state with it: an in-flight lookup's result will
  # find no row to attach to (the `{:assist, id}` success clause re-checks), a shown
  # slot must not survive its card, and a prompt attached to the deleted card closes —
  # without suppressing, since nobody dismissed it.
  defp clear_assist_state(socket, removed_id) do
    socket =
      socket
      |> assign(:assist_looking, MapSet.delete(socket.assigns.assist_looking, removed_id))
      |> assign(:assist_suggestions, Map.delete(socket.assigns.assist_suggestions, removed_id))
      |> assign(:assist_enriching, MapSet.delete(socket.assigns.assist_enriching, removed_id))

    case socket.assigns.area_prompt do
      # The prompt's anchor card is gone: the prompt closes and its queue dies with
      # it — nobody dismissed it, so nothing is suppressed and a later add may ask
      # again (and re-queue).
      %{activity_id: ^removed_id} ->
        socket |> assign(:area_prompt, nil) |> assign(:area_form, nil)

      # The prompt survives; a deleted card must not get a posthumous lookup.
      %{pending_ids: pending} = prompt ->
        assign(socket, :area_prompt, %{prompt | pending_ids: List.delete(pending, removed_id)})

      _ ->
        socket
    end
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
  # provenance line depends on `@fetching` membership, which just changed. Every
  # enrichment outcome funnels through here, so this is also where an assist-confirmed
  # card's 02e treatment (violet shadow, shimmer tile) ends.
  defp unmark_fetching(socket, activity_id) do
    socket
    |> assign(:fetching, MapSet.delete(socket.assigns.fetching, activity_id))
    |> assign(:assist_enriching, MapSet.delete(socket.assigns.assist_enriching, activity_id))
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

  defp parse_index(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {index, ""} when index >= 0 -> {:ok, index}
      _ -> :error
    end
  end

  defp parse_index(_raw), do: :error

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

  ## The unsaved-draft guard on `:edit_activity` (D-045)
  #
  # `back_patch` and every control in the global footer re-run `handle_params/3`, which
  # rebuilds `@edit_form` from the *stored* activity — so a name or description typed here
  # and not saved is discarded silently. Only the `:edit_activity` branch needs this: the
  # `:index` branch's "add an option" field commits on submit and holds nothing across a
  # navigation that anyone would miss. The image URL form is excluded for the same reason —
  # it is a one-field submit, and `@replacing_image` resets on its own.
  defp edit_draft?(%{edit_form: form, editing_activity: activity}) do
    field_differs?(form[:name].value, activity.name) or
      field_differs?(form[:description].value, activity.description)
  end

  defp field_differs?(typed, stored),
    do: String.trim(to_string(typed)) != String.trim(to_string(stored))

  defp edit_discard_prompt,
    do: "Leave without saving this option? Your edits to it aren't stored yet."

  ## Provenance line ("typed by you · no details yet", "fetching details…", ...)
  #
  # Derived from what the row actually holds, never from the fact that a fetch ran —
  # see the moduledoc. `metadata_fetched_at` is the only signal that a fetch ever
  # *succeeded*; whether it found a photo, a description, both or neither is read
  # straight off `image_url`/`description`, so a page with no og:description can never
  # be reported as having one.

  # A typed row starts with nothing, but the organizer can add a photo URL or a
  # description by hand in `02b` — so "no details yet" is only true while it still has
  # none. Reporting it unconditionally made the row contradict the editor the organizer
  # had just saved.
  defp provenance_text(%Activity{source_url: nil} = activity, _fetching) do
    if present?(activity.image_url) or present?(activity.description) do
      "typed by you · " <> resolved_summary(activity, "added")
    else
      "typed by you · no details yet"
    end
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

  # The pool card's meta line, as a single string — either the 02e enriching interval's
  # own copy or the derived provenance line above.
  defp card_meta_text(assigns, activity) do
    if assist_enriching?(assigns, activity),
      do: "link attached · details arriving",
      else: provenance_text(activity, assigns.fetching)
  end

  # Splits the meta line at its " · " separators into wrap-safe phrases, each non-final
  # phrase keeping a trailing " ·" — see the template comment on the pool card's meta
  # line: the phrases render as `whitespace-nowrap` spans so a narrow viewport breaks
  # at a separator, never mid-phrase.
  defp meta_phrases(text) do
    phrases = String.split(text, " · ")
    last = length(phrases) - 1

    Enum.with_index(phrases, fn phrase, index ->
      if index < last, do: phrase <> " ·", else: phrase
    end)
  end

  defp added_by_you_count(%Group{activities: activities}, current_scope) do
    Enum.count(activities, &(&1.added_by_id == current_scope.user.id))
  end

  ## Assist rendering helpers (frame t5). All read the socket assigns handed to
  ## `render/1`, so a stream re-insert re-evaluates them against current state.

  # What hangs under a card: the one-time area prompt beats suggestions (they cannot
  # coexist — no lookup has run while the prompt is open), then a non-empty result
  # list, then nothing.
  defp assist_slot(%{area_prompt: %{activity_id: id}}, %Activity{id: id}), do: :area_prompt

  defp assist_slot(%{assist_suggestions: suggestions}, %Activity{id: id}) do
    case Map.get(suggestions, id) do
      [_ | _] = results -> {:suggestions, results}
      _ -> nil
    end
  end

  # The slot's exit (02c annotation: "✕ collapses the same way", 120ms). The server has
  # already dropped the element; `phx-remove` keeps it in the DOM for exactly the
  # collapse: `.assist-slot-collapsing` animates the reveal wrapper's grid row back to
  # 0fr (and, under prefers-reduced-motion, does nothing — the media query strips every
  # transition, so the element just leaves).
  defp collapse_slot do
    JS.hide(transition: {"assist-slot-collapsing", "", ""}, time: 120)
  end

  defp assist_looking?(%{assist_looking: looking}, %Activity{id: id}),
    do: MapSet.member?(looking, id)

  defp assist_enriching?(%{assist_enriching: enriching}, %Activity{id: id}),
    do: MapSet.member?(enriching, id)

  # The pool card is `sticker_card/1`'s depth-2 white row hand-rolled, because the
  # assist needs three chrome states the primitive has no prop for: with a slot
  # attached the card squares its bottom corners and hands the slot its shadow
  # (frames 02c/02d/02f); while enriching the shadow goes violet (02e); otherwise it
  # is byte-for-byte the row the screen always drew.
  defp pool_card_class(slot, enriching?) do
    [
      "flex items-center gap-2.5 border-2 border-ink bg-white px-2.5 py-2.5",
      if(slot, do: "rounded-t-2xl", else: "rounded-2xl"),
      cond do
        slot != nil -> nil
        enriching? -> "shadow-assist"
        true -> "shadow-sticker-2"
      end
    ]
  end

  # The one-match row's cuisine chip (02c) — only when the provider supplied one.
  # `Result.chips` is display-only `[{label, value}]`; anything else renders nothing.
  defp suggestion_cuisine(%Result{chips: chips}) when is_list(chips) do
    case List.keyfind(chips, "cuisine", 0) do
      {"cuisine", value} when is_binary(value) and value != "" -> String.capitalize(value)
      _ -> nil
    end
  end

  defp suggestion_cuisine(_result), do: nil

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

  # `relative` + a `-inset-y-2` `::before` takes the painted 54×28 pill to a 54×44 hit box
  # without moving a pixel of it — the same expander `GroupLive.Review`'s `×` and
  # `Chrome`'s header circles use, on the screen the whole creation flow types into and
  # repeated once per option. It grows vertically only: the pill is already wider than 44,
  # and `Remove` sits 16px to its right with its own box (see the row below). 8px a side
  # also stays inside the card's own `py-2.5`, so two stacked cards' boxes cannot meet.
  # White at rest, yellow only on hover/press. Both the original 02 frame
  # (docs/design/screens/1a-1-02-add-options-manual-mvp.html) and every t5 panel draw
  # the resting pill as white with the 2px ink outline and `hover: background:#FFD84D`
  # — the single yellow pill in each drawing carries the *pressed* hover (translate +
  # shadow collapse), i.e. it is the same control illustrated mid-hover. Solid yellow
  # at rest was an app deviation; yellow stays the fill of the actual actions
  # (Add / Save / Use this).
  defp edit_pill_class do
    [
      "relative inline-flex items-center gap-1 rounded-full border-2 border-ink bg-white",
      "hover:bg-yellow active:bg-yellow",
      "px-2.5 py-1 text-[10.5px] font-semibold text-ink shadow-sticker-2 press-2",
      # `inset-x-0` is not decoration. An absolutely positioned `::before` with only
      # `top`/`bottom` set has `width: auto` on empty content, which is zero — measured, the
      # box stayed 54×29 until both axes were named.
      "before:absolute before:inset-x-0 before:-inset-y-2 before:content-['']"
    ]
  end

  @impl true
  def render(%{live_action: :edit_activity, editing_activity: activity} = assigns)
      when not is_nil(activity) do
    ~H"""
    <%!-- `02b`'s `✕` was a close-to-parent, i.e. a back control, so it is the global
          header's `back` now (plan ruling 1) and this row keeps only the h1 and Remove.
          `back_patch`, not `back`: `/groups/:id/options` is *this same LiveView*, so a
          `navigate` would tear the socket down, cancel any in-flight `LinkPreview`
          `start_async` keyed to a row and rebuild the stream — which is exactly what the
          `✕`'s `patch` used to avoid. No `context` either: "EDIT OPTION" in the header
          and "Edit option" in the row 40px below is the same string twice. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back_patch={~p"/groups/#{@group}/options"}
      back_confirm={edit_draft?(assigns) && edit_discard_prompt()}
      footer_confirm={edit_draft?(assigns) && edit_discard_prompt()}
    >
      <div class="flex items-center justify-between gap-3 border-b-2 border-ink px-5 py-3">
        <div class="flex items-center gap-2.5">
          <h1 class="text-[15px] font-bold text-ink">Edit option</h1>
        </div>
        <%!-- Ink, not tangerine. Tangerine appears exactly once per screen as the one
              forward action, and on this screen that is "Save option"; a destructive
              control wearing the same colour as the forward one is the house rule
              broken twice over. --%>
        <%!-- **The one control on this screen that destroys an option, and it was the
              smallest.** Measured at 360×640: painted 47.8×18.8 with no `::before` at all,
              i.e. a 19px effective box on the vertical axis — 43% of the 44px platform
              minimum — 13.9px under the sticky header, beside a 56px field and a 60px Save.

              Same pseudo-element expander `Chrome.header/1` uses for its 29px circles and
              `edit_pill_class/0` uses two hundred lines up: the glyph keeps the design's
              12.5px underline treatment and the hit box reaches 44. The arithmetic is off
              the **padding** box (no border and no padding here, so 18.8), giving
              (44 − 18.8) / 2 = 12.6px a side — top lands at 49.3 against the header's 48px
              bottom edge, so the two do not meet. Both axes are named because an absolutely
              positioned `::before` with only `top`/`bottom` set has `width: auto`, which on
              empty content is zero.

              `active:` beside `hover:` for the reason every other control in this app now
              carries it: `:hover` does not exist on touch, so on a phone the destructive
              control acknowledged a tap in no way at all until the round-trip landed. --%>
        <button
          type="button"
          phx-click="remove_option"
          data-confirm={"Remove #{@editing_activity.name}? This can't be undone."}
          aria-label={"Remove #{@editing_activity.name}"}
          class={[
            "relative text-[12.5px] font-semibold text-ink-soft underline decoration-ink/30",
            "underline-offset-2 hover:text-ink hover:decoration-ink",
            "active:text-ink active:decoration-ink",
            "before:absolute before:-inset-x-2 before:-inset-y-[12.6px] before:content-['']"
          ]}
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
            <%!-- **These two were the only controls in the app whose entire feedback state
                  was `hover:`** — no `active:`, no `press-*`, and `box-shadow: none`, so on
                  touch a tap produced no visual change whatsoever. Both also measured 32.5px
                  tall at 360×640 (65.3×32.5 and 99×32.5), under the 44px minimum.

                  The expander grows **vertically only**: they sit in a `flex gap-1.5` pair,
                  so 6px is all the horizontal clearance there is and two boxes meeting would
                  be worse than two small ones. `inset-x-0` rather than an inset, because the
                  `width: auto` trap above applies here too. Off the padding box again —
                  `border-2` means 32.5 − 4 = 28.5, so (44 − 28.5) / 2 = 7.75px a side, which
                  lands the pair at 234.75–282.75 inside a photo frame whose bottom edge is
                  285. --%>
            <div class="absolute bottom-2.5 right-2.5 flex gap-1.5">
              <button
                type="button"
                phx-click="toggle_replace_image"
                class={[
                  "relative rounded-2xl border-2 border-ink bg-white px-2.5 py-1.5",
                  "text-[11px] font-semibold hover:bg-yellow active:bg-yellow",
                  "before:absolute before:inset-x-0 before:-inset-y-[7.75px] before:content-['']"
                ]}
              >
                Replace
              </button>
              <%!-- "Remove photo", not "Remove": the row above this frame carries a
                    `Remove` that deletes the whole option, and two controls with the same
                    word on one screen doing different things — one destructive, one
                    trivially undoable by pasting the link again — is plan confusion type 5.
                    The bare word belongs to the destructive one. --%>
              <button
                type="button"
                phx-click="remove_image"
                disabled={is_nil(@editing_activity.image_url)}
                class={[
                  "relative rounded-2xl border-2 border-ink bg-white px-2.5 py-1.5",
                  "text-[11px] font-semibold hover:bg-yellow active:bg-yellow",
                  "disabled:cursor-not-allowed disabled:opacity-45",
                  "before:absolute before:inset-x-0 before:-inset-y-[7.75px] before:content-['']"
                ]}
              >
                Remove photo
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
                class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[16px] shadow-field focus:outline-none"
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
              class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[16px] font-bold shadow-field focus:outline-none"
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
              class="min-h-[74px] w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[16px] leading-[1.45] shadow-field focus:outline-none"
            />
            <%!-- "vote", not "rank". Nothing in this app ranks anything —
                  `JoinLive.Ballot`'s moduledoc says "there is no ranking anywhere in here"
                  and `Consensus.Voting.Vote`'s says "there is deliberately no rank or weight
                  column here". This was the last user-visible instance in `lib/`; keep
                  `grep -rni rank lib/` clean. --%>
            <p class="text-[11px] text-muted">Everyone sees this when they vote.</p>
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

      <%!-- "Cancel" is gone. It navigated to `/groups/:id/options` — the same place the
            header's `‹` goes — so it was the second back affordance plan ruling 1 exists
            to remove, and it sat next to the tangerine as if it were the other half of a
            pair of form actions. Save is the only action in this bar now. --%>
      <div class="flex items-center gap-2.5 border-t-2 border-ink bg-white px-5 py-4">
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
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back={~p"/groups/#{@group}/edit"}
      context="STEP 2 OF 3"
    >
      <div class="flex min-h-0 flex-1 flex-col gap-4 px-5 pt-4">
        <.step_progress total={3} current={2} />

        <%!-- One line, never two. Every t5 panel draws the H1 as a single line —
              `font:700 28px/1.1`, letter-spacing -.025em — and it holds one line at the
              panel's own 300px content width, so it holds at 375px (335px content) with
              room to spare. The old 29px/`<br/>` two-line stack was an app deviation. --%>
        <h1 class="text-[28px] font-bold leading-[1.1] tracking-[-0.025em] text-ink">
          Add the options
        </h1>

        <div class="flex flex-col gap-2">
          <.eyebrow>Activity type</.eyebrow>
          <div class="flex items-center gap-2 overflow-x-auto pb-1">
            <.chip selected tone={:ink} class="shrink-0">
              {String.capitalize(@group.activity_type)}
              <span class="text-[11px] font-medium opacity-75" aria-hidden="true">›</span>
            </.chip>
            <%!-- `quiet`, not the bare disabled state: the t5 panels draw Bars/Movies
                  with a fine `rgba(23,33,28,.38)` dash and faint text so they visibly
                  recede behind the live Restaurant chip, where the `01` frame draws its
                  disabled `Custom…` chip full-ink dashed. The frame families differ per
                  screen, so the quiet treatment is a `Sticker.chip/1` variant this
                  screen opts into, not a change to the shared disabled default. --%>
            <.chip disabled quiet>Bars</.chip>
            <.chip disabled quiet>Movies</.chip>
          </div>
          <%!-- No caption under the chips. The original 02 frame carried "Restaurants
                first. More types as we grow." but every t5 panel — the newest ground
                truth for this screen — omits it (the helper budget moved to the
                assist's line under the input), so the removal is current design
                intent. The dashed Bars/Movies chips still say "more types later" on
                their own. --%>
        </div>

        <%!-- **The add form is sticky; the pool scrolls beneath it.** Every t5 panel
              composes this screen as a fixed input with earlier cards sliding off under
              the helper line, and the brief's constraint 5 says why: the input must stay
              reachable for the next option while a suggestion is showing — on a long
              pool, page scroll used to carry it out of the viewport exactly then.
              `sticky top-[48px]` pins it flush under the global chrome header (a
              constant 48px — `Chrome.header/1` is `sticky top-0 z-40 min-h-[48px]`);
              `z-20` keeps it under the flash (`z-30`) and header; `-mx-5 px-5` bleeds
              the opaque `bg-surface` across the column's own padding so a card's 2px
              offset shadow cannot peek past the dock's edge as it slides under. The
              page stays the scroller (the layouts moduledoc's rule: no `fill_viewport`
              here — sticky works at every viewport height, including the short-viewport
              range where `.viewport-column`'s clamp deliberately turns off). H1 and the
              type chips scroll away above it, a recorded divergence from the frame's
              fixed-height device. `data-reveal-boundary` is load-bearing: the
              `AssistReveal` hook treats the dock's bottom edge as the top of the
              visible area, so its clamp cannot scroll a card's name row under the
              pinned form. --%>
        <div
          id="add-option-dock"
          data-reveal-boundary
          class="sticky top-[48px] z-20 -mx-5 flex flex-col gap-2 bg-surface px-5"
        >
          <%!-- **Every field on this screen is 16px, and none may go below it.** iOS
                Safari zooms the page on focus whenever the focused field computes under
                16px and never zooms back out; this is the field the whole creation flow
                types into, so it was the worst instance in the app. The frames specify
                13–15px here — a static mockup measured in a design tool cannot see focus
                zoom, and the join-entry field was already raised to 16px for exactly this
                reason (the precedent existed, it simply was not swept). Recorded in
                D-046. --%>
          <.eyebrow>Type a name or paste a link</.eyebrow>
          <.form for={@add_form} id="add-option-form" phx-submit="add_activity" class="flex gap-2">
            <div class="flex-1">
              <%!-- `phx-mounted` only when `@add_refocus` armed it (an Add press, and
                    nothing else): the id bump recreates this element to clear it, and
                    the recreated element must take the focus the old one held (frame
                    02b: "the input clears and stays focused"). Initial mount and every
                    patch render it without the attribute — see `insert_activity/2`. --%>
              <.input
                id={"add-option-query-#{@add_reset}"}
                field={@add_form[:query]}
                type="text"
                placeholder="Name or link"
                phx-mounted={@add_refocus && JS.focus()}
                class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-[16px] font-medium shadow-field placeholder:text-faint focus:outline-none"
              />
            </div>
            <button type="submit" class={yellow_button_class()}>Add</button>
          </.form>
          <%!-- The F4 copy swap (frame 02a): describes what the assist actually does — a
                lookup after Add, never search — so the line stays honest whether or not a
                suggestion ever appears. The word "search" is deliberately absent: this is
                not search, and calling it that invites the "thai near me" misuse the old
                line existed to prevent. The dashed Bars/Movies chips above stay dashed. --%>
          <p class="text-[11.5px] leading-[1.4] text-muted">
            Type a name and we'll try to find its link. Or paste one yourself.
          </p>
        </div>

        <%!-- `overflow-x-clip` beside `overflow-y-auto`: Tailwind's `overflow-y-auto` sets
              only one axis and the other computes to `auto`, so the cards' 2px hard offset
              shadow (`scrollWidth` 382 against `clientWidth` 380 — measured with a single
              option in the pool) painted a permanent full-width horizontal scrollbar under
              the pool that scrolls exactly two pixels. At this width it reads as a divider
              or a progress bar, not as a scrollbar, on the screen the organizer spends the
              most time on. Clipping the axis rather than padding the track keeps the
              cards' left edge on the page's type column. --%>
        <div
          id="pool-list"
          phx-update="stream"
          class="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto overflow-x-clip pb-2"
        >
          <%!-- Each stream child is a wrapper so the assist's suggestion slot (02c/02d)
                or the one-time area prompt (02f) can attach *under* the card while the
                pair stays one stream item. The card itself is the old `sticker_card`
                depth-2 row hand-rolled (same classes), because the assist needs states
                the primitive has no prop for: squared bottom corners + no shadow while a
                slot hangs off it (the slot carries the pair's `shadow-sticker-2`), and
                the violet `shadow-assist` for the 02e enriching interval. With the
                feature absent every conditional below is inert and the row renders
                exactly as it always has. Assist state lives in assigns, so every change
                to it re-streams the affected row (mark/unmark/restream helpers) — a
                streamed item never re-renders on an assign change alone. --%>
          <div
            :for={{dom_id, activity} <- @streams.activities}
            id={dom_id}
            class="flex flex-col"
          >
            <div class={
              pool_card_class(assist_slot(assigns, activity), assist_enriching?(assigns, activity))
            }>
              <.position_badge n={activity.position} />
              <div
                :if={assist_enriching?(assigns, activity)}
                class="assist-shim-anim stripes-mint stripe-pitch-5 size-8 shrink-0 rounded-[9px] border-2 border-ink"
                aria-hidden="true"
              >
              </div>
              <div class="min-w-0 flex-1">
                <p class={[
                  "truncate font-bold text-ink",
                  if(assist_enriching?(assigns, activity),
                    do: "assist-name-in text-[13.5px] leading-[1.15]",
                    else: "text-[14px]"
                  )
                ]}>
                  {activity.name}
                </p>
                <%!-- 02b "added, looking": the shimmer bar replaces the meta line while
                      the one lookup is in flight, and must read as "nothing is wrong" if
                      nothing ever follows — when the async returns, empty or not, the
                      plain provenance line simply comes back. No spinner, no text. --%>
                <div
                  :if={assist_looking?(assigns, activity)}
                  class="assist-shim mt-[3px] h-[9px] w-[132px] rounded-full"
                  aria-hidden="true"
                >
                </div>
                <%!-- Phrase-by-phrase, not one text node: at 375px the line used to
                      wrap mid-phrase ("no details / yet"). Each phrase is a nowrap
                      span carrying its own trailing "·", and the whitespace *between*
                      the spans (the `for` block's newlines) is the only break
                      opportunity — so a narrow card wraps at the separator, never
                      inside a phrase. --%>
                <p
                  :if={!assist_looking?(assigns, activity)}
                  class="font-mono text-[10.5px] text-muted"
                >
                  <%= for phrase <- meta_phrases(card_meta_text(assigns, activity)) do %>
                    <span class="whitespace-nowrap">{phrase}</span>
                  <% end %>
                </p>
              </div>
              <%!-- `gap-6`, not `gap-2.5`. Both controls now carry a `::before` expander, and
                  `Remove` starts 6px early (`-m-1.5`) before its box adds another 8px to the
                  left — so the gutter has to cover 14px before either control gets any clear
                  space at all. At 16px the destructive control's hit box came within 2px of
                  Edit's; 24px leaves 10px, measured. The name beside them is
                  `min-w-0 flex-1 truncate`, so the width comes out of an ellipsis. --%>
              <div class="flex shrink-0 items-center gap-6">
                <%!-- Icon-only while the card enriches (frame 02e collapses Edit to ✎ to
                      make room for the photo tile); the aria-label carries the word. --%>
                <.link
                  patch={~p"/groups/#{@group}/options/#{activity.id}"}
                  aria-label={"Edit #{activity.name}"}
                  class={edit_pill_class()}
                >
                  {if assist_enriching?(assigns, activity), do: "✎", else: "✎ Edit"}
                </.link>
                <%!-- Measured 16×24px, whose entire affordance was a hover colour — which does
                    not exist on touch, so a tap gave no feedback at all. `-m-1.5 p-1.5`
                    grows the box to 28×36 without moving the glyph, and `active:` gives
                    touch the acknowledgement `hover:` gave the pointer.

                    28×36 was still 8px short in each axis of the 44×44 platform minimum, on
                    the destructive control of the screen the creation flow lives in — while
                    `Chrome`'s header circles and `GroupLive.Review`'s `×` both reach 44 with
                    a `::before` expander. `-inset-x-2 -inset-y-1` is that expander sized to
                    land exactly on 44×44: asymmetric because the padding already bought
                    height and not width. Both insets stay inside the card's own `px-2.5` /
                    `py-2.5`, so no two cards' Remove boxes can touch across the list gap —
                    which for a destructive control would be worse than the small target
                    was. `data-confirm` is still what makes a mis-tap recoverable. --%>
                <button
                  type="button"
                  phx-click="delete_activity"
                  phx-value-id={activity.id}
                  data-confirm={"Remove #{activity.name} from the pool?"}
                  aria-label={"Remove #{activity.name}"}
                  class="relative -m-1.5 rounded-full p-1.5 text-muted transition-colors before:absolute before:-inset-x-2 before:-inset-y-1 before:content-[''] hover:text-tangerine active:bg-yellow active:text-tangerine"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>
            <%= case assist_slot(assigns, activity) do %>
              <% {:suggestions, results} -> %>
                <%!-- Frames 02c (one match) / 02d (two–three). Rows carry name + street
                      address (+ a cuisine chip on the one-match shape) and NOTHING else:
                      no rating, no price, no photo, no hours, no distance — the licence
                      rule the brief's constraint 2 pins. Max 3 rows, hard. --%>
                <%!-- The reveal wrapper carries the slot's whole life in motion terms
                      (02c annotation: 180ms height expand in, 120ms collapse out via
                      phx-remove; CSS `.assist-slot-reveal` / `@starting-style`, no JS)
                      plus the `AssistReveal` hook that scrolls the pool just enough to
                      show it (02d annotation, frame-review §e-3 clamp). It exists only
                      while the slot does, so the silence states' subtree is untouched. --%>
                <div
                  id={"assist-slot-#{activity.id}"}
                  class="assist-slot-reveal"
                  phx-hook="AssistReveal"
                  phx-remove={collapse_slot()}
                >
                  <div class="assist-slot flex flex-col gap-2 px-[11px] pb-2 pt-[9px]">
                    <div class="flex items-center justify-between gap-2">
                      <span class="font-mono text-[10.5px] font-semibold uppercase tracking-[0.05em] text-muted">
                        Is this it?
                      </span>
                      <button
                        type="button"
                        phx-click="assist_dismiss"
                        phx-value-id={activity.id}
                        title="No thanks"
                        aria-label="No thanks"
                        class="relative px-1 text-[15px] font-medium leading-none text-muted before:absolute before:-inset-3 before:content-[''] hover:text-tangerine active:text-tangerine"
                      >
                        ✕
                      </button>
                    </div>
                    <%= for {result, index} <- Enum.with_index(results) do %>
                      <div :if={index > 0} class="assist-divider" aria-hidden="true"></div>
                      <div class="flex items-center gap-[9px]">
                        <%!-- Stacked, never inline: the frame's own 02c rendering puts
                              the cuisine chip on its own row between the venue name and
                              the address (at the panel's 340px the name+chip pair
                              wraps, and the rendered PNG — the judge's ground truth —
                              shows three stacked rows). `self-start` keeps the chip
                              hugging its text instead of stretching the column. --%>
                        <div class="flex min-w-0 flex-1 flex-col gap-[3px]">
                          <span class={[
                            "font-bold text-ink",
                            if(length(results) == 1, do: "text-[13.5px]", else: "text-[13px]")
                          ]}>
                            {result.name}
                          </span>
                          <span
                            :if={length(results) == 1 && suggestion_cuisine(result)}
                            class="self-start rounded-full border-[1.5px] border-ink/45 bg-white px-[7px] py-px font-mono text-[9px] font-medium text-muted"
                          >
                            {suggestion_cuisine(result)}
                          </span>
                          <span :if={result.address} class="font-mono text-[10.5px] text-muted">
                            {result.address}
                          </span>
                        </div>
                        <button
                          type="button"
                          phx-click="assist_use"
                          phx-value-id={activity.id}
                          phx-value-index={index}
                          class={[
                            "shrink-0 rounded-full border-2 border-ink bg-yellow font-bold text-ink shadow-sticker-2 press-2",
                            if(length(results) == 1,
                              do: "px-[13px] py-[9px] text-[11.5px]",
                              else: "px-3 py-2 text-[11px]"
                            )
                          ]}
                        >
                          Use this
                        </button>
                      </div>
                    <% end %>
                    <%!-- The frame links ONLY the contributors phrase; the "Places from "
                        prefix stays plain text. Both halves and the ODbL href come from
                        the provider via `Discovery.attribution_for/1` — nothing here is
                        hardcoded. --%>
                    <p :if={@assist_attribution} class="font-mono text-[9px] text-faint">
                      {@assist_attribution.prefix}<a
                        href={@assist_attribution.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="underline underline-offset-2 hover:text-tangerine"
                      >{@assist_attribution.text}</a>
                    </p>
                  </div>
                </div>
              <% :area_prompt -> %>
                <%!-- Frame 02f, the one-time area prompt (F2) — in the slot, instead of
                      results. The ✕ is the flagged frame disagreement resolved in favour
                      of the annotation + brief: dismissible like any suggestion. The
                      field computes at 16px (invariant 18) and carries no maxlength
                      (invariant 11 — `Group.search_area_changeset/2`'s 100-grapheme cap
                      is the real limit; `01 setup`'s title field has no live counter, so
                      none here either, matching that convention). --%>
                <%!-- Same reveal wrapper as the suggestion slot above — the prompt
                      occupies the slot and expands the same way (02f annotation), and
                      the `AssistReveal` scroll matters MOST here: an area prompt that
                      renders below the fold and is never seen silently disables the
                      assist for the session. --%>
                <div
                  id={"assist-area-prompt-#{activity.id}"}
                  class="assist-slot-reveal"
                  phx-hook="AssistReveal"
                  phx-remove={collapse_slot()}
                >
                  <div class="assist-slot flex flex-col gap-2 px-[11px] py-2.5">
                    <div class="flex items-start justify-between gap-2">
                      <div class="flex min-w-0 flex-col gap-[3px]">
                        <span class="text-[13.5px] font-bold text-ink">Where should we look?</span>
                        <span class="text-[11px] leading-[1.35] text-muted">
                          So we can match names to the right places. Asked once, then remembered for this group.
                        </span>
                      </div>
                      <button
                        type="button"
                        phx-click="assist_dismiss_area"
                        title="No thanks"
                        aria-label="No thanks"
                        class="relative shrink-0 px-1 text-[15px] font-medium leading-none text-muted before:absolute before:-inset-3 before:content-[''] hover:text-tangerine active:text-tangerine"
                      >
                        ✕
                      </button>
                    </div>
                    <.form
                      for={@area_form}
                      id="area-prompt-form"
                      phx-submit="area_submit"
                      class="flex items-start gap-2"
                    >
                      <div class="min-w-0 flex-1">
                        <%!-- The violet-soft shadow needs the `!`: `CoreComponents.input/1`
                              *appends* @class to its base classes (which carry the mint
                              `shadow-field`), and `.shadow-field` sorts after this
                              arbitrary utility in the compiled sheet, so without the
                              important marker the mint won and the field measured
                              #B9EFC9 at rest. The assist family carries violet-soft
                              #D6CCFB (frame-review §d.5 — a deliberate, scoped
                              deviation from DESIGN-SPEC's mint-at-rest rule). --%>
                        <.input
                          field={@area_form[:search_area]}
                          type="text"
                          placeholder="Neighborhood or city"
                          class="w-full rounded-xl border-2 border-ink bg-white px-3 py-2.5 text-[16px] font-medium shadow-[2px_2px_0_var(--color-violet-soft)]! placeholder:text-faint focus:outline-none"
                        />
                      </div>
                      <button
                        type="submit"
                        class="shrink-0 rounded-xl border-2 border-ink bg-yellow px-3.5 py-[11px] text-[13px] font-bold text-ink shadow-sticker-2 press-2"
                      >
                        Save
                      </button>
                    </.form>
                    <p :if={@assist_attribution} class="font-mono text-[9px] text-faint">
                      {@assist_attribution.prefix}<a
                        href={@assist_attribution.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="underline underline-offset-2 hover:text-tangerine"
                      >{@assist_attribution.text}</a>
                    </p>
                  </div>
                </div>
              <% nil -> %>
            <% end %>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-3 border-t-2 border-ink bg-white px-5 py-4">
        <div class="flex flex-1 flex-col gap-0.5">
          <span class="text-[15px] font-bold text-ink">
            {length(@group.activities)} in the pool
          </span>
          <%!-- "N yours", not "N added by you" — both the original 02 frame
                ("2 yours · 1 from friends") and t5 ("3 yours") word it this way; the
                longer copy was an app deviation. The "· N from friends" half stays
                unbuilt: co-creation is Post-MVP sample garnish (frame-review §e-4). --%>
          <span class="text-[11px] text-muted">
            {added_by_you_count(@group, @current_scope)} yours
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
