defmodule ConsensusWeb.JoinLive.Results do
  @moduledoc """
  Design frame `05b · same screen, after anyone votes` — `/join/:slug/results`.

  The participant's half of the shared `ConsensusWeb.ResultsComponents.results_panel/1`
  (see that module for everything the two `results` screens have in common). This
  LiveView is only the mount, the reload plumbing, and the footer/banner that are
  participant-only:

    * the mint **"Your votes are in."** confirmation banner once this participant has
      voted (`participant.voted_at` set). It said "Your ranking is in" until D-045.
      **Nothing in this app ranks anything** — `JoinLive.Ballot`'s own moduledoc says
      "there is no ranking anywhere in here" and `Consensus.Voting.Vote`'s says "there
      is deliberately no rank or weight column here" — and this was the single
      highest-stakes instance of that false verb, being the one screen that confirms a
      guest's only action. The wording echoes the button one screen earlier ("Send my
      votes"), so the confirmation names the thing that was pressed;
    * a footer that is **enumerated over every cell** rather than assembled from `:if`
      branches — see `footer_state/3`;
    * a **"Cast your vote"** link when this browser has not voted yet and the group
      is still open — not drawn on `05b` (which assumes a voter who already has), but
      needed for anyone who reaches `/results` first (a direct link, or the
      `:completed`/`:cancelled` redirect `ConsensusWeb.JoinAuth` sends a non-voter
      through).

  There is deliberately **no "Change my ranking"** button, which frame `05b` draws.
  D-036: the ballot is locked; there is no update path, so there is nothing here to wire
  up. Do not add one back.

  ## Why the footer enumerates every cell

  It used to be three `:if`s, and a group that was `:completed` in a browser that had
  never voted matched **none** of them, so the footer rendered completely empty: a
  latecomer who opened the link after voting closed saw an outcome and had no exit
  whatsoever. `footer_state/3` takes `{status, participation, saw_voting?}` and has one
  clause for every one of `{:voting, :completed, :cancelled} × {:voted, :joined,
  :stranger}`, with `{:completed, :stranger}` split in two by the third argument. Several
  cells collapse onto the same rendered footer; they are still written out one per line,
  including the ones that ignore `saw_voting?`, because the failure this replaces was a
  *missing* combination and a table cannot hide one.
  `test/consensus_web/live/join_live/results_test.exs` has a case per cell.

  The table does not cover the D-051 takeover states, and that is not a missing cell: an
  unresolved all-vetoed pool or dead heat on a `:completed` group replaces the whole
  panel — this footer included — with `ConsensusWeb.Endgame.AllVetoed` /
  `ConsensusWeb.Endgame.Tie`, which carry their own exits (here, the guest half: a
  waiting line naming the organizer and `Create your own →`). Every cell the takeovers
  do not intercept renders exactly as before.

  Enumerating the cells is not the same as getting each one right, and the same mistake has
  now been made twice in the same corner of the table. `{:completed, :joined}` first shipped
  pointing at `:closed_missed` — "Voting closed before you got here." — for a browser that
  holds a participant token, which can only be minted while the group is `:voting`. That
  reader was demonstrably here; their own avatar is on the screen, captioned "you". It has
  its own cell, `:closed_no_ballot`. `{:completed, :stranger}` then kept asserting the same
  thing to the *more* common arrival: a guest reading the tally without joining, whose page
  flipped from `:voting` to `:completed` in place while they watched the countdown run out.
  `saw_voting?`, captured at mount, is what tells that reader from a cold arrival. The
  lesson the table is for is to stop inferring *how* someone arrived from *that* the
  session ended.

  The `:voting` copy also no longer promises **nudging**. `avatar_caption` was
  `"ORGANIZER NUDGES"` and the footer said "Only `<organizer>` can nudge or close early" —
  rendered even on a `:completed` group, telling a voter the organizer could "close early"
  a vote that had already closed. `grep -rn 'nudge' lib/` finds no nudge path: the
  organizer's own control for it is disabled and labelled `Soon`, and `/about` says in as
  many words that this app sends no notifications. A caption instructing the reader to
  expect an action nothing performs is the plan's confusion class 1.

  `@group` and `@participant` arrive already assigned by `ConsensusWeb.JoinAuth`'s
  `:resolve_participant` on_mount hook, which also applies the `/join`-tree's status
  guards (a `:draft` group never reaches here; `:completed`/`:cancelled` land here
  directly rather than looping through `/join/:slug`). `@participant` is `nil` for a
  visitor this browser session has no token for.

  ## Live updates — the acceptance bar

  Same as `ConsensusWeb.GroupLive.Results`: `Consensus.Voting.subscribe/1` on mount, a
  30s `:tick` for the countdown, and a reload — re-fetching the group by slug (status
  can change), the tally, and this browser's own participant row — on every message
  the topic can carry. A guest sitting on this screen sees the tally move the instant
  anyone else submits a ballot, with no reload.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Voting
  alias ConsensusWeb.Endgame

  import ConsensusWeb.EndgameComponents, only: [takeover: 2]
  import ConsensusWeb.ResultsComponents

  @tick_interval :timer.seconds(30)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    group = socket.assigns.group

    if connected?(socket) do
      Voting.subscribe(group.id)
      Process.send_after(self(), :tick, @tick_interval)
    end

    organizer = Accounts.get_user!(group.organizer_id)

    {:ok,
     socket
     |> assign(:page_title, "Results · #{group.title}")
     # The card names the vote but never the tally, for the reason
     # `ConsensusWeb.SocialPreview` gives for leaving the deadline out of `06`'s: a chat
     # client caches an unfurl for hours, and a leader that changes with the next ballot
     # would be pinned wrong in that cache with no way to correct it. The page itself is
     # live over PubSub; the card is not, and must not pretend to be.
     |> assign(:og_title, "#{group.title} · results")
     |> assign(
       :og_description,
       "#{organizer.username} called this vote on Consensus. Open the link to see where it landed."
     )
     |> assign(:now, DateTime.utc_now())
     |> assign(:slug, slug)
     |> assign(:organizer_username, organizer.username)
     # Did *this* mount arrive while the vote was still open? Set once and never cleared:
     # the LiveView re-renders in place when the deadline passes, so a reader who was
     # sitting here watching the countdown must not be told they arrived too late. See
     # `footer_state/3`.
     |> assign(:saw_voting?, group.status == :voting)
     |> assign_clock()
     |> load_tally()}
  end

  # The violet header counts *down* ("2d 4h"); the footer needs the wall-clock instant,
  # because "when does this close" is one of the three things a voter who has just
  # submitted actually wants and a relative duration does not answer it.
  #
  # The reading is in **this guest's** own zone, not the organizer's — a voter in
  # California opening a Philadelphia dinner's link should read 4:00 PM for a 7:00 PM
  # Eastern close, because the question the line answers is "by when must I vote".
  # That was already true under offset arithmetic and stays true under zone rules
  # (D-055); what changed is that it is now also right across a DST boundary.
  defp assign_clock(socket) do
    params = if connected?(socket), do: get_connect_params(socket)
    assign(socket, :clock, Deadlines.clock_from_params(params))
  end

  @impl true
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

  # `:draft` is reachable under an open tab now: `Consensus.Activities.reopen_group/2`
  # (the All Vetoed takeover's "Add new options" exit) puts the group back in the wizard
  # and broadcasts. The `/join` tree never renders a draft (`ConsensusWeb.JoinAuth`
  # halts them at mount), so this reload mirrors that guard instead of crashing in
  # `results_header/1` — and the copy tells the guest the one thing that matters: the
  # link in their chat is not dead, it works again the moment round 2 is published
  # (participants and tokens survive a reopen by design).
  defp reload(socket) do
    case Activities.get_group_by_slug(socket.assigns.slug) do
      nil ->
        socket

      %{status: :draft} ->
        socket
        |> put_flash(
          :info,
          "#{socket.assigns.organizer_username} reopened the option pool, so voting is " <>
            "paused. Keep your link — it works again the moment round 2 is published."
        )
        |> push_navigate(to: ~p"/")

      group ->
        socket
        |> assign(:group, group)
        |> refresh_participant()
        |> load_tally()
    end
  end

  defp refresh_participant(%{assigns: %{participant: nil}} = socket), do: socket

  defp refresh_participant(%{assigns: %{participant: participant}} = socket) do
    # A second tab could have cast this same participant's ballot since we mounted;
    # re-reading by token (rather than trusting the struct in hand) is the same
    # "don't trust it, re-check" idiom `Consensus.Voting.get_participant_by_token/1`'s
    # docs call for.
    assign(socket, :participant, Voting.get_participant_by_token(participant.token))
  end

  # `presentable_tally/2`: see its docs. A cancelled session keeps its `leader?` flags and
  # `tally_bar/1` paints a ★ from them, so this screen showed a starred front-runner under
  # **Final tally** while the panel above it said the session was cancelled before a winner
  # was chosen.
  # `Voting.outcome/2`, not `outcome/1`: only the status-aware arity answers
  # `{:tie, tied_rows}` for a completed, unresolved dead heat — the flags-only reading
  # reports the position tie-break as a `{:winner, row}` and this screen then announces
  # an unqualified win over a draw to the very people whose votes drew.
  defp load_tally(socket) do
    group = socket.assigns.group
    tally = presentable_tally(group, Voting.tally(group))
    outcome = Voting.outcome(group, tally)

    socket
    |> assign(:tally, tally)
    |> assign(:outcome, outcome)
    |> assign(:takeover, takeover(group, outcome))
    |> assign(:participants, Voting.participants(group))
  end

  defp voted?(nil), do: false
  defp voted?(%{voted_at: nil}), do: false
  defp voted?(%{voted_at: %DateTime{}}), do: true

  # -- the footer table ---------------------------------------------------------------

  # What this browser is, to this group. `nil` means no participant token in the session
  # for this group: a stranger who opened the link and went straight to `/results`.
  defp participation(nil), do: :stranger
  defp participation(%{voted_at: nil}), do: :joined
  defp participation(%{voted_at: %DateTime{}}), do: :voted

  # Every cell of {status} × {participation}, one per line, plus the one cell that also
  # needs to know whether this mount saw the vote open. See the moduledoc for why this is a
  # table and not a stack of `:if`s. Adding a fourth group status or a fourth participation
  # value now fails to match here — loudly, in a test — instead of silently rendering an
  # empty footer. The third argument is written out on every clause rather than delegated
  # to a catch-all, so the table still cannot hide a missing combination.
  defp footer_state(:voting, :voted, _saw_voting?), do: :watching
  defp footer_state(:voting, :joined, _saw_voting?), do: :can_vote
  defp footer_state(:voting, :stranger, _saw_voting?), do: :can_vote
  defp footer_state(:completed, :voted, _saw_voting?), do: :closed_voted
  # `:joined` means this browser holds a participant token with `voted_at` nil, and a
  # participant row can only be created while the group is `:voting` — so this reader was
  # provably here before it closed, and their own avatar is on the screen above captioned
  # "you". Telling them "voting closed before you got here" is flatly false, and it was
  # pinned by a test. Its own cell now.
  defp footer_state(:completed, :joined, _saw_voting?), do: :closed_no_ballot
  # The same lesson one cell over, and this is the **more** common arrival: a guest who
  # opens the link and reads the tally without joining. Measured on one never-reloaded
  # page, two screenshots 20 seconds apart: at 11:03:24Z the footer offered "Cast your
  # vote" over "Closes Today 7:03 AM — voting locks then, on its own", the deadline passed
  # at 11:03:32Z, the LiveView flipped in place, and the same page then read "Voting closed
  # **before you got here**" to a reader who had been watching the countdown do it. The
  # substance below is identical either way; only the first sentence differs.
  defp footer_state(:completed, :stranger, true), do: :closed_just_now
  defp footer_state(:completed, :stranger, false), do: :closed_missed
  defp footer_state(:cancelled, :voted, _saw_voting?), do: :cancelled
  defp footer_state(:cancelled, :joined, _saw_voting?), do: :cancelled
  defp footer_state(:cancelled, :stranger, _saw_voting?), do: :cancelled

  # The twin of `ConsensusWeb.GroupLive.Results`' own `closed_early?/1`, which exists there
  # for exactly this failure and was not grepped for when this screen grew a "just closed"
  # cell. `:completed` is reached two ways — the lazy deadline sweep in
  # `Consensus.Activities.maybe_complete_group/1`, which stamps `completed_at` at or after
  # `deadline_at`, and the organizer's **Close now** button, which stamps it earlier.
  defp closed_early?(%{completed_at: %DateTime{} = at, deadline_at: %DateTime{} = deadline}),
    do: DateTime.compare(at, deadline) == :lt

  defp closed_early?(_group), do: false

  # Which treatment `#results-start-your-own` gets. The design system allows exactly one
  # resting tangerine per screen, on the one forward action; `:can_vote` is the only cell
  # that already has one ("Cast your vote"), and in that cell the ballot must stay the
  # louder of the two. See the call site.
  defp own_cta_variant(:can_vote), do: nil
  defp own_cta_variant(_footer_state), do: "primary"

  # The header context names the takeover state in its design's accent — tangerine
  # "ALL VETOED", violet "DEAD HEAT". The `:public` header renders the slot only when a
  # context is passed, and this screen's pill is already `false`, so the slot has the
  # right edge to itself.
  defp takeover_context(:all_vetoed), do: "ALL VETOED"
  defp takeover_context(:tie), do: "DEAD HEAT"
  defp takeover_context(nil), do: nil

  defp takeover_context_class(:all_vetoed), do: "text-tangerine"
  defp takeover_context_class(:tie), do: "text-violet"
  defp takeover_context_class(nil), do: nil

  # The tied-at-top rows the tie takeover renders; only read under
  # `:if={@takeover == :tie}`, whose trigger only answers for a `{:tie, rows}` outcome.
  defp tie_rows({:tie, rows}), do: rows
  defp tie_rows(_outcome), do: []

  defp closes_at_text(%{deadline_at: nil}, _now, _clock), do: nil

  defp closes_at_text(%{deadline_at: at}, now, clock),
    do: Deadlines.label_for(at, now, clock)

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :footer_state,
        footer_state(
          assigns.group.status,
          participation(assigns.participant),
          assigns.saw_voting?
        )
      )
      |> assign(:closes_at, closes_at_text(assigns.group, assigns.now, assigns.clock))

    ~H"""
    <%!-- `:public` — this is still the `/join` tree, reached by someone who may have no
          account. The screen's own status lives in the violet countdown block below, so
          there is nothing the `:app` context slot would add. --%>
    <%!-- The context slot names the takeover state (the design's tangerine "ALL VETOED");
          the `:public` header renders it only when a context is passed, and this screen's
          pill is already `false`, so the slot has the right edge to itself. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      variant={:public}
      pill={false}
      context={takeover_context(@takeover)}
      context_class={takeover_context_class(@takeover)}
    >
      <%!-- The guest's half of the All Vetoed takeover: same scene, headline and carnage
            as the organizer's, a waiting line naming the organizer (the only person who
            can fix it), the standing `Create your own →` exit — and never the organizer's
            two write buttons. Replaces the whole panel, banner and footer table included;
            the PubSub reload flips it back the moment the organizer acts. --%>
      <.live_component
        :if={@takeover == :all_vetoed}
        module={Endgame.AllVetoed}
        id="endgame-all-vetoed"
        group={@group}
        tally={@tally}
        role={:guest}
        organizer_username={@organizer_username}
      />
      <%!-- The guest's half of the Tie takeover: the same tug-of-war scene and TIED FOR
            FIRST list as the organizer's, with no tap affordance and no buttons — a
            waiting line naming the organizer (the only one who can break it) and the
            standing `Create your own →` exit. Replaces the whole panel, banner and
            footer table included; the PubSub reload flips it to the winner ending the
            moment the organizer locks a pick in. --%>
      <.live_component
        :if={@takeover == :tie}
        module={Endgame.Tie}
        id="endgame-tie"
        group={@group}
        rows={tie_rows(@outcome)}
        role={:guest}
        organizer_username={@organizer_username}
      />
      <%!-- `WHO'S VOTED`, not `ORGANIZER NUDGES`. The organizer's identical component was
            corrected for exactly this and the participant's half was left behind: there is
            no nudge path in `lib/` at all, and `/about` says this app sends no
            notifications. See the moduledoc. --%>
      <.results_panel
        :if={@takeover == nil}
        group={@group}
        tally={@tally}
        outcome={@outcome}
        participants={@participants}
        current_participant_id={@participant && @participant.id}
        avatar_caption="WHO'S VOTED"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
        organizer_username={@organizer_username}
      >
        <:banner :if={voted?(@participant)}>
          <.sticker_card tone={:mint} depth={2} radius={:sm} class="flex items-center gap-2.5 p-3">
            <span
              class="grid size-[22px] shrink-0 place-items-center rounded-full bg-ink text-white"
              aria-hidden="true"
            >
              ✓
            </span>
            <span class="text-sm font-bold text-ink">Your votes are in.</span>
          </.sticker_card>
        </:banner>

        <:footer>
          <%!-- The single worst dead end in the app was here: a voter who had just
                submitted got a banner, one static sentence about nudging, and no control of
                any kind — at the end of the flow the whole product exists for. What they
                honestly want is three things, so the copy says all three: this page is
                live, it closes by itself at a named time, and there is a door out. --%>
          <div
            :if={@footer_state == :watching}
            id="results-watching"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">Nothing more to do — you can close this.</p>
            <p class="mt-1">
              The tally above is live: it moves on its own each time somebody else sends
              theirs, with no refresh.
            </p>
            <%!-- `@closes_at` is `Deadlines.label_for/3`, which already *starts* with the
                  word "Closes" — the first cut of this read "Voting closes Closes Tomorrow
                  5:00 PM", caught on the walk. It leads the sentence rather than being
                  embedded in one. --%>
            <%!-- Unconditional. There used to be an `else` branch here reading
                  "{organizer} closes the voting; there is no deadline on this one", which
                  can never render: `Activities.publish_group/2` refuses with
                  `{:error, :no_deadline}` when `deadline_at` is nil, so no group in
                  `:voting`, `:completed` or `:cancelled` has one — and a `:draft` group
                  never reaches this LiveView (`JoinAuth` halts it). It also contradicted
                  `03 review`'s promise that voting closes itself at the deadline. Copy
                  maintained for a state the schema forbids is copy nobody will ever check
                  again. --%>
            <%!-- Keeps the true half of what the old "Only {organizer} can nudge or close
                  early" said. Nudging does not exist; closing early does — `Close now` is
                  rendered on the organizer's `/groups/:id/results` for **every** `:voting`
                  group — so a line reading "nobody has to press anything" implied a fixed
                  close time and set a voter up to find the session over three hours early,
                  which is the same class of surprise this screen exists to remove. --%>
            <p :if={@closes_at} class="mt-1">
              {@closes_at}, and the winner is picked then without anyone pressing anything. {@organizer_username} can also close it early.
            </p>
          </div>

          <.link
            :if={@footer_state == :can_vote}
            navigate={~p"/join/#{@group.slug}/vote"}
            class="block rounded-2xl border-2 border-ink bg-tangerine p-4 text-center font-bold text-white shadow-sticker-4 press-4"
          >
            Cast your vote
          </.link>

          <%!-- Said once. `Deadlines.label_for/3` already returns a full clause starting
                "Closes …", so ", by itself" stranded the adverbial from its verb and the
                tail after the em dash ("voting locks at the deadline") restated the fact the
                first half had just given. --%>
          <p
            :if={@footer_state == :can_vote && @closes_at}
            class="text-center text-[11.5px] leading-[1.35] text-muted"
          >
            {@closes_at} — voting locks then, on its own.
          </p>

          <div
            :if={@footer_state == :closed_voted}
            id="results-closed-voted"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">Voting is closed.</p>
            <p class="mt-1">
              This is the final result — your votes are counted in it. Nothing here changes
              from now on.
            </p>
          </div>

          <%!-- Joined, never sent a ballot, and the vote has since closed. Split out of
                `:closed_missed`, whose "before you got here" is false for anyone holding a
                participant token — they got here, they just did not finish. --%>
          <div
            :if={@footer_state == :closed_no_ballot}
            id="results-closed-no-ballot"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">Voting closed before your votes went in.</p>
            <p class="mt-1">
              You opened the ballot but never sent it, so nothing of yours is counted below.
              There is no way to add a vote to a session that has finished — not even for {@organizer_username}.
            </p>
          </div>

          <%!-- The same reader, on the same never-reloaded page, on the other side of the
                deadline. `@saw_voting?` is set at mount and never cleared, so this is the
                one that renders when the countdown ran out in front of them — the LiveView
                flips the whole screen in place and the old copy then asserted they had
                arrived too late. Everything after the first sentence is identical, because
                everything after the first sentence is true of both. --%>
          <div
            :if={@footer_state == :closed_just_now}
            id="results-closed-just-now"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">Voting just closed.</p>
            <%!-- Split on *how* it ended, not only on that it did. `saw_voting?` records
                  that the group was `:voting` at mount and nothing more, so the
                  deadline sentence was asserted verbatim to a reader whose session the
                  organizer had closed by hand with a day left on the countdown. This is
                  the same `closed_early?/1` test — and the same mistake — that
                  `ConsensusWeb.GroupLive.Results` already carries a comment about, on the
                  organizer's own half of this screen. --%>
            <p class="mt-1">
              <%= if closed_early?(@group) do %>
                {@organizer_username} closed it while you were on this page, so this is the
                final result.
              <% else %>
                The deadline passed while you were on this page, so this is the final result.
              <% end %>
              There is no way to add a vote to a session that has finished — not even for {@organizer_username}.
            </p>
          </div>

          <%!-- The cell that used to render **nothing at all**: a `:completed` group in a
                browser with no participant token matched none of the three old `:if`s, so a
                latecomer saw an outcome and had no exit. A **cold** arrival only now — see
                `:closed_just_now` above. --%>
          <div
            :if={@footer_state == :closed_missed}
            id="results-closed-missed"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">Voting closed before you got here.</p>
            <p class="mt-1">
              This is the final result. There is no way to add a vote to a session that has
              finished — not even for {@organizer_username}.
            </p>
          </div>

          <div
            :if={@footer_state == :cancelled}
            id="results-cancelled"
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12px] leading-[1.45] text-ink-soft"
          >
            <p class="text-[13px] font-bold text-ink">This session was cancelled.</p>
            <p class="mt-1">
              {@organizer_username} called it off, so no winner was picked. If that was a
              mistake, they can start a new one — this session cannot be reopened.
            </p>
          </div>

          <%!-- Rendered in **every** cell, which is the point: whatever combination of
                status and participation a visitor arrives in, there is a labelled way off
                this screen.

                It is now the **only** `Create your own →` on this screen. It shared both
                its destination (`/`) and, since the last pass, its wording with the
                header's yellow pill — two controls, one label, one path, on a screen whose
                only two controls those were, which is confusion class 5 exactly as the
                plan defines it. Matching the wording was the right half of that fix and
                keeping both was the wrong half. The body's copy is the one that survives:
                the pill is 10.5px of chrome in the top corner and reads as furniture,
                while this is where a guest who has just finished is actually looking.
                `pill={false}` on `Layouts.app` above; the pill stays on `/join/:slug` and
                `/join/:slug/vote`, whose bodies carry no such link. --%>
          <%!-- **A real button, because this is the guest's forward action.** It was a bare
                12.5px violet text link with no border, no fill and no shadow, sitting at
                document y=1168 in a 900px viewport — 268px below the fold on the terminal
                screen of the flow this product exists for, and the screen the PRD's "guest
                drop-off under 5%" is measured on. The reachability half is
                `.results-actions` in `ResultsComponents.results_panel/1`; this is the
                treatment half.

                Tangerine in every cell **except** `:can_vote`, which already spends the
                screen's one forward action on "Cast your vote" directly above — a guest who
                has not voted yet should not be offered a louder door out than the ballot.
                Everywhere else there is nothing else to press and this is it. --%>
          <.button
            navigate={~p"/"}
            id="results-start-your-own"
            variant={own_cta_variant(@footer_state)}
            class="w-full"
          >
            Create your own <span aria-hidden="true">→</span>
          </.button>
        </:footer>
      </.results_panel>
    </Layouts.app>
    """
  end
end
