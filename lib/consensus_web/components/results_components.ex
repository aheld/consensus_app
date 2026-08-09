defmodule ConsensusWeb.ResultsComponents do
  @moduledoc """
  The shared body of design frames `05` (live results, organizer) and `05b` (live
  results, participant) — see `docs/design/screens/1a-6-05-live-results-organizer.html`
  and `1a-7-05b-same-screen-after-anyone-votes.html`, and `docs/plans/voting-loop.md`.

  One function component, `results_panel/1`, rendered by two thin callers:
  `ConsensusWeb.GroupLive.Results` (`/groups/:id/results`, the organizer) and
  `ConsensusWeb.JoinLive.Results` (`/join/:slug/results`, a participant). The two
  screens share everything except the footer — **Close now** for the organizer, the
  locked "Your votes are in." state for a participant — so the footer is the one
  slot a caller must fill; everything above it (header, avatar row, the outcome
  section, the tally, the anonymity caption) is drawn here from plain data so neither
  caller can render it differently by accident.

  ## Anonymity (D-035)

  This module never receives, and could not render, who approved what — `tally/1`
  (`Consensus.Voting.tally/1`) returns totals only, and `participants/1` returns
  participation, never choices. The caption below the tally states that rule
  unconditionally, matching the review screen's card (D-035) rather than reading a
  `group.anonymous` flag that nothing in `Consensus.Voting` acts on.

  **It states it about the tally and nothing else**, and that is a correction, not a
  nicety (D-049). It used to read "Anonymous session — totals only, no names." on a page
  whose avatar row half a screen above carries every participant's typed name in a `title`
  and an `sr-only` span, readable by anyone holding the share link with no cookie at all.
  Participation is public here and choices are secret; a caption that generalises the
  second half over the whole screen contradicts the first.

  ## The completed state is new, not drawn

  Frames `05`/`05b` only ever show a group still `:voting`. Neither comp draws what
  happens once a group is `:completed` or `:cancelled` — that is this module's own
  extension, built to satisfy PRD product invariant 5 (the session ends in an action:
  a winner, a booking CTA, a runner-up failsafe, a paste-back-to-chat summary) and
  `Consensus.Voting.outcome/1`'s four-way answer (`{:winner, row}`, `{:leader, row}`,
  `:no_consensus`, `:no_votes`). `{:leader, _}` cannot reach a completed group in
  practice (`outcome/1` reports `:winner` once `Consensus.Voting.tally/1`'s `winner?`
  flags flip, which only happens after completion) — the private `outcome_section/1`
  clause for it exists only so a caller that somehow reaches it renders nothing
  instead of crashing.

  Q-5 and Q-7 in `docs/open-questions.md` are still open: there is no real booking API
  and no delivery channel for a winner notification. What is built here is the
  realistic fallback both note — the winner's own `source_url` (whatever link the
  organizer pasted or typed when adding it) as the "View" action, and a copy-to-
  clipboard summary string for the organizer or a participant to paste into the group
  chat by hand. Both degrade honestly to nothing when there is no link to show,
  never to a fabricated one.
  """

  use Phoenix.Component

  import ConsensusWeb.Sticker

  @doc """
  `Consensus.Voting.tally/1`'s rows as a finished screen must render them.

  A **cancelled** group keeps its `leader?` flags: `tally/1` gates only `winner?` on
  `status == :completed`, and `Sticker.tally_bar/1` paints its tangerine ★ from
  `leader?`. So both results screens rendered a starred front-runner under a **Final
  tally** heading on a session that says, twice on the same screen, that it was
  cancelled before a winner was chosen and cannot be reopened. A star is the one glyph on
  the page that means "this is the answer"; on a cancelled session there is no answer.

  Applied by both callers *before* `Consensus.Voting.outcome/1`, so the outcome derived
  from these rows is `:no_consensus`/`:no_votes` rather than `{:leader, row}` — neither is
  rendered for a cancelled group (`outcome_section/1` matches on the status first), and
  neither can be mistaken for a result. Everything else about the rows is untouched: the
  approvals, the vetoes and the bars are the real numbers, because what people voted is
  still true; only the crown comes off.
  """
  def presentable_tally(%{status: :cancelled}, tally),
    do: Enum.map(tally, &%{&1 | leader?: false, winner?: false})

  def presentable_tally(_group, tally), do: tally

  @doc """
  True when two or more surviving options share the highest approval count.

  Public because the *callers* have to say the same thing this module's winner card says.
  `ConsensusWeb.GroupLive.Results` renders a footer headline under the panel, and
  `finished_headline/2` had no tie branch — so on a dead heat the card at document y=263
  read **Tied at the top** and explained that pool position, not votes, settled it, while
  the footer at y=1030 read "Voting is closed and you have a winner." One scroll of one
  page, opposite claims.

  The tie itself is presentation-only, exactly as `mark_leaders/2` is: `Consensus.Voting`
  is untouched, `tally/1` still breaks the tie by `activity.position` and one option still
  wins. What this exposes is the *fact of* the dead heat, so nothing above the context can
  announce an unqualified win over one.
  """
  def tie_at_top?(tally), do: length(tied_at_top(tally)) > 1

  @doc """
  The shared results body: header, an optional banner, the avatar row, the outcome
  section (completed/cancelled groups only), the tally, the anonymity caption, and a
  caller-supplied footer.

  `group` needs `:activities` preloaded (every caller already has this —
  `Consensus.Activities.get_group!/2` and `get_group_by_slug/1` both preload it).
  `tally` and `outcome` are `Consensus.Voting.tally/1` and `Consensus.Voting.outcome/1`
  applied to that same `group`, computed by the caller so this component does no
  reads of its own. `participants` is `Consensus.Voting.participants/1`'s shape,
  passed straight through to `Sticker.participant_avatar_row/1`.

  `countdown_text` is only shown while `group.status == :voting` — reuse
  `Consensus.Deadlines.countdown/2` to produce it, same as `Sticker.countdown_header/1`
  itself asks for. It is ignored for a finished group, which draws its own header.

  ## Examples

      <.results_panel
        group={@group}
        tally={@tally}
        outcome={@outcome}
        participants={@participants}
        avatar_caption="WHO'S VOTED"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
      >
        <:footer>
          <.button variant="primary" navigate={~p"/groups/new"}>Start another session</.button>
        </:footer>
      </.results_panel>

  There is no `nudge` anywhere in `lib/` — no handler, no control, no notification
  channel — so an example wiring a `phx-click="nudge"` under a `TAP TO NUDGE` caption
  documented a promise D-045 deleted for being unkeepable. The footer above is copied
  from `ConsensusWeb.GroupLive.Results`' live `:completed` branch.
  """
  attr :group, :map, required: true
  attr :tally, :list, required: true
  attr :outcome, :any, required: true
  attr :participants, :list, required: true
  attr :current_participant_id, :integer, default: nil
  attr :avatar_caption, :string, default: nil
  attr :countdown_text, :string, default: nil

  slot :banner, doc: "e.g. the participant's mint \"Your votes are in.\" confirmation"
  slot :footer, required: true

  def results_panel(assigns) do
    assigns = assign(assigns, :tally_rows, mark_leaders(assigns.group, assigns.tally))

    ~H"""
    <%!-- `min-h-0`, not `overflow-hidden`. Nothing bounds this panel — neither results
          LiveView passes `fill_viewport` — so the clip did nothing except make this box a
          scrollport, which is precisely what stops `position: sticky` working on the footer
          slot below (a sticky element sticks inside its nearest scrollport, and this one's
          bottom edge is off-screen). `min-h-0` keeps the panel correct as a flex child if a
          bounded column is ever added, without creating one. --%>
    <div class="flex min-h-0 flex-1 flex-col">
      <.results_header group={@group} countdown_text={@countdown_text} />

      <div class="flex flex-1 flex-col gap-3.5 overflow-y-auto px-5 py-4">
        {render_slot(@banner)}

        <%!-- `waiting_label` on a finished session: "waiting" under a header reading
              **Voting closed** captions a person who never sent a ballot as though
              something is still expected of them, on the same screen whose footer says
              "There is no way to add a vote to a session that has finished." Nothing is
              waiting; they missed it. --%>
        <.participant_avatar_row
          participants={@participants}
          current_participant_id={@current_participant_id}
          caption={@avatar_caption}
          waiting_label={if @group.status != :voting, do: "missed it"}
        />

        <.outcome_section
          :if={@group.status in [:completed, :cancelled]}
          group={@group}
          outcome={@outcome}
          tally={@tally}
        />

        <div class="flex flex-col gap-[11px]">
          <%!-- The ★ means two different things one screen apart and only one of them is
                labelled. While `:voting` it is `row.leader?` — who is ahead right now, on a
                page that stays open for another day and a half — and once the organizer
                closes, the identical glyph reappears inside the green **We have a winner**
                card as `row.winner?`. A first-time voter who has cast the only ballot sees
                "1/1 voted" and a starred row and reads the session as decided. The star is
                kept (who is ahead is the whole point of a running tally) and captioned, so
                the reader is told which of the two they are looking at. --%>
          <div class="flex items-baseline justify-between gap-2">
            <span class="text-sm font-bold text-ink">{tally_heading(@group)}</span>
            <span
              :if={star_legend(@group, @tally_rows)}
              id="tally-star-legend"
              class="shrink-0 font-mono text-[10.5px] text-muted"
            >
              <span class="text-violet">★</span> {star_legend(@group, @tally_rows)}
            </span>
          </div>
          <div class="flex flex-col gap-2.5">
            <.tally_bar :for={row <- @tally_rows} row={row} />
          </div>
          <%!-- **Scoped to the tally, because "no names" was false about the page it sits
                on** (D-049). This screen publishes participants' names: measured on one
                group, the element carrying `title="Sam"` at document y=170 and the words
                "Anonymous session — totals only, no names." at y=969, in the same render.
                A screen-reader user heard "Sam, voted" and then, forty rows later, that
                there are no names.

                The behaviour is right and settled — participation is public, choices are
                secret (D-035) — so the caption now claims only what the block it captions
                does. It is directly under `tally_bar/1`'s rows and "here" is those rows. --%>
          <p class="text-[11px]/[1.4] text-muted">
            Totals only — nothing here shows who picked what.
          </p>
        </div>
      </div>

      <%!-- `.results-actions` + `bg-surface`: this block holds the only controls either
            results screen has, and it was below the fold on both. Measured at 420×900 on a
            completed session, `#results-start-your-own` — the guest's one forward action,
            on the terminal screen of the flow — sat at document y=971.3. The rule and its
            reasoning are in `assets/css/app.css`, next to the ballot's. `bg-surface` is
            `Layouts.app`'s default background, which both results screens take, and it is
            what stops the tally showing through while this floats. --%>
      <div class="results-actions flex flex-col gap-2.5 bg-surface px-5 pb-5 pt-3">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  defp tally_heading(%{status: :voting}), do: "Running tally"
  defp tally_heading(_group), do: "Final tally"

  # `Consensus.Voting.tally/1` gives `leader?` to **exactly one** survivor, and on a tie it
  # picks by `activity.position` — the order the organizer happened to drag the pool into on
  # `03 review`, which no voter has ever seen and cannot reason about. So a live tally
  # reading "Alpha 1 ★ / Beta 1 / Gamma 0" told a reader that Alpha was ahead of Beta when
  # nothing on the screen, and nothing they could act on, made that true.
  #
  # The star is a *statement about the count*, so it goes to everyone who shares the top
  # count, and the legend beside the heading says which case this is. This is deliberately
  # presentation-only: `tally/1`'s deterministic single leader is still what `outcome/1`
  # reads and still what the winner card announces.
  #
  # **This used to be `:voting`-only, and that was the bug.** The reasoning on file was
  # that starring several rows on a `:completed` group would contradict the green **We have
  # a winner** card above — which is exactly backwards: it is the *card* that needs the
  # contradiction shown, not hidden. Reproduced on a real session: one ballot picking two
  # of five options, the page renders both rows starred under `★ TIED FOR THE LEAD` for the
  # whole vote, and the instant the organizer presses **Close now** the same never-reloaded
  # screen reads "We have a winner — Noodle Bar", demotes Pizza Corner to **Runner-up** at
  # the identical count of 1, and drops the legend. Nothing changed except the status. The
  # winner reverted to `tally/1`'s tie-break — first by `activity.position`, the order the
  # organizer happened to drag the pool into on `03 review`, which no voter has ever
  # seen — and the screen offered "Copy summary for the group chat" under it.
  #
  # Whether a tie should get a runoff is a genuine open product question
  # (`docs/open-questions.md`), and this does not answer it: `tally/1` is untouched and one
  # option still wins. What it stops doing is *asserting* an unqualified win over a dead
  # heat. Every tied row keeps its star, the legend says `TIED AT THE TOP`, and
  # `outcome_section/1` captions the card with the count and the reason that one of them
  # took it.
  defp mark_leaders(%{status: :cancelled}, tally), do: tally

  defp mark_leaders(_group, tally) do
    leading = leading_ids(tally)
    Enum.map(tally, &%{&1 | leader?: MapSet.member?(leading, &1.activity.id)})
  end

  defp leading_ids(tally) do
    tally |> tied_at_top() |> MapSet.new(& &1.activity.id)
  end

  # The survivors sharing the highest approval count, or `[]` when nothing has an approval
  # (an untouched pool has no leader — the same rule `tally/1` applies).
  defp tied_at_top(tally) do
    survivors = Enum.reject(tally, & &1.vetoed?)
    highest = survivors |> Enum.map(& &1.approvals) |> Enum.max(fn -> 0 end)

    if highest > 0, do: Enum.filter(survivors, &(&1.approvals == highest)), else: []
  end

  # `nil` renders no legend at all. A finished session with one clear winner does not need
  # one — the green card directly above says so in words — but a finished session with a
  # tie very much does, and it is the same glyph in both cases.
  defp star_legend(%{status: :cancelled}, _rows), do: nil

  defp star_legend(%{status: :voting}, rows) do
    cond do
      Enum.count(rows, & &1.leader?) > 1 -> "TIED FOR THE LEAD"
      Enum.any?(rows, & &1.leader?) -> "LEADING RIGHT NOW"
      true -> nil
    end
  end

  defp star_legend(_group, rows) do
    if Enum.count(rows, & &1.leader?) > 1, do: "TIED AT THE TOP"
  end

  # -- header: the violet block. Frame 05/05b's own header while `:voting`; a
  # deliberately similar but not-drawn-anywhere variant once the group has finished
  # (see moduledoc "The completed state is new, not drawn").
  defp results_header(%{group: %{status: :voting}} = assigns) do
    ~H"""
    <.countdown_header title={@group.title} countdown_text={@countdown_text || "—"} />
    """
  end

  defp results_header(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 border-b-2 border-ink bg-violet px-5 pb-4 pt-3 text-white">
      <div class="flex items-baseline justify-between gap-2">
        <span class="truncate text-[12px] font-semibold opacity-85">{@group.title}</span>
        <span class="shrink-0 font-mono text-[10.5px] font-medium opacity-80">
          {header_status_label(@group)}
        </span>
      </div>
      <div class="font-mono text-[22px] font-medium leading-none tracking-[-0.02em]">
        {header_closed_text(@group)}
      </div>
    </div>
    """
  end

  defp header_status_label(%{status: :cancelled}), do: "CANCELLED"
  defp header_status_label(%{status: :completed}), do: "RESULTS"

  defp header_closed_text(%{status: :cancelled}), do: "Session cancelled"
  defp header_closed_text(%{status: :completed}), do: "Voting closed"

  # -- the outcome section: only rendered for a finished group (see :if on the call
  # site above). A `:cancelled` group short-circuits every outcome — the organizer
  # called it off, so nothing below is worth announcing as a "result".
  defp outcome_section(%{group: %{status: :cancelled}} = assigns) do
    ~H"""
    <.sticker_card tone={:muted} class="p-4">
      <p class="text-sm text-muted">
        This session was cancelled before a winner was chosen.
      </p>
    </.sticker_card>
    """
  end

  defp outcome_section(%{outcome: {:winner, row}} = assigns) do
    tied = tied_at_top(assigns.tally)

    assigns =
      assigns
      |> assign(:row, row)
      |> assign(:runner_up, runner_up(assigns.tally, row))
      |> assign(:summary, winner_summary(assigns.group, row, tied))
      |> assign(:tied, if(length(tied) > 1, do: tied))

    ~H"""
    <.sticker_card tone={:mint} depth={2} class="flex flex-col gap-3 p-4">
      <div class="flex items-center gap-2">
        <%!-- `bg-violet`, not `bg-tangerine`. Measured on a completed session with one
              vetoed option, three tangerine elements painted on one screen: this badge, the
              tally's `Vetoed` pill, and `#results-start-another` — which is the only one of
              the three a reader can press, and therefore the only one the design system's
              "tangerine exactly once, on the forward action" rule is about. This badge is a
              statement of outcome sitting on a mint sticker under a bold headline that says
              "We have a winner" in words; violet makes it the same accent as the `★` on the
              winning tally row a few centimetres below, which is what it means. See
              `Sticker.tally_bar/1`'s doc, which used to argue for keeping it tangerine. --%>
        <span
          class="grid size-[26px] shrink-0 place-items-center rounded-full border-2 border-ink bg-violet text-white"
          aria-hidden="true"
        >
          ★
        </span>
        <%!-- **"We have a winner" over a dead heat is a false headline, not a rounding
              error.** `Consensus.Voting.tally/1` breaks a tie by `activity.position` — the
              order the organizer dragged the pool into on `03 review` — so on a 1–1 tie
              this card named one option and the row beneath demoted the other to
              "Runner-up" at the identical count, with a paste-to-chat button under it. The
              group still gets one answer (a runoff is an open product question and this is
              not the place to invent one), but it is told that it is a tie and told the
              rule that settled it. --%>
        <span class="text-sm font-bold text-ink">
          {if @tied, do: "Tied at the top", else: "We have a winner"}
        </span>
      </div>
      <%!-- One interpolation, not five. HEEx puts the template's own newlines and
            indentation into the text node between adjacent `{}`s, so a sentence assembled
            inline renders as `…level on 1\n        approval.` — readable on screen, but
            un-assertable in a test without matching whitespace, which is the
            whitespace-significant-string trap of CLAUDE.md invariant 11 from the other
            direction. `tie_note/2` returns the finished sentence. --%>
      <p :if={@tied} id="winner-tie-note" class="-mt-1 text-[12.5px] leading-[1.45] text-ink-soft">
        {tie_note(@tied, @row)}
      </p>
      <.photo_frame src={@row.activity.image_url} alt={@row.activity.name} height="h-[130px]" />
      <div>
        <p class="text-[19px] font-bold text-ink">{@row.activity.name}</p>
        <p :if={@row.activity.description} class="mt-0.5 text-sm text-ink-soft">
          {@row.activity.description}
        </p>
      </div>
      <.link
        :if={@row.activity.source_url}
        href={@row.activity.source_url}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center justify-center gap-2 rounded-2xl border-2 border-ink bg-tangerine p-4 text-center font-bold text-white shadow-sticker-4 press-4"
      >
        View {@row.activity.name} →
      </.link>
      <button
        type="button"
        id="copy-summary"
        phx-hook="Clipboard"
        data-copy={@summary}
        class="rounded-2xl border-2 border-ink bg-white p-3 text-center text-sm font-bold text-ink shadow-sticker-2 press-2"
      >
        Copy summary for the group chat
      </button>
    </.sticker_card>

    <div
      :if={@runner_up}
      class="flex items-center justify-between gap-3 rounded-2xl border-2 border-ink-30 bg-white/60 p-3"
    >
      <div class="min-w-0">
        <%!-- "Runner-up" is a claim that it came second. On a tie it did not — it drew,
              and the eyebrow was the second place this screen quietly resolved the tie. --%>
        <p class="eyebrow">
          {if @tied && @runner_up.approvals == @row.approvals, do: "Also tied", else: "Runner-up"}
        </p>
        <p class="truncate text-sm font-semibold text-ink">{@runner_up.activity.name}</p>
      </div>
      <.link
        :if={@runner_up.activity.source_url}
        href={@runner_up.activity.source_url}
        target="_blank"
        rel="noopener noreferrer"
        class="shrink-0 rounded-full border-2 border-ink bg-white px-3 py-1.5 text-[12px] font-semibold text-ink hover:bg-yellow"
      >
        View →
      </.link>
    </div>
    """
  end

  defp outcome_section(%{outcome: :no_consensus} = assigns) do
    ~H"""
    <.sticker_card tone={:muted} class="p-4">
      <p class="text-sm text-muted">
        Everyone gets one veto, and everything in the pool got one — no consensus this
        time.
      </p>
    </.sticker_card>
    """
  end

  # Ballots were cast; nothing survived them with an approval. Split out of `:no_votes`,
  # which asserted "before anyone cast a ballot" on a screen simultaneously showing
  # `1/1 voted` and a `VETOED` pill.
  defp outcome_section(%{outcome: :vetoes_only} = assigns) do
    ~H"""
    <.sticker_card tone={:muted} class="p-4">
      <p class="text-sm text-muted">
        Votes came in, but nothing survived them: no option that escaped a veto picked up a
        single approval.
      </p>
    </.sticker_card>
    """
  end

  defp outcome_section(%{outcome: :no_votes} = assigns) do
    ~H"""
    <.sticker_card tone={:muted} class="p-4">
      <p class="text-sm text-muted">Voting closed before anyone cast a ballot.</p>
    </.sticker_card>
    """
  end

  # `outcome/1` cannot return `{:leader, _}` for a group this section is ever called
  # for — a completed group's tally has already flipped `winner?` — but a defensive
  # empty render beats a `FunctionClauseError` if that invariant is ever wrong.
  defp outcome_section(%{outcome: {:leader, _row}} = assigns), do: ~H""

  defp tie_note(tied, row) do
    approvals = row.approvals
    unit = if approvals == 1, do: "approval", else: "approvals"

    "#{length(tied)} options finished level on #{approvals} #{unit}. " <>
      "#{row.activity.name} takes it because it was first in the pool — no vote separated them."
  end

  # The paste-to-chat string is the one artefact that leaves the app, so it is the last
  # place a tie may be rounded off to a clean win: the group reads this line in the chat
  # and never opens the screen that would have qualified it.
  defp winner_summary(group, row, tied) when length(tied) > 1 do
    names = tied |> Enum.map(& &1.activity.name) |> Enum.join(", ")

    "🤝 \"#{group.title}\" ended in a tie at #{row.approvals} — #{names}. " <>
      "#{row.activity.name} takes it as first in the list."
  end

  defp winner_summary(group, row, _tied) do
    "🎉 #{row.activity.name} won \"#{group.title}\"!"
  end

  defp runner_up(tally, %{activity: %{id: winner_id}}) do
    tally
    |> Enum.reject(& &1.vetoed?)
    |> Enum.reject(&(&1.activity.id == winner_id))
    |> List.first()
  end
end
