defmodule Consensus.Catalog do
  @moduledoc """
  The shared catalog (D-060; docs/plans/item-details-and-catalog.md §3): options
  organizers chose to **Let anyone find this**, searched by the Assisted Add before
  Nominatim so the next organizer who types that name nearby gets the details someone
  already fixed.

  A sibling of `Consensus.Activities`, not part of it: the catalog is read by people
  who own nothing in it.

  ## Sharing is a snapshot (§3.2)

    * `share_activity/2` copies an option's name, description, photo and details into
      a row — or, when an equal row already exists (same `osm_ref`, else the same
      normalised name within ~50 m), links to that one without touching it. One
      organizer's share never rewrites a row another organizer created.
    * A row an option **created** (`shared_from_activity_id`) follows that option's
      later edits (`sync_activity/1`, called by `Consensus.Activities` after every
      write) — until an admin edits it (`admin_edited_at`), after which the admin's
      version wins.
    * `unshare_activity/2` unlinks; a row the option created that nothing else links
      to is deleted with it.
    * Nothing propagates the other way: a group that used a catalog row keeps its own
      copy.

  The share is refused (`{:error, :nothing_to_find}`) for an option with no website,
  address or location — a bare typed name ("Grandma's") has nothing anyone else could
  find, and is the likeliest thing to be private.

  ## Ownership

  `share_activity/2` and `unshare_activity/2` are owning writes on an `%Activity{}`,
  which carries no owner, so they authorize through `Activities.authorize_activity/2`
  — the same two-clause re-read `update_activity/3` uses (invariant 1). Allowed at any
  group status: neither changes the option.

  ## Matching (§3.3)

  `search/3` is a plain indexed query plus a short filter in Elixir — the catalog is
  hundreds to low thousands of rows on one machine, so FTS5 is the upgrade path, not
  the starting point. Every query token must be a prefix of some name token, in any
  order, after `search_name/1` normalised both sides. With a group area, a located row
  must fall inside the area's box widened exactly as the Nominatim lookup widens it;
  a row with no location matches only on an exact normalised name and ranks last.

  `activity_type` is data here as everywhere (invariant 12): the type filter is a
  keyword `where/2`, never a comparison.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Activities.AnonymousOrganizer
  alias Consensus.Catalog.CatalogItem
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Provider.Nominatim
  alias Consensus.Repo

  @dedupe_radius_m 50
  @candidate_limit 200
  @results_cap 3

  ## Normalisation

  @doc """
  The one normalisation used for stored names and for queries: lowercase, accents
  stripped (NFD, combining marks dropped), `&` → `and`, apostrophes deleted, every
  other non-alphanumeric character a space, whitespace collapsed.

      iex> Consensus.Catalog.search_name("Joe's Pizza")
      "joes pizza"

      iex> Consensus.Catalog.search_name("  Café   La Maude & Co. ")
      "cafe la maude and co"
  """
  @spec search_name(String.t()) :: String.t()
  def search_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace("&", " and ")
    |> String.replace(~r/['’‘`]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  def search_name(_name), do: ""

  ## Sharing

  @doc """
  Turns **Let anyone find this** on for `activity`: links it to an equal catalog row,
  or creates one from its snapshot. Returns `{:ok, %Activity{}}` with
  `catalog_item_id` and `shared_to_catalog_at` set.

  Refuses with `{:error, :unauthorized}` for someone else's option (and raises for a
  malformed scope — invariant 1's three rules, via `Activities.authorize_activity/2`),
  `{:error, :nothing_to_find}` for an option with no website, address or location.
  """
  def share_activity(%Scope{} = scope, %Activity{} = activity) do
    # Everything, the ownership re-read included, inside `transact/1`: its rescue is
    # what turns a busy database into a tuple rather than a crashed LiveView whose
    # option has already been saved.
    transact(fn ->
      with {:ok, group} <- Activities.authorize_activity(scope, activity) do
        activity = Repo.get!(Activity, activity.id)

        if findable?(activity),
          do: do_share(scope, group, activity),
          else: {:error, :nothing_to_find}
      end
    end)
  end

  @doc "Whether an option carries something anyone else could find it by."
  def findable?(%{source_url: url, address: address, latitude: lat, longitude: lon}) do
    present?(url) or present?(address) or (is_float(lat) and is_float(lon))
  end

  defp do_share(scope, group, %Activity{} = activity) do
    now = DateTime.utc_now(:second)

    case own_row(activity) do
      %CatalogItem{} = row ->
        # Already the creator of a row (a re-share after an unsaved toggle, or a
        # second Save): the snapshot is refreshed by the sync rules, not re-created.
        with {:ok, _row} <- maybe_sync(row, activity) do
          link(activity, row, now)
        end

      nil ->
        existing = equal_row(group.activity_type, activity)

        case existing do
          %CatalogItem{} = row ->
            link(activity, row, now)

          nil ->
            with {:ok, row} <- insert_row(scope, group, activity) do
              link(activity, row, now)
            end
        end
    end
  end

  @doc """
  Turns **Let anyone find this** off: unlinks `activity` from its row, and deletes the
  row when this option created it and nothing else links to it. Returns
  `{:ok, %Activity{}}`. Same authorization as `share_activity/2`.
  """
  def unshare_activity(%Scope{} = scope, %Activity{} = activity) do
    transact(fn ->
      with {:ok, _group} <- Activities.authorize_activity(scope, activity) do
        activity |> Map.fetch!(:id) |> then(&Repo.get!(Activity, &1)) |> do_unshare()
      end
    end)
  end

  @doc false
  # `Consensus.Activities.delete_activity/2` calls this inside its own transaction,
  # before the delete: an option that goes away takes its share with it, exactly as
  # turning the toggle off would. Ownership was already checked by the caller.
  def release_activity(%Activity{} = activity), do: do_unshare(activity)

  defp do_unshare(%Activity{catalog_item_id: nil} = activity),
    do: unlink(activity)

  defp do_unshare(%Activity{id: id, catalog_item_id: row_id} = activity) do
    with {:ok, unlinked} <- unlink(activity) do
      case Repo.get(CatalogItem, row_id) do
        %CatalogItem{shared_from_activity_id: ^id} = row -> release_row(row)
        _other -> :ok
      end

      {:ok, unlinked}
    end
  end

  # The row this option created, once the option stops sharing. Only another option
  # that is itself **shared** into the row can keep it alive — an option that merely
  # *used* the row holds its own copy already, so keeping the row "for it" protects
  # nothing and would leave this organizer unable to take their data back. When one
  # exists, the row passes to it and takes its snapshot, so nothing of the departing
  # option stays public; otherwise the row is deleted.
  defp release_row(%CatalogItem{} = row) do
    case next_sharer(row.id) do
      nil ->
        Repo.delete!(row)

      %Activity{} = heir ->
        heir = Repo.preload(heir, :group)

        row
        |> CatalogItem.share_changeset(snapshot(heir))
        |> Ecto.Changeset.change(
          shared_from_activity_id: heir.id,
          shared_by_user_id: heir.group.organizer_id,
          shared_by_anonymous_organizer_id: heir.group.anonymous_organizer_id
        )
        |> Repo.update!()
    end
  end

  defp next_sharer(row_id) do
    from(a in Activity,
      where: a.catalog_item_id == ^row_id and not is_nil(a.shared_to_catalog_at),
      order_by: [asc: a.shared_to_catalog_at, asc: a.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Called by `Consensus.Activities` after every successful write to an option: if the
  option is shared and created its row, and no admin has edited that row, the row
  takes the option's current snapshot. Never raises and never fails the caller's
  write — a sync that cannot apply (say, an `osm_ref` now owned by another row) is
  logged and dropped.
  """
  @spec sync_activity(Activity.t()) :: :ok
  def sync_activity(
        %Activity{shared_to_catalog_at: %DateTime{}, catalog_item_id: row_id} = activity
      )
      when is_integer(row_id) do
    # An edit that leaves nothing to find it by (website, address and location all
    # cleared) ends the share: syncing it would publish a row the share itself would
    # have refused, under whatever the option was renamed to.
    if findable?(activity), do: sync_row(activity, row_id), else: unshare_unfindable(activity)
    :ok
  rescue
    exception ->
      Logger.error("Consensus.Catalog: sync raised " <> Exception.message(exception))
      :ok
  end

  def sync_activity(_activity), do: :ok

  defp unshare_unfindable(activity) do
    case transact(fn -> do_unshare(activity) end) do
      {:ok, _unlinked} -> :ok
      {:error, reason} -> Logger.warning("Consensus.Catalog: unshare refused: #{inspect(reason)}")
    end
  end

  defp sync_row(activity, row_id) do
    with %CatalogItem{} = row <- Repo.get(CatalogItem, row_id),
         {:error, reason} <- maybe_sync(row, activity) do
      Logger.warning(
        "Consensus.Catalog: sync of activity #{activity.id} refused: #{inspect(reason)}"
      )
    end
  end

  @doc """
  Bumps a row's `use_count` after an organizer filled an option from it. Best-effort:
  a busy database costs a ranking hint, never the organizer's write.
  """
  def record_use(row_id) when is_integer(row_id) do
    from(c in CatalogItem, where: c.id == ^row_id) |> Repo.update_all(inc: [use_count: 1])
    :ok
  rescue
    _exception -> :ok
  end

  def record_use(_row_id), do: :ok

  @doc "One catalog row by id, or `nil`."
  def get_item(id) when is_integer(id), do: Repo.get(CatalogItem, id)
  def get_item(_id), do: nil

  ## Admin (`/admin/items`)
  #
  # Every write matches `%Scope{user: %User{is_admin: true}}` in its head — invariant
  # 1's precondition shape, its first living example since D-027: a non-admin caller
  # raises `FunctionClauseError` rather than reaching a branch. Every write also
  # re-reads the actor's role inside its transaction (`as_admin/2`, the
  # `Accounts.ensure_actor_is_admin/1` idiom), because the scope in hand can be stale —
  # a tab mounted before a demotion keeps its old scope. No sudo gate: nothing
  # cascades from a catalog row — every group's copy survives.

  @doc """
  The admin listing: every row, newest first, optionally narrowed by `:activity_type`,
  `:status` and `:query` (matched against `search_name`).
  """
  def list_items_for_admin(%Scope{user: %User{is_admin: true}}, filters \\ %{}) do
    CatalogItem
    |> admin_filter(:activity_type, filters[:activity_type])
    |> admin_filter(:status, filters[:status])
    |> admin_name_filter(filters[:query])
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload([:shared_by_user, :shared_by_anonymous_organizer])
    |> Repo.all()
  end

  defp admin_filter(query, _field, value) when value in [nil, ""], do: query
  defp admin_filter(query, field, value), do: where(query, ^[{field, value}])

  defp admin_name_filter(query, value) when value in [nil, ""], do: query

  defp admin_name_filter(query, value) do
    Enum.reduce(String.split(search_name(value), " ", trim: true), query, fn token, q ->
      where(q, [c], like(c.search_name, ^"%#{token}%"))
    end)
  end

  @doc "An admin's edit of any field; stamps `admin_edited_at`, so organizer syncs stop."
  def admin_update(%Scope{user: %User{is_admin: true} = actor}, %CatalogItem{} = item, attrs) do
    as_admin(actor, fn ->
      item
      |> CatalogItem.admin_changeset(attrs)
      |> Ecto.Changeset.put_change(:admin_edited_at, DateTime.utc_now(:second))
      |> Repo.update()
    end)
    |> Consensus.Audit.log("catalog_edit", actor, item.id)
  end

  @doc "Hide (`\"hidden\"`) or unhide (`\"visible\"`) a row. Effective on the next search."
  def admin_set_status(%Scope{user: %User{is_admin: true} = actor}, %CatalogItem{} = item, status)
      when status in ["visible", "hidden"] do
    action = if status == "hidden", do: "catalog_hide", else: "catalog_unhide"

    as_admin(actor, fn -> item |> CatalogItem.status_changeset(status) |> Repo.update() end)
    |> Consensus.Audit.log(action, actor, item.id)
  end

  @doc """
  Deletes a row. Options linked to it keep their own copy (`catalog_item_id` is
  `ON DELETE SET NULL`), so no group changes.
  """
  def admin_delete(%Scope{user: %User{is_admin: true} = actor}, %CatalogItem{} = item) do
    as_admin(actor, fn -> Repo.delete(item) end)
    |> Consensus.Audit.log("catalog_delete", actor, item.id)
  end

  @doc """
  An admin's **Share to catalog** from the all-items tab: a snapshot of someone else's
  option as an admin-owned row (`admin_edited_at` set, so nothing syncs into it) that
  does **not** link the option — its organizer's own toggle stays theirs. Returns the
  existing row instead when an equal one exists.
  """
  def admin_share(%Scope{user: %User{is_admin: true} = actor}, %Activity{} = activity) do
    as_admin(actor, fn ->
      activity = Repo.preload(Repo.get!(Activity, activity.id), :group)
      existing = equal_row(activity.group.activity_type, activity)

      cond do
        not findable?(activity) ->
          {:error, :nothing_to_find}

        # A hidden twin was hidden on purpose: say so, rather than report a share no
        # search will ever return.
        match?(%CatalogItem{status: "hidden"}, existing) ->
          {:error, :hidden}

        existing ->
          {:ok, existing}

        true ->
          %CatalogItem{shared_by_user_id: actor.id, admin_edited_at: DateTime.utc_now(:second)}
          |> CatalogItem.share_changeset(
            Map.put(snapshot(activity), :activity_type, activity.group.activity_type)
          )
          |> Repo.insert()
      end
    end)
    |> Consensus.Audit.log("catalog_share", actor, activity.id)
  end

  @doc false
  # The admin re-read every admin write in this module and `Consensus.Activities`
  # shares: the check and the write see one snapshot.
  def as_admin(%User{id: actor_id}, fun) when is_function(fun, 0) do
    transact(fn ->
      case Repo.get(User, actor_id) do
        %User{is_admin: true} -> fun.()
        _not_admin -> {:error, :unauthorized}
      end
    end)
  end

  ## Search

  @doc """
  The visible rows of `activity_type` matching `query`, best first, at most
  #{@results_cap}. `area` is the group's `%Area{}` or `nil`. See the moduledoc for the
  rules. Raises nothing it can avoid; `Consensus.Catalog.Provider` rescues the rest.
  """
  @spec search(String.t(), String.t(), Area.t() | nil) :: [CatalogItem.t()]
  def search(activity_type, query, area) when is_binary(activity_type) and is_binary(query) do
    normalised = search_name(query)

    case String.split(normalised, " ", trim: true) do
      [] ->
        []

      tokens ->
        tokens
        |> Enum.reduce(visible_rows(activity_type), fn token, q ->
          where(q, [c], like(c.search_name, ^"%#{token}%"))
        end)
        |> limit(@candidate_limit)
        |> Repo.all()
        |> Enum.filter(&(name_matches?(&1, tokens) and in_area?(&1, normalised, area)))
        |> Enum.sort_by(&rank(&1, normalised))
        |> Enum.take(@results_cap)
    end
  end

  def search(_activity_type, _query, _area), do: []

  defp visible_rows(activity_type),
    do: where(CatalogItem, activity_type: ^activity_type, status: "visible")

  defp name_matches?(%CatalogItem{search_name: name}, tokens) do
    name_tokens = String.split(name, " ", trim: true)
    Enum.all?(tokens, fn token -> Enum.any?(name_tokens, &String.starts_with?(&1, token)) end)
  end

  # A row with no location cannot be placed. With a group area it is never eligible:
  # the chain stops at the first non-empty answer, so a "Joe's Pizza" shared from
  # another city — even ranked last — would stop the local lookup from running at all.
  # With no area it may still answer, but only on an exact name.
  defp in_area?(%CatalogItem{latitude: lat, longitude: lon} = row, normalised, area) do
    located? = is_float(lat) and is_float(lon)

    cond do
      match?(%Area{}, area) -> located? and inside?(Nominatim.widen_bbox(area.bbox), lat, lon)
      located? -> true
      true -> row.search_name == normalised
    end
  end

  defp inside?({min_lat, min_lon, max_lat, max_lon}, lat, lon),
    do: lat >= min_lat and lat <= max_lat and lon >= min_lon and lon <= max_lon

  # Exact before prefix, located before unlocated, then the most used.
  defp rank(%CatalogItem{} = row, normalised) do
    located? = is_float(row.latitude) and is_float(row.longitude)

    {if(located?, do: 0, else: 1), if(row.search_name == normalised, do: 0, else: 1),
     -row.use_count}
  end

  ## Share plumbing

  defp own_row(%Activity{id: id, catalog_item_id: row_id}) when is_integer(row_id) do
    case Repo.get(CatalogItem, row_id) do
      %CatalogItem{shared_from_activity_id: ^id} = row -> row
      _other -> nil
    end
  end

  defp own_row(_activity), do: nil

  # Deduplication: the OSM element first, then the same normalised name within
  # @dedupe_radius_m of a located option. Hidden rows count — sharing again must not
  # resurrect a row an admin hid by creating its twin.
  defp equal_row(activity_type, %Activity{osm_ref: ref} = activity) do
    by_ref =
      if present?(ref),
        do: Repo.one(where(CatalogItem, activity_type: ^activity_type, osm_ref: ^ref)),
        else: nil

    by_ref || nearby_namesake(activity_type, activity)
  end

  defp nearby_namesake(activity_type, %Activity{latitude: lat, longitude: lon} = activity)
       when is_float(lat) and is_float(lon) do
    name = search_name(activity.name)

    CatalogItem
    |> where(activity_type: ^activity_type, search_name: ^name)
    |> where([c], not is_nil(c.latitude) and not is_nil(c.longitude))
    |> Repo.all()
    |> Enum.find(&(distance_m({lat, lon}, {&1.latitude, &1.longitude}) <= @dedupe_radius_m))
  end

  defp nearby_namesake(_activity_type, _activity), do: nil

  # Equirectangular — exact enough at 50 m, and no trigonometry beyond one cosine.
  defp distance_m({lat1, lon1}, {lat2, lon2}) do
    metres_per_degree = 111_320
    x = (lon2 - lon1) * :math.cos((lat1 + lat2) / 2 * :math.pi() / 180) * metres_per_degree
    y = (lat2 - lat1) * metres_per_degree
    :math.sqrt(x * x + y * y)
  end

  defp insert_row(scope, group, activity) do
    %CatalogItem{
      shared_from_activity_id: activity.id,
      shared_by_user_id: sharer_user_id(scope),
      shared_by_anonymous_organizer_id: sharer_anonymous_id(scope)
    }
    |> CatalogItem.share_changeset(
      Map.put(snapshot(activity), :activity_type, group.activity_type)
    )
    |> Repo.insert()
  end

  defp sharer_user_id(%Scope{user: %{id: id}}), do: id
  defp sharer_user_id(_scope), do: nil

  defp sharer_anonymous_id(%Scope{anonymous_organizer: %AnonymousOrganizer{id: id}}), do: id
  defp sharer_anonymous_id(_scope), do: nil

  defp maybe_sync(
         %CatalogItem{admin_edited_at: nil, shared_from_activity_id: id} = row,
         %Activity{
           id: id
         } = activity
       ) do
    row |> CatalogItem.share_changeset(snapshot(activity)) |> Repo.update()
  end

  defp maybe_sync(row, _activity), do: {:ok, row}

  defp snapshot(%Activity{} = activity), do: Map.take(activity, CatalogItem.snapshot_fields())

  defp link(activity, row, now) do
    activity
    |> Ecto.Changeset.change(catalog_item_id: row.id, shared_to_catalog_at: now)
    |> Repo.update()
  end

  defp unlink(activity) do
    activity
    |> Ecto.Changeset.change(catalog_item_id: nil, shared_to_catalog_at: nil)
    |> Repo.update()
  end

  defp transact(fun) do
    Repo.transact(fun)
  rescue
    exception in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(exception)}}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
