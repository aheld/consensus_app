defmodule Consensus.Activities do
  @moduledoc """
  The Activities context: activity groups (a titled, deadlined pool of options that a
  group of people will vote on) and the activities (options) inside them.

  Every function that reads or writes on an organizer's behalf takes
  `%Consensus.Accounts.Scope{}` as its first argument, exactly like `Consensus.Accounts`.

  ## Ownership is a precondition in the function head — with two kinds of owner

  A group is owned by a signed-in user (`organizer_id`) **or** by an organizer with no
  account (`anonymous_organizer_id`, D-058) — exactly one of the two, which the
  database enforces with a CHECK. Where the resource being acted on is passed in
  already (a `%Group{}` or an `%Activity{}`), ownership is a **precondition in the
  function head**: the scope's id and the group's owner column are bound to the same
  variable name, so a call on someone else's group fails to match any clause and
  raises `FunctionClauseError` rather than taking a runtime branch.

  Every owning function therefore has **two heads**, one per kind of owner, and both
  delegate to one shared private body that never looks at the owner again:

      def publish_group(%Scope{user: %User{id: id}, anonymous_organizer: nil},
                        %Group{organizer_id: id} = group) when is_integer(id)
      def publish_group(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
                        %Group{anonymous_organizer_id: id} = group) when is_integer(id)

  Three rules hold in every pair, and each one closes a hole the other two leave:

    * **The other identity is pinned to `nil`.** A `%Scope{}` with both fields set
      matches neither head and raises, instead of the first head silently winning.
    * **`when is_integer(id)`.** Once both owner columns are nullable, every user-owned
      group has `anonymous_organizer_id: nil` and every anonymous-owned one has
      `organizer_id: nil`, so an unsaved struct with `id: nil` would otherwise match
      every group owned by the *other* kind — a cross-tenant write no "different
      owner" test notices.
    * **No owner comparison in the body.** Collapsing a pair into a computed owner key
      compared at runtime is one inverted comparison away from that same write, and it
      turns a `FunctionClauseError` the suite can see into a branch it cannot (D-058).

  `update_activity/3` and `delete_activity/2` are the one exception: an `%Activity{}`
  only carries `group_id`, not the organizer, so ownership there is a DB re-read
  (`authorize_activity/2`, itself two clauses) rather than a pure pattern match — see
  the note on those two functions. `claim_anonymous_groups/2` is the other kind of
  exception: the one write here authorized by possession of a secret rather than by a
  scope.

  *Anonymous* in `AnonymousOrganizer` means **has no account**; it is unrelated to a
  group's `anonymous` field, which is voting secrecy (D-035).

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

  An option's **details** (website, phone, address, location, category) are
  deliberately outside the frozen set: `update_activity_details/3` works in every
  status but `:cancelled`. None of the three reasons above applies to a phone number,
  and the winner card is where a wrong one hurts (D-060). `adopt_lookup_result/3`
  renames, so it stays inside.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities.Activity
  alias Consensus.Activities.AnonymousOrganizer
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

  @topic_prefix "activity_group:"

  # An anonymous organizer's token stops resolving after this long without a visit,
  # and the resolver records a visit at most once per `@touch_interval_seconds` — so an
  # organizer clicking around the wizard costs one write a day, not one per page.
  @organizer_idle_days 90
  @touch_interval_seconds 24 * 60 * 60

  # The boot sweep deletes an unclaimed identity that owns no group after this long.
  @sweep_idle_days 30

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
  Lists the caller's groups — a signed-in user's, or an anonymous organizer's — newest
  first, activities preloaded.

  Each group is passed through `maybe_complete_group/1` first, so a `:voting` group
  whose deadline has already passed is reported (and, on its first read since expiry,
  persisted) as `:completed` rather than stale.
  """
  def list_groups(%Scope{user: %User{id: user_id}, anonymous_organizer: nil})
      when is_integer(user_id) do
    do_list_groups(from(g in Group, where: g.organizer_id == ^user_id))
  end

  def list_groups(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}})
      when is_integer(id) do
    do_list_groups(from(g in Group, where: g.anonymous_organizer_id == ^id))
  end

  defp do_list_groups(owned) do
    from(g in owned, order_by: [desc: g.inserted_at, desc: g.id])
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
  someone else — the query itself is filtered by the caller's owner column, so the two
  cases are indistinguishable from outside, which is the point.

  Preloads the activities and the owner (see `organizer_custom_name/1`).
  """
  def get_group!(%Scope{user: %User{id: user_id}, anonymous_organizer: nil}, id)
      when is_integer(user_id) do
    do_get_group!(id, organizer_id: user_id)
  end

  def get_group!(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: owner_id}}, id)
      when is_integer(owner_id) do
    do_get_group!(id, anonymous_organizer_id: owner_id)
  end

  defp do_get_group!(id, owned_by) do
    Group
    |> Repo.get_by!([{:id, id} | owned_by])
    |> Repo.preload([:activities | owner_preloads()])
    |> maybe_complete_group()
  end

  @doc """
  Gets a group by its public share slug, unscoped.

  This is the `/join/<slug>` lookup a guest voter follows — there is no organizer to
  scope it to. Returns `nil` when the slug does not match anything.

  Preloads the activities and the owner, so a guest screen can name the organizer
  (`organizer_custom_name/1`) without another query. An anonymous owner is loaded
  **narrowly** — `id` and `display_name` only — because this group lands in a guest's
  socket assigns and the row's `token_hash` must never be among them.
  """
  def get_group_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Group, slug: slug) do
      nil -> nil
      group -> group |> Repo.preload([:activities | owner_preloads()]) |> maybe_complete_group()
    end
  end

  # The owner, for naming. An anonymous organizer row also holds the hash of a write
  # capability; only the two fields a name needs are ever selected into a `%Group{}`.
  defp owner_preloads do
    [
      :organizer,
      anonymous_organizer: from(o in AnonymousOrganizer, select: struct(o, [:id, :display_name]))
    ]
  end

  @doc """
  The name the organizer chose to be shown to guests, or `nil` for none.

  The account's username for a user-owned group; the self-chosen `display_name` (which
  may be `nil`) for an anonymous-owned one. This is the domain's only accessor for the
  organizer's name — how `nil` reads ("The organizer" / "the organizer") is
  presentation and lives in the web layer. An owner not already preloaded is loaded
  here, narrowly, rather than silently reading as unnamed.
  """
  def organizer_custom_name(%Group{} = group) do
    case Repo.preload(group, owner_preloads()) do
      %Group{organizer: %User{username: username}} -> username
      %Group{anonymous_organizer: %AnonymousOrganizer{display_name: name}} -> name
      %Group{} -> nil
    end
  end

  @doc """
  True when the user owns at least one group.

  One query, for the log-out flash only (plan §6.4) — a claim moves an anonymous
  organizer's sessions to the account, so logging out makes them unreachable from that
  browser until the person logs back in. Never call it per render.
  """
  def owns_any_group?(%User{id: user_id}) when is_integer(user_id) do
    Repo.exists?(from(g in Group, where: g.organizer_id == ^user_id))
  end

  @doc """
  How many groups an organizer with no account owns. One `COUNT`, for the magic-link
  confirmation screen's "save N sessions" consent (D-058) — never per render elsewhere,
  and no lazy completion, which `list_groups/1` would run on every row.
  """
  def count_groups(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}})
      when is_integer(id) do
    Repo.aggregate(from(g in Group, where: g.anonymous_organizer_id == ^id), :count)
  end

  ## Groups — writes

  @doc """
  An unsaved `%Group{}` owned by the caller — the struct the `01 setup` form starts
  from, so a LiveView never reaches into `scope.user.id` itself.
  """
  def new_group(%Scope{user: %User{id: user_id}, anonymous_organizer: nil})
      when is_integer(user_id) do
    %Group{organizer_id: user_id}
  end

  def new_group(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}})
      when is_integer(id) do
    %Group{anonymous_organizer_id: id}
  end

  @doc "Returns an `%Ecto.Changeset{}` for tracking new-group changes."
  def change_group(scope, group, attrs \\ %{})

  def change_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        attrs
      )
      when is_integer(user_id) do
    Group.changeset(group, attrs)
  end

  def change_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        attrs
      )
      when is_integer(id) do
    Group.changeset(group, attrs)
  end

  @doc """
  Creates a group with the caller as organizer.

  The owner (`:organizer_id`, or `:anonymous_organizer_id` for an organizer with no
  account) comes from the scope, never from `attrs` — see
  `Consensus.Activities.Group.changeset/2`.

  An organizer with no account is refused with `{:error, :claimed}` once their identity
  has been claimed. The scope is whatever the socket mounted with, and a log-in in
  another tab can claim the identity under it — often while it still owns nothing, since
  it is minted before step 1 is submitted. A group inserted on a claimed identity would
  be stranded for good: no resolver returns a claimed row, the cookie is gone, and a
  re-claim finds nothing new to move. The re-read sits in the same transaction as the
  insert, so under production's `:immediate` mode it cannot interleave with the claim.
  """
  def create_group(%Scope{user: %User{id: user_id}, anonymous_organizer: nil}, attrs)
      when is_integer(user_id) do
    do_create_group(%Group{organizer_id: user_id}, attrs)
  end

  def create_group(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}}, attrs)
      when is_integer(id) do
    Repo.transact(fn ->
      with :ok <- ensure_unclaimed(id) do
        do_create_group(%Group{anonymous_organizer_id: id}, attrs)
      end
    end)
  end

  # Gone counts as claimed too: either way nothing will ever resolve to this identity.
  defp ensure_unclaimed(organizer_id) do
    if Repo.exists?(
         from(o in AnonymousOrganizer, where: o.id == ^organizer_id and is_nil(o.claimed_at))
       ),
       do: :ok,
       else: {:error, :claimed}
  end

  defp do_create_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a group's own fields. Broadcasts `{:group_updated, group}` on success."
  def update_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        attrs
      )
      when is_integer(user_id) do
    do_update_group(group, attrs)
  end

  def update_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        attrs
      )
      when is_integer(id) do
    do_update_group(group, attrs)
  end

  defp do_update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> broadcast_group_update()
  end

  @doc """
  `create_group/2` and `update_organizer_display_name/2` as one transaction, for `01
  setup`'s submit when an organizer with no account typed a name (plan §7.3).

  Anonymous head only: a signed-in organizer is named by their username. The group is
  written first, so its own errors come back exactly as `create_group/2` returns them;
  a refused name rolls the group back with it and comes back tagged as
  `{:error, {:organizer_name, changeset_or_not_found}}`, so a resubmit never creates a
  second group. A claimed identity is refused with `{:error, :claimed}`, exactly as
  `create_group/2` refuses it.
  """
  def create_group_with_organizer_name(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        group_attrs,
        name_attrs
      )
      when is_integer(id) do
    Repo.transact(fn ->
      with :ok <- ensure_unclaimed(id),
           {:ok, group} <- do_create_group(%Group{anonymous_organizer_id: id}, group_attrs),
           {:ok, _organizer} <- write_organizer_name(id, name_attrs) do
        {:ok, group}
      end
    end)
  end

  @doc """
  `update_group/3` and `update_organizer_display_name/2` as one transaction — the `:edit`
  twin of `create_group_with_organizer_name/3`, with the same returns. The
  `{:group_updated, group}` broadcast fires after commit, never from inside the
  transaction: a broadcast cannot be rolled back.
  """
  def update_group_with_organizer_name(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        group_attrs,
        name_attrs
      )
      when is_integer(id) do
    Repo.transact(fn ->
      with {:ok, group} <- group |> Group.changeset(group_attrs) |> Repo.update(),
           {:ok, _organizer} <- write_organizer_name(id, name_attrs) do
        {:ok, group}
      end
    end)
    |> broadcast_group_update()
  end

  defp write_organizer_name(organizer_id, attrs) do
    case do_update_organizer_display_name(organizer_id, attrs) do
      {:ok, organizer} -> {:ok, organizer}
      {:error, reason} -> {:error, {:organizer_name, reason}}
    end
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
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        attrs
      )
      when is_integer(user_id) do
    do_set_search_area(group, attrs)
  end

  def set_search_area(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        attrs
      )
      when is_integer(id) do
    do_set_search_area(group, attrs)
  end

  defp do_set_search_area(%Group{status: :draft} = group, attrs) do
    group
    |> Group.search_area_changeset(attrs)
    |> Repo.update()
  end

  defp do_set_search_area(%Group{}, _attrs), do: {:error, :pool_locked}

  @doc """
  Moves a group from `:draft` to `:voting`.

  Refuses with `{:error, :no_activities}` when the pool is empty, `{:error, :no_deadline}`
  when `deadline_at` is unset, and `{:error, :not_draft}` when the group has already
  left `:draft` (publishing is not idempotent — a second call is almost always a bug
  in the caller, not a no-op the caller wants). Broadcasts `{:group_updated, group}` on
  success.
  """
  def publish_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group
      )
      when is_integer(user_id) do
    do_publish_group(group)
  end

  def publish_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group
      )
      when is_integer(id) do
    do_publish_group(group)
  end

  defp do_publish_group(%Group{} = group) do
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
  def cancel_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group
      )
      when is_integer(user_id) do
    do_cancel_group(group)
  end

  def cancel_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group
      )
      when is_integer(id) do
    do_cancel_group(group)
  end

  defp do_cancel_group(%Group{} = group) do
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
  def complete_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group
      )
      when is_integer(user_id) do
    do_complete_group(group)
  end

  def complete_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group
      )
      when is_integer(id) do
    do_complete_group(group)
  end

  defp do_complete_group(%Group{} = group) do
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
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        activity_id,
        resolution
      )
      when is_integer(user_id) do
    do_resolve_group(group, activity_id, resolution)
  end

  def resolve_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        activity_id,
        resolution
      )
      when is_integer(id) do
    do_resolve_group(group, activity_id, resolution)
  end

  defp do_resolve_group(%Group{} = group, activity_id, resolution) do
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
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil} = scope,
        %Group{organizer_id: user_id} = group
      )
      when is_integer(user_id) do
    do_rescue_group(scope, group)
  end

  def rescue_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}} = scope,
        %Group{anonymous_organizer_id: id} = group
      )
      when is_integer(id) do
    do_rescue_group(scope, group)
  end

  # Takes the scope only to hand it back to `resolve_group/4`, whose own heads check
  # ownership again — never to read the owner here.
  defp do_rescue_group(%Scope{} = scope, %Group{} = group) do
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
  def reopen_group(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group
      )
      when is_integer(user_id) do
    do_reopen_group(group)
  end

  def reopen_group(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group
      )
      when is_integer(id) do
    do_reopen_group(group)
  end

  defp do_reopen_group(%Group{} = group) do
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
  set from the scope; `attrs` cannot override it. It is a foreign key to `users`, so an
  organizer with no account leaves it `nil`. Broadcasts `{:activity_added, activity}`
  on success.
  """
  def add_activity(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        attrs
      )
      when is_integer(user_id) do
    do_add_activity(group, user_id, attrs)
  end

  def add_activity(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        attrs
      )
      when is_integer(id) do
    do_add_activity(group, nil, attrs)
  end

  defp do_add_activity(%Group{status: :draft} = group, added_by_id, attrs) do
    %Activity{group_id: group.id, added_by_id: added_by_id}
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

  defp do_add_activity(%Group{}, _added_by_id, _attrs), do: {:error, :pool_locked}

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
      |> broadcast_activity_update(group.id)
    end
  end

  @doc """
  `02b`'s Save while the group is still a draft: the activity's own fields
  (`Activity.changeset/2`) **and** its details (`Activity.details_changeset/2`) in one
  write, so a Save cannot half-apply. Ownership, the frozen-pool refusal and the
  broadcast are `update_activity/3`'s. After publish the editor saves through
  `update_activity_details/3` instead.
  """
  def update_activity_and_details(%Scope{} = scope, %Activity{} = activity, attrs) do
    with {:ok, group} <- authorize_activity(scope, activity),
         :ok <- ensure_pool_editable(group) do
      activity
      |> Activity.changeset(attrs)
      |> Activity.details_changeset(attrs)
      |> Repo.update()
      |> broadcast_activity_update(group.id)
    end
  end

  @doc """
  Updates an activity's **details** — website (`source_url`), phone, address,
  location, category — and nothing else (`Activity.details_changeset/2`).

  Ownership is `update_activity/3`'s re-read (`authorize_activity/2`). Deliberately
  **not** behind the frozen-pool check (D-060, amending D-037): votes point at an
  option's identity, not its phone number, and a wrong phone matters most *after* the
  vote, on the winner card. A `:cancelled` group is refused with
  `{:error, :group_closed}` — there is no winner card left to fix. Broadcasts
  `{:activity_updated, activity}`, so open results screens update live.
  """
  def update_activity_details(%Scope{} = scope, %Activity{} = activity, attrs) do
    with {:ok, group} <- authorize_activity(scope, activity),
         :ok <- ensure_group_open(group) do
      activity
      |> Activity.details_changeset(attrs)
      |> Repo.update()
      |> broadcast_activity_update(group.id)
    end
  end

  @doc """
  Adopts a lookup result the organizer confirmed with **Use this**: the provider's
  canonical name, its details and its `osm_ref` provenance in one write
  (`Activity.lookup_changeset/2`), so a half-applied suggestion cannot exist.

  `attrs` must come from `Consensus.Discovery.Result.persistable_attrs/1` — the
  retention firewall — never from a form. Same ownership re-read as
  `update_activity/3`, and the same `{:error, :pool_locked}` once the group has left
  `:draft`, because it renames. Broadcasts `{:activity_updated, activity}`. A result
  that came from the shared catalog links the option to its row (`catalog_item_id`)
  and counts one use of it; the option's later edits stay its own (D-060 §3.2).
  """
  def adopt_lookup_result(%Scope{} = scope, %Activity{} = activity, attrs) when is_map(attrs) do
    with {:ok, group} <- authorize_activity(scope, activity),
         :ok <- ensure_pool_editable(group) do
      Repo.transact(fn ->
        with {:ok, current} <- release_before_relink(activity, attrs) do
          current |> Activity.lookup_changeset(attrs) |> Repo.update()
        end
      end)
      |> broadcast_activity_update(group.id)
      |> tap(fn
        {:ok, %Activity{catalog_item_id: row_id}} -> Consensus.Catalog.record_use(row_id)
        _error -> :ok
      end)
    end
  end

  # Every write to an option ends here: the shared catalog row it created (if any)
  # follows the edit — `Consensus.Catalog.sync_activity/1` never raises and never fails
  # this write (D-060) — and open screens hear about it.
  @doc """
  An admin's fix to someone else's option, from `/admin/items` (D-060): the
  **details only** (`Activity.details_changeset/2`). Admins cannot rename, reorder or
  delete another organizer's options — invariant 16's reasons bind them too, and a
  delete would cascade votes. Matches an admin scope in the head (a non-admin raises
  `FunctionClauseError`), re-reads the actor's role in the write's transaction, logs an `[audit] activity_details_edit` line, and broadcasts
  like any other write so open screens update.
  """
  def admin_update_activity_details(
        %Scope{user: %User{is_admin: true} = actor},
        %Activity{} = activity,
        attrs
      ) do
    Consensus.Catalog.as_admin(actor, fn ->
      activity |> Activity.details_changeset(attrs) |> Repo.update()
    end)
    |> broadcast_activity_update(activity.group_id)
    |> Consensus.Audit.log("activity_details_edit", actor, activity.id)
  end

  @doc """
  The admin listing of every option in every group, newest first, with its group (and
  the group's owners, for `ConsensusWeb.OrganizerLabel`) preloaded. Filters:
  `:group_status`, `:details` (`true` — has a phone, address, location or category)
  and `:shared` (`true` — its organizer has **Let anyone find this** on).
  """
  def list_all_activities_for_admin(%Scope{user: %User{is_admin: true}}, filters \\ %{}) do
    Activity
    |> join(:inner, [a], g in assoc(a, :group), as: :group)
    |> admin_group_status(filters[:group_status])
    |> admin_has_details(filters[:details])
    |> admin_shared(filters[:shared])
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> preload(group: [:organizer, :anonymous_organizer])
    |> Repo.all()
  end

  defp admin_group_status(query, status) when status in [nil, ""], do: query

  defp admin_group_status(query, status) when is_binary(status) do
    case Enum.find(Group.statuses(), &(Atom.to_string(&1) == status)) do
      nil -> query
      atom -> where(query, [group: g], g.status == ^atom)
    end
  end

  defp admin_has_details(query, true) do
    where(
      query,
      [a],
      not is_nil(a.phone) or not is_nil(a.address) or not is_nil(a.latitude) or
        not is_nil(a.category)
    )
  end

  defp admin_has_details(query, _off), do: query

  defp admin_shared(query, true), do: where(query, [a], not is_nil(a.shared_to_catalog_at))
  defp admin_shared(query, _off), do: query

  # Adopting a shared-catalog row re-links the option. If the option was itself
  # sharing a row it created, that share ends first — otherwise the old row would keep
  # pointing at an option that no longer links to it, and no unshare could ever reach
  # it again. Any other adoption leaves the link alone (the own row then syncs).
  defp release_before_relink(%Activity{id: id}, %{catalog_item_id: new_row})
       when not is_nil(new_row) do
    current = Repo.get!(Activity, id)

    if current.shared_to_catalog_at && current.catalog_item_id != new_row,
      do: Consensus.Catalog.release_activity(current),
      else: {:ok, current}
  end

  defp release_before_relink(%Activity{id: id}, _attrs), do: {:ok, Repo.get!(Activity, id)}

  defp broadcast_activity_update({:ok, updated} = result, group_id) do
    Consensus.Catalog.sync_activity(updated)
    broadcast(group_id, {:activity_updated, updated})
    result
  end

  defp broadcast_activity_update(error, _group_id), do: error

  defp ensure_group_open(%Group{status: :cancelled}), do: {:error, :group_closed}
  defp ensure_group_open(%Group{}), do: :ok

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
        # An option that goes away takes its catalog share with it (D-060), exactly as
        # turning the toggle off would — the FK's SET NULL would otherwise leave the row
        # public with nobody able to retract it.
        with {:ok, _released} <-
               Activity |> Repo.get!(activity.id) |> Consensus.Catalog.release_activity(),
             {:ok, deleted} <- Repo.delete(activity) do
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
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Group{organizer_id: user_id} = group,
        ordered_ids
      )
      when is_integer(user_id) and is_list(ordered_ids) do
    do_reorder_activities(group, ordered_ids)
  end

  def reorder_activities(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Group{anonymous_organizer_id: id} = group,
        ordered_ids
      )
      when is_integer(id) and is_list(ordered_ids) do
    do_reorder_activities(group, ordered_ids)
  end

  defp do_reorder_activities(%Group{status: :draft} = group, ordered_ids) do
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

  defp do_reorder_activities(%Group{}, _ordered_ids), do: {:error, :pool_locked}

  defp valid_reorder?(ordered_ids, current_ids) do
    length(ordered_ids) == length(current_ids) and
      MapSet.new(ordered_ids) == MapSet.new(current_ids)
  end

  # The pool is editable only while the group is a draft. See "The pool is frozen the
  # moment the vote opens" in the moduledoc for why this is an integrity rule rather
  # than a workflow preference.
  defp ensure_pool_editable(%Group{status: :draft}), do: :ok
  defp ensure_pool_editable(%Group{}), do: {:error, :pool_locked}

  # The documented exception to head-matched ownership (see the moduledoc): an
  # `%Activity{}` does not carry its owner, so the group is re-read and its owner column
  # pinned against the scope's id. Two clauses, one per kind of owner, with the same
  # three rules as every other pair — so a both-set scope or an unsaved id raises here
  # too, rather than reaching the re-read.
  @doc false
  # Public for `Consensus.Catalog`, whose share/unshare are owning writes on an
  # `%Activity{}` too (D-060) and must use this exact pair rather than a second copy.
  def authorize_activity(
        %Scope{user: %User{id: user_id}, anonymous_organizer: nil},
        %Activity{group_id: group_id}
      )
      when is_integer(user_id) do
    case Repo.get(Group, group_id) do
      %Group{organizer_id: ^user_id} = group -> {:ok, group}
      %Group{} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  def authorize_activity(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        %Activity{group_id: group_id}
      )
      when is_integer(id) do
    case Repo.get(Group, group_id) do
      %Group{anonymous_organizer_id: ^id} = group -> {:ok, group}
      %Group{} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  ## Anonymous organizers (D-058)

  @doc """
  Mints a new organizer identity for a browser with no account.

  Returns `{raw_token, %AnonymousOrganizer{}}`. `raw_token` is 32 random bytes for the
  browser's signed cookie and is never stored; the row holds only its SHA-256 digest.
  Called by the web layer's mint plug on `GET /groups/new` only — never per request,
  since every call is a write on the single SQLite writer.
  """
  def mint_anonymous_organizer do
    raw_token = :crypto.strong_rand_bytes(32)

    organizer =
      raw_token
      |> hash_organizer_token()
      |> AnonymousOrganizer.creation_changeset()
      |> Repo.insert!()

    {raw_token, organizer}
  end

  @doc """
  Resolves a browser's raw organizer token to its live identity, or `nil`.

  The one resolver every caller shares, so the mint plug, the wizard's on_mount hook
  and `/` all agree on whether an identity is alive. Returns `nil` for anything that
  is not a binary, for an unknown token, for a row that has been **claimed** (its
  sessions belong to an account now), and for a row idle longer than
  #{@organizer_idle_days} days.

  On a hit it records the visit by bumping `last_seen_at` — at most once per 24 hours,
  through a conditional `UPDATE`, so a row already touched today costs no write. A
  touch refused by a busy database is logged and skipped: a failed bookkeeping write
  never fails the request it rode in on.
  """
  def get_anonymous_organizer_by_token(raw_token) when is_binary(raw_token) do
    now = DateTime.utc_now(:second)
    idle_cutoff = DateTime.add(now, -@organizer_idle_days, :day)
    token_hash = hash_organizer_token(raw_token)

    from(o in AnonymousOrganizer,
      where:
        o.token_hash == ^token_hash and is_nil(o.claimed_at) and
          o.last_seen_at >= ^idle_cutoff
    )
    |> Repo.one()
    |> case do
      nil -> nil
      %AnonymousOrganizer{} = organizer -> touch_anonymous_organizer(organizer, now)
    end
  end

  def get_anonymous_organizer_by_token(_raw_token), do: nil

  defp touch_anonymous_organizer(%AnonymousOrganizer{} = organizer, now) do
    touch_cutoff = DateTime.add(now, -@touch_interval_seconds, :second)

    if DateTime.compare(organizer.last_seen_at, touch_cutoff) == :lt do
      {_, _} =
        Repo.update_all(
          from(o in AnonymousOrganizer,
            where: o.id == ^organizer.id and o.last_seen_at < ^touch_cutoff
          ),
          set: [last_seen_at: now]
        )

      %{organizer | last_seen_at: now}
    else
      organizer
    end
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "[organizer] last_seen_at touch skipped: database busy (#{Exception.message(error)})"
      )

      organizer
  end

  defp hash_organizer_token(raw_token), do: :crypto.hash(:sha256, raw_token)

  @doc """
  Returns an `%Ecto.Changeset{}` for an anonymous organizer's display name, for the
  `01 setup` "Your name" field. See `update_organizer_display_name/2`.
  """
  def change_organizer_display_name(scope, attrs \\ %{})

  def change_organizer_display_name(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id} = organizer},
        attrs
      )
      when is_integer(id) do
    AnonymousOrganizer.display_name_changeset(organizer, attrs)
  end

  @doc """
  Sets the optional name an anonymous organizer is shown to guests as.

  Casts only `:display_name`, through `AnonymousOrganizer.display_name_changeset/2`:
  trimmed, internal whitespace collapsed, invisible and text-direction characters
  refused, capped at `AnonymousOrganizer.max_display_name_length/0` graphemes; blank
  becomes `nil` ("the organizer"). The name lives on the person, so it changes on every
  one of their unclaimed sessions at once (D-058).

  The changeset is built on a fresh read of the row, never on the struct in the scope.
  That struct is whatever the socket mounted with, and Ecto writes only fields that
  differ from it — so with another tab having renamed the person since, clearing the
  field back to the stale value would be a silent no-op reported as `{:ok, _}`.

  Returns `{:ok, %AnonymousOrganizer{}}`, `{:error, changeset}`, or
  `{:error, :not_found}` once the row is gone (swept or claimed). There is no user
  head: a signed-in organizer is named by their username.
  """
  def update_organizer_display_name(
        %Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
        attrs
      )
      when is_integer(id) do
    do_update_organizer_display_name(id, attrs)
  end

  defp do_update_organizer_display_name(organizer_id, attrs) do
    case Repo.get(AnonymousOrganizer, organizer_id) do
      nil ->
        {:error, :not_found}

      organizer ->
        organizer
        |> AnonymousOrganizer.display_name_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Moves every group an anonymous organizer owns to `user`'s account — the claim
  (D-058, plan §6.3).

  **This is the one write in this module authorized by possession of a secret rather
  than by a head-matched scope**, so where `raw_token` comes from is the whole of its
  security: it is read only from the signed organizer cookie on the conn, in
  `ConsensusWeb.UserAuth.log_in_user/4`, after the person has proved they own `user`.
  It must never be taken from a client parameter — a token in a form field or a query
  string would let anyone holding one move sessions into any account they can log in
  to, and would put a write capability in history and `Referer`.

  In one transaction:

    1. a compare-and-swap on the identity, `SET claimed_by_user_id, claimed_at WHERE
       claimed_at IS NULL` — the house idiom (`Consensus.Voting.cast_ballot/3`'s `WHERE
       voted_at IS NULL`), so two simultaneous claims cannot both win whatever the
       transaction mode;
    2. every group it owns has `organizer_id` set and `anonymous_organizer_id` cleared.
       Ownership *moves*; the identity is left owning nothing.

  Returns:

    * `{:ok, count}` — the number of groups moved. A re-claim by the user who already
      claimed it moves whatever still names the identity — normally nothing, so
      `{:ok, 0}` — which makes the claim self-healing: a group that raced onto the
      identity after the first claim is picked up by the next one;
    * `{:error, :already_claimed}` — claimed by a different account;
    * `{:error, :not_found}` — an unknown token, or one idle past
      #{@organizer_idle_days} days;
    * `{:error, {:database_busy, message}}` — SQLite refused the write. Logged at
      `:warning`; the caller keeps the cookie so the next log-in retries.
  """
  def claim_anonymous_groups(%User{id: user_id}, raw_token)
      when is_integer(user_id) and is_binary(raw_token) do
    now = DateTime.utc_now(:second)
    idle_cutoff = DateTime.add(now, -@organizer_idle_days, :day)

    case Repo.get_by(AnonymousOrganizer, token_hash: hash_organizer_token(raw_token)) do
      nil ->
        {:error, :not_found}

      %AnonymousOrganizer{claimed_at: nil, last_seen_at: last_seen_at} = organizer ->
        if DateTime.compare(last_seen_at, idle_cutoff) == :lt,
          do: {:error, :not_found},
          else: claim_organizer(organizer, user_id, now)

      %AnonymousOrganizer{} = organizer ->
        claim_organizer(organizer, user_id, now)
    end
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "[organizer] claim refused for user_id=#{user_id}: database busy " <>
          "(#{Exception.message(error)})"
      )

      {:error, {:database_busy, Exception.message(error)}}
  end

  def claim_anonymous_groups(%User{id: user_id}, _raw_token) when is_integer(user_id) do
    {:error, :not_found}
  end

  # Runs the CAS even for a row already seen as claimed: the zero-row branch is what
  # tells "claimed by me" from "claimed by someone else", and it re-reads inside the
  # transaction rather than trusting the read above.
  defp claim_organizer(%AnonymousOrganizer{id: organizer_id}, user_id, now) do
    Repo.transact(fn ->
      claimed =
        Repo.update_all(
          from(o in AnonymousOrganizer, where: o.id == ^organizer_id and is_nil(o.claimed_at)),
          set: [claimed_by_user_id: user_id, claimed_at: now, updated_at: now]
        )

      case claimed do
        {1, _} ->
          {:ok, move_groups(organizer_id, user_id, now)}

        {0, _} ->
          case Repo.get(AnonymousOrganizer, organizer_id) do
            # Moved again rather than answered `{:ok, 0}` outright, so a group that
            # landed on the identity after the first claim is not stranded.
            %AnonymousOrganizer{claimed_by_user_id: ^user_id} ->
              {:ok, move_groups(organizer_id, user_id, now)}

            %AnonymousOrganizer{} ->
              {:error, :already_claimed}

            nil ->
              {:error, :not_found}
          end
      end
    end)
  end

  defp move_groups(organizer_id, user_id, now) do
    {moved, _} =
      Repo.update_all(
        from(g in Group, where: g.anonymous_organizer_id == ^organizer_id),
        set: [organizer_id: user_id, anonymous_organizer_id: nil, updated_at: now]
      )

    moved
  end

  @doc """
  Deletes abandoned anonymous organizer identities and returns how many went.

  An identity is abandoned when it is unclaimed, idle for more than
  #{@sweep_idle_days} days as of `now`, and owns **no** group — in practice a drive-by
  visit to `/groups/new` that never saved anything. One statement. Rows that own a
  group are never touched (past #{@organizer_idle_days} days they simply stop
  resolving), and `activity_groups.anonymous_organizer_id` is `ON DELETE RESTRICT`, so
  a wrong predicate here raises instead of cascading through groups and votes.
  Claimed rows are history and are kept.

  Housekeeping, not correctness: run once at boot (there is no scheduler — D-029). A
  busy database is logged and reported as `0` so it can never abort a boot.
  """
  def sweep_anonymous_organizers(%DateTime{} = now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@sweep_idle_days, :day)

    owns_a_group =
      from(g in Group,
        where: g.anonymous_organizer_id == parent_as(:organizer).id,
        select: 1
      )

    {count, _} =
      Repo.delete_all(
        from(o in AnonymousOrganizer,
          as: :organizer,
          where: is_nil(o.claimed_at) and o.last_seen_at < ^cutoff and not exists(owns_a_group)
        )
      )

    count
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.warning("[organizer] sweep skipped: database busy (#{Exception.message(error)})")

      0
  end
end
