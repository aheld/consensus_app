defmodule ConsensusWeb.GroupLive.Results do
  @moduledoc """
  Design frame `05 · live results (organizer)` — `/groups/:id/results`.

  The organizer's half of the shared `ConsensusWeb.ResultsComponents.results_panel/1`
  (see that module for everything the two `results` screens have in common — header,
  avatar row, the completed/cancelled outcome section, the tally, the anonymity
  caption). This LiveView is only the mount, the reload plumbing, and the footer that
  is organizer-only: **Get the share link again**, the unbuilt **Nudge N friends** marker
  and **Close now** while the vote is open. The nudge marker renders only while somebody is
  actually waiting — neither "nobody has joined" nor "everybody has voted" gets a control,
  because a state with nothing to press gets a sentence, not a `disabled` box carrying a
  status line. **Get the share link again** is the screen's one tangerine primary: it is the
  single forward action here, and while it was a bare underlined link the only
  button-shaped control on a freshly published session was the irreversible one. It is also
  not decoration — without it `04 share` and `03 review` are a closed island (each is
  reachable only from the other) and an organizer who closed the tab could never re-copy the
  link this product exists to hand out.

  **Every status has a footer**, which is new in D-045. The slot had branches for `:voting`
  and `:cancelled` only, so a `:completed` group rendered *nothing* below the tally — and
  when the outcome was `:no_consensus` or `:no_votes` there was no winner card above it
  either, leaving the organizer of a finished session with no control anywhere on the page.
  `:completed` now names the outcome and offers `Start another session`; `:cancelled` says
  it cannot be reopened and offers the same. Since D-051 the two unresolved endgames never
  reach that footer at all: a `:completed` all-vetoed pool or dead heat replaces the whole
  panel — footer included — with a takeover state (`ConsensusWeb.Endgame.AllVetoed` /
  `ConsensusWeb.Endgame.Tie`) carrying its own exits, and this LiveView's part is the
  `@takeover` assign, the two `:if` branches in `render/1`, and the
  `{:endgame_flash, ...}` / `:endgame_refresh` plumbing the LiveComponents report through.

  Reached from `HomeLive`'s group list and from `GroupLive.Share`'s "session is live"
  preview — see `docs/plans/voting-loop.md`. Sits in the router's existing
  `:require_authenticated_user` live_session (not a new one — AGENTS.md), so
  `Consensus.Activities.get_group!/2`'s organizer scoping is what keeps a stranger
  from reading someone else's tally: it raises `Ecto.NoResultsError` for any id that
  is not this signed-in user's own group.

  ## Live updates — the acceptance bar

  `Consensus.Voting.subscribe/1` on mount (the same `"activity_group:<id>"` topic
  `Consensus.Activities` already publishes group/activity changes on), plus a 30s
  `:tick` for the countdown text. Every message this topic can carry —
  `{:ballot_cast, group_id}`, `{:participant_joined, group_id}`, `{:group_updated,
  group}`, and the three activity messages (harmless here:
  `Consensus.Activities.add_activity/3` and friends already refuse once the pool leaves
  `:draft`, D-037) — reloads the group and re-tallies. This is the one behaviour the
  brief calls out by name: a guest's vote, cast in a second browser tab, must appear
  here **without this tab navigating** — and so must a guest simply joining, so the
  avatar row and the "Nudge N friends" count never sit stale for up to 30 seconds.

  ## A `:draft` group has no results yet

  Bounces to `03 review`, the same redirect `GroupLive.Share` uses for the same
  reason — nothing has been published, so there is no tally and no share link either.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Voting
  alias ConsensusWeb.Endgame

  import ConsensusWeb.EndgameComponents, only: [takeover: 2]
  import ConsensusWeb.ResultsComponents

  @tick_interval :timer.seconds(30)

  # `Activities.get_group!/2` scopes by organizer, so *someone else's* group and a group
  # that never existed both arrive here as `Ecto.NoResultsError` — which Phoenix renders as
  # a bare 404. Two ordinary paths walk into it. An organizer watching a tally copies
  # `/groups/12/results` out of the address bar into the group chat instead of the share
  # link, and every recipient gets a log-in wall and then Not Found. And `UserAuth`'s
  # `:user_return_to` survives an identity change: sign out, open a results URL, sign in as
  # anyone, and log-in delivers you straight to a group you cannot read — measured, on a
  # brand-new account, as the very first screen after "Account created".
  #
  # A 404 is technically honest and useless in both cases: it names nothing and offers the
  # reader no account of what they did. The redirect says which of the two it was — a
  # session you don't own, or one that is gone — and lands on the group list, which is the
  # only screen that is right from either. `rescue` rather than a `get_group/2` variant
  # because the raising function is the one every other caller in this tree uses and this
  # screen should not be the reason a non-raising twin exists.
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, id)

    if group.status == :draft do
      # Same silent-redirect fix as `GroupLive.Share` (D-045): the organizer asked for
      # results and got a different screen with no account of why.
      {:ok,
       socket
       |> put_flash(
         :info,
         "There are no results yet — #{group.title} hasn't been published, so nobody can " <>
           "vote on it."
       )
       |> push_navigate(to: ~p"/groups/#{group}/review")}
    else
      if connected?(socket) do
        Voting.subscribe(group.id)
        Process.send_after(self(), :tick, @tick_interval)
      end

      {:ok,
       socket
       |> assign(:page_title, "Results · #{group.title}")
       |> assign(:now, DateTime.utc_now())
       |> load_group(group)}
    end
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(
         :error,
         "That session isn't yours, or it no longer exists. Here is everything you organize."
       )
       |> push_navigate(to: ~p"/")}
  end

  # There is deliberately no `"nudge"` clause. The control that pushed it is now `disabled`
  # and labelled `Soon`, so the only thing this handler ever did — flash "there is no
  # notification system yet" at someone who had just been invited to press it — has no
  # sender. When notifications are built, the handler comes back with them.
  @impl true
  def handle_event("close_now", _params, socket) do
    case Activities.complete_group(socket.assigns.current_scope, socket.assigns.group) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Voting is closed.")
         |> reload()}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "This session has already finished.")}
    end
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Summary copied")}
  end

  def handle_event("copy_failed", _params, socket) do
    {:noreply, put_flash(socket, :info, "Couldn't copy automatically — select the text above")}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> reload()}
  end

  def handle_info({:ballot_cast, _group_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:participant_joined, _group_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:group_updated, _group}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_added, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_updated, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activities_changed, _activities}, socket), do: {:noreply, reload(socket)}

  # The endgame takeover's two writes live in `ConsensusWeb.Endgame.AllVetoed`, a
  # LiveComponent — and a LiveComponent's own `put_flash` is discarded unless it rides a
  # redirect, so refusals (and the rescue's success line) report through these two
  # messages instead. `:endgame_refresh` is how a stale tab whose PubSub message was
  # late or lost still flips to the state its refusal was about.
  def handle_info({:endgame_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info(:endgame_refresh, socket), do: {:noreply, reload(socket)}

  # `presentable_tally/2` is what keeps a cancelled session from painting a ★. See its
  # docs in `ConsensusWeb.ResultsComponents`: `Voting.tally/1` still marks a `leader?` on
  # a cancelled group (only `winner?` is gated on `:completed`), so this screen rendered
  # "Alpha Diner ★ 1" under a **Final tally** heading while saying twice, in the panel and
  # in the footer, that the session was cancelled and nobody won.
  # `Voting.outcome/2`, not `outcome/1`: the status-aware arity is the only one that can
  # answer `{:tie, tied_rows}` for a completed, unresolved dead heat — the flags-only
  # reading crowns `tally/1`'s position tie-break and this screen then asserts an
  # unqualified win over a draw. A recorded resolution comes back `{:winner, row}` with
  # the resolved activity flagged, so the ordinary winner ending needs nothing special.
  defp load_group(socket, group) do
    tally = presentable_tally(group, Voting.tally(group))
    outcome = Voting.outcome(group, tally)

    socket
    |> assign(:group, group)
    |> assign(:tally, tally)
    |> assign(:outcome, outcome)
    |> assign(:takeover, takeover(group, outcome))
    |> assign(:participants, Voting.participants(group))
  end

  # A group can return to `:draft` under an open results tab now:
  # `Consensus.Activities.reopen_group/2` (the All Vetoed takeover's "Add new options"
  # exit) broadcasts on the same topic every other write does, and a draft has no
  # results — `results_header/1` has no `:draft` clause on purpose, and mount bounces
  # drafts for the same reason. Follow the reopen to the wizard rather than crash on it.
  defp reload(socket) do
    group = Activities.get_group!(socket.assigns.current_scope, socket.assigns.group.id)

    if group.status == :draft do
      socket
      |> put_flash(
        :info,
        "This pool was reopened — there are no results until it is published again."
      )
      |> push_navigate(to: ~p"/groups/#{group}/review")
    else
      load_group(socket, group)
    end
  end

  defp waiting_count(participants), do: Enum.count(participants, &(!&1.voted?))

  # The nudge marker is rendered **only when there is somebody to nudge** — see the
  # `:if={waiting_count(@participants) > 0}` on it — so this function has exactly one
  # branch and no dead copy behind it.
  #
  # This took three rounds. Keyed only on `waiting_count == 0`, an **empty** participant
  # list satisfied it exactly as a fully-voted one did, so the first thing an organizer saw
  # after publishing — before anyone had opened the link — was `0/0 voted` in the header
  # above a control reading "Everyone has voted / SOON". Replacing that with "Nobody has
  # opened the link yet / SHARE THE LINK" made it worse: an imperative printed on a
  # `disabled`, dashed button. Dropping the empty case fixed half of it and left the other
  # half standing: a fully-voted session still rendered a dashed, un-pressable box reading
  # "Everyone has voted / ALL IN", which is a *status sentence* wearing a control's clothes,
  # and the two sub-labels (`Soon` = the feature is unbuilt, `All in` = everyone voted) were
  # two different axes in one 8px mono slot. The rule this screen keeps re-learning: when a
  # control cannot do what it appears to offer, stop rendering the control. Both states with
  # nothing to press now get a plain sentence.
  #
  # "Nudge 0 friends" was the oldest version of the same bug, on the other end.
  defp nudge_label(participants) do
    n = waiting_count(participants)
    "Nudge #{n} #{pluralize(n, "friend")}"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  # The footer's headline for a `:completed` group. Split from `finished_note/1` so the
  # bold first line names the state and the sentence under it says what to do about it —
  # and so `:no_consensus` and `:no_votes`, which have no winner card above them at all,
  # still get a heading rather than a bare paragraph.
  #
  # **The tie has its own clause because the outcome carries it now.** This used to take
  # the tally as a second argument and re-derive the dead heat with `tie_at_top?/1` —
  # the fix for the page reading "Tied at the top" at document y=263 and "Voting is
  # closed and you have a winner." at y=1030. `Voting.outcome/2` moved that fact into
  # the outcome itself: an unresolved dead heat arrives as `{:tie, rows}`, and a
  # `{:winner, _}` over a still-level tally means the tie was *resolved* — there is a
  # winner, and saying so is the truth, not the contradiction.
  defp finished_headline({:winner, _row}), do: "Voting is closed and you have a winner."
  defp finished_headline({:tie, _rows}), do: "Voting is closed, and it ended in a tie."
  defp finished_headline(:no_consensus), do: "Voting is closed with no winner."
  defp finished_headline(:vetoes_only), do: "Voting is closed with no winner."
  defp finished_headline(:no_votes), do: "Voting is closed and nobody voted."
  defp finished_headline(_outcome), do: "Voting is closed."

  # `:completed` is reached two ways — the lazy deadline sweep in
  # `Consensus.Activities.maybe_complete_group/1`, and the **Close now** button 300px up
  # this same file — and the note has to know which, because it used to tell an organizer
  # who had just closed a session with 1d 12h left on the countdown that "the deadline
  # passed". Both timestamps are on `%Group{}`: the sweep stamps `completed_at` at or after
  # `deadline_at`, so an earlier `completed_at` means a human pressed the button.
  defp closed_early?(%{completed_at: %DateTime{} = at, deadline_at: %DateTime{} = deadline}),
    do: DateTime.compare(at, deadline) == :lt

  defp closed_early?(_group), do: false

  # True on a broken tie as well as on a clean win: `ResultsComponents.winner_summary/4`
  # writes the tie and its tie-breaker into the copied string, so "copy the summary" is
  # not an instruction to paste an unqualified win into the chat.
  defp finished_note(_group, {:winner, _row}),
    do: "Copy the summary above to paste it back into the group chat."

  # Nearly unreachable since the tie takeover landed (D-051): an unresolved dead heat
  # renders `Endgame.Tie` — the organizer's break-the-tie exits — instead of this
  # footer, and a resolved one's outcome is `{:winner, row}`. Kept as the defensive
  # rendering for the same reason `:no_consensus` below keeps its clause: it states the
  # standoff honestly and promises no tiebreak, which beats a crash if the takeover
  # trigger and the outcome ever disagree.
  defp finished_note(_group, {:tie, _rows}),
    do:
      "No winner is declared — no vote separated the tied options. Copy the summary above to hand the standoff back to the group chat."

  # Almost unreachable since the endgame takeover landed: an unresolved all-vetoed
  # `:completed` group renders `Endgame.AllVetoed` instead of this footer, and a resolved
  # one's outcome is `{:winner, row}`. What remains is the degenerate case of a recorded
  # resolution whose `resolved_activity_id` was nilified — so the copy states the fact
  # and stops. The old tail ("a new session with a different pool is the way forward")
  # is gone because it is no longer true: the takeover's own exits — reopen the pool, or
  # let the app pick — are the way forward now.
  defp finished_note(_group, :no_consensus),
    do: "Every option in the pool was vetoed, so nothing could win."

  # Distinct from `:no_votes` above it and `:no_consensus` beside it: people did vote, and
  # part of the pool did survive — it just collected no approvals. Saying "nobody voted"
  # here (which is what this fell through to) is contradicted by the avatar row three
  # inches up the same screen.
  # Parallel to the `:no_consensus` note above it, and deliberately **not** a second copy of
  # the sentence `ResultsComponents.outcome_section/1` already puts in the panel: that one
  # says what happened, this one says what to do about it.
  defp finished_note(_group, :vetoes_only),
    do:
      "Nothing left standing picked up an approval, so nothing could win. A new session with a different pool is the way forward."

  # No "everyone who voted can still open the link" tail on this branch: nobody voted, so
  # there is no "everyone" for it to be about.
  defp finished_note(group, :no_votes) do
    if closed_early?(group) do
      "You closed this before anyone sent their votes in."
    else
      "The deadline passed with an empty ballot box. If the link never reached anyone, starting again is quicker than explaining this one."
    end
  end

  defp finished_note(_group, _outcome), do: ""

  # The `:no_votes` branch says its own last word; the others get the standing reassurance
  # that the address keeps working.
  defp finished_tail(:no_votes), do: ""

  defp finished_tail(_outcome),
    do:
      "The result stays at this address, and everyone who voted can still open the link you shared."

  # The global header's context slot (D-041). `LIVE SESSION` is frame `4a`'s own
  # example text and this is the screen it was drawn for; "LIVE" over a closed vote would
  # be a lie in the one place a reader scans for status.
  #
  # **A finished group gets `nil`, not its status spelled out.** Plan ruling 9 and D-041:
  # the slot is state, never the page's name, and where the screen's own body already says
  # the word the slot stays empty. `ResultsComponents.results_header/1` prints exactly
  # `RESULTS` and `CANCELLED` in the violet band 47px below this, in the same DM Mono
  # 10.5px uppercase — so those two clauses printed the same string twice, 47px apart, in
  # one treatment. `:voting` keeps its string because the band says something else there
  # (a countdown, and `LIVE`), which is the case the slot was drawn for.
  #
  # The takeover clause does not break the rule: the takeover replaces the whole panel,
  # violet band included, so nothing in the body prints "ALL VETOED" — the slot is the
  # one place the state is named in the chrome, in the design's own tangerine.
  defp header_context(_group, :all_vetoed), do: "ALL VETOED"
  defp header_context(_group, :tie), do: "DEAD HEAT"
  defp header_context(%{status: :voting}, _takeover), do: "LIVE SESSION"
  defp header_context(_group, _takeover), do: nil

  defp header_context_class(:all_vetoed), do: "text-tangerine"
  defp header_context_class(:tie), do: "text-violet"
  defp header_context_class(_takeover), do: nil

  # The tied-at-top rows the tie takeover renders. Only read under
  # `:if={@takeover == :tie}`, which `EndgameComponents.takeover/2` only answers for a
  # `{:tie, rows}` outcome — the fallback keeps a mismatch a blank list, not a crash.
  defp tie_rows({:tie, rows}), do: rows
  defp tie_rows(_outcome), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Back goes to `/`, not to `04 share`: this screen is reached from the home list
          as often as from the wizard, and the group list is the only destination that is
          correct from both. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back={~p"/"}
      context={header_context(@group, @takeover)}
      context_class={header_context_class(@takeover)}
    >
      <%!-- The All Vetoed takeover (docs/plans/endgame-screens.md) replaces the whole
            results panel — no violet band, no avatar row, no tally — when a completed
            group's every option was vetoed and nothing has resolved it. The component
            owns the poke toy and the two exits; the moment a rescue lands (this tab or
            any other, over PubSub) `@takeover` goes nil on reload and the ordinary
            winner ending below takes over again. --%>
      <.live_component
        :if={@takeover == :all_vetoed}
        module={Endgame.AllVetoed}
        id="endgame-all-vetoed"
        group={@group}
        tally={@tally}
        role={:organizer}
        scope={@current_scope}
      />
      <%!-- The Tie takeover — the tug-of-war scene with the organizer's two ways to
            break the dead heat: tap a tied row (or let the app shuffle onto one) and
            lock it in through `Activities.resolve_group/4`. The moment a resolution
            lands (this tab or any other, over PubSub) the outcome flips to
            `{:winner, row}`, `@takeover` goes nil on reload, and the ordinary winner
            ending below names the tie-break and who made it. --%>
      <.live_component
        :if={@takeover == :tie}
        module={Endgame.Tie}
        id="endgame-tie"
        group={@group}
        rows={tie_rows(@outcome)}
        role={:organizer}
        scope={@current_scope}
      />
      <%!-- `avatar_caption` is not "TAP TO NUDGE": the avatars are not tappable, and nudging
            does not exist at all (see the disabled control in `:footer`). A caption that
            instructs the reader to perform an action nothing on the screen performs is the
            plan's confusion class 1 twice over. --%>
      <%!-- `organizer_username` is the viewer's own name: `Activities.get_group!/2`
            scopes by organizer, so whoever mounted this screen is the organizer — and a
            broken tie's note/summary name them ("aheld picked X to break the tie"),
            matching the guest waiting copy that already names the human. --%>
      <.results_panel
        :if={@takeover == nil}
        group={@group}
        tally={@tally}
        outcome={@outcome}
        participants={@participants}
        avatar_caption="WHO'S VOTED"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
        organizer_username={@current_scope.user.username}
      >
        <:footer>
          <%!-- The one link back to `04 share`, and the reason this screen needs it: `/`
                routes a `:voting` group here, `04 share` is otherwise reachable only from
                `03 review`, and `03 review` is otherwise reachable only from `04 share`'s
                `‹`. That made the two a closed island — an organizer who shut the tab could
                never re-copy the link the whole product exists to hand out. `:voting` only:
                once the vote is closed there is nothing left to invite anyone to. It is
                also what "Nudge N friends" tells you to do, so it sits directly above it. --%>
          <%!-- **The screen's one tangerine forward action.** It was a bare underlined link
                measuring 320×18.8, and while a group is `:voting` with nobody in it a
                tangerine sweep of the whole page returned zero elements — the only
                button-shaped control on an organizer's first screen after publishing was
                the irreversible one. Handing out the link is the forward action here and
                "Close now" is the exit, so the design-system rule (tangerine exactly once,
                on the one forward action) settles the hierarchy. `Close now` stays the
                bordered secondary at its natural width in every state. --%>
          <%!-- Zero participants gets a sentence, not a control. Everything in the row
                below is either dead or wrong in that state: there is nobody to nudge, and
                the one thing the organizer should do — hand out the link — has a working
                control directly beneath this line.

                **Above the button, not below it.** It is the state that motivates the
                press, and printed underneath it was read *after* the decision it should
                have informed — and a bare sentence sandwiched between "Get the share link
                again" and "Close now" reads as a caption belonging to whichever of the two
                the eye lands on. State, then action, which is the order the `:completed`
                footer further down already uses. --%>
          <p
            :if={@group.status == :voting and @participants == []}
            id="results-nobody-yet"
            class="text-center text-[12.5px] leading-[1.4] text-muted"
          >
            Nobody has opened the link yet.
          </p>

          <.button
            :if={@group.status == :voting}
            variant="primary"
            navigate={~p"/groups/#{@group}/share"}
            id="results-share-again"
          >
            Get the share link again <span aria-hidden="true">→</span>
          </.button>

          <%!-- And the mirror image: everybody who joined has voted, so there is nobody to
                nudge either. This used to render the marker anyway, reading "Everyone has
                voted / ALL IN" — a status sentence inside a dashed box that cannot be
                pressed, with the only hint that it was an unbuilt *nudge* control in a
                hover `title`. `04 share` deleted its QR `title` in this same round on the
                argument that an explanation only a mouse can reach is not an explanation on
                a phone; the same argument applies here, so the `title` is gone with the
                control. --%>
          <p
            :if={
              @group.status == :voting and @participants != [] and waiting_count(@participants) == 0
            }
            id="results-all-voted"
            class="text-center text-[12.5px] leading-[1.4] text-muted"
          >
            Everyone who joined has voted.
          </p>

          <div :if={@group.status == :voting} class="flex gap-[9px]">
            <%!-- Hand-built rather than `<.button>`: the comp draws this flat — no shadow —
                  same as "Close now" beside it, and `<.button>`'s default variant always
                  adds `shadow-sticker-2`/`press-2`. --%>
            <%!-- **Drawn as unbuilt, because it is unbuilt.** This shipped fully enabled and
                  sticker-styled for a feature that does not exist: the `nudge` handler did
                  nothing but flash "There's no notification system yet". There is no
                  notification path at all — production's mailer falls back to
                  `Swoosh.Adapters.Logger` without `RESEND_API_KEY`, and nothing anywhere
                  messages a participant. The house convention for exactly this is already on
                  two screens: `QR` on `04 share` is `disabled` under a mono `Soon`, and the
                  `Bars` / `Movies` chips on `02 add options` are dashed and inert.

                  It renders **only when somebody is actually waiting**, so `Soon` is the one
                  thing the sub-label ever says and it always means the same thing: the
                  feature is unbuilt. Both zero-state variants — nobody joined, everybody
                  voted — are sentences above instead. --%>
            <button
              :if={waiting_count(@participants) > 0}
              type="button"
              disabled
              class="flex flex-1 flex-col items-center justify-center gap-0.5 rounded-2xl border-2 border-dashed border-ink/35 bg-white px-4 py-3 text-center text-muted disabled:cursor-not-allowed"
            >
              <span class="text-[13px] font-bold leading-[1.2]">{nudge_label(@participants)}</span>
              <span class="font-mono text-[8px] font-semibold uppercase tracking-[0.06em]">
                Soon
              </span>
            </button>
            <button
              type="button"
              phx-click="close_now"
              data-confirm="Close voting now? This can't be undone."
              class="rounded-2xl border-2 border-ink px-4 py-3.5 text-[14px] font-semibold text-ink-soft hover:bg-white active:bg-white"
            >
              Close now
            </button>
          </div>

          <%!-- The `:completed` cell used to render **nothing**: the slot had branches for
                `:voting` and `:cancelled` only, so an organizer opening a finished session
                had no control on the page at all — and with an outcome of `:no_consensus`
                or `:no_votes` not even the winner card's "Copy summary" existed to stand in
                for one. The three things an organizer of a finished session wants are: see
                the winner (the outcome section above, unchanged), share the result, and
                start the next one. --%>
          <div :if={@group.status == :completed} class="flex flex-col gap-2.5">
            <p
              id="results-finished-note"
              class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
            >
              <span class="text-[13px] font-bold text-ink">
                {finished_headline(@outcome)}
              </span>
              <span class="mt-1 block">
                {finished_note(@group, @outcome)} {finished_tail(@outcome)}
              </span>
            </p>

            <.button variant="primary" navigate={~p"/groups/new"} id="results-start-another">
              Start another session <span aria-hidden="true">→</span>
            </.button>
          </div>

          <div :if={@group.status == :cancelled} class="flex flex-col gap-2.5">
            <p class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-center text-sm text-muted">
              This session was cancelled, so no winner was picked. It cannot be reopened.
            </p>

            <.button variant="primary" navigate={~p"/groups/new"} id="results-start-another-cancelled">
              Start another session <span aria-hidden="true">→</span>
            </.button>
          </div>
        </:footer>
      </.results_panel>
    </Layouts.app>
    """
  end
end
