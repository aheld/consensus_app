defmodule ConsensusWeb.ResultsComponents do
  @moduledoc """
  The shared body of design frames `05` (live results, organizer) and `05b` (live
  results, participant) — see `docs/design/screens/1a-6-05-live-results-organizer.html`
  and `1a-7-05b-same-screen-after-anyone-votes.html`, and `docs/plans/voting-loop.md`.

  One function component, `results_panel/1`, rendered by two thin callers:
  `ConsensusWeb.GroupLive.Results` (`/groups/:id/results`, the organizer) and
  `ConsensusWeb.JoinLive.Results` (`/join/:slug/results`, a participant). The two
  screens share everything except the footer — Nudge/Close now for the organizer,
  the locked "your ranking is in" state for a participant — so the footer is the one
  slot a caller must fill; everything above it (header, avatar row, the outcome
  section, the tally, the anonymity caption) is drawn here from plain data so neither
  caller can render it differently by accident.

  ## Anonymity (D-035)

  This module never receives, and could not render, who approved what — `tally/1`
  (`Consensus.Voting.tally/1`) returns totals only, and `participants/1` returns
  participation, never choices. The anonymity caption below the tally states the rule
  unconditionally, matching the review screen's card (D-035) rather than reading a
  `group.anonymous` flag that nothing in `Consensus.Voting` acts on.

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
        avatar_caption="TAP TO NUDGE"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
      >
        <:footer>
          <.button phx-click="nudge">Nudge {@waiting} friends</.button>
        </:footer>
      </.results_panel>
  """
  attr :group, :map, required: true
  attr :tally, :list, required: true
  attr :outcome, :any, required: true
  attr :participants, :list, required: true
  attr :current_participant_id, :integer, default: nil
  attr :avatar_caption, :string, default: nil
  attr :countdown_text, :string, default: nil

  slot :banner, doc: "e.g. the participant's mint \"Your ranking is in\" confirmation"
  slot :footer, required: true

  def results_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <.results_header group={@group} countdown_text={@countdown_text} />

      <div class="flex flex-1 flex-col gap-3.5 overflow-y-auto px-5 py-4">
        {render_slot(@banner)}

        <.participant_avatar_row
          participants={@participants}
          current_participant_id={@current_participant_id}
          caption={@avatar_caption}
        />

        <.outcome_section
          :if={@group.status in [:completed, :cancelled]}
          group={@group}
          outcome={@outcome}
          tally={@tally}
        />

        <div class="flex flex-col gap-[11px]">
          <span class="text-sm font-bold text-ink">{tally_heading(@group)}</span>
          <div class="flex flex-col gap-2.5">
            <.tally_bar :for={row <- @tally} row={row} />
          </div>
          <p class="text-[11px]/[1.4] text-muted">Anonymous session — totals only, no names.</p>
        </div>
      </div>

      <div class="flex flex-col gap-2.5 px-5 pb-5 pt-3">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  defp tally_heading(%{status: :voting}), do: "Running tally"
  defp tally_heading(_group), do: "Final tally"

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
    assigns =
      assigns
      |> assign(:row, row)
      |> assign(:runner_up, runner_up(assigns.tally, row))
      |> assign(:summary, winner_summary(assigns.group, row))

    ~H"""
    <.sticker_card tone={:mint} depth={2} class="flex flex-col gap-3 p-4">
      <div class="flex items-center gap-2">
        <span
          class="grid size-[26px] shrink-0 place-items-center rounded-full border-2 border-ink bg-tangerine text-white"
          aria-hidden="true"
        >
          ★
        </span>
        <span class="text-sm font-bold text-ink">We have a winner</span>
      </div>
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
        <p class="eyebrow">Runner-up</p>
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

  defp winner_summary(group, row) do
    "🎉 #{row.activity.name} won \"#{group.title}\"!"
  end

  defp runner_up(tally, %{activity: %{id: winner_id}}) do
    tally
    |> Enum.reject(& &1.vetoed?)
    |> Enum.reject(&(&1.activity.id == winner_id))
    |> List.first()
  end
end
