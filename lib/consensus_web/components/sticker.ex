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
  attr :tone, :atom, default: :mint, values: [:mint, :yellow, :violet, :mint_soft]
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
  """
  attr :src, :string, default: nil
  attr :alt, :string, required: true
  attr :height, :string, default: "h-[150px]", doc: "a Tailwind height class"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "overlay badges/buttons positioned over the frame"

  def photo_frame(assigns) do
    ~H"""
    <div
      class={[
        "relative overflow-hidden rounded-2xl border-2 border-ink shadow-sticker-3",
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
end
