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
      <.link class={chip_class(@selected, @disabled, @tone, @class)} {@rest}>
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
        class={chip_class(@selected, @disabled, @tone, @class)}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp chip_class(selected, disabled, tone, class) do
    [
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border-2 px-3.5 py-2",
      "text-[13px] transition-colors",
      cond do
        disabled -> "cursor-not-allowed border-dashed border-ink text-faint"
        selected and tone == :ink -> "border-ink bg-ink font-semibold text-white shadow-chip"
        selected -> "border-ink bg-violet font-semibold text-white shadow-sticker-2"
        true -> "cursor-pointer border-ink bg-white font-medium hover:bg-violet-tint"
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
    values: [:mint, :yellow, :violet, :mint_soft, :tangerine]

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
  # Added for the voting loop's `tally_bar/1` — the `05`/`05b` design frames draw
  # `VETOED` filled tangerine-on-white, which none of the four existing tones cover.
  defp pill_tone_class(:tangerine), do: "bg-tangerine text-white"

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
  The wizard header: a circular back button, an N-segment progress bar, and a `current/total`
  counter.

  `back` is a path to navigate to (typically a `~p` route) and is omitted entirely — no empty
  circle left behind — when `nil`. The segment row carries `role="progressbar"` with the
  matching `aria-value*` attributes and an `aria-label`, since a row of coloured bars is
  otherwise invisible to a screen reader.

  ## Examples

      <.step_progress total={3} current={1} back={~p"/"} />
      <.step_progress total={3} current={2} back={nil} />
  """
  attr :total, :integer, required: true
  attr :current, :integer, required: true
  attr :back, :string, default: nil, doc: "a path to navigate to; omitted when nil"
  attr :class, :any, default: nil
  attr :rest, :global

  def step_progress(assigns) do
    ~H"""
    <div class={["flex items-center gap-3", @class]} {@rest}>
      <.link
        :if={@back}
        navigate={@back}
        aria-label="Back"
        class="grid size-[34px] shrink-0 place-items-center rounded-full border-2 border-ink font-semibold hover:bg-yellow"
      >
        <span aria-hidden="true">‹</span>
      </.link>
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
  shadow (the ballot's `1b-4` sticker grid, `docs/design/screens/1b-4-sticker-grid-kept-in-play.html`,
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
        is_nil(@src) && "stripes-violet",
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
        onerror="this.style.display='none';this.parentElement.classList.add('stripes-violet')"
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
      <span
        class={[
          "grid shrink-0 place-items-center rounded-full border-2 font-bold",
          avatar_state_class(@state, avatar_fill(@participant_id), @ring),
          @class
        ]}
        style={"width:#{@size}px;height:#{@size}px;font-size:#{round(@size * 0.325)}px"}
        aria-hidden="true"
        {@rest}
      >{@initial}</span>
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

  `caption` is the small DM Mono line on the right of the label row. The two callers
  say different things — `"TAP TO NUDGE"` on `05` (the organizer), `"ORGANIZER NUDGES"`
  on `05b` (a participant) — and this component does not wire up a click for either;
  pass `nil` (the default) to omit the line entirely.

  ## Examples

      <.participant_avatar_row
        participants={Voting.participants(@group)}
        caption="TAP TO NUDGE"
      />

      <.participant_avatar_row
        participants={Voting.participants(@group)}
        current_participant_id={@participant.id}
        caption="ORGANIZER NUDGES"
      />
  """
  attr :participants, :list, required: true, doc: "Consensus.Voting.participants/1's shape"
  attr :current_participant_id, :integer, default: nil
  attr :caption, :string, default: nil
  attr :label, :string, default: nil, doc: "overrides the default \"N/M voted\" count"
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
          state={if(p.voted?, do: :voted, else: :waiting)}
          label={if(p.id == @current_participant_id, do: "you")}
          size={@avatar_size}
        />
      </div>
    </div>
    """
  end

  @doc """
  One row of the running tally (frames `05`/`05b`): the activity's name, its approval
  count (or the tangerine `VETOED` pill), and the 16px bar.

  Built to take one row of `Consensus.Voting.tally/1`'s return shape —
  `%{activity:, approvals:, vetoed?:, leader?:, bar_percent:, ...}` — straight through,
  so a caller does `<.tally_bar :for={row <- @tally} row={row} />` with no reshaping.
  The tangerine `★` renders whenever `row.leader?` is true; `tally/1` already
  guarantees a vetoed row is never the leader, so this component does not re-check it.

  A vetoed row strikes the name through, mutes it, swaps the approval count for the
  `VETOED` pill (`pill/1`'s `:tangerine` tone), and replaces the violet fill with the
  inert `.stripes-vetoed` pattern (`assets/css/app.css`) instead of drawing a 0%-width
  bar — colour is never the only signal (CLAUDE.md's neighbour rule to invariant 11):
  struck-through text, a pill, and a different bar texture all say "eliminated"
  together.

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
          <span :if={@row.leader?} class="text-tangerine">★</span>
        </span>
        <span :if={!@row.vetoed?} class="shrink-0 font-mono text-[11px] text-ink-soft">
          {@row.approvals}
        </span>
        <.pill :if={@row.vetoed?} tone={:tangerine} class="shrink-0">Vetoed</.pill>
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
end
