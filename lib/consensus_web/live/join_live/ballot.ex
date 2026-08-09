defmodule ConsensusWeb.JoinLive.Ballot do
  @moduledoc """
  The ballot — `/join/:slug/vote`. **One ballot, two views** (D-044).

  Approval voting only: "Tap all you'd be happy with · Pick as many as you like." There
  is no ranking anywhere in here — ranked-choice is explicitly Post-MVP
  (`docs/plans/voting-loop.md`).

  `ConsensusWeb.JoinAuth`'s `:resolve_participant` hook has already assigned `@group`
  (with `:activities` preloaded, in position order — see
  `Consensus.Activities.get_group_by_slug/1`) and `@participant` (`nil` when the
  visitor has not joined) before `mount/3` runs here, and it deliberately does **not**
  enforce the two guards this screen owns:

    * **No participant yet.** A visitor who lands on `/join/:slug/vote` without having
      gone through `06 entry` (`POST /join/:slug/enter`) first has no ballot to cast —
      sent back to `/join/:slug` to join.
    * **The ballot is locked (D-036).** `participant.voted_at` set means
      `Consensus.Voting.cast_ballot/3` will refuse with `{:error, :already_voted}` no
      matter what this screen renders, so re-entering this route once it is set
      redirects straight to results. This is a route-level fact checked in `mount/3`,
      not a `disabled` button — the same shape D-021's sudo-mode UI and D-037's frozen
      pool use elsewhere in this app.

  ## Two views of one ballot

  `@view` is `:grid` (the default — the sticker grid of frame
  `docs/design/screens/1c-1-sticker-grid-kept-in-play.html`) or `:deck` (the swipe deck
  of frame `1c-0`). The design section both frames come from is titled *"Option-picking —
  ranked list is the lead, the other two stay in play"*, and the deck is explicitly the
  alternative rather than the recommendation, so the grid stays default and the deck is
  opt-in.

  **The deck is a view, not a mode of the domain.** It changes nothing below this module:
  the same `@approved` / `@veto_id` assigns, the same single `Voting.cast_ballot/3` write,
  invariant 17 untouched. Switching views therefore cannot lose a selection, and the
  switch says so in as many words next to itself — a screen with two views of the same
  data has to tell the user which one they are in, how to get back, and that switching
  costs nothing (confusion #7 in `docs/plans/chrome-and-feedback.md`).

  ## The whole ballot lives in the URL

  `@view`, `@deck_index` and `@deck_changing?` are derived in `handle_params/3` from
  `?view=deck&card=N&changing=1`, **and so are `@approved`, `@veto_id` and `@deck_seen`,
  from `?picked=1,5&veto=7&seen=1,5,7`**. Every control that moves the voter around or
  changes a selection `push_patch`es rather than only assigning.

  That is not tidiness. Selections held only in socket assigns are destroyed by *any*
  remount, silently and with no signal — and a remount is not an edge case on a phone:

    * browser Back, which is the first thing a person reaches for on a card deck (and on
      Android is an edge swipe, on the one screen in this app that teaches horizontal
      swiping);
    * a LiveView **reconnect** — a screen lock, a tab switch, a cell handoff. Measured
      before this change: two picks and a spent veto became `0 PICKED · 1 VETO LEFT` after
      a 400ms disconnect, with no flash and no reload, and the voter walked the rest of the
      deck believing their earlier picks were in. D-036 then locks the short ballot they
      send;
    * a reload, a pull-to-refresh, a restored background tab, or opening the link twice.

  A URL survives all four for free, which is why it is the store rather than assigns plus a
  `sessionStorage` mirror: no client-side copy of what is picked, nothing to re-sync, and
  the grid keeps working with no hook of its own. `handle_params/3` **hydrates only when
  the assigns are absent** (i.e. on a real mount) — an ordinary patch inside a live session
  keeps what is already in the process, so stepping Back through the deck reverses the
  *movement* without reversing the decisions, which is what Back means everywhere else and
  what `Undo` is for.

  Selection changes patch with `replace: true`, so ten taps in the grid do not become ten
  history entries the voter has to walk back out of; deck decisions push, because they are
  movement as well as a decision.

  (`JoinLive.Entry`'s bounce is `replace: true` for the other half of the same bug — it used
  to append a history entry per visit, so Back could never leave the ballot at all.)

  The deck's own state is navigation only:

    * `@deck_index` — which card is face up; `>= length(activities)` means the end-of-deck
      summary. The `N / M` counter above the stack is the deck's answer to "how much more
      of this is there?" (confusion #6); the wizard answers it with `1/3`.
    * `@deck_seen` — the ids already decided, which is the only thing that separates
      "passed on it" from "hasn't looked at it yet". Neither approves, so the distinction
      exists for the summary's benefit, not the tally's.
    * `@deck_history` — a stack of whole-state snapshots, one per decision, so `Undo`
      restores the index *and* the selections. A swipe is fast and easy to do by accident
      and a mis-vetoed option is expensive (a voter gets exactly one), and the design
      draws no undo — this is an addition, "no way back" being confusion #4.
    * `@deck_changing?` — set when a card was re-opened from the summary's `Change`, so
      the next decision returns to the summary instead of walking the rest of the deck
      again. The card says so while the flag is set; a mode with no signal is confusion #7.

  Every gesture has a button doing exactly the same thing, sitting under the card where
  the frame draws it. The buttons are not a fallback: they are the only path for a
  keyboard, a screen reader, or a desktop browser, and the deck is fully usable if
  `assets/js/hooks.js` never loads. The grid, which is the default, uses no JavaScript of
  its own at all.

  ## Selection state is local until submit

  `@approved` (a `MapSet` of activity ids) and `@veto_id` (an integer or `nil` — at
  most one veto, per `Consensus.Voting.tally/1`'s rule, "everyone gets one veto") live
  only in this socket's assigns until "Send my votes" is pressed. Nothing is written
  to the database, and nothing is broadcast, until `cast_ballot/3` runs — a mis-tap
  costs nothing before submit, which is the only recovery this screen offers (D-036:
  there is no recovery *after* submit). Both views say that in a line above the button,
  because the moment to learn that a press is permanent is before it.

  Vetoing a card that was approved un-approves it, and vice versa — a card can never
  read as both at once (`ensure_no_veto_conflict/2` in `Consensus.Voting` would refuse
  it server-side regardless, but the UI never lets the client build that state to begin
  with). Vetoing a second card **moves** the single veto rather than refusing the click,
  in both views; the footer's "N VETOES LEFT" always reads 0 or 1, honestly.

  ## Deviations from the comps, and why

  See the inline notes below for each: the grid's dashed "Add your own" tile is omitted
  (ruling 5 — the pool is frozen once voting opens, so the control would always fail),
  the meta line under each name is the activity's description rather than the comps'
  fictitious `$$$ · 4.5★` / `Italian · 0.8 mi` (this schema carries no price, rating,
  cuisine or distance — Yelp/Places is Post-MVP), and the grid has an explicit veto
  control the comp only implies through its copy ("1 VETO LEFT") with no visible
  affordance for it (ruling 6).

  ## Why the top card carries no `phx-update="ignore"`

  The plan's hook checklist asks for it "where appropriate", and here it is not. The card
  holds three JS-owned attributes mid-drag (`style.transform`, `.is-dragging`,
  `data-swipe-dir` / `data-swipe-hint`) that a diff would strip — but it also holds a
  server-rendered state note ("You picked this.") that has to change when a card is
  re-opened through `Change` or `Undo`, and `phx-update="ignore"` freezes exactly that,
  because the card's `id` is stable while the voter is on it. The drag survives without it
  on a stated precondition: **this LiveView never initiates a render.** It has no
  `handle_info/2`, no `subscribe`, no `Process.send_after` and no `handle_async` — every
  render is the reply to an event the voter caused, so nothing can patch the card while a
  finger is down. If a server-initiated render is ever added here (a live deadline
  countdown, a PubSub tally), that precondition is gone and this has to be revisited.

  ## A tap on the deck's card

  Handled in the hook rather than by `phx-click`, and it means the same thing as a swipe
  right. It is a *pointer* affordance shadowing a pointer-only gesture — the card gets no
  `role` and no `tabindex`, because its accessible peer is the real `#deck-approve` button
  directly below it and a focusable card would put a second "Pick <name>" control in the
  tab order ahead of the one the design draws. The reason it exists at all: the grid one
  switch away makes the option card the tap target, so the largest object on the deck
  answering a tap with silence is the same unreadable affordance in reverse (confusion #1).
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities.Activity
  alias Consensus.Voting

  @impl true
  def mount(_params, _session, socket) do
    %{group: group, participant: participant} = socket.assigns

    cond do
      is_nil(participant) ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}")}

      not is_nil(participant.voted_at) ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}/results")}

      true ->
        # Deliberately does NOT assign `:approved` / `:veto_id` / `:deck_seen`. Their
        # absence is exactly the signal `handle_params/3` uses to tell "this is a mount —
        # hydrate the ballot out of the URL" from "this is a patch inside a live session —
        # keep what the process already holds".
        {:ok,
         socket
         |> assign(:page_title, "Vote · #{group.title}")
         |> assign(:ballot_open?, true)
         |> assign(:deck_history, [])
         |> assign(:veto_note, nil)}
    end
  end

  # `@view`, `@deck_index` and `@deck_changing?` come from the URL on every call. The three
  # selection assigns come from it **only on a mount** — see the moduledoc: a mount is a
  # reconnect, a reload, a restored tab or a Back onto an entry this process did not create,
  # and each of those used to hand the voter an empty ballot with no signal at all. Within a
  # live session the process keeps its own state, so Back reverses movement and not votes.
  #
  # Clamped rather than trusted: `?card=-3`, `?card=999` or `?picked=nope,4` on a hand-typed
  # URL resolve to a real position and to ids that are actually in this pool.
  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:ballot_open?] do
      count = card_count(socket.assigns.group)
      index = clamp_index(params["card"], count)

      {:noreply,
       socket
       |> hydrate_selections(params)
       |> assign(:view, if(params["view"] == "deck", do: :deck, else: :grid))
       |> assign(:deck_index, index)
       |> assign(:deck_changing?, params["changing"] == "1" and index < count)}
    else
      # `mount/3` already redirected (no participant, or the ballot is locked). LiveView
      # skips `handle_params/3` in that case today; this clause is here so a change to
      # that ordering surfaces as a redirect rather than a KeyError on `@group`.
      {:noreply, socket}
    end
  end

  defp clamp_index(nil, _count), do: 0

  defp clamp_index(raw, count) do
    case Integer.parse(to_string(raw)) do
      {index, ""} when index >= 0 -> min(index, count)
      _not_a_position -> 0
    end
  end

  ## The ballot ⇄ the query string

  defp hydrate_selections(socket, params) do
    if Map.has_key?(socket.assigns, :approved) do
      socket
    else
      known = MapSet.new(socket.assigns.group.activities, & &1.id)
      veto_id = params["veto"] |> id_set(known) |> Enum.at(0)
      approved = params["picked"] |> id_set(known) |> MapSet.delete(veto_id)

      seen =
        params["seen"]
        |> id_set(known)
        |> MapSet.union(approved)
        |> then(&if(veto_id, do: MapSet.put(&1, veto_id), else: &1))

      socket
      |> assign(:approved, approved)
      |> assign(:veto_id, veto_id)
      |> assign(:deck_seen, seen)
    end
  end

  defp id_set(nil, _known), do: MapSet.new()

  defp id_set(raw, known) do
    raw
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(part) do
        {id, ""} -> [id]
        _not_an_id -> []
      end
    end)
    |> Enum.filter(&MapSet.member?(known, &1))
    |> MapSet.new()
  end

  # The inverse: what every `push_patch` has to carry so the next mount can rebuild the
  # ballot. Omitted entirely when empty, so an untouched ballot keeps a clean URL.
  defp state_params(assigns) do
    []
    |> put_id_list(:picked, assigns.approved)
    |> put_id_list(:seen, assigns.deck_seen)
    |> then(&if(assigns.veto_id, do: [{:veto, assigns.veto_id} | &1], else: &1))
  end

  defp put_id_list(params, key, set) do
    if MapSet.size(set) == 0 do
      params
    else
      [{key, set |> Enum.sort() |> Enum.join(",")} | params]
    end
  end

  ## Events — the grid

  @impl true
  def handle_event("toggle_approve", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        socket =
          if id == socket.assigns.veto_id do
            # The approve button is `disabled` for a vetoed card, but a disabled attribute
            # is a client-side hint, not enforcement (D-021's own reasoning) — ignore a
            # pushed event for a vetoed card rather than letting it slip past the UI's
            # own "never both" rule.
            socket
          else
            socket
            |> toggle_set(:approved, id)
            |> assign(:veto_note, nil)
            |> mark_seen(id)
            |> repatch()
          end

        {:noreply, socket}

      _not_an_integer ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_veto", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        current_veto = socket.assigns.veto_id

        {new_veto_id, approved} =
          if current_veto == id do
            {nil, socket.assigns.approved}
          else
            # Moves the single veto rather than refusing the click — "everyone gets one
            # veto" (Consensus.Voting), and moving it is friendlier than making the voter
            # un-veto the old card before they can veto a different one. Un-approves the
            # newly-vetoed card so the two states can never coexist.
            {id, MapSet.delete(socket.assigns.approved, id)}
          end

        {:noreply,
         socket
         |> assign(:veto_id, new_veto_id)
         |> assign(:approved, approved)
         # The grid used to move the veto in total silence: the previous holder simply
         # stopped being struck through, four buttons still read `VETO`, and the counter
         # read `0 VETOES LEFT`. The deck has always said it in a line; both do now.
         |> assign(
           :veto_note,
           veto_note("veto", current_veto, id, socket.assigns.group.activities)
         )
         # **The card the veto came *off* stops counting as decided.** `mark_seen/2` used
         # to run unconditionally on both halves of this event, and `decision_for/4` maps
         # "in `seen`, neither approved nor vetoed" to `:passed` — so vetoing Taco Palace
         # and then pressing MOVE VETO on Sushi Room left Taco Palace's deck card saying
         # "You passed on this." and its summary row reading `PASSED`, in the first person,
         # on the last screen before an irreversible send. The voter never passed it. Same
         # for the plain un-veto: taking a veto back is a retraction, not a decision.
         #
         # Unmarking rather than adding a fourth `:veto_released` decision is the smaller
         # true statement: the card genuinely is undecided again, `Keep going` should offer
         # it, and the neighbouring "NOT LOOKED AT — COUNTS AS A PASS" row already says
         # exactly what an undecided option is worth. Approval is unreachable here — this
         # handler deletes the id from `approved` before it can veto it — so nothing else
         # rides on the flag.
         |> unmark_seen(current_veto)
         |> then(&if(new_veto_id, do: mark_seen(&1, new_veto_id), else: &1))
         |> repatch()}

      _not_an_integer ->
        {:noreply, socket}
    end
  end

  ## Events — switching views

  # Only the view changes. The selections and the deck's position ride along in the URL
  # unchanged, which is what makes "switching costs you nothing" a true sentence rather
  # than a reassuring one — and the position half is not decoration: dropping it restarted
  # the deck at card 1 on every round trip. The switch is a `push_patch`, so it is also a
  # history entry: Back out of the deck returns to the grid with the same picks.
  def handle_event("set_view", %{"view" => "deck"}, socket) do
    {:noreply, patch(socket, :deck, socket.assigns.deck_index, socket.assigns.deck_changing?)}
  end

  def handle_event("set_view", %{"view" => "grid"}, socket) do
    {:noreply, patch(socket, :grid, socket.assigns.deck_index, socket.assigns.deck_changing?)}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  ## Events — the deck

  # The pushed id must be the card that is actually face up. A swipe released as the
  # server re-renders, a double-tap on a button, or a hand-rolled event all arrive here;
  # without the check the second one would decide the *next* card the voter has not seen.
  def handle_event("deck_decide", %{"decision" => decision, "id" => raw_id}, socket)
      when decision in ["approve", "pass", "veto"] do
    %{group: group, deck_index: index} = socket.assigns

    with {id, ""} <- Integer.parse(to_string(raw_id)),
         %Activity{id: ^id} <- current_card(group, index) do
      {:noreply, decide(socket, decision, id)}
    else
      _stale_or_invalid -> {:noreply, socket}
    end
  end

  def handle_event("deck_decide", _params, socket), do: {:noreply, socket}

  # `Undo` reverses the last **decision**, and it now says which one on the control itself
  # — a bare "Undo" next to "Keep going" read as navigation, and the two are one tap apart.
  #
  # Pressed from the summary it restores the selections and *stays on the summary*, so the
  # voter watches the row they were reading change from `Picked` back to `Not looked at`.
  # It used to throw them into the deck and take the submit button off the screen with it:
  # the last thing they did was press "Review picks", so the visible effect was the
  # navigation being undone while the vote quietly went with it.
  def handle_event("deck_undo", _params, socket) do
    %{deck_history: history, deck_index: index, group: group} = socket.assigns
    count = card_count(group)
    at_summary? = index >= count

    case history do
      [] ->
        {:noreply, socket}

      [snapshot | rest] ->
        {index, changing?} =
          if at_summary?, do: {count, false}, else: {snapshot.index, snapshot.changing?}

        {:noreply,
         socket
         |> assign(:approved, snapshot.approved)
         |> assign(:veto_id, snapshot.veto_id)
         |> assign(:deck_seen, snapshot.seen)
         |> assign(:deck_history, rest)
         |> assign(:veto_note, nil)
         |> patch(:deck, index, changing?)}
    end
  end

  # Moving around the deck. None of these changes a selection, so none is undoable and none
  # pushes a snapshot — `Undo` reverses decisions, not movement. Every one of them is a
  # `push_patch`, so Back reverses the movement instead, which is what a browser's Back
  # button means everywhere else.
  #
  # "Review picks" jumps to the end-of-deck summary from wherever the voter is.
  def handle_event("deck_review", _params, socket) do
    {:noreply, patch(socket, :deck, card_count(socket.assigns.group), false)}
  end

  # "Change" on a summary row: re-open one card and come straight back here after it is
  # decided, rather than making the voter walk the rest of the deck a second time.
  def handle_event("deck_change", %{"index" => raw_index}, socket) do
    goto(socket, raw_index, true)
  end

  # "Keep going" on the summary: resume the walk at the first card not looked at yet, so
  # deciding it advances to the next one as usual.
  def handle_event("deck_resume", %{"index" => raw_index}, socket) do
    goto(socket, raw_index, false)
  end

  # The way out of a `Change` that was opened by mistake. While `@deck_changing?` is set,
  # this replaces `Undo` in the row — because pressing "Undo" there reversed an unrelated
  # decision from three actions ago, cancelled the change *and* jumped to a different card,
  # which is not what a control offered one tap after "Change" can plausibly mean.
  def handle_event("deck_cancel_change", _params, socket) do
    {:noreply,
     socket
     |> assign(:veto_note, nil)
     |> patch(:deck, card_count(socket.assigns.group), false)}
  end

  ## Events — the write

  def handle_event("submit_ballot", _params, socket) do
    %{participant: participant, group: group, approved: approved, veto_id: veto_id} =
      socket.assigns

    case Voting.cast_ballot(participant, MapSet.to_list(approved), veto_id) do
      {:ok, _voted_participant} ->
        {:noreply, push_navigate(socket, to: ~p"/join/#{group.slug}/results")}

      {:error, reason} ->
        {:noreply, handle_cast_error(socket, group, reason)}
    end
  end

  defp goto(socket, raw_index, changing?) do
    count = card_count(socket.assigns.group)

    case Integer.parse(to_string(raw_index)) do
      {index, ""} when index >= 0 and index < count ->
        {:noreply, socket |> assign(:veto_note, nil) |> patch(:deck, index, changing?)}

      _out_of_range ->
        {:noreply, socket}
    end
  end

  # The one place `@view` / `@deck_index` / `@deck_changing?` and the three selection
  # assigns reach the URL. `@view` is written out explicitly — `view=grid` rather than the
  # bare route — so that every history entry the ballot creates is one this live session
  # created, and a Back onto it patches instead of remounting.
  #
  # The grid keeps `card` too. Dropping it meant `Grid → Swipe` re-derived `deck_index`
  # from a missing param and restarted the deck at card 1; from the end-of-deck summary
  # that also took `#submit-ballot` off the screen and re-showed every card as already
  # decided.
  #
  # `~p` sorts query params when it encodes them, so the order given here is for reading
  # only. `opts` carries `replace: true` for a change that is not movement.
  defp patch(socket, view, index, changing?, opts \\ []) do
    params =
      [view: to_string(view), card: index] ++
        if(changing?, do: [changing: "1"], else: []) ++
        state_params(socket.assigns)

    push_patch(
      socket,
      Keyword.merge([to: ~p"/join/#{socket.assigns.group.slug}/vote?#{params}"], opts)
    )
  end

  # A selection changed but the voter did not move. Same URL shape, `replace: true`, so
  # tapping ten options in the grid leaves one history entry rather than ten.
  defp repatch(socket) do
    %{view: view, deck_index: index, deck_changing?: changing?} = socket.assigns
    patch(socket, view, index, changing?, replace: true)
  end

  # A card the voter has answered in *either* view. Without the grid writing here, a voter
  # who worked entirely in the grid and then opened the deck's summary was told every row
  # was "Not looked at" — a claim about their behaviour that was simply false.
  defp mark_seen(socket, id) do
    assign(socket, :deck_seen, MapSet.put(socket.assigns.deck_seen, id))
  end

  # `nil` is the ordinary case — `toggle_veto` calls this with whatever held the veto
  # before, which is usually nothing.
  defp unmark_seen(socket, nil), do: socket

  defp unmark_seen(socket, id) do
    assign(socket, :deck_seen, MapSet.delete(socket.assigns.deck_seen, id))
  end

  defp toggle_set(socket, key, id) do
    set = Map.fetch!(socket.assigns, key)
    updated = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
    assign(socket, key, updated)
  end

  # One decision on the face-up card: record where we were so `Undo` can come back, apply
  # it to the same two assigns the grid writes, then move on.
  defp decide(socket, decision, id) do
    %{
      approved: approved,
      veto_id: veto_id,
      deck_index: index,
      deck_seen: seen,
      deck_changing?: changing?,
      group: group
    } = socket.assigns

    snapshot = %{
      approved: approved,
      veto_id: veto_id,
      index: index,
      seen: seen,
      changing?: changing?
    }

    # Pressing the veto on the card that already holds it **releases** it, exactly as the
    # grid's toggle does, and stays on the card. The control's own label has always read
    # "Remove veto on <name>" in that state; before this it re-applied the same veto and
    # advanced, so the one control that promised to give a voter their veto back was the
    # one control that could not.
    release_veto? = decision == "veto" and veto_id == id

    {approved, veto_id} =
      case decision do
        # Approving or passing on a card that currently holds the veto also releases the
        # veto — a decision on a card replaces whatever the last one was, and the "never
        # both at once" rule the grid enforces has to hold here too.
        "approve" -> {MapSet.put(approved, id), if(veto_id == id, do: nil, else: veto_id)}
        "pass" -> {MapSet.delete(approved, id), if(veto_id == id, do: nil, else: veto_id)}
        "veto" when release_veto? -> {approved, nil}
        "veto" -> {MapSet.delete(approved, id), id}
      end

    next_index =
      cond do
        # Releasing a veto is a toggle, not an answer to "do you want this?" — advancing
        # would slide the card away before the voter has seen that it worked.
        release_veto? -> index
        changing? -> card_count(group)
        true -> min(index + 1, card_count(group))
      end

    socket
    |> assign(:approved, approved)
    |> assign(:veto_id, veto_id)
    |> assign(:deck_seen, MapSet.put(seen, id))
    |> assign(:veto_note, veto_note(decision, snapshot.veto_id, id, group.activities))
    |> assign(:deck_history, [snapshot | socket.assigns.deck_history])
    |> patch(:deck, next_index, release_veto? and changing?)
  end

  # A voter gets one veto and moving it takes it off whatever held it before. The only
  # signal at the moment that happens was a 9px mono caption reading `MOVE VETO`, which is
  # gone from the screen the instant the card advances — so the previous holder quietly
  # became an ordinary pass. This says so in a line, on the next card and at the top of the
  # summary, and it is cleared by the next decision or any movement.
  defp veto_note("veto", previous_veto_id, id, activities)
       when is_integer(previous_veto_id) and previous_veto_id != id do
    previous = Enum.find(activities, &(&1.id == previous_veto_id))
    current = Enum.find(activities, &(&1.id == id))

    if previous && current do
      "Your veto moved from #{previous.name} to #{current.name} — you only get one."
    end
  end

  # The *release* case, and it needs a note for the same reason the move does. `decide/3`
  # drops the veto whenever the card holding it is approved or passed — a decision replaces
  # whatever the last one was — and that came with no signal at all: the card slid away, the
  # summary row silently read `PASSED`, and the only trace was the counter going from
  # `0 VETOES LEFT` back to `1 VETO LEFT`, which on a 5-option pool at 360×640 sat below the
  # fold. Pressing veto on the card that holds it is excluded: that path stays on the card,
  # whose own control flips to `VETO` and whose status note clears in front of the voter.
  defp veto_note(decision, previous_veto_id, id, activities)
       when decision in ["approve", "pass"] and is_integer(previous_veto_id) and
              previous_veto_id == id do
    case Enum.find(activities, &(&1.id == id)) do
      nil -> nil
      current -> "Your veto came off #{current.name} — you have it back."
    end
  end

  defp veto_note(_decision, _previous_veto_id, _id, _activities), do: nil

  # Every refusal `Consensus.Voting.cast_ballot/3` documents, handled explicitly —
  # CLAUDE.md invariant 4: a voter must never see this escape as a crash. The first
  # three are "the vote is over, one way or another" and send the voter on to results;
  # the rest are "fix this and try again", so they stay on the ballot with a flash.
  defp handle_cast_error(socket, group, :already_voted) do
    socket
    |> put_flash(:info, "Your vote is already in.")
    |> push_navigate(to: ~p"/join/#{group.slug}/results")
  end

  defp handle_cast_error(socket, group, reason) when reason in [:not_open, :deadline_passed] do
    socket
    |> put_flash(:info, "Voting has closed.")
    |> push_navigate(to: ~p"/join/#{group.slug}/results")
  end

  defp handle_cast_error(socket, group, :not_found) do
    socket
    |> put_flash(:error, "We lost track of you — join again to vote.")
    |> push_navigate(to: ~p"/join/#{group.slug}")
  end

  defp handle_cast_error(socket, _group, :empty_ballot) do
    put_flash(socket, :error, "Pick at least one, or veto one, before sending.")
  end

  defp handle_cast_error(socket, _group, :veto_conflict) do
    put_flash(socket, :error, "That option can't be both approved and vetoed.")
  end

  # Not "something in the pool changed": the pool *cannot* change once voting opens
  # (CLAUDE.md invariant 16 / D-037 — add, update, delete and reorder all return
  # `{:error, :pool_locked}` for any non-`:draft` group), so that sentence sent a voter
  # looking for a change the app forbids. What this tuple actually means is that an id in
  # the submitted ballot is not one of this group's activities, which from the voter's side
  # is a stale page. Say the observable thing and the remedy.
  defp handle_cast_error(socket, _group, :unknown_activity) do
    put_flash(
      socket,
      :error,
      "We didn't recognise one of those options — reload this page and send again."
    )
  end

  defp handle_cast_error(socket, _group, :veto_not_allowed) do
    put_flash(socket, :error, "Vetoes aren't allowed in this session.")
  end

  defp handle_cast_error(socket, _group, {:database_busy, _message}) do
    put_flash(socket, :error, "Lots of people are voting right now — try again in a second.")
  end

  defp handle_cast_error(socket, _group, _other) do
    put_flash(socket, :error, "Something went wrong — try again.")
  end

  ## View helpers

  defp approved?(id, approved), do: MapSet.member?(approved, id)
  defp vetoed?(id, veto_id), do: veto_id == id

  defp submit_disabled?(approved, veto_id),
    do: MapSet.size(approved) == 0 and is_nil(veto_id)

  defp summary_heading(approved, veto_id) do
    cond do
      MapSet.size(approved) > 0 -> "Your picks"
      is_nil(veto_id) -> "Nothing picked yet"
      true -> "Nothing picked, one vetoed"
    end
  end

  defp card_count(group), do: length(group.activities)
  defp current_card(group, index), do: Enum.at(group.activities, index)

  # Which states ask `Layouts.app` to bound the column — the two that put a list above the
  # submit button. `is_nil(current_card/2)` is exactly the condition `deck_view/1` branches
  # its summary on, so this cannot drift out of step with which markup is rendered.
  defp fill_viewport?(:grid, _group, _deck_index), do: true
  defp fill_viewport?(:deck, group, deck_index), do: is_nil(current_card(group, deck_index))

  defp decision_for(id, approved, veto_id, seen) do
    cond do
      veto_id == id -> :vetoed
      MapSet.member?(approved, id) -> :approved
      MapSet.member?(seen, id) -> :passed
      true -> :undecided
    end
  end

  defp decision_label(:approved), do: "Picked"
  defp decision_label(:vetoed), do: "Vetoed"
  defp decision_label(:passed), do: "Passed"
  defp decision_label(:undecided), do: "Not looked at — counts as a pass"

  # What the face-up card says about itself when the voter has already decided it once
  # (they came back through Undo or Change). Without it, a re-opened card looks identical
  # to a fresh one and the controls give no clue which of them is already true.
  defp card_state_note(:approved), do: "You picked this."
  defp card_state_note(:vetoed), do: "You vetoed this."
  defp card_state_note(:passed), do: "You passed on this."
  defp card_state_note(:undecided), do: nil

  defp first_undecided_index(activities, seen) do
    Enum.find_index(activities, &(not MapSet.member?(seen, &1.id)))
  end

  # What `Sticker.deck_stack/1`'s `behind` actually means: cards after this one that have
  # not been decided. It used to be passed `count - index - 1`, a purely positional number,
  # which agreed with the documented meaning only on a straight forward walk — pressing
  # `Change` on the first summary row with everything decided drew two ghost cards behind a
  # card with nothing undecided after it.
  defp undecided_after(activities, index, seen) do
    activities
    |> Enum.drop(index + 1)
    |> Enum.count(&(not MapSet.member?(seen, &1.id)))
  end

  # The card whose answer `Undo` will put back — the control names it, because "Undo" alone
  # sitting beside "Keep going" reads as navigation and its real cost is a vote.
  defp undo_target([%{index: index} | _rest], activities), do: Enum.at(activities, index)
  defp undo_target([], _activities), do: nil

  # The comps' meta lines read "$$$ · 4.5★" and "Italian · $$$ · 4.5 ★ · 0.8 mi" — price,
  # rating, cuisine and distance this schema has no field for (Yelp/Places is Post-MVP,
  # CLAUDE.md scope discipline). The description an organizer typed or a link preview
  # filled in is the closest real data to that slot; `activity_fixture/2`-created options
  # and a typed-with-no-description option both fall back to plain text rather than an
  # empty line.
  defp meta_line(%Activity{description: description})
       when is_binary(description) and description != "" do
    description
  end

  defp meta_line(%Activity{}), do: "No details yet"

  defp ballot_status_text(approved, veto_id, veto_allowed?) do
    picked_text = "#{MapSet.size(approved)} PICKED"

    if veto_allowed? do
      veto_left = if veto_id, do: 0, else: 1
      veto_word = if veto_left == 1, do: "VETO", else: "VETOES"
      "#{picked_text} · #{veto_left} #{veto_word} LEFT"
    else
      picked_text
    end
  end

  # The veto is one control with three jobs, so its glyph reports the state ("1×" you still
  # have it, absent once you have spent it) and its caption reports what pressing it will do.
  # Spending it elsewhere does not disable it — a second veto MOVEs the veto — and the two
  # views **behave** identically: on the card that holds the veto, pressing it releases the
  # veto in both.
  #
  # The captions differ, and only because the two views have a different number of controls.
  # The deck has exactly one veto button, so it can afford to say `MOVE VETO` — there is one
  # of it and it is describing the next press. The grid has one per option, so the same
  # three-state caption printed `MOVE VETO` down every remaining card in the pool (nine of
  # them at ten options), which reads as nine vetoes rather than one being relocated. There
  # the state lives in the counter (`0 VETOES LEFT`), where it is said once.
  defp deck_veto_caption(veto_id, id) do
    cond do
      veto_id == id -> "VETOED"
      is_nil(veto_id) -> "VETO"
      true -> "MOVE VETO"
    end
  end

  defp grid_veto_caption(veto_id, id) do
    cond do
      veto_id == id -> "VETOED"
      is_nil(veto_id) -> "VETO"
      # Not "VETO". With the veto spent, four buttons reading `VETO` sat under a counter
      # reading `0 VETOES LEFT` — two things on one screen disagreeing about the same
      # fact. `MOVE VETO` is what the press does; the "reads as nine vetoes" objection was
      # against the `1×` glyph beside it, which is gone.
      true -> "MOVE VETO"
    end
  end

  defp deck_veto_glyph(veto_id), do: if(is_nil(veto_id), do: "1×", else: "0×")

  # Cycles the missing-photo stripe down the pool, keyed on the id so it survives a
  # re-render. **Three**, matching the three pastel pairs frame `1c-1` actually draws
  # (IMPORT-NOTES §8): the fourth was `stripes-violet`, which this cycle invented, and it
  # is also the only one of the five whose default pitch is 12px rather than 9 — so the
  # invented member was the coarsest, and Kismet's violet bands read as twice the width of
  # Guisados' blue on two cards a few pixels apart. The grid additionally sets
  # `stripe-pitch-6` at the call site, which is the pitch the frame draws at this 38px size
  # and the pitch `.stripes-ink` (the selected state) was already hard-coded to.
  defp thumb_stripe(id) do
    Enum.at(["stripes-peach", "stripes-yellow", "stripes-blue"], Integer.mod(id, 3))
  end

  defp deck_veto_label(%Activity{name: name}, veto_id, id, activities) do
    cond do
      veto_id == id ->
        "Remove veto on #{name}"

      is_nil(veto_id) ->
        "Veto #{name} — this is your only veto"

      true ->
        held_by = Enum.find(activities, &(&1.id == veto_id))
        "Move your veto from #{held_by && held_by.name} to #{name}"
    end
  end

  # The header's `Create your own →` pill is a `navigate` to `/`, and it is the highest-
  # contrast control on this screen while "Send my votes" is a disabled peach. Selections
  # live only in `@approved`/`@veto_id` until `Voting.cast_ballot/3` runs, and a guest has
  # no account and no route back except the original share link in someone's chat app — so
  # once there is something to lose, the pill asks first. `nil` until then: an empty ballot
  # costs nothing and a confirm on it would be noise (confusion class 1, an affordance that
  # behaves unpredictably). See `ConsensusWeb.Chrome`'s moduledoc and plan ruling 8.
  defp leave_confirm(approved, veto_id) do
    if submit_disabled?(approved, veto_id) do
      nil
    else
      "Leave without sending? Your picks aren't saved yet, and this link is the only way back."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `:public`, and no `back`: the entry screen bounces a joined participant
          straight here, so a back control would be a redirect loop. `min-h-dvh` became
          `flex-1` for the reason `JoinLive.Entry` records. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      variant={:public}
      pill_confirm={leave_confirm(@approved, @veto_id)}
      fill_viewport={fill_viewport?(@view, @group, @deck_index)}
    >
      <%!-- `fill_viewport` belongs to the two states that hold a *list* under the submit
            button: the grid, and the deck's end-of-deck summary. Frame `1c-1` is a 600px
            device with `overflow:hidden` whose *pool* is the scroll track
            (`flex:1;min-height:0;overflow-y:auto`) and whose `Send my votes` is pinned
            below it — measured in the frame: `scrollHeight 402 > clientHeight 300`, button
            permanently at y=436. The app shipped the same markup without a bounded
            ancestor, so the page scrolled instead: at 360×640 on a five-option pool
            `#submit-ballot` sat 212px below the fold with `#ballot-status` below it too,
            and the first screenful ended mid-pool with nothing indicating either existed.

            The summary was left on the page scroller in the first pass, on the grounds
            that "a growing list a fixed-height column would clip" — but a list that grows
            past the viewport is precisely the case a scroll *track* is for, and leaving it
            out reproduced the same defect on the deck's only route to Send: at 360×640 on
            the same five-option pool `#submit-ballot` sat entirely off-screen at 695–755,
            with `#ballot-status` below the fold too. The list is now the track and the
            submit block is its `shrink-0` sibling, exactly as in the grid.

            The deck's *card* state keeps the page scroller. It has no list — one card plus
            a control row — and its stack is already a `flex-1` box with its own floor. --%>
      <div class="flex min-h-0 flex-1 flex-col">
        <%!-- Arms the browser's own "leave site?" prompt while there is an unsent ballot.
              `leave_confirm/2` already computes "there is something to lose" for the
              header pill; a reload could throw away the same thing with no warning at all,
              and the deck makes that worse by turning the ballot into a long sequential
              walk a stray pull-to-refresh erases. `beforeunload` does not fire on
              LiveView's own pushState, so submitting is unaffected. --%>
        <div
          id="ballot-unsaved-guard"
          phx-hook="UnsavedBallot"
          data-unsaved={to_string(not is_nil(leave_confirm(@approved, @veto_id)))}
          class="hidden"
        />

        <.view_switch view={@view} />

        <.grid_view
          :if={@view == :grid}
          group={@group}
          approved={@approved}
          veto_id={@veto_id}
          veto_note={@veto_note}
        />

        <.deck_view
          :if={@view == :deck}
          group={@group}
          approved={@approved}
          veto_id={@veto_id}
          deck_index={@deck_index}
          deck_seen={@deck_seen}
          deck_history={@deck_history}
          deck_changing?={@deck_changing?}
          veto_note={@veto_note}
        />
      </div>
    </Layouts.app>
    """
  end

  ## -- the two views ------------------------------------------------------------------

  attr :view, :atom, required: true

  defp view_switch(assigns) do
    ~H"""
    <%!-- **One line, not a two-line header over a self-labelling control.** The `VIEW`
          eyebrow stacked over "Your picks stay when you switch." introduced a toggle whose
          own two buttons already say `Grid` and `Swipe`. The eyebrow was the half carrying
          no information; the reassurance is the half a voter needs before touching a
          control that looks like it might reset something, so that is the one that stays.
          `items-center` because one line beside a pill centres rather than hangs.

          **It buys no height, and that is worth knowing before someone tries again.** This
          block measures 66px before and after: 54px of it is the toggle (two 44px buttons
          — the touch floor — inside `p-[3px]` and a 2px border) and 12px is `pt-3`, and the
          text column was never what set the height. The track's share of a 360×640 viewport
          is 31.9% against frame `1c-1`'s 50.3% (`docs/open-questions.md` F-8), and closing
          that gap means giving up either the toggle's touch target or the status region
          below the track, not tightening the copy. --%>
    <div class="flex shrink-0 items-center justify-between gap-3 px-4 pt-3">
      <p class="min-w-0 text-[10.5px] text-muted">Your picks stay when you switch.</p>
      <div
        role="group"
        aria-label="Choose how to pick"
        class="inline-flex shrink-0 items-center rounded-full border-2 border-ink bg-white p-[3px] shadow-sticker-2"
      >
        <button
          :for={{value, label} <- [{"grid", "Grid"}, {"deck", "Swipe"}]}
          type="button"
          id={"view-#{value}"}
          phx-click="set_view"
          phx-value-view={value}
          aria-pressed={to_string(to_string(@view) == value)}
          class={
            [
              "inline-flex min-h-11 items-center rounded-full px-3.5 text-[12px] transition-colors",
              # `active:` as well as `hover:`. `:hover` does not exist on touch, so on a
              # phone the only control that moves a voter between the two views — the one
              # the line beside it advertises — gave no feedback at all until the server
              # round-trip landed and the pill flipped.
              if(to_string(@view) == value,
                do: "bg-ink font-bold text-white active:bg-ink-soft",
                else: "font-semibold text-ink hover:bg-yellow-tint active:bg-yellow-tint"
              )
            ]
          }
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :approved, :any, required: true
  attr :veto_id, :any, required: true
  attr :veto_note, :string, default: nil

  defp grid_view(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <div class="shrink-0 px-4 pb-1.5 pt-2">
        <h1 class="text-[18px] font-bold leading-[1.1] tracking-[-0.025em] text-ink">
          Tap all you'd be happy with
        </h1>
        <%!-- The veto sentence is the only place the grid explains what the veto does — the
              word appeared on this screen exactly twice before it, inside an `aria-label` no
              sighted reader can obtain and in the counter's "1 VETO LEFT", which names a
              budget for a mechanism it never describes. The deck has always carried its
              explanation in the control itself.

              It is **dropped once the veto has been spent**, and that is height, not tidiness.
              At 360×640 on a five-option pool the block above the pool measured 192px against
              a 198px pool — the introduction taller than the thing it introduces, on the
              screen where the pool is the whole point. A voter holding a live veto still gets
              the full sentence; one who has already used it is being told how to do the thing
              they have done, and `#veto-note` plus the card's own `VETOED` label carry the
              state from there. --%>
        <%!-- Tightened, not cut. "You also get one veto" became "One veto each" because
              the sentence was the obvious place to look for the track's missing height
              (F-8) — it still wraps to two lines at 360px, so it bought nothing, and the
              clause it would have to lose is the one thing that earns its place: the
              counter's "1 VETO LEFT" names a budget without ever describing the mechanism,
              and this is still the only place in the grid that says what a veto *does*. --%>
        <p :if={@group.veto_allowed and is_nil(@veto_id)} class="mt-1 text-[11.5px] text-ink-soft">
          Pick as many as you like. One <strong class="font-semibold">veto</strong>
          each — it drops an option for everyone.
        </p>
        <p
          :if={!@group.veto_allowed or not is_nil(@veto_id)}
          class="mt-1 text-[11.5px] text-ink-soft"
        >
          Pick as many as you like.
        </p>
        <%!-- The same line the deck shows when a veto is relocated. Moving it in the grid
              used to be silent: the previous holder just stopped being struck through,
              somewhere else in a two-column list the voter was not looking at. --%>
        <p :if={@veto_note} class="mt-1 text-[11.5px] font-semibold text-ink" id="veto-note">
          {@veto_note}
        </p>
      </div>

      <%!-- The scroll track, and the whole reason this view asks `Layouts.app` for
            `fill_viewport`. `min-h-0` is what lets a flex item shrink below its content —
            without it `overflow-y-auto` has nothing to overflow *into* and the class is
            inert. Frame `1c-1` draws exactly this: `flex:1;min-height:0;overflow-y:auto`
            on the pool, with the status line and the button outside it.

            `min-h-[200px]` does the `min-h-0` job *and* puts a floor under it — a flex
            item's default `min-height: auto` is what makes `overflow-y-auto` inert, and
            any explicit value clears it. A floor rather than `0` because every sibling of
            this track is `shrink-0`: on a viewport too short for the chrome the flex
            algorithm has only this box left to take space from, and it drove the pool to
            16px with the overflow painting on top of the footer. The floor and
            `.viewport-column`'s 640px height gate are one fix in two places — the gate
            keeps the clamp off where the floor could not be honoured, the floor keeps the
            track legible everywhere the clamp is on. Do not "simplify" it back to
            `min-h-0`. --%>
      <div class="grid min-h-[200px] flex-1 grid-cols-2 content-start gap-2.5 overflow-y-auto px-4 py-2">
        <%!-- `min-w-0` is load-bearing: a grid item defaults to `min-width: auto`, which lets a
        long description force the column wider than its track instead of being clipped, so
        the meta line spilled past the card's own border. Same trap D-024 records for flex. --%>
        <%!-- The veto used to be a 24px glyph-only circle absolutely positioned at
              `left-2 top-2` — i.e. *inside* the approve button's own rect, 8px from the
              corner a thumb is most likely to clip, at 2.9% of its area, with no text
              anywhere and no confirmation. Two overlapping targets whose meanings are
              opposite: approve is one vote for you, veto removes the option for the whole
              group. WCAG 2.5.8's spacing exception cannot rescue overlapping targets, and
              this is a guest's single, locked (D-036) submission.

              It is now a sibling of the card rather than a child, so the two rects are
              disjoint, and it is labelled with the same three-state caption the deck view
              already uses (`deck_veto_caption/2`) so switching views is not lossy.

              No `data-confirm` on it. The veto is a toggle — pressing it again clears it, the
              button reads VETOED while it is held, and nothing is written until "Send my
              votes" — so a confirm dialog would be friction on the path PRD product
              invariant 1 says must have none. What made a mis-tap dangerous was the overlap,
              and the overlap is what changed. --%>
        <div
          :for={activity <- @group.activities}
          class="flex min-w-0 flex-col gap-1.5"
          id={"activity-#{activity.id}"}
        >
          <button
            type="button"
            phx-click="toggle_approve"
            phx-value-id={activity.id}
            disabled={vetoed?(activity.id, @veto_id)}
            aria-pressed={to_string(approved?(activity.id, @approved))}
            class={
              [
                # `flex-1` so the card fills its grid cell. Grid rows stretch to the taller
                # of the two cells, and without this the shorter card kept its intrinsic
                # height and its VETO pill rode up with it — measured at 420×900 with a
                # three-line name in the right column, the two VETO pills in one row sat
                # 60px apart, which reads as a broken grid rather than as two options.
                "relative flex min-h-[96px] w-full flex-1 flex-col gap-1.5 rounded-2xl border-2 border-ink p-2.5",
                "text-left shadow-sticker-3 press-3 transition-colors",
                # No blanket `disabled:opacity-60 disabled:shadow-none`. It faded the 2px ink
                # border to grey and deleted the hard offset shadow — the design system's
                # first two rules — so a vetoed option stopped being a sticker at all. A
                # struck-out sticker is still a sticker; the dimming belongs on the text,
                # which is where the `line-through` and `text-muted` below already are.
                "disabled:cursor-not-allowed",
                cond do
                  vetoed?(activity.id, @veto_id) -> "bg-white"
                  approved?(activity.id, @approved) -> "bg-mint"
                  # `active:` beside `hover:`, the pairing every other control on this
                  # screen already carries. `:hover` does not exist on touch — a browser
                  # synthesises one on tap and holds it until the finger lands elsewhere —
                  # so the yellow tint stayed on the card after the tap and competed with
                  # the mint `picked` fill the same tap had just set.
                  true -> "bg-white hover:bg-yellow-tint active:bg-yellow-tint"
                end
              ]
            }
          >
            <%!-- `z-10` is load-bearing, not decoration. `photo_frame/1`'s root is
                  `relative overflow-hidden`, so with both at `z-index: auto` the thumbnail
                  paints over this badge in DOM order and only a ~2px crescent of it escaped
                  from behind the thumbnail's corner — measured at 420×900,
                  `elementFromPoint` over the badge returned the thumbnail. --%>
            <span
              :if={approved?(activity.id, @approved)}
              class="absolute right-2 top-2 z-10 grid size-[21px] place-items-center rounded-full border-2 border-ink bg-ink text-[11px] font-semibold text-white"
              aria-hidden="true"
            >
              ✓
            </span>
            <%!-- Frame `1c-1` gives a selected card two markers, not one: the mint fill AND
                  the thumbnail's stripe switching from its pastel to a muted-ink
                  `rgba(23,33,28,.14)` pattern. `.stripes-ink` is unlayered in app.css so it
                  wins over the `.stripes-violet` `photo_frame/1` adds when there is no
                  image; with a real image it is behind the `<img>` and invisible, exactly
                  like every other stripe here. --%>
            <%!-- The stripe cycles by id rather than being one colour for the whole pool.
                  Frame `1c-1` gives its unselected tiles three different pastel pairs, and
                  app.css's own comment says why: "a pool of five options with one repeated
                  stripe reads as a single grey block, and the eye stops separating the
                  rows". Keyed on `activity.id`, the way `Sticker.participant_avatar/1`
                  keys its fill, so the colour survives a re-render and a reorder. --%>
            <.photo_frame
              src={activity.image_url}
              alt={activity.name}
              height="h-[38px]"
              bare
              stripe={thumb_stripe(activity.id)}
              class={[
                "rounded-[9px] border-[1.5px] border-ink stripe-pitch-6",
                approved?(activity.id, @approved) && "stripes-ink"
              ]}
            />
            <%!-- `line-clamp-2`, the same cap `Sticker.deck_stack/1` puts on the same
                  field. Grid rows stretch to the taller cell, so an unclamped third line
                  in one card grew its row-mate too — and the row-mate's own name stayed one
                  line while its `mt-auto` meta line went to the new floor, opening a 36px
                  void inside a card whose sibling had 6px. Frame `1c-1`'s cards are a
                  uniform 122px with one name→meta gap. An ellipsis, not a vanished line,
                  is the failure mode invariant 11 asks for here. --%>
            <p class={[
              "line-clamp-2 pr-5 text-[13px] font-bold leading-[1.15]",
              if(vetoed?(activity.id, @veto_id),
                do: "text-muted line-through",
                else: "text-ink"
              )
            ]}>
              {activity.name}
            </p>
            <%!-- The in-card `Vetoed` pill is gone. It announced the same state as the
                  labelled control 6px below it — the card said `Vetoed` and the bar said
                  `VETOED`, one above the other, which is ambiguous duplication (confusion
                  #5) and put a second tangerine on a screen whose one forward action is
                  "Send my votes". The struck-through name carries the state on the card.
                  `truncate` needs a block box to clip against; on a bare inline <span> the
                  ellipsis never applies and a 140-character description runs off the
                  card. --%>
            <div class="mt-auto w-full min-w-0">
              <span class={[
                "block truncate font-mono text-[10.5px] font-medium",
                if(vetoed?(activity.id, @veto_id), do: "text-faint", else: "text-ink-soft")
              ]}>
                {meta_line(activity)}
              </span>
            </div>
          </button>

          <button
            :if={@group.veto_allowed}
            type="button"
            phx-click="toggle_veto"
            phx-value-id={activity.id}
            aria-label={deck_veto_label(activity, @veto_id, activity.id, @group.activities)}
            aria-pressed={to_string(vetoed?(activity.id, @veto_id))}
            class={
              [
                # `min-h-11` (44px), matching every other control on this screen. It was
                # 36px, which is under the touch floor on the default view of the most
                # touch-critical screen in the app, for the one destructive control a
                # voter can reach — and it sits directly under a tap-to-pick card, so a low
                # tap lands on the wrong one of two opposite meanings.
                "flex min-h-11 w-full items-center justify-center gap-1 rounded-full border-2 border-ink px-2",
                "font-mono text-[9.5px] font-semibold uppercase tracking-[0.06em] transition-colors",
                # `bg-peach`, not `bg-tangerine`. The old control was a 24px circle, so filling
                # it tangerine cost nothing; at full width it became a second tangerine bar
                # directly above "Send my votes", and the design system reserves tangerine
                # for the one forward action on a screen. The card above carries the
                # struck-through name and its meta line drops to `text-faint` — the state is
                # not under-signalled.
                # `yellow-tint` (#FFF6DC), not `yellow` (#FFD84D). Frame `1c-1` declares
                # exactly one hover fill for anything in this grid — #FFF6DC, on the option
                # card — and #FFD84D is the header pill's *resting* CTA yellow. Two
                # different yellows lit up on two controls 6px apart, and the louder,
                # CTA-coloured one was on the destructive control.
                if(vetoed?(activity.id, @veto_id),
                  do: "bg-peach text-ink",
                  else: "bg-white text-ink-soft hover:bg-yellow-tint active:bg-yellow-tint"
                )
              ]
            }
          >
            <%!-- No `1×` glyph. It printed once per option, so a five-option pool drew
                  "VETO 1×" five times down the screen under a counter that says the budget
                  once — the same ambiguous duplication (confusion #5) the caption was
                  narrowed for. The deck keeps the glyph, where there is exactly one of it
                  and it is a genuine counter. --%>
            <.icon name="hero-no-symbol" class="size-3.5 shrink-0" />
            <span class="truncate">{grid_veto_caption(@veto_id, activity.id)}</span>
          </button>
        </div>
      </div>

      <%!-- Conditional, because with vetoes off it was the one sentence whose whole job is
            unsticking a voter and it sent them hunting for a control that is not on the
            screen and that `Voting.ensure_veto_permitted/2` would refuse anyway. --%>
      <.submit_block
        approved={@approved}
        veto_id={@veto_id}
        veto_allowed={@group.veto_allowed}
        empty_hint={
          if @group.veto_allowed,
            do: "Tap the ones you'd be happy with, or veto the one you can't do.",
            else: "Tap the ones you'd be happy with."
        }
      />
    </div>
    """
  end

  attr :group, :map, required: true
  attr :approved, :any, required: true
  attr :veto_id, :any, required: true
  attr :deck_index, :integer, required: true
  attr :deck_seen, :any, required: true
  attr :deck_history, :list, required: true
  attr :deck_changing?, :boolean, required: true
  attr :veto_note, :string, default: nil

  defp deck_view(assigns) do
    assigns =
      assign(assigns, :card, current_card(assigns.group, assigns.deck_index))
      |> assign(:count, card_count(assigns.group))

    ~H"""
    <%!-- `overflow-x-clip` because a dragged card is `position: absolute` and translates
          past the column's edge: measured at 420×900, a 150px drag to the right grew
          `document.documentElement.scrollWidth` from 420 to 587 and the whole page could
          be scrolled sideways. `clip` rather than `hidden` — `hidden` would make this a
          scroll container and take the vertical axis with it. The card is clipped at the
          column edge, which is where a card leaving the deck should disappear anyway. --%>
    <div :if={@card} class="flex flex-1 flex-col overflow-x-clip">
      <div class="flex items-center justify-between gap-3 px-4 pb-1 pt-3">
        <span class="min-w-0 truncate text-[12px] font-semibold">{@group.title}</span>
        <span class="shrink-0 font-mono text-[11px] font-medium text-ink-soft" aria-live="polite">
          {@deck_index + 1} / {@count}
        </span>
      </div>
      <p class="px-4 text-[11.5px] text-ink-soft">
        Tap or swipe right to pick it, swipe left to pass — or use the buttons.
      </p>
      <p :if={@deck_changing?} class="px-4 pt-1 text-[11.5px] font-semibold text-ink">
        Changing this one. You'll go straight back to your picks.
      </p>
      <%!-- Set only by the decision that moved the veto off another card, and cleared by
            the next decision or any movement. Without it the only signal was a 9px caption
            on the control the voter has already stopped reading, gone the instant the card
            advanced — and the previous holder silently became an ordinary pass. --%>
      <p :if={@veto_note} class="px-4 pt-1 text-[11.5px] font-semibold text-ink" id="veto-note">
        {@veto_note}
      </p>

      <%!-- **No `max-h` here any more, and putting one back would undo the fix.** Two
            successive card-height caps (430px, then 380px) were attempts to control the
            photo's aspect ratio from the wrong end: the ratio was whatever the cap minus
            the body happened to leave, so it tracked the viewport — 1.08:1, then 1.26:1,
            against frame `1c-0`'s 1.326. `Sticker.deck_stack/1` now states the ratio on
            the photo itself and centres the resulting shorter card in this slot, so this
            box only has to say how much room the deck may take. `min-h-[220px]` stays as
            the floor a short phone bottoms out at. --%>
      <div class="relative mx-[18px] mb-3.5 mt-2 min-h-[220px] flex-1">
        <.deck_stack
          id={"deck-card-#{@card.id}"}
          name={@card.name}
          detail={meta_line(@card)}
          image_url={@card.image_url}
          behind={undecided_after(@group.activities, @deck_index, @deck_seen)}
          phx-hook="SwipeCard"
          data-activity-id={@card.id}
        >
          <p
            :if={card_state_note(decision_for(@card.id, @approved, @veto_id, @deck_seen))}
            class="font-mono text-[10.5px] font-medium text-ink"
          >
            {card_state_note(decision_for(@card.id, @approved, @veto_id, @deck_seen))}
          </p>
        </.deck_stack>
      </div>

      <%!-- Frame `1c-0` fixes this control set and its left-to-right order. Pass and
            approve are 58px circles whose hover darkens the fill instead of pressing —
            IMPORT-NOTES §9.1: they have no room to press. The 44px veto does press,
            which is what the frame draws for it. Both circles also carry an `active:`
            fill: `:hover` does not exist on touch, so on a phone the two primary controls
            of this view gave no feedback at all until the server round-trip landed.

            `pt-4` restores the frame's `padding:16px 18px 20px` on this row — measured, it
            put the pass button 15px below the card where `1c-0` draws it 30px below. --%>
      <%!-- Each control is ONE button containing its shape and its caption, so the words
            that describe the press are pressable. The veto's caption used to be a sibling
            `<span>` 3.5px under a 44px button — `elementFromPoint` over it returned the
            span, `closest("button")` was null, and it is the only thing that ever says
            `MOVE VETO`, i.e. the text explaining the control's most surprising behaviour.

            `PASS` and `PICK` are new. The two circles carried a bare `✕` and a bare `♥`
            and the line above the card maps *gestures*, never which button is which — so a
            first-time voter had to infer ✕ = pass from the Tinder convention, on a ballot
            that locks on submit (D-036). The fill states move to `group-hover:` /
            `group-active:` on the inner shape so hovering the caption lights the control. --%>
      <div class="flex items-start justify-center gap-3.5 px-[18px] pb-2 pt-4">
        <button
          type="button"
          id="deck-pass"
          phx-click="deck_decide"
          phx-value-decision="pass"
          phx-value-id={@card.id}
          aria-label={"Pass on #{@card.name}"}
          aria-pressed={to_string(decision_for(@card.id, @approved, @veto_id, @deck_seen) == :passed)}
          class="group flex flex-col items-center gap-[3px]"
        >
          <%!-- 62px, not 58. Frame `1c-0` measures these at 62×62 and 48×48 *border-box*
                — IMPORT-NOTES §7.6's 58/44 are the content boxes, plus the 2px border each
                side the same section specifies. Everything else on this card was converted
                from content-box to border-box on the way in; the three controls were the
                one place that was dropped, so every control in this row rendered ~6.5%
                small. --%>
          <span class="grid size-[62px] place-items-center rounded-full border-2 border-ink bg-white text-[20px] font-semibold shadow-sticker-3 transition-colors group-hover:bg-yellow-soft group-active:bg-yellow-soft">
            ✕
          </span>
          <span class="font-mono text-[9px] font-medium text-ink-soft">PASS</span>
        </button>

        <button
          :if={@group.veto_allowed}
          type="button"
          id="deck-veto"
          phx-click="deck_decide"
          phx-value-decision="veto"
          phx-value-id={@card.id}
          aria-label={deck_veto_label(@card, @veto_id, @card.id, @group.activities)}
          aria-pressed={to_string(vetoed?(@card.id, @veto_id))}
          class="group flex flex-col items-center gap-[3px]"
        >
          <%!-- A 62px band with the 48px square centred in it, rather than `pt-[7px]` on
                the column. Both centre the square against its two 62px neighbours; only
                this one also leaves the caption where the other two captions are.
                `pt-[7px]` pushed the whole column down, so `MOVE VETO` sat 7px above
                `PASS` and `PICK` and the row of captions read as stepped. `1c-0` gives no
                answer here — it draws a caption under the veto only, and `PASS`/`PICK`
                are ours. --%>
          <span class="grid h-[62px] place-items-center">
            <span class="grid size-12 place-items-center rounded-[14px] border-2 border-ink bg-tangerine font-mono text-[11px] font-semibold text-white shadow-sticker-3 press-3">
              {deck_veto_glyph(@veto_id)}
            </span>
          </span>
          <span class="font-mono text-[9px] font-medium text-ink-soft">
            {deck_veto_caption(@veto_id, @card.id)}
          </span>
        </button>

        <button
          type="button"
          id="deck-approve"
          phx-click="deck_decide"
          phx-value-decision="approve"
          phx-value-id={@card.id}
          aria-label={"Pick #{@card.name}"}
          aria-pressed={to_string(approved?(@card.id, @approved))}
          class="group flex flex-col items-center gap-[3px]"
        >
          <span class="grid size-[62px] place-items-center rounded-full border-2 border-ink bg-violet text-[22px] font-semibold text-white shadow-sticker-3 transition-colors group-hover:bg-violet-deep group-active:bg-violet-deep">
            ♥
          </span>
          <span class="font-mono text-[9px] font-medium text-ink-soft">PICK</span>
        </button>
      </div>

      <%!-- The same running count the grid carries above its button. Without it a ♥ only
            slides a card away and the ballot the voter is building is invisible until the
            end of the deck (confusion #2). `id` is shared with `submit_block/1`'s copy —
            the card view and the summary are mutually exclusive, so only one is ever in
            the document. --%>
      <p
        class="px-4 pt-1 text-center font-mono text-[11px] font-medium text-ink-soft"
        aria-live="polite"
        id="ballot-status"
      >
        {ballot_status_text(@approved, @veto_id, @group.veto_allowed)}
      </p>

      <%!-- "Review picks" is unconditional. It is the deck's only route to the submit
            button, and a voter who tapped three cards in the grid and then switched over
            arrives at card 1 with nothing decided *in the deck* — hiding it there would
            strand a ready ballot behind a walk through the whole pool. --%>
      <div class="flex min-h-[56px] flex-wrap items-center justify-center gap-2 px-4 pb-4 pt-1">
        <%!-- While a `Change` is open, `Cancel change` replaces `Undo`. Undo one tap after
              `Change` reads as "cancel this change"; what it actually did was reverse a
              decision made three actions earlier, drop the change mode and jump to a
              different card — an unpredictable outcome (confusion #3) on the control added
              to close "no way back". Cancel is the honest control for that moment, and
              Undo is still one press away from the summary it returns to. --%>
        <button
          :if={@deck_changing?}
          type="button"
          id="deck-cancel-change"
          phx-click="deck_cancel_change"
          class="inline-flex min-h-11 items-center rounded-full border-2 border-ink bg-white px-3.5 text-[12px] font-semibold shadow-sticker-2 press-2 transition-colors hover:bg-yellow-tint"
        >
          Cancel change
        </button>
        <.deck_undo_button
          :if={!@deck_changing?}
          history={@deck_history}
          activities={@group.activities}
        />
        <%!-- Hidden while a `Change` is open, because there it was the same control twice:
              `deck_review/2` and `deck_cancel_change/2` both patch to the summary with
              `changing?: false`, so two adjacent pills appeared to do different things and
              did not (confusion #5). `Cancel change` names the mode it is leaving and is
              the honest one of the pair. --%>
        <button
          :if={!@deck_changing?}
          type="button"
          id="deck-review"
          phx-click="deck_review"
          class="inline-flex min-h-11 items-center rounded-full border-2 border-ink bg-white px-3.5 text-[12px] font-semibold shadow-sticker-2 press-2 transition-colors hover:bg-yellow-tint"
        >
          Review picks
        </button>
      </div>
    </div>

    <%!-- End of deck. The design draws no such state (IMPORT-NOTES §7.7); ruling 7 settles
          the shape: what you chose, the same "Send my votes" the grid has, and a way back
          into the deck to change a card. Reachable early through "Review picks", so it also
          has to handle cards the voter has not looked at yet. --%>
    <%!-- `px-4` sits on the children, NOT on this root. `submit_block/1` carries its own
          16px gutter, and wrapping it in a second one made the same control 356px wide on
          the summary and 388px wide in the grid — the one tangerine action visibly
          under-hanging the list above it on both edges. --%>
    <%!-- `min-h-0` and the `shrink-0` header below it are the `fill_viewport` contract:
          the `<ul>` further down is the scroll track and everything else in this column
          holds its size. --%>
    <div :if={is_nil(@card)} class="flex min-h-0 flex-1 flex-col pb-2 pt-3">
      <div class="shrink-0">
        <%!-- Branched on whether anything was *picked*, not on whether the ballot is
            sendable. Those are different questions: a veto alone makes `submit_disabled?/2`
            false, so a ballot with one veto and no picks was headed "Your picks" over a
            counter reading "0 PICKED". --%>
        <h1
          class="px-4 text-[18px] font-bold leading-[1.1] tracking-[-0.025em] text-ink"
          id="deck-summary-heading"
          tabindex="-1"
          phx-mounted={JS.focus()}
        >
          {summary_heading(@approved, @veto_id)}
        </h1>
        <%!-- "Pick at least one below" pointed at a list whose only control is `Change`, and
            named picking as the only way to enable Send when a veto also does. It now says
            what is actually below and matches `#ballot-empty-hint` three lines down, which
            used to be the only accurate sentence of the two. --%>
        <p class="mt-1 px-4 text-[11.5px] text-ink-soft">
          {if submit_disabled?(@approved, @veto_id),
            do: "Nothing has been sent yet. Press Change on any option to answer it.",
            else: "Change any of them before you send — nothing has been sent yet."}
        </p>
        <p :if={@veto_note} class="mt-1 px-4 text-[11.5px] font-semibold text-ink" id="veto-note">
          {@veto_note}
        </p>
      </div>

      <%!-- The scroll track. The floor is the same idea as the grid pool's and a smaller
            number for a measured reason: this state carries more `shrink-0` chrome than
            the grid does (a heading, a hint, the Undo/Keep-going row, then the whole submit
            block), so at 360×640 there are 146px left for the list and a 160px floor pushed
            `#submit-ballot` 14px onto the footer — the same class of overflow the grid's
            unconditional clamp caused. 110 leaves slack at every viewport the gate lets the
            clamp run at, down to 320×640. `pb-1` keeps the last row's 2px shadow from being
            clipped by the scroll edge. --%>
      <ul class="mt-3 flex min-h-[110px] flex-1 flex-col gap-2 overflow-y-auto px-4 pb-1">
        <li
          :for={{activity, index} <- Enum.with_index(@group.activities)}
          id={"deck-summary-#{activity.id}"}
          class="flex items-center gap-2 rounded-2xl border-2 border-ink bg-white p-2.5 shadow-sticker-2"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] font-bold leading-[1.15]">{activity.name}</p>
            <.summary_state decision={decision_for(activity.id, @approved, @veto_id, @deck_seen)} />
          </div>
          <button
            type="button"
            phx-click="deck_change"
            phx-value-index={index}
            aria-label={"Change your answer on #{activity.name}"}
            class="inline-flex min-h-11 shrink-0 items-center rounded-full border-2 border-ink bg-white px-3.5 text-[12px] font-semibold shadow-sticker-2 press-2 transition-colors hover:bg-yellow-tint"
          >
            Change
          </button>
        </li>
      </ul>

      <div class="mt-3 flex shrink-0 flex-wrap items-center justify-center gap-2 px-4">
        <.deck_undo_button history={@deck_history} activities={@group.activities} />
        <button
          :if={first_undecided_index(@group.activities, @deck_seen)}
          type="button"
          id="deck-keep-going"
          phx-click="deck_resume"
          phx-value-index={first_undecided_index(@group.activities, @deck_seen)}
          class="inline-flex min-h-11 items-center rounded-full border-2 border-ink bg-white px-3.5 text-[12px] font-semibold shadow-sticker-2 press-2 transition-colors hover:bg-yellow-tint"
        >
          Keep going
        </button>
      </div>

      <.submit_block
        approved={@approved}
        veto_id={@veto_id}
        veto_allowed={@group.veto_allowed}
        empty_hint={
          if @group.veto_allowed,
            do:
              "Press Change on one above to pick it or veto it, or switch back to Grid and tap the ones you'd be happy with.",
            else:
              "Press Change on one above, or switch back to Grid and tap the ones you'd be happy with."
        }
      />
    </div>
    """
  end

  # One summary row's state, in the same two markers the grid uses for the same two
  # states — a mint pill for a pick, a tangerine one for a veto — so a voter who built
  # the ballot in one view recognises it in the other. The word is always present, so a
  # fill is never the only signal, and the two states with no pill are the two that are
  # not marks on the ballot at all.
  attr :decision, :atom, required: true

  defp summary_state(assigns) do
    ~H"""
    <p class="mt-1">
      <.pill :if={@decision == :approved} tone={:mint}>{decision_label(@decision)}</.pill>
      <%!-- Peach, not tangerine. On this screen the one tangerine element is
            `#submit-ballot`, and a tangerine `Vetoed` pill made two — the grid's held-veto
            button already uses peach for the identical state one view away. --%>
      <.pill :if={@decision == :vetoed} tone={:peach}>{decision_label(@decision)}</.pill>
      <span
        :if={@decision in [:passed, :undecided]}
        class="font-mono text-[10px] uppercase tracking-[0.04em] text-ink-soft"
      >
        {decision_label(@decision)}
      </span>
    </p>
    """
  end

  # Rendered only when there is something to undo. A permanently-disabled control on a
  # fresh deck would be an affordance that never does anything (confusion #1); the row it
  # sits in keeps its height either way so the controls above it do not jump.
  #
  # It names its object. "Undo" alone, sitting inline beside "Keep going" and "Review
  # picks", reads as navigation — and on the summary that is exactly what the voter's last
  # action was, so pressing it looked like it would take back the trip rather than the
  # vote. The label says "last card"; the `aria-label` says which card.
  attr :history, :list, required: true
  attr :activities, :list, required: true

  defp deck_undo_button(assigns) do
    assigns = assign(assigns, :target, undo_target(assigns.history, assigns.activities))

    ~H"""
    <button
      :if={@target}
      type="button"
      id="deck-undo"
      phx-click="deck_undo"
      aria-label={"Undo — put back your answer on #{@target.name}"}
      class="inline-flex min-h-11 items-center gap-1.5 rounded-full border-2 border-ink bg-white px-3.5 text-[12px] font-semibold shadow-sticker-2 press-2 transition-colors hover:bg-yellow-tint"
    >
      <.icon name="hero-arrow-uturn-left" class="size-3.5" /> Undo last card
    </button>
    """
  end

  # Shared by both views, so the count, the warning and the button are the same sentence
  # and the same control wherever the voter ended up. D-036 locks a cast ballot and there
  # is no recast; the line above the button is the only place that fact can usefully be
  # said, which is before the press rather than after it.
  attr :approved, :any, required: true
  attr :veto_id, :any, required: true
  attr :veto_allowed, :boolean, required: true

  attr :empty_hint, :string,
    required: true,
    doc: """
    what to do about the inert button, in this view's own words. The explanation used to
    live in the deck's summary only, so the grid — the default view — showed a dead
    tangerine button with the count above it and no sentence saying why.
    """

  attr :class, :any, default: nil

  defp submit_block(assigns) do
    ~H"""
    <%!-- `.ballot-actions` + `bg-canvas`: below `.viewport-column`'s 640px gate the page is
          the scroller, and nothing was keeping this block on screen — at 375×553 (an iPhone
          SE in Safari) `#submit-ballot` ended 330.7px below the fold with `#ballot-status`
          below it again. The rule and its measurements are in `assets/css/app.css`; it is
          `position: static` above the gate, where the clamped column already pins this
          block and the page does not scroll at all. The fill is what stops the pool showing
          through it while it floats. --%>
    <div class={["ballot-actions flex shrink-0 flex-col gap-2 bg-canvas px-4 pb-6 pt-2", @class]}>
      <%!-- One status region, not three loose centred lines. The counter, the empty hint
            and the irreversibility warning used to be three sibling paragraphs in three
            barely-different treatments — all centred, all 11–11.5px, all the same colour
            family — so the one sentence that matters most ("you can't change your votes
            afterwards") competed for the same visual slot as a running count and nothing
            told a reader which of the three to read first.

            They are the same *kind* of thing (what is true about this ballot right now), so
            they belong in one bordered block with an explicit weight ramp: the count in
            bold mono, the "what to do about the dead button" line under it while there is
            nothing to send, and the D-036 warning last and quietest — quietest because it
            never changes, not because it matters least.

            The warning is **unconditional**, and stays that way. It is tempting to hide it
            while the button is disabled, on the grounds that it describes a press that
            cannot happen — but the moment to learn that sending is permanent is while you
            are still deciding what to pick, which is exactly the empty state. Pinned by
            "both views say submitting is final before the press (D-036)". --%>
      <div
        id="ballot-status-region"
        class="flex flex-col gap-1 rounded-2xl border-2 border-ink-30 bg-white/65 px-3 py-2 text-center"
      >
        <%!-- `font-medium text-ink-soft`, which is what frame `1c-1` computes for this
              exact line (`2 PICKED · 1 VETO LEFT`, DM Mono 11px/500, `#3B4A42`). At
              `font-semibold text-ink` it was a weight heavier and a full ink step darker
              than drawn, so a running count competed with the `<h1>` and the one tangerine
              action for the eye. It is also what the deck's own copy of `#ballot-status`
              has always used, 200 lines up. --%>
        <p
          class="font-mono text-[11px] font-medium text-ink-soft"
          aria-live="polite"
          id="ballot-status"
        >
          {ballot_status_text(@approved, @veto_id, @veto_allowed)}
        </p>
        <p
          :if={submit_disabled?(@approved, @veto_id)}
          class="text-[11.5px] leading-[1.4] text-ink-soft"
          id="ballot-empty-hint"
        >
          Nothing to send yet. {@empty_hint}
        </p>
        <p class="text-[10.5px] leading-[1.4] text-muted" id="ballot-final-warning">
          Sending is final — you can't change your votes afterwards.
        </p>
      </div>
      <.button
        id="submit-ballot"
        variant="primary"
        type="button"
        phx-click="submit_ballot"
        disabled={submit_disabled?(@approved, @veto_id)}
      >
        Send my votes
      </.button>
    </div>
    """
  end
end
