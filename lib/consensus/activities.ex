defmodule Consensus.Activities do
  @moduledoc """
  The Activities context: activity groups (a titled, deadlined pool of options that a
  group of people will vote on) and the activities (options) inside them.

  Every function that reads or writes on a user's behalf takes `%Consensus.Accounts.Scope{}`
  as its first argument, exactly like `Consensus.Accounts`.
  Where the resource being acted on is passed in already (a `%Group{}` or an
  `%Activity{}`), ownership is a **precondition in the function head**: the scope's
  `user_id` and the group's `organizer_id` are bound to the same variable name, so a
  call on someone else's group fails to match any clause and raises
  `FunctionClauseError` rather than taking a runtime branch. `update_activity/3` and
  `delete_activity/2`
  are the one exception: an `%Activity{}` only carries `group_id`, not the organizer,
  so ownership there is a DB re-read (`authorize_activity/2`) rather than a pure
  pattern match — see the note on those two functions.

  Changes are broadcast over `Phoenix.PubSub` on the `"activity_group:<id>"` topic
  (`subscribe_group/1`), so LiveViews showing a group update without a refresh (see
  CLAUDE.md product invariant 4).
  """

  import Ecto.Query, warn: false

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.Repo

  @topic_prefix "activity_group:"

  ## PubSub

  @doc """
  Subscribes the calling process to updates for one group.

  Subscribers receive `{:group_updated, %Group{}}`, `{:activity_added, %Activity{}}`,
  `{:activity_updated, %Activity{}}` or `{:activities_changed, [%Activity{}]}` (sent
  after a delete-and-renumber or a full reorder, since either can move more than one
  row).
  """
  def subscribe_group(group_id) do
    Phoenix.PubSub.subscribe(Consensus.PubSub, topic(group_id))
  end

  defp topic(group_id), do: @topic_prefix <> to_string(group_id)

  defp broadcast(group_id, message) do
    Phoenix.PubSub.broadcast(Consensus.PubSub, topic(group_id), message)
  end

  defp broadcast_group_update({:ok, %Group{} = group} = result) do
    broadcast(group.id, {:group_updated, group})
    result
  end

  defp broadcast_group_update(error), do: error

  ## Groups — reads

  @doc """
  Lists the signed-in user's groups, newest first, activities preloaded.

  Each group is passed through `maybe_complete_group/1` first, so a `:voting` group
  whose deadline has already passed is reported (and, on its first read since expiry,
  persisted) as `:completed` rather than stale.
  """
  def list_groups(%Scope{user: %User{id: user_id}}) do
    from(g in Group,
      where: g.organizer_id == ^user_id,
      order_by: [desc: g.inserted_at, desc: g.id]
    )
    |> Repo.all()
    |> Repo.preload(:activities)
    |> Enum.map(&maybe_complete_group/1)
  end

  @doc "The subset of `list_groups/1` still open: status `:draft` or `:voting`."
  def list_active_groups(%Scope{} = scope) do
    scope |> list_groups() |> Enum.filter(&(&1.status in [:draft, :voting]))
  end

  @doc "The subset of `list_groups/1` finished: status `:completed` or `:cancelled`."
  def list_past_groups(%Scope{} = scope) do
    scope |> list_groups() |> Enum.filter(&(&1.status in [:completed, :cancelled]))
  end

  @doc """
  Gets a single group, scoped to its organizer.

  Raises `Ecto.NoResultsError` both when the id does not exist and when it belongs to
  someone else — the query itself is filtered by `organizer_id`, so the two cases are
  indistinguishable from outside, which is the point.
  """
  def get_group!(%Scope{user: %User{id: user_id}}, id) do
    Group
    |> Repo.get_by!(id: id, organizer_id: user_id)
    |> Repo.preload(:activities)
    |> maybe_complete_group()
  end

  @doc """
  Gets a group by its public share slug, unscoped.

  This is the `/join/<slug>` lookup a guest voter follows — there is no organizer to
  scope it to. Returns `nil` when the slug does not match anything.
  """
  def get_group_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Group, slug: slug) do
      nil -> nil
      group -> group |> Repo.preload(:activities) |> maybe_complete_group()
    end
  end

  ## Groups — writes

  @doc "Returns an `%Ecto.Changeset{}` for tracking new-group changes."
  def change_group(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id} = group,
        attrs \\ %{}
      ) do
    Group.changeset(group, attrs)
  end

  @doc """
  Creates a group with the caller as organizer.

  `:organizer_id` comes from the scope, never from `attrs` — see
  `Consensus.Activities.Group.changeset/2`.
  """
  def create_group(%Scope{user: %User{id: user_id}}, attrs) do
    %Group{organizer_id: user_id}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a group's own fields. Broadcasts `{:group_updated, group}` on success."
  def update_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> broadcast_group_update()
  end

  @doc """
  Moves a group from `:draft` to `:voting`.

  Refuses with `{:error, :no_activities}` when the pool is empty, `{:error, :no_deadline}`
  when `deadline_at` is unset, and `{:error, :not_draft}` when the group has already
  left `:draft` (publishing is not idempotent — a second call is almost always a bug
  in the caller, not a no-op the caller wants). Broadcasts `{:group_updated, group}` on
  success.
  """
  def publish_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group) do
    cond do
      group.status != :draft -> {:error, :not_draft}
      count_activities(group) == 0 -> {:error, :no_activities}
      is_nil(group.deadline_at) -> {:error, :no_deadline}
      true -> transition(group, status: :voting)
    end
  end

  @doc """
  Cancels a group.

  Refuses with `{:error, :already_finished}` if the group is already `:completed` or
  `:cancelled`. Broadcasts `{:group_updated, group}` on success.
  """
  def cancel_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group) do
    if group.status in [:completed, :cancelled] do
      {:error, :already_finished}
    else
      transition(group, status: :cancelled, cancelled_at: DateTime.utc_now(:second))
    end
  end

  @doc """
  Completes a group.

  Refuses with `{:error, :already_finished}` if the group is already `:completed` or
  `:cancelled`. Broadcasts `{:group_updated, group}` on success. See
  `maybe_complete_group/1` for the deadline-triggered path that reaches the same
  transition without an organizer scope.
  """
  def complete_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group) do
    if group.status in [:completed, :cancelled] do
      {:error, :already_finished}
    else
      transition(group, status: :completed, completed_at: DateTime.utc_now(:second))
    end
  end

  @doc """
  Completes a `:voting` group whose `deadline_at` has passed. Returns the group,
  updated if it transitioned and unchanged otherwise — there is no scope argument
  because this is a system-triggered transition, not a user action, and no refusal
  tuple because "not past its deadline yet" is not an error.

  There is no scheduler or GenServer behind this: `list_groups/1`, `get_group!/2` and
  `get_group_by_slug/1` all call it lazily on every read, which is enough to keep a
  group's reported status honest without a background process.

  TODO: also complete a group once every expected voter has voted, using
  `expected_voter_count`. There is no voting yet, so only the deadline half is
  implemented.
  """
  def maybe_complete_group(%Group{status: :voting, deadline_at: %DateTime{} = deadline} = group) do
    if DateTime.compare(DateTime.utc_now(), deadline) != :lt do
      case transition(group, status: :completed, completed_at: DateTime.utc_now(:second)) do
        {:ok, completed} -> completed
        {:error, _reason} -> group
      end
    else
      group
    end
  end

  def maybe_complete_group(%Group{} = group), do: group

  defp transition(%Group{} = group, changes) do
    group
    |> Group.status_changeset(Map.new(changes))
    |> Repo.update()
    |> broadcast_group_update()
  end

  ## Activities — reads

  @doc "Counts the activities in a group. Accepts either a `%Group{}` or its id."
  def count_activities(%Group{id: id}), do: count_activities(id)

  def count_activities(group_id) when is_integer(group_id) do
    Repo.aggregate(from(a in Activity, where: a.group_id == ^group_id), :count)
  end

  defp next_position(group_id) do
    case Repo.one(from(a in Activity, where: a.group_id == ^group_id, select: max(a.position))) do
      nil -> 1
      max -> max + 1
    end
  end

  ## Activities — writes

  @doc """
  Appends an activity to a group's pool, at `max(position) + 1`.

  Refuses with `{:error, :group_not_open}` when the group is not `:draft` or
  `:voting` — a completed or cancelled group's pool is frozen. `:added_by_id` is set
  from the scope; `attrs` cannot override it. Broadcasts `{:activity_added, activity}`
  on success.
  """
  def add_activity(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id, status: status} = group,
        attrs
      )
      when status in [:draft, :voting] do
    %Activity{group_id: group.id, added_by_id: user_id}
    |> Activity.changeset(attrs)
    |> Ecto.Changeset.put_change(:position, next_position(group.id))
    |> Repo.insert()
    |> case do
      {:ok, activity} = result ->
        broadcast(group.id, {:activity_added, activity})
        result

      error ->
        error
    end
  end

  def add_activity(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id}, _attrs) do
    {:error, :group_not_open}
  end

  @doc """
  Updates an activity's own fields (never its position or group — see
  `reorder_activities/3` for the former).

  An `%Activity{}` carries only `group_id`, not the organizer, so ownership cannot be
  a pure function-head pattern match the way it is for group-level writes above; it is
  instead re-read from the database via `authorize_activity/2`, the same "don't trust
  the struct in hand, re-read from storage" idiom `Consensus.Accounts.set_admin/3` uses
  for its actor. Returns `{:error, :unauthorized}` for someone else's group.
  Broadcasts `{:activity_updated, activity}` on success.
  """
  def update_activity(%Scope{} = scope, %Activity{} = activity, attrs) do
    with {:ok, group} <- authorize_activity(scope, activity) do
      activity
      |> Activity.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} = result ->
          broadcast(group.id, {:activity_updated, updated})
          result

        error ->
          error
      end
    end
  end

  @doc """
  Deletes an activity and renumbers the remaining activities in its group to stay
  contiguous, in one transaction. Broadcasts `{:activities_changed, activities}` (the
  group's remaining activities, in order) on success. See `update_activity/3` for why
  ownership is a DB re-read here rather than a function-head match.
  """
  def delete_activity(%Scope{} = scope, %Activity{} = activity) do
    with {:ok, group} <- authorize_activity(scope, activity) do
      Repo.transact(fn ->
        with {:ok, deleted} <- Repo.delete(activity) do
          remaining = renumber(group.id)
          {:ok, {deleted, remaining}}
        end
      end)
      |> case do
        {:ok, {deleted, remaining}} ->
          broadcast(group.id, {:activities_changed, remaining})
          {:ok, deleted}

        error ->
          error
      end
    end
  end

  defp renumber(group_id) do
    from(a in Activity, where: a.group_id == ^group_id, order_by: [asc: a.position])
    |> Repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Activity{position: position} = activity, position} -> activity
      {activity, position} -> activity |> Activity.position_changeset(position) |> Repo.update!()
    end)
  end

  @doc """
  Reorders a group's activities to match `ordered_ids`, in one transaction.

  `ordered_ids` must contain exactly the group's current activity ids, each exactly
  once — any other list (missing an id, containing a foreign one, or repeating one) is
  refused with `{:error, :invalid_ids}` and nothing is written. Broadcasts
  `{:activities_changed, activities}` (in the new order) on success.
  """
  def reorder_activities(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id} = group,
        ordered_ids
      )
      when is_list(ordered_ids) do
    current_ids =
      from(a in Activity, where: a.group_id == ^group.id, select: a.id) |> Repo.all()

    if valid_reorder?(ordered_ids, current_ids) do
      Repo.transact(fn ->
        activities =
          ordered_ids
          |> Enum.with_index(1)
          |> Enum.map(fn {id, position} ->
            Activity |> Repo.get!(id) |> Activity.position_changeset(position) |> Repo.update!()
          end)

        {:ok, activities}
      end)
      |> case do
        {:ok, activities} ->
          broadcast(group.id, {:activities_changed, activities})
          {:ok, activities}
      end
    else
      {:error, :invalid_ids}
    end
  end

  defp valid_reorder?(ordered_ids, current_ids) do
    length(ordered_ids) == length(current_ids) and
      MapSet.new(ordered_ids) == MapSet.new(current_ids)
  end

  defp authorize_activity(%Scope{user: %User{id: user_id}}, %Activity{group_id: group_id}) do
    case Repo.get(Group, group_id) do
      %Group{organizer_id: ^user_id} = group -> {:ok, group}
      %Group{} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end
end
