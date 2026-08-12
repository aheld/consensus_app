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

  ## The pool is frozen the moment the vote opens

  `add_activity/3`, `update_activity/3`, `delete_activity/2`, `reorder_activities/3` and
  `set_search_area/3` all refuse with `{:error, :pool_locked}` unless the group is still
  a `:draft`. This is
  a **data-integrity** rule, not a UX preference, and it became load-bearing the moment
  `Consensus.Voting` shipped: `votes.activity_id` references `activities` with
  `ON DELETE CASCADE`, so deleting an option that people have already voted on silently
  destroys their vote rows while their `participants.voted_at` stays set — the ballot is
  locked (D-036), so they cannot recast, and their submission is permanently short one
  choice. Reordering is the same bug more quietly: `tally/1` breaks ties by
  `activity.position`, so renumbering mid-vote retroactively changes who is winning.
  Renaming an option people approved changes what they agreed to.

  The refusal lives here rather than in the LiveViews because here is the only place it
  can be enforced — `ConsensusWeb.GroupLive.Options` and `.Review` hide their editing
  controls once a group leaves `:draft`, but a `phx-click` can be pushed at any socket
  the organizer can mount. See D-037.
  """

  import Ecto.Query, warn: false

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

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

  @doc """
  The PubSub topic one group's updates travel on.

  Public so that a sibling context broadcasting about the *same* group can reuse the
  string rather than re-deriving it — `Consensus.Voting` sends `{:ballot_cast, group_id}`
  here, which is what lets a results screen hold a single subscription and still see
  both organizer edits and incoming ballots.
  """
  def topic(group_id), do: @topic_prefix <> to_string(group_id)

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
  Answers the Assisted Add area prompt (`docs/design/assisted-add-ux-brief.md` F2):
  sets `:search_area` and/or `:search_bbox` on the group.

  Refuses with `{:error, :pool_locked}` unless the group is still a `:draft` — the
  assist only exists on the draft `02 add options` screen, per the brief, so there is
  never a legitimate write once the group has left `:draft`. Same "the pool is frozen
  the moment the vote opens" reasoning as `add_activity/3` and friends in the
  moduledoc, applied to this field even though it is not itself part of the tally.
  No broadcast: nothing outside the organizer's own socket reads these fields.
  """
  def set_search_area(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id, status: :draft} = group,
        attrs
      ) do
    group
    |> Group.search_area_changeset(attrs)
    |> Repo.update()
  end

  def set_search_area(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id}, _attrs) do
    {:error, :pool_locked}
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

  ## Groups — endgame resolution

  @doc """
  Records how a `:completed` group's endgame was settled, when the tally alone could
  not settle it — a dead heat, or an all-vetoed pool.

  `resolution` is one of `Consensus.Activities.Group.resolutions/0`:

    * `"organizer_pick"` — tie: the organizer tapped a tied row and locked it in.
    * `"app_pick"` — tie: the app shuffled the tied set and the organizer locked the
      result in.
    * `"app_rescue"` — all-vetoed: the app picked one option at random; its veto is
      undone in *interpretation* only (see below).

  **No vote rows are written or deleted.** Resolution stamps `:resolution`,
  `:resolved_activity_id` and `:resolved_at` on the group and nothing else;
  `Consensus.Voting.tally/1` then reads them — an `"app_rescue"`'s activity reports
  `vetoed?: false, rescued?: true` with its veto count intact, and `winner?`/`leader?`
  go to the resolved activity. The votes stay true; only the reading of them is
  recorded.

  ### Refusals, in the order they are checked

    * `{:error, :invalid_resolution}` — a string outside `Group.resolutions/0`.
    * `{:error, :not_completed}` — the group is not `:completed`. A mid-vote dead heat
      is not an endgame; the deadline can still break it.
    * `{:error, :already_resolved}` — a resolution is already recorded. There is no
      re-resolve path: the whole point of the stamp is that every open results screen
      settled on the same answer.
    * `{:error, :not_a_candidate}` — the activity is not in the resolution's valid
      candidate set. For the two tie resolutions that set is the tied-at-top
      survivors (so a clear-winner group cannot be "resolved" onto something else);
      for `"app_rescue"` it is the whole pool, and only when **every** option is
      vetoed (`Consensus.Voting.outcome/2` answers `:no_consensus`) — a pool with a
      survivor has nothing to rescue. An id from another group, a deleted id, or
      non-numeric garbage all land here too.

  Broadcasts `{:group_updated, group}` on success, so every open results screen —
  the organizer's and every guest's — flips at once.

  `activity_id` may be an integer or the string a client event delivers; anything
  else is refused, never raised. The random half of `"app_rescue"` lives in
  `rescue_group/2`, which picks server-side and delegates here — so tests (and the
  tie screen, whose app-pick animation lands on a server-chosen row *before* the
  organizer locks it) can call this function deterministically.

  Everything after the pure `resolution` check runs inside `Repo.transact/1` on a
  **fresh primary-key re-read of the group** — the struct in hand came from a socket
  assign and may predate a resolution committed in another tab (the window between
  that commit and PubSub delivery). The stale struct's `resolution: nil` would
  otherwise sail past `:already_resolved` and overwrite a result people have already
  seen. Same "don't trust the struct in hand, re-read from storage" idiom as
  `Consensus.Accounts.set_admin/3` and `Voting.cast_ballot/3`'s in-transaction group
  re-read (CLAUDE.md invariants 1 and 17); the broadcast fires after commit.
  """
  def resolve_group(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id} = group,
        activity_id,
        resolution
      ) do
    activity_id = cast_activity_id(activity_id)

    if resolution not in Group.resolutions() do
      {:error, :invalid_resolution}
    else
      Repo.transact(fn ->
        group = Repo.get!(Group, group.id)

        cond do
          group.status != :completed ->
            {:error, :not_completed}

          not is_nil(group.resolution) ->
            {:error, :already_resolved}

          is_nil(activity_id) or activity_id not in resolution_candidate_ids(group, resolution) ->
            {:error, :not_a_candidate}

          true ->
            group
            |> Group.resolution_changeset(%{
              resolution: resolution,
              resolved_activity_id: activity_id,
              resolved_at: DateTime.utc_now(:second)
            })
            |> Repo.update()
        end
      end)
      |> broadcast_group_update()
    end
  end

  @doc """
  The all-vetoed rescue: picks one of the group's vetoed options at random
  (server-side, `:rand` via `Enum.random/1`) and records it through
  `resolve_group/4` as an `"app_rescue"`.

  Every refusal is `resolve_group/4`'s own — a group that is not `:completed`, is
  already resolved, or is not fully vetoed refuses there, so the two functions cannot
  disagree about when a rescue is legal. Broadcasts `{:group_updated, group}` on
  success, which is what flips every open results screen from the all-vetoed takeover
  to the ordinary winner ending at once.
  """
  def rescue_group(
        %Scope{user: %User{id: user_id}} = scope,
        %Group{organizer_id: user_id} = group
      ) do
    candidate =
      group
      |> Voting.tally()
      |> Enum.filter(& &1.vetoed?)
      |> Enum.map(& &1.activity.id)
      |> case do
        [] -> nil
        ids -> Enum.random(ids)
      end

    resolve_group(scope, group, candidate, "app_rescue")
  end

  @doc """
  The all-vetoed "Add new options" exit: reopens a fully-vetoed `:completed` group as
  a `:draft` so the organizer can grow the pool and run round 2 on the same share
  link.

  Refuses with `{:error, :not_completed}` unless the group is `:completed`, with
  `{:error, :already_resolved}` when a resolution is recorded (a rescued group has a
  winner; reopening it would un-declare a result people have already seen), and with
  `{:error, :not_all_vetoed}` unless **every** option is vetoed — a tie, a winner, or
  an untouched pool is not this exit's case.

  Then, in one transaction:

    * every vote row in the group is deleted, and every participant's `voted_at` is
      reset to `nil` — round 1's votes are gone **by design**: its outcome was
      "everything vetoed", the screen the organizer is leaving said exactly that, and
      a locked ballot (D-036) would otherwise pin every returning voter to a pool
      they have already fully rejected;
    * the participants themselves and their tokens survive — the share link keeps
      working and nobody re-enters a name;
    * status goes back to `:draft` with `completed_at`, the resolution columns, and
      **`deadline_at`** cleared (see `Group.reopen_changeset/1` — the old deadline has
      passed, and leaving it set would let round 2 re-complete itself on the first
      read after publish). Publishing again requires a fresh deadline;
      `publish_group/2` already refuses `:no_deadline`.

  Broadcasts `{:group_updated, group}` on success.

  Every guard runs inside the same transaction as the deletes, against a **fresh
  primary-key re-read of the group** — not the caller's struct, which came from a
  socket assign and may predate a rescue committed in another tab (the window
  between that commit and PubSub delivery). Guarding on the stale struct let
  exactly that race destroy a declared result: the stale `resolution: nil` sailed
  past `:already_resolved`, the votes were deleted, and — because a stale struct
  also made `change/2` drop the resolution clears as no-ops — the reopened `:draft`
  kept its `"app_rescue"` stamp, silently pre-deciding round 2. Same idiom as
  `resolve_group/4` above; the broadcast fires after commit.
  """
  def reopen_group(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id} = group) do
    Repo.transact(fn ->
      group = Repo.get!(Group, group.id)

      cond do
        group.status != :completed ->
          {:error, :not_completed}

        not is_nil(group.resolution) ->
          {:error, :already_resolved}

        Voting.outcome(group, Voting.tally(group)) != :no_consensus ->
          {:error, :not_all_vetoed}

        true ->
          now = DateTime.utc_now(:second)
          participant_ids = from(p in Participant, where: p.group_id == ^group.id, select: p.id)

          {_, _} =
            Repo.delete_all(from(v in Vote, where: v.participant_id in subquery(participant_ids)))

          {_, _} =
            Repo.update_all(from(p in Participant, where: p.group_id == ^group.id),
              set: [voted_at: nil, updated_at: now]
            )

          group |> Group.reopen_changeset() |> Repo.update()
      end
    end)
    |> broadcast_group_update()
  end

  # The set of activities a given resolution may legally land on, derived from the
  # same reading every results screen uses (`Consensus.Voting.outcome/2`) so the two
  # cannot drift: the tie resolutions may only pick among the tied-at-top survivors,
  # and a rescue may only pick from a pool in which everything is vetoed.
  defp resolution_candidate_ids(%Group{} = group, resolution) do
    tally = Voting.tally(group)

    case {resolution, Voting.outcome(group, tally)} do
      {"app_rescue", :no_consensus} ->
        Enum.map(tally, & &1.activity.id)

      {pick, {:tie, rows}} when pick in ["organizer_pick", "app_pick"] ->
        Enum.map(rows, & &1.activity.id)

      _other ->
        []
    end
  end

  defp cast_activity_id(id) when is_integer(id), do: id

  defp cast_activity_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp cast_activity_id(_id), do: nil

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

  Refuses with `{:error, :pool_locked}` unless the group is still a `:draft` — see
  "The pool is frozen the moment the vote opens" in the moduledoc. `:added_by_id` is
  set from the scope; `attrs` cannot override it. Broadcasts
  `{:activity_added, activity}` on success.
  """
  def add_activity(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id, status: :draft} = group,
        attrs
      ) do
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
    {:error, :pool_locked}
  end

  @doc """
  Updates an activity's own fields (never its position or group — see
  `reorder_activities/3` for the former).

  An `%Activity{}` carries only `group_id`, not the organizer, so ownership cannot be
  a pure function-head pattern match the way it is for group-level writes above; it is
  instead re-read from the database via `authorize_activity/2`, the same "don't trust
  the struct in hand, re-read from storage" idiom `Consensus.Accounts.set_admin/3` uses
  for its actor. Returns `{:error, :unauthorized}` for someone else's group, and
  `{:error, :pool_locked}` once that group has left `:draft` — see "The pool is frozen
  the moment the vote opens" in the moduledoc. Broadcasts
  `{:activity_updated, activity}` on success.
  """
  def update_activity(%Scope{} = scope, %Activity{} = activity, attrs) do
    with {:ok, group} <- authorize_activity(scope, activity),
         :ok <- ensure_pool_editable(group) do
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

  Refuses with `{:error, :pool_locked}` once the group has left `:draft`. This is the
  single most important place that guard sits: `votes.activity_id` cascades, so a delete
  here would take already-cast votes with it. See the moduledoc and D-037.
  """
  def delete_activity(%Scope{} = scope, %Activity{} = activity) do
    with {:ok, group} <- authorize_activity(scope, activity),
         :ok <- ensure_pool_editable(group) do
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

  Refuses with `{:error, :pool_locked}` once the group has left `:draft`: `tally/1`
  breaks ties by `activity.position`, so renumbering a pool people have already voted on
  retroactively changes who is winning. See the moduledoc and D-037.
  """
  def reorder_activities(
        %Scope{user: %User{id: user_id}},
        %Group{organizer_id: user_id, status: :draft} = group,
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

  def reorder_activities(%Scope{user: %User{id: user_id}}, %Group{organizer_id: user_id}, ids)
      when is_list(ids) do
    {:error, :pool_locked}
  end

  defp valid_reorder?(ordered_ids, current_ids) do
    length(ordered_ids) == length(current_ids) and
      MapSet.new(ordered_ids) == MapSet.new(current_ids)
  end

  # The pool is editable only while the group is a draft. See "The pool is frozen the
  # moment the vote opens" in the moduledoc for why this is an integrity rule rather
  # than a workflow preference.
  defp ensure_pool_editable(%Group{status: :draft}), do: :ok
  defp ensure_pool_editable(%Group{}), do: {:error, :pool_locked}

  defp authorize_activity(%Scope{user: %User{id: user_id}}, %Activity{group_id: group_id}) do
    case Repo.get(Group, group_id) do
      %Group{organizer_id: ^user_id} = group -> {:ok, group}
      %Group{} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end
end
