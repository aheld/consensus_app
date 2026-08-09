defmodule Consensus.Voting do
  @moduledoc """
  The Voting context: participants in an activity group's vote, and the ballots they
  cast.

  This is deliberately **not** part of `Consensus.Activities`. That context is
  organizer-scoped and takes a `%Consensus.Accounts.Scope{}` first; every function here
  acts for a participant who usually has no account at all (CLAUDE.md product invariant
  1 — voter friction is zero, a guest never sees a signup, a password or an email
  field). The unit of authorization here is therefore the participant's **token**, not a
  scope: whoever holds the token in their session is that participant, and
  `get_participant_by_token/1` is the only way to turn one back into a row.

  ## The tally is approval voting

  A ballot is a set of approvals plus at most one veto. An option with **any** veto is
  eliminated; among the survivors, more approvals wins, ties broken by the organizer's
  own `position` so the result is deterministic. Ranked-choice (Borda / IRV) is
  explicitly Post-MVP — do not add a rank or weight anywhere in here.

  ## Anonymity is structural, not cosmetic

  `tally/1` returns **totals only**. There is deliberately no public function in this
  module that maps a participant to the activities they approved, so an anonymous group
  cannot leak choices through a template that forgot to hide something. `participants/1`
  returns name/initial and *whether* someone has voted, never *what* they voted:
  participation is public, choices are secret.

  ## Live updates

  `subscribe/1` and both broadcasts — on a cast, and on a join — use the **existing**
  `"activity_group:<id>"` topic that `Consensus.Activities` already publishes on (via
  `Consensus.Activities.topic/1`), so a results screen needs one subscription to see
  organizer edits, incoming ballots, and new joiners alike. The messages are
  `{:ballot_cast, group_id}` and `{:participant_joined, group_id}`, and neither carries
  anything about the ballot's contents — a subscriber re-reads `tally/1` and
  `participants/1`, which are incapable of returning per-participant choices.

  ## Everything a voter can reach returns a tuple, and holds the write lock briefly

  This is the first **public, unauthenticated, deliberately burst-shaped** write in the
  app: five friends tapping "send my votes" the moment the deadline chip turns red is
  the core use case, not an edge. SQLite permits one write transaction across the whole
  file (D-033), so two rules follow and both are load-bearing:

    * **Validate outside the transaction.** `cast_ballot/3` does every pure and
      read-only check — id casting, ballot shape, participant, group status, deadline,
      "is this activity even in this group" — *before* `Repo.transact/1` opens. The
      transaction itself is three statements: one primary-key re-read of the group, the
      conditional `UPDATE` that is the lock, and one `insert_all` for every vote row.
      Measured on a real pool at production's settings (`pool_size: 5`,
      `default_transaction_mode: :immediate`, `busy_timeout: 5_000`, WAL), doing the
      reads *inside* the transaction instead cost 21 of 48 ballots at four simultaneous
      voters and 54 of 96 at eight; with them outside, every ballot succeeds at eight.
      Anything added inside this transaction has to earn its place.
    * **Every entry point rescues.** `create_participant/2` and `cast_ballot/3` both
      rescue `Exqlite.Error` **and** `DBConnection.ConnectionError` into
      `{:error, {:database_busy, message}}`. The first is SQLite refusing the write
      lock; the second is the connection pool timing out behind a writer that already
      has it. Only rescuing the first left a guest's LiveView crashing rather than
      flashing a message — the exact outcome the rescue exists to prevent.
  """

  import Ecto.Query, warn: false

  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Activities.Group
  alias Consensus.Repo
  alias Consensus.Voting.Participant
  alias Consensus.Voting.Vote

  require Logger

  # How many times a ballot re-queues for SQLite's write lock before giving up, and the
  # jittered pause between attempts. See `cast_ballot/3` and D-034.
  @busy_retries 2
  @busy_retry_pause_ms 25..150

  ## PubSub

  @doc """
  Subscribes the calling process to one group's updates, ballots included.

  This is the same topic `Consensus.Activities.subscribe_group/1` uses; calling both
  would subscribe twice and deliver every message twice. Subscribers receive
  `{:ballot_cast, group_id}` from this context, plus `{:group_updated, group}` and the
  activity messages from `Consensus.Activities`.
  """
  def subscribe(group_id), do: Activities.subscribe_group(group_id)

  defp broadcast(group_id, message) do
    Phoenix.PubSub.broadcast(Consensus.PubSub, Activities.topic(group_id), message)
  end

  ## Participants

  @doc """
  Creates a participant in a group and mints their token.

  `attrs` may use atom or string keys and understands three of them:

    * `:display_name` — the typed name, or `nil`/blank for anonymous. A blank or
      whitespace-only name is normalised to `nil`.
    * `:kind` — `:guest` (the default) or `:user`.
    * `:user_id` — required when `kind` is `:user`, and rejected otherwise.

  `:token` is generated here from 32 bytes of `:crypto.strong_rand_bytes/1` and is not
  castable; neither is `:voted_at`. `:group_id` comes from the group argument, never
  from `attrs`.

  Refuses with `{:error, :not_open}` unless the group is `:voting` — a draft's pool is
  still being edited and a finished group's vote is over, so neither should mint new
  voters. A signed-in user who joins twice is refused by the partial unique index on
  `(group_id, user_id)` and comes back as a changeset error on `:user_id`; call
  `get_participant_for_user/2` first so a returning user resumes instead.

  Returns `{:error, {:database_busy, message}}` rather than raising when SQLite refuses
  the write lock or the pool times out behind a writer holding it. This is the
  `/join/:slug` front door and its caller is a **controller**, which has no error tuple
  to render into a socket — without the rescue an ordinary burst of ballots on the same
  group turned a guest's first screen into a 500 before they had seen the pool.

      iex> create_participant(group, %{display_name: "Ada"})
      {:ok, %Participant{kind: :guest, display_name: "Ada"}}

      iex> create_participant(group, %{display_name: "  ", kind: :guest})
      {:ok, %Participant{display_name: nil}}

      iex> create_participant(draft_group, %{})
      {:error, :not_open}

  """
  def create_participant(group, attrs \\ %{})

  def create_participant(%Group{status: :voting} = group, attrs) do
    attrs = participant_attrs(attrs)

    result =
      %Participant{group_id: group.id, user_id: attrs.user_id, token: generate_token()}
      |> Participant.changeset(attrs)
      |> Repo.insert()

    with {:ok, %Participant{}} <- result do
      # A results screen's avatar row shows *who has joined*, not just who has voted
      # (`participants/1`'s own doc: "participation is public, choices are secret"), and
      # the footer's "Nudge N friends" count is read straight from that same list. Before
      # this broadcast, a guest who joined but had not yet voted stayed invisible on
      # every open results screen for up to the 30s `:tick` — PRD product invariant 4
      # says results are real-time, and joining is exactly as much "results" as voting
      # is for that row. Carries only the group id, same as `{:ballot_cast, group_id}` —
      # a subscriber re-reads `participants/1` rather than trusting anything in the
      # message.
      broadcast(group.id, {:participant_joined, group.id})
    end

    result
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      {:error, {:database_busy, Exception.message(error)}}
  end

  def create_participant(%Group{}, _attrs), do: {:error, :not_open}

  @doc """
  Looks a participant up by the token in their session. `nil` when unknown.

  Tokens are globally unique, so this is not scoped to a group — a caller that resolved
  a group from the URL slug should check `participant.group_id == group.id` before
  trusting the row for that page.
  """
  def get_participant_by_token(token) when is_binary(token) do
    Repo.get_by(Participant, token: token)
  end

  def get_participant_by_token(_token), do: nil

  @doc """
  The participant a signed-in user already has in this group, or `nil`.

  This is what makes a returning signed-in voter resume rather than duplicate.
  """
  def get_participant_for_user(%Group{} = group, user_id) when is_integer(user_id) do
    Repo.get_by(Participant, group_id: group.id, user_id: user_id)
  end

  def get_participant_for_user(%Group{}, _user_id), do: nil

  @doc """
  The avatar row: every participant in the group, in join order.

  Returns `[%{id:, display_name:, initial:, voted?:}]` — participation, never choices.
  `display_name` is `nil` for an anonymous participant and `initial` is then `"?"`.
  """
  def participants(%Group{} = group) do
    from(p in Participant,
      where: p.group_id == ^group.id,
      order_by: [asc: p.inserted_at, asc: p.id]
    )
    |> Repo.all()
    |> Enum.map(
      &%{
        id: &1.id,
        display_name: &1.display_name,
        initial: Participant.initial(&1),
        voted?: Participant.voted?(&1)
      }
    )
  end

  @doc "How many people have joined this group's vote."
  def count_participants(%Group{id: id}) do
    Repo.aggregate(from(p in Participant, where: p.group_id == ^id), :count)
  end

  @doc "How many of them have submitted a ballot."
  def count_voted(%Group{id: id}) do
    Repo.aggregate(
      from(p in Participant, where: p.group_id == ^id and not is_nil(p.voted_at)),
      :count
    )
  end

  ## The ballot

  @doc """
  Casts one participant's whole ballot — every approval and the optional veto — in one
  transaction, and locks it.

  `approved_activity_ids` and `veto_activity_id` arrive from the client and may be
  integers or strings; anything that is not a plain integer id belonging to **this
  participant's group** is refused without writing. Duplicates in the approval list are
  collapsed.

  **Client-shaped input is tolerated, not merely documented as tolerated.** The
  approvals argument goes through `List.wrap/1`, so `nil` — what a checkbox group sends
  when nothing is ticked — is an empty ballot rather than a `FunctionClauseError`, and a
  bare id is treated as a one-element list. A `nil` participant, which is what
  `get_participant_by_token/1` returns for an unknown token, is `{:error, :not_found}`.
  A LiveView may therefore push `params["approved"]` straight through without
  pre-parsing it.

  On success the participant's `voted_at` is stamped, one `%Vote{}` row exists per mark,
  and `{:ballot_cast, group_id}` is broadcast on the group topic. The ballot is then
  **locked** — there is no update path, by decision (D-036), and a second call refuses.

      iex> cast_ballot(participant, [1, 2], 3)
      {:ok, %Participant{voted_at: ~U[...]}}

      iex> cast_ballot(already_voted_participant, [1])
      {:error, :already_voted}

  ### Refusals, in the order they are checked

  Cheapest first: the pure checks on the submitted shape come before anything that
  touches the database, and everything that touches the database comes before the write
  lock is taken.

    * `{:error, :unknown_activity}` — an id that is not an integer, or is not an
      activity of this group.
    * `{:error, :empty_ballot}` — zero approvals and no veto.
    * `{:error, :veto_conflict}` — the same activity was both approved and vetoed.
    * `{:error, :not_found}` — the participant row is gone (or was `nil`).
    * `{:error, :already_voted}` — `voted_at` was already set.
    * `{:error, :not_open}` — the group is not `:voting`.
    * `{:error, :deadline_passed}` — the hard deadline has arrived.
    * `{:error, :veto_not_allowed}` — a veto was sent for a group with
      `veto_allowed: false`.
    * `{:error, {:database_busy, message}}` — SQLite refused the write lock, or the
      connection pool timed out behind a writer holding it. Same tuple as
      `Consensus.Accounts.set_admin/3`, and — unlike that one — it covers
      `DBConnection.ConnectionError` as well as `Exqlite.Error`.

  `:veto_not_allowed` and `:veto_conflict` are additions to the list in
  `docs/plans/voting-loop.md`; the plan states both rules ("`cast_ballot/3` rejects
  one") without naming a tuple for them.

  ### Why it is written the way it is

  **The lock.** `voted_at` is stamped by a conditional
  `UPDATE ... WHERE id = ? AND voted_at IS NULL`, which is both the re-read and the
  write: the `%Participant{}` the caller holds came from a socket assign and may be
  stale (the "don't trust the struct in hand" rule CLAUDE.md invariant 1 states for
  `Consensus.Accounts.set_admin/3`), and a conditional update does not depend on any
  read winning a race. Whichever ballot updates zero rows gets `{:error, :already_voted}`
  and rolls its vote rows back with it. Two tabs double-submitting therefore produce
  exactly one ballot and one refusal. The plain re-read *outside* the transaction is
  what turns the ordinary second submission into an honest `:already_voted` (and a
  deleted row into `:not_found`) without opening a transaction at all.

  **The transaction's size.** Only three statements run inside `Repo.transact/1`: a
  primary-key re-read of the group (so a group that completed while the ballot screen
  sat open cannot be voted on — the plan's requirement 4, and the one check worth the
  lock), the conditional `UPDATE`, and a single `Repo.insert_all/3` for every vote row.
  Validation that used to sit inside — three more queries and one `Repo.insert` per
  mark — held SQLite's single write lock for long enough to starve concurrent voters;
  see the moduledoc for the measurements. Nothing else belongs in here.
  """
  def cast_ballot(participant, approved_activity_ids, veto_activity_id \\ nil)

  def cast_ballot(nil, _approved_activity_ids, _veto_activity_id), do: {:error, :not_found}

  def cast_ballot(%Participant{} = participant, approved_activity_ids, veto_activity_id) do
    with_busy_retry(@busy_retries, fn ->
      with {:ok, approved_ids} <- cast_ids(List.wrap(approved_activity_ids)),
           {:ok, veto_id} <- cast_veto_id(veto_activity_id),
           :ok <- ensure_not_empty(approved_ids, veto_id),
           :ok <- ensure_no_veto_conflict(approved_ids, veto_id),
           {:ok, fresh} <- fetch_participant(participant.id),
           {:ok, group} <- fetch_group(fresh.group_id),
           :ok <- ensure_not_voted(fresh),
           :ok <- ensure_group_open(group),
           :ok <- ensure_before_deadline(group),
           :ok <- ensure_veto_permitted(group, veto_id),
           :ok <- ensure_all_in_group(group, approved_ids ++ List.wrap(veto_id)) do
        commit_ballot(fresh, approved_ids, veto_id)
      end
    end)
  end

  # A ballot that loses the race for SQLite's write lock re-queues instead of being
  # thrown away. Retrying the whole function is safe because a raise can only happen
  # before the transaction commits — `BEGIN IMMEDIATE` refusing the lock, or the pool
  # timing out on checkout — and `Repo.transact/1` rolls back anything in between. In
  # the one ambiguous case (a raise at `COMMIT`), the retry's conditional `UPDATE`
  # finds `voted_at` already set and answers `{:error, :already_voted}`, which is
  # wrong-but-harmless: the ballot did land, and the results screen will show it.
  #
  # The pause is jittered because the callers arrive together by construction — five
  # friends tapping "send my votes" at the deadline — and an unjittered retry just
  # rebuilds the same pile-up one interval later.
  defp with_busy_retry(attempts_left, fun) do
    fun.()
  rescue
    error in [Exqlite.Error, DBConnection.ConnectionError] ->
      if attempts_left > 0 do
        Process.sleep(Enum.random(@busy_retry_pause_ms))
        with_busy_retry(attempts_left - 1, fun)
      else
        Logger.warning("[voting] ballot refused after #{@busy_retries} retries: database busy")
        {:error, {:database_busy, Exception.message(error)}}
      end
  end

  # Three statements, and no more: the write lock is held for exactly as long as they
  # take. Every other check ran before this was called.
  defp commit_ballot(%Participant{} = participant, approved_ids, veto_id) do
    Repo.transact(fn ->
      with {:ok, group} <- fetch_group(participant.group_id),
           :ok <- ensure_group_open(group),
           :ok <- ensure_before_deadline(group),
           {:ok, voted} <- stamp_voted(participant) do
        insert_votes(voted, approved_ids, veto_id)
        {:ok, voted}
      end
    end)
    |> case do
      {:ok, %Participant{} = voted} = result ->
        broadcast(voted.group_id, {:ballot_cast, voted.group_id})
        result

      error ->
        error
    end
  end

  ## The tally

  @doc """
  The running tally for a group: **totals only**, never per-participant choices.

  Returns one map per activity, ordered for display:

      %{
        activity: %Activity{},
        approvals: 3,
        vetoes: 0,
        vetoed?: false,
        leader?: true,
        winner?: false,
        bar_percent: 100
      }

  Survivors come first, ranked by `approvals` descending and ties broken by
  `activity.position` ascending (the organizer's own order), which makes the result
  deterministic and testable. Every vetoed activity follows, in position order — one
  veto eliminates an option outright ("Everyone gets one veto. A vetoed option drops out
  for everyone", as `03 review` states it to the organizer).

  `leader?` marks the top survivor, and only when it has at least one approval — an
  untouched pool has no leader. `winner?` is that same activity once the group has
  reached `:completed`, and `false` before then: the mockups draw a star for the leader
  and announce a winner only after the vote closes.

  `bar_percent` is `approvals / max(1, highest_approval_count) * 100`, rounded, so the
  template does not have to find the maximum itself.
  """
  def tally(%Group{} = group) do
    activities =
      from(a in Activity, where: a.group_id == ^group.id, order_by: [asc: a.position])
      |> Repo.all()

    approvals = count_votes(group.id, :approve)
    vetoes = count_votes(group.id, :veto)

    rows =
      Enum.map(activities, fn activity ->
        veto_count = Map.get(vetoes, activity.id, 0)

        %{
          activity: activity,
          approvals: Map.get(approvals, activity.id, 0),
          vetoes: veto_count,
          vetoed?: veto_count > 0
        }
      end)

    {survivors, eliminated} = Enum.split_with(rows, &(not &1.vetoed?))

    survivors =
      Enum.sort_by(survivors, &{-&1.approvals, &1.activity.position})

    highest = survivors |> Enum.map(& &1.approvals) |> Enum.max(fn -> 0 end)
    leader_id = leader_id(survivors, highest)
    completed? = group.status == :completed

    Enum.map(survivors ++ eliminated, fn row ->
      leader? = not row.vetoed? and row.activity.id == leader_id

      row
      |> Map.put(:leader?, leader?)
      |> Map.put(:winner?, leader? and completed?)
      |> Map.put(:bar_percent, bar_percent(row, highest))
    end)
  end

  @doc """
  What a results screen should announce, given the list `tally/1` returned.

  Pure — it takes the tally rather than the group so a screen that already has one does
  not pay for a second. Four outcomes, and the last two are the reason this exists:

    * `{:winner, row}` — the group is `:completed` and one option won.
    * `{:leader, row}` — the vote is still open and one option is ahead.
    * `:no_consensus` — **every** option in the pool has been vetoed. Nothing caps total
      vetoes (one per participant, unlimited across the pool), so any group with as many
      participants as options can reach this, and `tally/1` alone reports it as a list
      with no `leader?` and no `winner?` anywhere — indistinguishable, from the outside,
      from a pool nobody has voted on. They are not the same thing and a results screen
      must not render them the same way. There is deliberately **no** fallback to the
      least-vetoed option: "everyone gets one veto, vetoed places drop out" is the rule
      the organizer showed the group, and quietly crowning something the group struck
      out would break it. See D-034.
    * `:vetoes_only` — **some** of the pool has been vetoed and nothing that survived has
      a single approval. Reachable with real ballots: a voter may spend their veto and
      approve nothing, and `cast_ballot/3` accepts that ballot. This used to fall through
      to `:no_votes` and the screen then said "Voting closed before anyone cast a ballot"
      over a `1/1 voted` avatar row and a struck-through, `VETOED`-pilled option — the
      screen contradicting itself, twice, in the reader's own line of sight. The
      discriminator is the tally alone: a veto row can only exist if a ballot carried it.
    * `:no_votes` — an empty pool, or a pool where nothing has been approved **or** vetoed.
      With `cast_ballot/3` refusing a ballot that is neither, that is now exactly "nobody
      voted", which is what every screen rendering it says.

  The runner-up failsafe CLAUDE.md product invariant 5 asks for is the second element of
  the tally itself; `outcome/1` names the top, not the list.
  """
  def outcome([]), do: :no_votes

  def outcome(tally) when is_list(tally) do
    cond do
      row = Enum.find(tally, & &1.winner?) -> {:winner, row}
      row = Enum.find(tally, & &1.leader?) -> {:leader, row}
      Enum.all?(tally, & &1.vetoed?) -> :no_consensus
      # Ordered after `:no_consensus` (which is the all-vetoed case) and before
      # `:no_votes`. Reaching here means no *surviving* option carries an approval, so the
      # two sub-cases it covers — nobody approved anything, and the only approvals landed
      # on options that were then vetoed — get one sentence that is true of both.
      Enum.any?(tally, & &1.vetoed?) -> :vetoes_only
      true -> :no_votes
    end
  end

  defp leader_id(_survivors, 0), do: nil
  defp leader_id([%{activity: %Activity{id: id}} | _rest], _highest), do: id
  defp leader_id([], _highest), do: nil

  defp bar_percent(%{vetoed?: true}, _highest), do: 0
  defp bar_percent(%{approvals: approvals}, highest), do: round(approvals * 100 / max(1, highest))

  defp count_votes(group_id, kind) do
    from(v in Vote,
      join: a in Activity,
      on: a.id == v.activity_id,
      where: a.group_id == ^group_id and v.kind == ^kind,
      group_by: v.activity_id,
      select: {v.activity_id, count(v.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## cast_ballot/3 internals

  defp fetch_participant(id) do
    case Repo.get(Participant, id) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  defp fetch_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  defp ensure_not_voted(%Participant{voted_at: nil}), do: :ok
  defp ensure_not_voted(%Participant{}), do: {:error, :already_voted}

  defp ensure_group_open(%Group{status: :voting}), do: :ok
  defp ensure_group_open(%Group{}), do: {:error, :not_open}

  defp ensure_before_deadline(%Group{deadline_at: nil}), do: :ok

  defp ensure_before_deadline(%Group{deadline_at: deadline}) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :lt do
      :ok
    else
      {:error, :deadline_passed}
    end
  end

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case cast_id(id) do
        {:ok, int} -> {:cont, {:ok, [int | acc]}}
        :error -> {:halt, {:error, :unknown_activity}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp cast_veto_id(nil), do: {:ok, nil}
  defp cast_veto_id(""), do: {:ok, nil}

  defp cast_veto_id(id) do
    case cast_id(id) do
      {:ok, int} -> {:ok, int}
      :error -> {:error, :unknown_activity}
    end
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp cast_id(_id), do: :error

  defp ensure_not_empty([], nil), do: {:error, :empty_ballot}
  defp ensure_not_empty(_approved_ids, _veto_id), do: :ok

  defp ensure_veto_permitted(%Group{}, nil), do: :ok
  defp ensure_veto_permitted(%Group{veto_allowed: true}, _veto_id), do: :ok
  defp ensure_veto_permitted(%Group{}, _veto_id), do: {:error, :veto_not_allowed}

  defp ensure_no_veto_conflict(_approved_ids, nil), do: :ok

  defp ensure_no_veto_conflict(approved_ids, veto_id) do
    if veto_id in approved_ids, do: {:error, :veto_conflict}, else: :ok
  end

  defp ensure_all_in_group(_group, []), do: :ok

  defp ensure_all_in_group(%Group{id: group_id}, ids) do
    ids = Enum.uniq(ids)

    # The pool size is checked *first*, and it is not an optimisation. The query below
    # interpolates a client-supplied id list into `IN (?, ?, ...)`, one bind variable
    # per id; a ballot naming forty thousand ids blows SQLite's variable limit and
    # raises, which the `rescue` in `cast_ballot/3` would then report as
    # `{:error, {:database_busy, _}}` — telling a voter to try again later about input
    # that can never succeed. A ballot can never legitimately name more options than
    # the group has, so this bound is free and exact.
    pool_size = Repo.aggregate(from(a in Activity, where: a.group_id == ^group_id), :count)

    if length(ids) > pool_size do
      {:error, :unknown_activity}
    else
      found =
        Repo.aggregate(
          from(a in Activity, where: a.group_id == ^group_id and a.id in ^ids),
          :count
        )

      if found == length(ids), do: :ok, else: {:error, :unknown_activity}
    end
  end

  # The lock. A conditional UPDATE rather than a changeset on the struct we just read:
  # the re-read above produces the honest `{:error, :already_voted}` for the ordinary
  # case, and this makes the write itself safe even when two transactions read the same
  # unvoted row — exactly one of them can update it, and the loser rolls back.
  defp stamp_voted(%Participant{} = participant) do
    now = DateTime.utc_now(:second)

    {count, _} =
      from(p in Participant, where: p.id == ^participant.id and is_nil(p.voted_at))
      |> Repo.update_all(set: [voted_at: now, updated_at: now])

    case count do
      1 -> {:ok, %{participant | voted_at: now, updated_at: now}}
      0 -> {:error, :already_voted}
    end
  end

  # One `INSERT` for the whole ballot rather than one per mark: this runs with the
  # write lock held, and a round trip per approval is the difference between holding it
  # for one statement and holding it for five. `Vote.changeset/2` is bypassed
  # deliberately — it validates only `:kind`, which is set here from a literal, and the
  # unique index on `(participant_id, activity_id)` still backstops a duplicate.
  defp insert_votes(%Participant{} = participant, approved_ids, veto_id) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(approved_ids, &vote_entry(participant, &1, :approve, now)) ++
        Enum.map(List.wrap(veto_id), &vote_entry(participant, &1, :veto, now))

    {_count, _} = Repo.insert_all(Vote, entries)
    :ok
  end

  defp vote_entry(%Participant{id: participant_id}, activity_id, kind, now) do
    %{
      participant_id: participant_id,
      activity_id: activity_id,
      kind: kind,
      inserted_at: now,
      updated_at: now
    }
  end

  ## Participant attrs

  defp participant_attrs(attrs) do
    %{
      display_name: fetch_attr(attrs, :display_name),
      kind: fetch_attr(attrs, :kind) || :guest,
      user_id: fetch_attr(attrs, :user_id)
    }
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
