defmodule ConsensusWeb.Sticker do
  @moduledoc """
  The design-specific primitives of the "sticker" system (see `docs/design/DESIGN-SPEC.md`).

  These are the shapes that repeat across four or more design frames — a bordered card, a
  pill chip, a status badge, the wizard's step-progress header, the photo placeholder — and
  don't belong in `ConsensusWeb.CoreComponents`, which stays the generic Phoenix building
  blocks (button, input, table, ...). Every colour and shadow here comes from the `@theme`
  tokens in `assets/css/app.css`; nothing here hardcodes a hex value.
  """
  # NOT `use ConsensusWeb, :html`: html_helpers/0 imports this module, so a module that
  # imports itself while still being defined fails to compile (the same reason
  # ConsensusWeb.CoreComponents uses Phoenix.Component directly instead of the macro).
  use Phoenix.Component

  @doc """
  The white (or tinted) bordered card that is the base surface of the whole design.

  `depth` picks the hard offset shadow (and, when `interactive`, the matching `.press-N`
  hover/active behaviour from app.css) — 2 for a small row, 3 (the default) for a card, 4 for
  something that wants to read as the most "liftable" surface on the screen. `tone` picks the
  fill; `:muted` is the de-emphasised "past" card and deliberately carries no shadow at all,
  matching the design's treatment of finished/cancelled groups.

  ## Examples

      <.sticker_card>
        <p>Plain white card.</p>
      </.sticker_card>

      <.sticker_card tone={:violet_tint} depth={2} interactive phx-click="toggle">
        Anonymous voting
      </.sticker_card>

      <.sticker_card tone={:muted}>
        <p>Birthday dinner · Kismet won · Jul 24</p>
      </.sticker_card>
  """
  attr :tone, :atom,
    default: :white,
    values: [:white, :mint, :violet_tint, :yellow, :canvas, :muted],
    doc: "the card's fill"

  attr :depth, :integer, default: 3, values: [2, 3, 4], doc: "shadow (and press) depth"

  # The design does not use one radius everywhere: a row inside a list is 14px, a card in a
  # list is 16px, a sheet's preview card is 18px, and a standalone panel is 20px. Rounding
  # them all to one value is the single change that most makes a screen read as "close but
  # not it", so the ladder is a parameter rather than a default nobody can override —
  # a `class="rounded-[15px]"` would collide with the base class instead of winning.
  attr :radius, :atom,
    default: :md,
    values: [:sm, :md, :lg, :xl],
    doc: "14px (row) | 16px (card) | 18px (panel) | 20px (large panel)"

  attr :interactive, :boolean,
    default: false,
    doc: "adds the matching press-N hover/active behaviour and a pointer cursor"

  attr :class, :any, default: nil
  attr :rest, :global, doc: "e.g. phx-click, id, aria-*"
  slot :inner_block, required: true

  def sticker_card(assigns) do
    ~H"""
    <div
      class={[
        "border-2",
        radius_class(@radius),
        tone_class(@tone),
        @tone != :muted && shadow_class(@depth),
        @interactive && [press_class(@depth), "cursor-pointer"],
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp tone_class(:white), do: "border-ink bg-white"
  defp tone_class(:mint), do: "border-ink bg-mint"
  defp tone_class(:violet_tint), do: "border-ink bg-violet-tint"
  defp tone_class(:yellow), do: "border-ink bg-yellow"
  defp tone_class(:canvas), do: "border-ink bg-canvas"
  defp tone_class(:muted), do: "border-ink-30 bg-white/60"

  defp radius_class(:sm), do: "rounded-[14px]"
  defp radius_class(:md), do: "rounded-2xl"
  defp radius_class(:lg), do: "rounded-[18px]"
  defp radius_class(:xl), do: "rounded-[20px]"

  defp shadow_class(2), do: "shadow-sticker-2"
  defp shadow_class(3), do: "shadow-sticker-3"
  defp shadow_class(4), do: "shadow-sticker-4"

  defp press_class(2), do: "press-2"
  defp press_class(3), do: "press-3"
  defp press_class(4), do: "press-4"

  @doc """
  The 99px pill-shaped selection chip (activity type, votes-close time, ...).

  Renders a `<.link>` when `navigate`, `patch` or `href` is given in `rest`, otherwise a
  `<button type="button">`. `selected` changes both fill *and* font weight — colour is never
  the only signal. `disabled` renders the dashed, `--faint`-text, unclickable state the design
  uses for post-MVP options (Bars, Movies, Custom…).

  ## Examples

      <.chip phx-click="select_time" phx-value-time="tonight" selected={@time == "tonight"}>
        Tonight 6pm
      </.chip>

      <.chip disabled>Custom…</.chip>

      <.chip navigate={~p"/groups/\#{@group}/options"}>Restaurant</.chip>
  """
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false

  # Two disabled treatments exist in the design frames, and they are per-screen, not
  # per-mood: `01 setup`'s `Custom…` chip is full-ink dashed (`2px dashed #17211C`),
  # while the t5 `02 add options` panels draw `Bars`/`Movies` with a fine
  # `rgba(23,33,28,.38)` dash and faint text so they visibly recede behind the one live
  # chip beside them. `quiet` opts a disabled chip into the latter; it is ignored when
  # the chip is not disabled.
  attr :quiet, :boolean,
    default: false,
    doc: "disabled only — the receding `ink/38` dashed border the `02` frames draw"

  # The design selects a chip two different ways, and the difference is meaningful rather
  # than decorative. On `01` a chosen deadline is a *value* — violet, the colour this app
  # uses for vote and session state. On `02` the chosen activity type is a *mode* the rest
  # of the screen sits inside — ink-filled with a mint shadow, so it reads as a heading
  # rather than as one option among equals.
  attr :tone, :atom,
    default: :violet,
    values: [:violet, :ink],
    doc: "how the selected state is filled; ignored when not selected"

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method download name value)
  slot :inner_block, required: true

  def chip(%{rest: rest} = assigns) do
    if !assigns.disabled && (rest[:navigate] || rest[:href] || rest[:patch]) do
      ~H"""
      <.link class={chip_class(@selected, @disabled, @quiet, @tone, @class)} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <%!-- `to_string/1`, not the bare boolean. HEEx treats an attribute whose value is
            `true` as a bare HTML boolean attribute and renders `aria-pressed=""`, and drops
            it entirely for `false`. ARIA reads an empty string as unset, so a chip written
            `aria-pressed={@selected}` announces no pressed state in either direction — the
            selected one and the unselected ones are indistinguishable to a screen reader,
            on the one control that carries this screen's only choice. --%>
      <button
        type="button"
        disabled={@disabled}
        aria-pressed={to_string(@selected)}
        class={chip_class(@selected, @disabled, @quiet, @tone, @class)}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp chip_class(selected, disabled, quiet, tone, class) do
    [
      # `min-h-11` (44px) with `py-2` kept. Every chip in the app painted 39.5px tall —
      # including the four deadline chips that are the very first input on the organizer's
      # first screen, packed 2×2 with 8px gutters — which is under the 44px platform touch
      # minimum on a phone-first app. The padding stays so the visual box is unchanged
      # wherever the row already had room; `min-h` only grows the short ones. The ballot's
      # own view toggle reached 44 this way and the shared primitive was simply not swept
      # with it.
      "inline-flex min-h-11 items-center gap-1.5 whitespace-nowrap rounded-full border-2 px-3.5 py-2",
      "text-[13px] transition-colors",
      cond do
        # `quiet` is the t5 `02` treatment — `2px dashed rgba(23,33,28,.38)`, faint
        # 500-weight text — a variant rather than the new default because `01`'s
        # `Custom…` frame keeps the full-ink dash (see the attr comment above).
        disabled and quiet ->
          "cursor-not-allowed border-dashed border-ink/38 font-medium text-faint"

        disabled ->
          "cursor-not-allowed border-dashed border-ink text-faint"

        selected and tone == :ink ->
          "border-ink bg-ink font-semibold text-white shadow-chip"

        selected ->
          "border-ink bg-violet font-semibold text-white shadow-sticker-2"

        true ->
          "cursor-pointer border-ink bg-white font-medium hover:bg-violet-tint"
      end,
      class
    ]
  end

  @doc """
  The tiny 99px status badge — `VOTING`, `YOUR TURN`, an attribution like `ALEX`.

  ## Examples

      <.pill tone={:mint}>Voting</.pill>
      <.pill tone={:yellow}>Your turn</.pill>
      <.pill tone={:violet}>Alex</.pill>
  """
  attr :tone, :atom,
    default: :mint,
    values: [:mint, :yellow, :violet, :mint_soft, :tangerine, :peach]

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center whitespace-nowrap rounded-full border-[1.5px] border-ink",
        "px-2 py-[1px] text-[9.5px] font-semibold uppercase",
        pill_tone_class(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp pill_tone_class(:mint), do: "bg-mint text-ink"
  defp pill_tone_class(:yellow), do: "bg-yellow text-ink"
  defp pill_tone_class(:violet), do: "bg-violet text-white"
  defp pill_tone_class(:mint_soft), do: "bg-mint-soft text-ink"
  # Added for the voting loop's `tally_bar/1`, because the `05`/`05b` design frames draw
  # `VETOED` filled tangerine-on-white. **Nothing in `lib/` uses it any more** — the tally's
  # own pill moved to `:peach` for the reason below, which is the same reason the ballot's
  # did. Kept as a tone rather than deleted because the frames still specify it and the next
  # screen that genuinely wants a tangerine-filled pill should not have to re-derive it; do
  # not reach for it on a screen that already has a forward action.
  defp pill_tone_class(:tangerine), do: "bg-tangerine text-white"
  # The `Vetoed` marker, on the ballot and now on both results screens. Tangerine appears
  # exactly once per screen as the one forward action — on the deck's end-of-deck summary
  # that is `Send my votes`, and on a completed `/groups/:id/results` it is
  # `Start another session`. A tangerine `Vetoed` pill made two on each. Peach is what the
  # grid's held veto already uses for the identical state one view away.
  defp pill_tone_class(:peach), do: "bg-peach text-ink"

  @doc """
  The uppercase DM Mono section label (`SESSION TITLE`, `VOTES CLOSE`, `GROUP`, ...).

  A thin wrapper over the `.eyebrow` class already defined in `app.css`.

  ## Examples

      <.eyebrow>Session title</.eyebrow>
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <span class={["eyebrow", @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  The wizard progress row: an N-segment bar and a `current/total` counter.

  **It no longer carries a back button** (D-041, plan ruling 1). It used to, and frames
  `01` and `02` still draw one — but they now *also* draw the global header's own `‹`
  directly above it, which is two controls that look like "back" and may go to different
  places. The route this component's `back` attribute used to take is now
  `ConsensusWeb.Chrome.header/1`'s `back`, passed through `Layouts.app/1`. Do not add a
  chevron back here to match the comp.

  The segment row carries `role="progressbar"` with the matching `aria-value*` attributes
  and an `aria-label`, since a row of coloured bars is otherwise invisible to a screen
  reader.

  ## Examples

      <.step_progress total={3} current={1} />
      <.step_progress total={3} current={2} />
  """
  attr :total, :integer, required: true
  attr :current, :integer, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def step_progress(assigns) do
    ~H"""
    <div class={["flex items-center gap-3", @class]} {@rest}>
      <div
        class="flex flex-1 gap-[5px]"
        role="progressbar"
        aria-valuenow={@current}
        aria-valuemin="1"
        aria-valuemax={@total}
        aria-label={"Step #{@current} of #{@total}"}
      >
        <div
          :for={step <- 1..@total}
          class={[
            "h-1.5 flex-1 rounded-full",
            if(step <= @current, do: "bg-violet", else: "bg-ink-12")
          ]}
        />
      </div>
      <span class="shrink-0 font-mono text-[10px] text-muted">{@current}/{@total}</span>
    </div>
    """
  end

  @doc """
  The 24px rounded-square position badge on each pool row (`1`, `2`, `3`, ...).

  The fill cycles mint → yellow-soft → violet-soft as `n` increases, purely decorative — the
  number itself is the real content.

  ## Examples

      <.position_badge n={1} />
  """
  attr :n, :integer, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def position_badge(assigns) do
    ~H"""
    <span
      class={[
        "grid size-6 shrink-0 place-items-center rounded-lg border-2 border-ink",
        "font-mono text-[11px] font-bold text-ink",
        position_badge_tone(@n),
        @class
      ]}
      {@rest}
    >
      {@n}
    </span>
    """
  end

  defp position_badge_tone(n) do
    case rem(n - 1, 3) do
      0 -> "bg-mint"
      1 -> "bg-yellow-soft"
      _ -> "bg-violet-soft"
    end
  end

  @doc """
  The option image box. Shows the image when `src` is present, or the diagonal
  `stripes-violet` placeholder (from app.css) when it is not — including when a real image
  URL 404s, since these are arbitrary third-party links and some will.

  The `inner_block` slot is for the overlay badges/buttons the editor draws on top (a
  `PULLED FROM LINK` pill, `Replace`/`Remove` buttons); it is rendered last so it stacks above
  the image.

  ## Examples

      <.photo_frame src={@option.photo_url} alt={@option.name} />

      <.photo_frame src={@option.photo_url} alt={@option.name} height="h-[150px]">
        <span class="absolute left-2.5 top-2.5 rounded-full bg-ink px-2.5 py-1 font-mono text-[9.5px] text-white">
          Pulled from link
        </span>
      </.photo_frame>

  Pass `bare` to drop the default 2px ink border, 16px radius and `shadow-sticker-3` —
  for a mini strip nested inside a card that already carries its own border and hard
  shadow (the ballot's `1c-1` sticker grid, `docs/design/screens/1c-1-sticker-grid-kept-in-play.html`,
  draws a flat `38px` strip with no shadow of its own). Supply whatever chrome the comp
  calls for through `class` instead of fighting the defaults — two same-property Tailwind
  utilities in one `class` list have no reliable winner, so the base classes have to be
  the ones that step aside, not merely be "overridden":

      <.photo_frame
        src={activity.image_url}
        alt={activity.name}
        height="h-[38px]"
        bare
        class="rounded-[9px] border-[1.5px] border-ink"
      />
  """
  attr :src, :string, default: nil
  attr :alt, :string, required: true
  attr :height, :string, default: "h-[150px]", doc: "a Tailwind height class"

  attr :bare, :boolean,
    default: false,
    doc: "omit the default border/radius/shadow — see moduledoc example for nested use"

  attr :stripe, :string,
    default: "stripes-violet",
    doc: """
    which of app.css's placeholder stripes to draw when there is no image. Violet is the
    default and the standalone case (the option editor's single large photo). Callers that
    render *many* frames at once pass something else — app.css's own comment for the five
    variants says why: "a pool of five options with one repeated stripe reads as a single
    grey block, and the eye stops separating the rows". Frame `1c-0` draws the swipe deck's
    card mint; frame `1c-1` cycles the grid's thumbnails through peach/yellow/blue.
    """

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "overlay badges/buttons positioned over the frame"

  def photo_frame(assigns) do
    ~H"""
    <div
      class={[
        "relative overflow-hidden",
        !@bare && "rounded-2xl border-2 border-ink shadow-sticker-3",
        @height,
        is_nil(@src) && @stripe,
        @class
      ]}
      {@rest}
    >
      <img
        :if={@src}
        src={@src}
        alt={@alt}
        loading="lazy"
        class="size-full object-cover"
        onerror={"this.style.display='none';this.parentElement.classList.add('#{@stripe}')"}
      />
      {render_slot(@inner_block)}
    </div>
    """
  end

  ## -- the voting-loop primitives (docs/plans/voting-loop.md) ------------------------
  #
  # Four more design-specific primitives, added for `/join/:slug`, `/join/:slug/vote`,
  # `/join/:slug/results` and `/groups/:id/results` (frames `06`, the ballot, `05` and
  # `05b`). Same rule as everything above: every colour comes from the `@theme` tokens,
  # nothing here hardcodes a hex value in a template (the one exception, `.stripes-vetoed`
  # in app.css, is CSS, not HEEx — see its comment there, and see `photo_frame/1`'s own
  # `.stripes-violet` above for the precedent).

  @doc """
  The circular initial avatar for a group's vote — reused across the entry invite row,
  the "N friends already voted" summary, and the live results avatar row (frames `06`,
  `05`, `05b`).

  Named `participant_avatar/1`, not `avatar/1`: `ConsensusWeb.Layouts` already defines
  an `avatar/1` (the signed-in account's own avatar, fixed peach fill) and imports this
  module, so a same-named function here would not compile — `imported
  ConsensusWeb.Sticker.avatar/1 conflicts with local function`. The two are different
  things anyway — an account's avatar vs. a vote's participant marker — so the longer
  name earns its keep as disambiguation, not just as a workaround.

  `state` is what changes the border/ring/text: `:voted` renders a filled circle, a 2px
  ink border, and a **permanent** `box-shadow:0 0 0 3px var(--color-mint)` ring — not a
  `:focus`-only ring, the same "resting shadow" idiom `shadow-field` uses on `<.input>`
  (design-system skill, rule 5). `:waiting` renders an unfilled circle with a dashed,
  45%-opacity ink border and `--faint` text, and no ring.

  `participant_id` (not the fill colour itself) is what a caller passes, because the
  fill has to survive re-renders and list reshuffles: it **cycles deterministically from
  the id** — yellow → mint → peach → violet-soft, `rem(participant_id, 4)` — so a given
  person keeps the same colour on every screen and every tally update, rather than a
  colour tied to their position in the list (which changes as `participant_avatar_row/1`'s
  row reorders, or as `tally_bar/1`'s rows re-sort by approval count).

  `label` overrides the default `"voted"`/`"waiting"` caption —
  `participant_avatar_row/1` passes `"you"` for the viewer's own avatar, matching `05b`.
  Pass `show_label={false}` for a compact context that draws its own caption, or none
  at all (the overlapping mini-avatars on `06` — out of scope for this pass, but the
  flag is here for whoever builds it).

  `ring` (default `true`) is the permanent mint `box-shadow` a `:voted` avatar carries
  on `05`/`05b`, where the comp draws it explicitly. `06`'s compact overlap-with-a-"+N"
  row does not — its two example avatars are plain colour-filled circles with no ring —
  so a caller composing this component for that layout passes `ring={false}` rather than
  inheriting chrome built for a different screen.

  ## Examples

      <.participant_avatar participant_id={p.id} initial={p.initial} state={:voted} />

      <.participant_avatar
        participant_id={p.id}
        initial={p.initial}
        state={:waiting}
        size={29}
      />

      <.participant_avatar
        participant_id={me.id}
        initial={me.initial}
        state={:voted}
        label="you"
      />

      <.participant_avatar
        participant_id={p.id}
        initial={p.initial}
        state={:voted}
        size={29}
        show_label={false}
        ring={false}
      />
  """
  attr :participant_id, :integer, required: true, doc: "picks the deterministic fill colour"
  attr :initial, :string, required: true

  attr :name, :string,
    default: nil,
    doc: "the participant's typed name, when there is one — see the moduledoc on why"

  attr :state, :atom, required: true, values: [:voted, :waiting]
  attr :label, :string, default: nil, doc: "overrides the default \"voted\"/\"waiting\" caption"
  attr :size, :integer, default: 40, doc: "px — 40 on 05/05b, 29 on 06's compact row"
  attr :show_label, :boolean, default: true
  attr :ring, :boolean, default: true, doc: "the permanent mint ring on :voted — see moduledoc"
  attr :class, :any, default: nil
  attr :rest, :global

  def participant_avatar(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-1">
      <%!-- **The circle carries the name when there is one, and is `aria-hidden` only when
            there is not.** `/join/:slug` asks a guest for their name under a stated
            purpose — "Just so <organizer> can see who has voted" — and the organizer's
            results screen then rendered `aria-hidden="true"` around a single letter with
            no `title` and no visually-hidden label, so the string the guest typed appeared
            nowhere in the document at all. Two guests called Sam and Sarah were the same
            avatar, and a screen-reader organizer got "1/1 voted, WHO'S VOTED, voted" and
            no identity whatsoever. The frame draws initials and that stays — the name
            reaches the accessibility tree and a hover tooltip instead of the layout.

            An anonymous participant has no `name` and keeps the old treatment: `?` in an
            `aria-hidden` circle is exactly as much as the app knows, and inventing
            "Anonymous" as an accessible name would read as somebody's chosen handle. --%>
      <span
        class={[
          "grid shrink-0 place-items-center rounded-full border-2 font-bold",
          avatar_state_class(@state, avatar_fill(@participant_id), @ring),
          @class
        ]}
        style={"width:#{@size}px;height:#{@size}px;font-size:#{round(@size * 0.325)}px"}
        aria-hidden={if @name, do: nil, else: "true"}
        title={@name}
        {@rest}
      >
        <span :if={@name} class="sr-only">{@name}</span>
        <span aria-hidden="true">{@initial}</span>
      </span>
      <span
        :if={@show_label}
        class={["font-mono text-[9.5px] font-medium", avatar_label_class(@state)]}
      >
        {@label || avatar_default_label(@state)}
      </span>
    </div>
    """
  end

  @avatar_fills ~w(bg-yellow bg-mint bg-peach bg-violet-soft)

  defp avatar_fill(id) when is_integer(id), do: Enum.at(@avatar_fills, rem(id, 4))

  defp avatar_state_class(:voted, fill, ring?),
    do: [fill, "border-ink text-ink", ring? && "shadow-[0_0_0_3px_var(--color-mint)]"]

  defp avatar_state_class(:waiting, _fill, _ring?), do: "border-dashed border-ink/45 text-faint"

  defp avatar_label_class(:voted), do: "text-ink-soft"
  defp avatar_label_class(:waiting), do: "text-faint"

  defp avatar_default_label(:voted), do: "voted"
  defp avatar_default_label(:waiting), do: "waiting"

  @doc """
  The voted/waiting avatar row from frames `05`/`05b`: a label row (a "N/M voted" count
  on the left, a caller-supplied caption on the right) over a horizontal row of
  `participant_avatar/1`s.

  `participants` takes exactly the shape `Consensus.Voting.participants/1` returns —
  `[%{id:, display_name:, initial:, voted?:}]` — so a caller passes that result
  straight through with no reshaping. `current_participant_id`, when given, renders
  that one avatar's label as `"you"` instead of `"voted"`/`"waiting"` (`05b`'s own
  avatar, the guest's view of themselves).

  `caption` is the small DM Mono line on the right of the label row. Both callers now
  pass `"WHO'S VOTED"`. The frames draw `"TAP TO NUDGE"` on `05` and `"ORGANIZER NUDGES"`
  on `05b`, and both shipped that way; neither is true. This component wires up no click
  for either caller, and `grep -rn 'nudge' lib/` finds no nudge path anywhere in the app —
  the organizer's own control is disabled and labelled `Soon`. A caption naming an action
  nothing on the screen performs is confusion class 1, so both were replaced (D-045 for
  the participant's half). Pass `nil` (the default) to omit the line entirely.

  ## Examples

      <.participant_avatar_row
        participants={Voting.participants(@group)}
        caption="WHO'S VOTED"
      />

      <.participant_avatar_row
        participants={Voting.participants(@group)}
        current_participant_id={@participant.id}
        caption="WHO'S VOTED"
      />
  """
  attr :participants, :list, required: true, doc: "Consensus.Voting.participants/1's shape"
  attr :current_participant_id, :integer, default: nil
  attr :caption, :string, default: nil
  attr :label, :string, default: nil, doc: "overrides the default \"N/M voted\" count"

  attr :waiting_label, :string,
    default: nil,
    doc:
      "overrides the per-avatar \"waiting\" caption — pass \"missed it\" on a finished session, " <>
        "where there is nothing left to wait for"

  attr :avatar_size, :integer, default: 40
  attr :class, :any, default: nil

  def participant_avatar_row(assigns) do
    voted = Enum.count(assigns.participants, & &1.voted?)
    total = length(assigns.participants)
    assigns = assign(assigns, voted_count: voted, total_count: total)

    ~H"""
    <div class={["flex flex-col gap-2.5", @class]}>
      <div class="flex items-baseline justify-between gap-2">
        <span class="text-sm font-bold text-ink">
          {@label || "#{@voted_count}/#{@total_count} voted"}
        </span>
        <span :if={@caption} class="shrink-0 font-mono text-[10.5px] text-muted">{@caption}</span>
      </div>
      <div class="flex gap-[7px]">
        <.participant_avatar
          :for={p <- @participants}
          participant_id={p.id}
          initial={p.initial}
          name={p.display_name}
          state={if(p.voted?, do: :voted, else: :waiting)}
          label={avatar_label(p, @current_participant_id, @waiting_label)}
          size={@avatar_size}
        />
      </div>
    </div>
    """
  end

  # "you" beats everything — it is the viewer's own avatar and that is the more useful
  # fact. Otherwise a caller-supplied `waiting_label` replaces the default "waiting" on the
  # people who have not voted: on a `:completed` or `:cancelled` session "waiting" sits
  # under a header reading **Voting closed**, promising something that cannot happen, while
  # the footer two hundred pixels down correctly says there is no way to add a vote now.
  # "voted" needs no override — it is equally true after the close.
  defp avatar_label(%{id: id}, id, _waiting_label), do: "you"
  defp avatar_label(%{voted?: true}, _current_id, _waiting_label), do: nil
  defp avatar_label(_participant, _current_id, waiting_label), do: waiting_label

  @doc """
  One row of the running tally (frames `05`/`05b`): the activity's name, its approval
  count (or the peach `Vetoed` pill), and the 16px bar.

  Built to take one row of `Consensus.Voting.tally/1`'s return shape —
  `%{activity:, approvals:, vetoed?:, leader?:, bar_percent:, ...}` — straight through,
  so a caller does `<.tally_bar :for={row <- @tally} row={row} />` with no reshaping.
  The `★` renders whenever `row.leader?` is true; `tally/1` already guarantees a vetoed
  row is never the leader, so this component does not re-check it. It is **violet**, not
  tangerine: the shared rule is that tangerine appears exactly once per screen as the one
  forward action, and once the tie fix started starring every row that shares the top
  count, one tangerine glyph became N — measured on a two-way tie, four tangerine elements
  on one screen against the forward action's one. Violet is the tally's own accent (it is
  the bar fill directly below), so the star reads as part of the bar rather than as a
  competing call to action.

  **The `:completed` winner card's `★` badge is violet too now, and this paragraph used to
  argue the opposite** ("there is exactly one of it, and it *is* that screen's headline").
  The argument fails on the count: a completed `/groups/:id/results` with a vetoed option
  painted three tangerine elements — the badge, this row's `Vetoed` pill, and
  `#results-start-another`, which is the screen's actual forward action. The card is a
  statement of outcome, not something to press; it already sits on a mint sticker under a
  bold headline that says "We have a winner" in words. Violet keeps it the tally's accent,
  matching the `★` on the winning row directly beneath it.

  A vetoed row strikes the name through, mutes it, swaps the approval count for the
  `Vetoed` pill (`pill/1`'s `:peach` tone — the fill the ballot's own held veto already
  uses for the identical state, and not a second tangerine on a screen that has a forward
  action), and replaces the violet fill with the inert `.stripes-vetoed` pattern
  (`assets/css/app.css`) instead of drawing a 0%-width bar — colour is never the only
  signal (CLAUDE.md's neighbour rule to invariant 11): struck-through text, a pill, and a
  different bar texture all say "eliminated" together.

  ## Examples

      <.tally_bar :for={row <- Voting.tally(@group)} row={row} />
  """
  attr :row, :map, required: true
  attr :class, :any, default: nil

  def tally_bar(assigns) do
    ~H"""
    <div class={["flex flex-col gap-[5px]", @class]}>
      <div class="flex items-baseline justify-between gap-2">
        <span class={[
          "truncate text-[13px] font-semibold",
          if(@row.vetoed?, do: "text-muted line-through", else: "text-ink")
        ]}>
          {@row.activity.name}
          <span :if={@row.leader?} class="text-violet">★</span>
        </span>
        <span :if={!@row.vetoed?} class="shrink-0 font-mono text-[11px] text-ink-soft">
          {@row.approvals}
        </span>
        <.pill :if={@row.vetoed?} tone={:peach} class="shrink-0">Vetoed</.pill>
      </div>
      <div class={[
        "h-4 overflow-hidden rounded-full border-2",
        if(@row.vetoed?, do: "stripes-vetoed", else: "border-ink bg-white")
      ]}>
        <div :if={!@row.vetoed?} class="h-full bg-violet" style={"width:#{@row.bar_percent}%"} />
      </div>
    </div>
    """
  end

  @doc """
  The violet header block on `05`/`05b`: the group title, a `LIVE` label, the big 34px
  DM Mono countdown, and "until votes close".

  `countdown_text` is a caller-supplied string — reuse `Consensus.Deadlines.countdown/2`
  to produce it (`"1d 04h left"`, `"12m left"`, `"Closing now"`; carrying no time-zone
  database is deliberate, D-031). This component does no date math and takes no
  `DateTime` itself, which keeps the live-updating tick — a `Process.send_after`
  re-render, or a client tick via a hook — entirely the caller's concern, and keeps this
  component trivially testable without freezing time.

  The countdown is wrapped in `aria-live="polite"` rather than left as bare text, since
  a `4h 12m` on its own is not announced sensibly by a screen reader on every update.

  ## Examples

      <.countdown_header
        title={@group.title}
        countdown_text={Deadlines.countdown(@group.deadline_at, DateTime.utc_now())}
      />
  """
  attr :title, :string, required: true
  attr :countdown_text, :string, required: true
  attr :class, :any, default: nil

  def countdown_header(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-1.5 border-b-2 border-ink bg-violet px-5 pb-4 pt-3 text-white",
      @class
    ]}>
      <div class="flex items-baseline justify-between gap-2">
        <span class="truncate text-[12px] font-semibold opacity-85">{@title}</span>
        <span class="shrink-0 font-mono text-[10.5px] font-medium opacity-80">LIVE</span>
      </div>
      <div
        class="font-mono text-[34px] font-medium leading-none tracking-[-0.02em]"
        aria-live="polite"
      >
        {@countdown_text}
      </div>
      <div class="text-[12px] opacity-85">until votes close</div>
    </div>
    """
  end

  ## -- the swipe deck (docs/plans/chrome-and-feedback.md P5, D-044) -------------------

  @doc """
  The swipe deck's card stack — frame `docs/design/screens/1c-0-swipe-deck-kept-in-play.html`,
  transcribed in `docs/design/IMPORT-NOTES.md` §7.4/§7.5.

  Three absolutely-positioned layers painted back to front. Only the top one has content
  and a shadow; the two behind it are empty white rectangles peeking out at the bottom
  (`top` 0 → 7 → 14, `left/right` 0 → 5 → 10) with alternating rotations (0°, −2°, +3.5°).

  `behind` is how many *undecided* cards follow this one, capped at 2 by the component —
  so the stack visibly thins as the voter works through the pool. That is decoration
  supporting the real answer to "how much more of this is there?", which is the
  `N / M` counter the caller renders above the stack (confusion #6 in
  `docs/plans/chrome-and-feedback.md`); do not make it the only signal.

  Everything interactive lives outside this component. The caller passes `id` and the
  hook/`data-*` attributes through `rest` onto the top card, and renders the pass / veto
  / approve buttons underneath it — a gesture is never the only way to decide a card.

  The photo region is `photo_frame/1`, so a missing or 404ing `image_url` degrades to a
  placeholder stripe (engineering invariant 14) — **`stripes-mint`, which is what the frame
  draws**, passed through `photo_frame/1`'s `stripe` attr. It is not a second "missing
  photo" pattern competing with the violet: the five stripe variants in app.css are one
  system, cycled precisely so a screen full of placeholders does not read as a single grey
  block, and this is the largest single region on the deck.

  The frame's meta row (`Italian · $$$ · 4.5 ★ · 0.8 mi`) has no counterpart in
  `Consensus.Activities.Activity` and cannot until Places/Yelp lands (Post-MVP). Per
  IMPORT-NOTES §7.5 the row collapses; `detail` carries the description instead.

  ## Examples

      <.deck_stack
        id={"deck-card-\#{activity.id}"}
        name={activity.name}
        detail={meta_line(activity)}
        image_url={activity.image_url}
        behind={remaining}
        phx-hook="SwipeCard"
        data-activity-id={activity.id}
      >
        <.pill tone={:mint}>Picked</.pill>
      </.deck_stack>
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :detail, :string, default: nil
  attr :image_url, :string, default: nil

  attr :behind, :integer,
    default: 0,
    doc: "undecided cards after this one; only 0, 1 and 2+ are distinguishable"

  attr :photo_class, :any,
    default: nil,
    doc: """
    extra classes for the photo region, which carries `aspect-[4/3]` and a `min-h-[72px]`
    floor of its own. Two earlier shapes were wrong and are worth not re-deriving: a
    `max-h-[62%]` default stopped the photo growing without giving the space to anything
    else (measured at 420×900: a 485px card with a 75px body and **112px of blank white**
    below the description), and capping the *card's* height instead left the ratio as an
    outcome of the viewport — 1.08:1 at one cap, 1.26:1 at the next, against the frame's
    1.326. The ratio belongs on the photo; see its own comment below.
    """

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "a status line under the detail — what the voter already chose"

  def deck_stack(assigns) do
    ~H"""
    <%!-- `absolute inset-0`, so the caller only has to give it a `relative` box with a
          height. It used to have no content height of its own — every layer inside was
          absolutely positioned, so as a plain `relative` div it collapsed to 0px and the
          three cards rendered as ink hairlines, and `h-full` did not fix it either. It is
          now a centring box instead: the card sizes itself from the photo's aspect ratio
          and this box centres what is left over, which is what frame `1c-0`'s own
          proportions ask for. Measured in the browser at 420×900: 0px, then 4px, then
          right. --%>
    <div class={["absolute inset-0 flex items-center", @class]}>
      <%!-- The sizing box. The top card is in normal flow inside it, so it gives this box
            its height, and the two `behind` layers position against that rather than
            against the caller's slot — otherwise a card shorter than its slot would leave
            its own stack floating below it. `max-h-full` is what keeps the whole thing
            inside the slot when the viewport is too short for the ratio (see the photo
            below).

            **`flex flex-col` on this box is load-bearing, not tidiness.** `max-h-full`
            here resolves (its parent is `absolute inset-0`, a definite height) but the
            card's own `max-h-full` did *not*: a percentage `max-height` against a
            content-height parent computes to `none`, so the cap never bound and the card
            simply overflowed. Measured before this line changed, at 390×664 (iPhone 14 in
            Safari): slot 231.5px, card 341.4px, 109.9px of card painted straight over the
            PASS / VETO / PICK row, `document.elementFromPoint` returning the description
            at all three button centres and `documentElement.scrollHeight === innerHeight`
            so there was nothing to scroll to. Same at 375×667 and 360×640; fine at
            420×900, which is the only viewport it had been checked at. As a flex column
            this box is clamped to the slot and the card, an ordinary flex item with
            `flex-shrink: 1`, shrinks into it — which is why the card also carries
            `min-h-0` (a column flex item's default `min-height: auto` is its content
            minimum and would have blocked exactly that shrink). --%>
      <div class="relative flex max-h-full w-full flex-col">
        <div
          :if={@behind >= 2}
          aria-hidden="true"
          class="absolute inset-x-[10px] bottom-0 top-[14px] rotate-[3.5deg] rounded-[22px] border-2 border-ink bg-white"
        />
        <div
          :if={@behind >= 1}
          aria-hidden="true"
          class="absolute inset-x-[5px] bottom-0 top-[7px] -rotate-2 rounded-[22px] border-2 border-ink bg-white"
        />
        <div
          id={@id}
          class="deck-card relative flex max-h-full min-h-0 flex-col overflow-hidden rounded-[22px] border-2 border-ink bg-white shadow-sticker-4"
          {@rest}
        >
          <%!-- **The ratio lives here, on the photo, and not as a `max-h` on the card.**
                Frame `1c-0` measures its photo at 260×196.1 — 1.326:1 — and both the frame
                and this component let the photo be `flex:1` inside a bounded card, which
                makes the ratio an *outcome* of the slot's height rather than a property of
                the photo. On the frame's own 300×600 device that outcome happens to be
                1.33; on a 420×900 review viewport ours came out at 1.08, then 1.26 after
                the card was capped at 380px, and the number kept tracking the viewport
                because the card cap is the wrong lever. `aspect-[4/3]` (1.333) states it
                directly, and the caller's slot no longer needs a height cap at all: the
                card sizes itself and the centring box above holds it in the middle.

                `flex-1` is deliberately **gone** and `min-h-[72px]` deliberately stays. The
                photo must not *grow* past its ratio, but it must still be allowed to
                shrink: on a short phone the slot can be smaller than ratio + body, and
                flex's default `shrink: 1` is what lets the photo give way there instead of
                the card overflowing (measured at 360×640 before the floor existed:
                `scrollHeight` 224 against `clientHeight` 216, the description 6px from the
                ink border). The photo is the part that can afford to give way.

                One thing this does not fix, on purpose: the photo's *share* of card
                height. The frame is 64.7%; this lands near 78%. The arithmetic is closed —
                at a 380px-wide photo the ratio fixes it at ~286px, and this card's body is
                two clamped lines plus `py-3.5` ≈ 79px, so the share is 286/367. The
                frame's 264px card carries a 105px body because it draws *three* lines
                (name, a chip meta row, a description) where `meta_line/1` gives us one.
                Matching the share as well would mean inventing card content, which is a
                product decision, not a CSS one. --%>
          <.photo_frame
            src={@image_url}
            alt={@name}
            height="h-auto"
            bare
            stripe="stripes-mint"
            class={["aspect-[4/3] min-h-[72px] border-b-2 border-ink", @photo_class]}
          />
          <%!-- `shrink-0` so the text is never the thing that gets squeezed, and the two
                lines clamp rather than clip: `.deck-card` is `overflow: hidden`, so without
                this a long name silently ate a whole line of the description with no
                ellipsis and no scroll. Same rule invariant 11 applies to this field
                elsewhere — the failure mode has to be an ellipsis, not a vanished line. --%>
          <%!-- `relative z-[3] bg-white` keeps the swipe wash off the card's own words.
                `.deck-card::after` (app.css) is `position:absolute; inset:0`, so at the
                moment a release would commit the vote the 0.85 mint veil covered the body as
                well as the photo: measured mid-drag past the threshold, the name's contrast
                against its own background fell from 13.9:1 to roughly 1.4:1 — the one piece
                of information saying *what* is being voted on, erased at the instant of the
                vote. The wash is invented chrome (the frame draws none), so the fix is to
                scope it to the photo region rather than to soften it. `z-[3]` clears the
                `::before` stamp's `z-index: 2`, which sits inside the photo and never
                overlaps this; the opaque fill is what actually blocks the veil, since a
                transparent box above it would still show it through. --%>
          <div class="relative z-[3] flex shrink-0 flex-col gap-[7px] bg-white px-4 py-3.5">
            <p class="line-clamp-2 text-[21px] font-bold leading-[1.1] tracking-[-0.02em]">
              {@name}
            </p>
            <p :if={@detail} class="line-clamp-2 text-[12px] leading-[1.4] text-muted">{@detail}</p>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
