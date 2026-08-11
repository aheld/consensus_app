defmodule ConsensusWeb.EndgameComponents do
  @moduledoc """
  The shared chrome of the endgame takeover screens (`docs/plans/endgame-screens.md`) —
  the designed states that replace the whole results panel when a `:completed` group
  could not settle itself: every option vetoed (`docs/design/all-vetoed.dc.html`) or a
  dead heat at the top (`docs/design/tie.dc.html`).

  Both designs share one skeleton, and these components are that skeleton built once:

    * `endgame_hero/1` — the dark scene card: ink border, `rounded-2xl`,
      `shadow-sticker-4`, a scene the caller supplies as the inner block, a yellow
      buzzing counter chip top-left and a quiet outlined label chip top-right. The
      docs draw it 250px tall; `height_class` is where a screen whose scene
      full-bleed slice-fills swaps that for the viewBox's own aspect (the Tie does).
    * `endgame_headline/1` — the 700 30px headline over the 400 14px subline.
    * `endgame_list/1` — the bordered list card with the DM Mono header band
      (`THE CARNAGE` / `TIED FOR FIRST`); the rows are the caller's, because the two
      screens' rows share nothing but the card they sit in.

  What is *not* here: the scenes (each screen transcribes its own SVG), the action
  stacks (the exits are what the two screens most differ on), and every event. Each
  screen's logic lives in its own module — `ConsensusWeb.Endgame.AllVetoed` and
  `ConsensusWeb.Endgame.Tie` — so the screens can be iterated independently; this
  module is paint only.

  The design docs draw their surfaces at radius 18/14/13 and this module renders all of
  them `rounded-2xl`, which is the sticker system's one surface radius — the same
  flattening every other imported frame got (design-system skill, rule 3). The scene
  keyframes (`flick`, `flick2`, `bob`, `ember`, `buzz`) live in `assets/css/app.css`.
  """

  use Phoenix.Component

  @doc """
  Which endgame takeover — if any — a results screen should render instead of its
  ordinary `ResultsComponents.results_panel/1`. Called by both results LiveViews with
  the group and the outcome they already computed, so the two screens cannot disagree
  about when the takeover shows.

  `:all_vetoed` only when the group is `:completed`, the outcome is `:no_consensus`,
  **and no resolution is recorded** — a rescued group has a winner and renders the
  ordinary winner ending, and a mid-vote all-vetoed pool keeps the running tally
  (people can still approve; the state can still gain vetoes). `:tie` only for
  `Consensus.Voting.outcome/2`'s `{:tie, rows}`, which that function already gates on
  `:completed` + unresolved — a resolved tie arrives as `{:winner, row}` and a
  mid-vote dead heat is a `{:leader, row}` the deadline can still break. The
  status/resolution guard is repeated here anyway, so a caller handing this function
  a flags-only reading cannot take over a screen the plan says to leave alone.
  `nil` otherwise.
  """
  def takeover(%{status: :completed, resolution: nil}, :no_consensus), do: :all_vetoed
  def takeover(%{status: :completed, resolution: nil}, {:tie, _rows}), do: :tie
  def takeover(_group, _outcome), do: nil

  @doc """
  The hero scene card. The caller supplies the scene itself (a positioned backdrop
  plus an SVG, both `absolute inset-0`) as the inner block; this component supplies
  the card and the two chips over it.

  `height_class` is how tall the card stands, and the two screens deliberately differ:
  the default is the design docs' own fixed `h-[250px]` (All Vetoed keeps it — its
  scene is a bottom-centered fixed-aspect SVG, so the card's height is free), while
  the Tie screen passes `aspect-[7/5]` so the card keeps its scene's 350×250 viewBox
  ratio at any width — its scene is the doc's own full-bleed `slice` fill, and a fixed
  height under a wider-than-346px column makes `slice` crop the sky and cramp the
  figures (the composition regression a blind judge caught).

  `as: "button"` (plus `type="button"` and a `phx-click` through `rest`) makes the whole
  card the control — the All Vetoed screen's poke. The default is an inert `"div"` for a
  scene that is not itself tappable. Children are `<span>`s, not `<div>`s, so the
  rendered markup stays valid inside a `<button>`.

  ## Examples

      <.endgame_hero
        as="button"
        type="button"
        phx-click="poke"
        phx-target={@myself}
        aria-label="Poke the guy in the fire"
        counter="VETOES 6/6"
        label="TAP THE GUY"
      >
        <.fire_scene />
      </.endgame_hero>
  """
  attr :as, :string, default: "div", doc: ~s(the container tag — "button" for a poke toy)
  attr :counter, :string, required: true, doc: "the yellow buzzing chip, top-left"
  attr :label, :string, required: true, doc: "the quiet outlined chip, top-right"

  attr :height_class, :string,
    default: "h-[250px]",
    doc: ~s(the card's height — "aspect-[7/5]" for a scene that full-bleed slice-fills)

  attr :label_class, :string,
    default: "border-peach text-peach",
    doc: "border/text colour pair for the label chip — the fire scene's is peach"

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(type)
  slot :inner_block, required: true, doc: "the scene: backdrop + SVG, absolute inset-0"

  def endgame_hero(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@as}
      class={[
        "relative block w-full overflow-hidden rounded-2xl border-2 border-ink",
        "bg-ink text-left shadow-sticker-4",
        @height_class,
        @as == "button" && "cursor-pointer",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <span
        class={[
          "endgame-buzz absolute left-3.5 top-3.5 rounded-lg border-2 border-ink bg-yellow",
          "px-[9px] py-[5px] font-mono text-[10px] font-medium text-ink"
        ]}
        aria-hidden="true"
      >
        {@counter}
      </span>
      <span
        class={[
          "absolute right-3.5 top-3.5 rounded-lg border-2 px-[9px] py-[5px]",
          "font-mono text-[9.5px] font-medium",
          @label_class
        ]}
        aria-hidden="true"
      >
        {@label}
      </span>
    </.dynamic_tag>
    """
  end

  @doc """
  The headline block under the hero: 700 30px/1.08 over 400 14px/1.5, both ink on the
  page, both `text-pretty` as the design docs' `text-wrap:pretty`.
  """
  attr :headline, :string, required: true
  attr :subline, :string, required: true
  attr :class, :any, default: nil

  def endgame_headline(assigns) do
    ~H"""
    <div class={["flex flex-col gap-[7px]", @class]}>
      <h1 class="text-pretty text-[30px] font-bold leading-[1.08] tracking-[-0.02em] text-ink">
        {@headline}
      </h1>
      <p class="text-pretty text-sm leading-[1.5] text-ink-soft">{@subline}</p>
    </div>
    """
  end

  @doc """
  The bordered list card: a DM Mono header band over caller-supplied rows, hairline
  (`divide-ink-12`) dividers between them. The band's right side is an optional slot for
  a state chip (the tie screen's `TAP ONE` / `APP PICKED`); All Vetoed leaves it empty.

  `band_class` recolours the band — the tie screen passes `"endgame-tie-band"` (the
  design's violet band with its own dark-violet ink) plus `title_class="text-current"`
  so the title and the state chip both inherit it; All Vetoed keeps the neutral
  defaults.
  """
  attr :title, :string, required: true
  attr :band_class, :string, default: "bg-surface", doc: "the header band's fill"

  attr :title_class, :string,
    default: "text-muted",
    doc: ~s(the band text's colour — "text-current" to inherit band_class's own ink)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :band, doc: "optional right side of the header band — a state chip"
  slot :inner_block, required: true, doc: "the rows"

  def endgame_list(assigns) do
    ~H"""
    <div class={["overflow-hidden rounded-2xl border-2 border-ink bg-white", @class]} {@rest}>
      <div class={[
        "flex items-center justify-between gap-2 border-b-2 border-ink px-[13px] py-[9px]",
        @band_class
      ]}>
        <span class={["font-mono text-[10px] font-medium tracking-[0.07em]", @title_class]}>
          {@title}
        </span>
        {render_slot(@band)}
      </div>
      <div class="flex flex-col divide-y divide-ink-12">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
