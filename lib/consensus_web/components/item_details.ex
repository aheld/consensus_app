defmodule ConsensusWeb.ItemDetails do
  @moduledoc """
  How an option's details (D-060 — website, phone, address, location, category) render
  outside the `02b` editor: design frame `t7`.

    * `detail_line/1` — the category chip and the street address on one truncating
      line, under an option's name on `02`/`03` cards, the guest ballot and the `05`
      winner card (`t7-e`/`t7-f`/`t7-g`).
    * `osm_credit/1` — the ODbL line owed wherever OpenStreetMap-derived details render
      (research trap I). Shown once per list when any item's details came from OSM
      (`osm_derived?/1` — an `osm_ref` on the row), never per card.
    * `action_row/1` — the winner card's **Call · Directions** (`t7-g`, with the owner's
      2026-10-25 ruling that the website stays the card's tangerine **View … →** rather
      than a third white button that would duplicate it).
    * `info_sheet/1` — the ballot's read-only **More** sheet (`t8-c`, D-062): photo, the
      full name, chip + the full address, the full description and **Website ↗**. It
      holds no vote controls and never touches the ballot's selections.

  Everything that reaches an `href` is built here from stored values, never passed
  through raw: `tel:` from `+` and digits only (`Activity.tel_href/1`), and the two
  openstreetmap.org shapes from floats or a URI-encoded address. No third party learns
  anything until someone taps.
  """

  use Phoenix.Component

  alias Consensus.Activities.Activity
  alias ConsensusWeb.Sticker
  alias Phoenix.LiveView.JS
  alias Consensus.Discovery.Provider.Nominatim

  @doc "Whether any of `activities` carries OSM-derived details (and so owes the credit)."
  def osm_derived?(activities) when is_list(activities),
    do: Enum.any?(activities, &osm_derived?/1)

  def osm_derived?(%Activity{osm_ref: ref}), do: is_binary(ref) and ref != ""
  def osm_derived?(_other), do: false

  @doc "Whether an option has anything for `detail_line/1` to show."
  def has_detail_line?(%Activity{category: category, address: address}),
    do: present?(category) or present?(address)

  @doc """
  Where **Directions** goes: the map location on openstreetmap.org, or, with an address
  but no location (`t7-g`'s Kismet case, accepted 2026-10-25), an OSM address search.
  `nil` when there is neither.
  """
  def directions_href(%Activity{latitude: lat, longitude: lon})
      when is_float(lat) and is_float(lon) do
    lat = coordinate(lat)
    lon = coordinate(lon)
    "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=18/#{lat}/#{lon}"
  end

  def directions_href(%Activity{address: address}) do
    if present?(address),
      do: "https://www.openstreetmap.org/search?" <> URI.encode_query(%{"query" => address}),
      else: nil
  end

  @doc "The editor's **Open in Maps** link — the location only, never an address search."
  def map_href(lat, lon) when is_float(lat) and is_float(lon),
    do: directions_href(%Activity{latitude: lat, longitude: lon})

  def map_href(_lat, _lon), do: nil

  @doc "A stored category as the chip shows it (`\"new american\"` → `\"New american\"`)."
  def category_text(category) when is_binary(category), do: String.capitalize(category)
  def category_text(_category), do: nil

  attr :activity, Activity, required: true
  attr :size, :atom, values: [:card, :tile, :winner], default: :card
  attr :class, :any, default: nil

  @doc """
  The category chip (`t5`'s small-pill convention: 1.5px `ink/45`) and the street
  address, one line, the address truncating. Renders nothing when the option has
  neither — the card keeps whatever line it had before details existed.
  """
  def detail_line(assigns) do
    ~H"""
    <div
      :if={has_detail_line?(@activity)}
      class={["flex min-w-0 items-center", gap(@size), @class]}
    >
      <span
        :if={present?(@activity.category)}
        class={[
          "flex-none rounded-full border-[1.5px] border-ink/45 font-semibold text-ink",
          chip_size(@size)
        ]}
      >
        {category_text(@activity.category)}
      </span>
      <span
        :if={present?(@activity.address)}
        class={["min-w-0 flex-1 truncate font-mono text-muted", address_size(@size)]}
      >
        {@activity.address}
      </span>
    </div>
    """
  end

  defp gap(:winner), do: "gap-[7px]"
  defp gap(_size), do: "gap-1.5"

  defp chip_size(:winner), do: "px-2 py-px text-[11px] leading-[1.4]"
  defp chip_size(_size), do: "px-[7px] py-px text-[10px] leading-[1.35]"

  defp address_size(:winner), do: "text-[11px]"
  defp address_size(_size), do: "text-[10.5px]"

  attr :class, :any, default: nil
  attr :id, :string, default: nil

  @doc """
  "Places from OpenStreetMap contributors" — the provider's own pre-split attribution
  (only the contributors phrase is a link, to the ODbL licence), in DM Mono 9px
  `--faint`. The words and the URL come from `Nominatim.attribution/0`, the same
  source the `02` assist slot renders, so the two can never drift.

  Always a new tab, like the assist slot's credit — and on the `/join` tree that is
  required, not a convenience: a guest's unsent ballot lives in socket assigns, and a
  same-tab link off it discards it (owner ruling, 2026-10-25).
  """
  def osm_credit(assigns) do
    assigns = assign(assigns, :attribution, Nominatim.attribution())

    ~H"""
    <p id={@id} class={["font-mono text-[9px] text-faint", @class]}>
      {@attribution.prefix}<a
        href={@attribution.url}
        target="_blank"
        rel="noopener noreferrer"
        class="underline hover:text-tangerine active:text-tangerine"
      >{@attribution.text}</a>
    </p>
    """
  end

  attr :activity, Activity, required: true
  attr :id, :string, default: nil

  @doc """
  **Call · Directions** under the winner (`t7-g`). Each appears only when its detail
  exists; the row is absent, not empty, when neither does. White, ≥44px, splitting the
  row equally — none of them is the screen's forward action.
  """
  def action_row(assigns) do
    assigns =
      assigns
      |> assign(:tel, Activity.tel_href(assigns.activity.phone))
      |> assign(:directions, directions_href(assigns.activity))

    ~H"""
    <div :if={@tel || @directions} id={@id} class="flex gap-2">
      <a :if={@tel} href={@tel} class={action_class()}>Call</a>
      <a
        :if={@directions}
        href={@directions}
        target="_blank"
        rel="noopener noreferrer"
        class={action_class()}
      >
        Directions
      </a>
    </div>
    """
  end

  defp action_class do
    [
      "grid min-h-11 min-w-0 flex-1 place-items-center rounded-[14px] border-2 border-ink bg-white",
      "text-[13.5px] font-bold text-ink shadow-sticker-2 press-2 hover:bg-yellow active:bg-yellow"
    ]
  end

  attr :activity, Activity, required: true
  attr :id, :string, default: "info-sheet"
  attr :stripe, :string, default: "stripes-violet"

  attr :on_close, JS,
    required: true,
    doc: "run by ✕ and by Escape — the only two ways out (t8 ruling 5)"

  @doc """
  The read-only option sheet (`t8-c`): a bottom sheet over a scrim, opened from a ballot
  tile's or the deck header's **More**.

  Rows that don't apply are left out, without gaps. The scrim swallows taps rather than
  closing — ✕ and Escape are the only exits, and browser back is deliberately not
  intercepted: making it close the sheet needs a pushed history entry, i.e. a navigation,
  and on the `/join` tree a navigation is what discards an unsent ballot (t8 ruling 5).
  Every link here is a new tab for the same reason (t7 ruling 4).

  Focus moves to ✕ when it opens, and `focus_wrap/1` keeps Tab inside it; the caller's
  `on_close` is expected to `JS.pop_focus/0` back to the control that opened it.
  """
  def info_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-ink/50" aria-hidden="true"></div>
      <.focus_wrap
        id={@id}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-name"}
        phx-mounted={JS.focus(to: "##{@id}-close")}
        phx-window-keydown={@on_close}
        phx-key="Escape"
        class="absolute inset-x-0 bottom-0 mx-auto flex max-h-[92%] w-full max-w-[440px] flex-col overflow-y-auto rounded-t-[24px] border-t-2 border-ink bg-white"
      >
        <div class="flex items-center justify-between pb-2 pl-[18px] pr-3 pt-2.5">
          <span class="font-mono text-[10.5px] font-semibold tracking-[0.08em] text-muted">
            OPTION DETAILS
          </span>
          <button
            type="button"
            id={"#{@id}-close"}
            phx-click={@on_close}
            aria-label="Close"
            class="grid size-11 place-items-center rounded-full border-2 border-ink bg-white text-[16px] font-semibold leading-none text-ink shadow-sticker-2 press-2 hover:bg-yellow active:bg-yellow"
          >
            ✕
          </button>
        </div>
        <Sticker.photo_frame
          src={@activity.image_url}
          alt={@activity.name}
          height="h-[128px]"
          bare
          stripe={@stripe}
          class="mx-[18px] flex-none rounded-[14px] border-2 border-ink"
        />
        <div class="flex flex-col gap-[11px] px-[18px] pb-6 pt-3.5">
          <h2
            id={"#{@id}-name"}
            class="text-[24px] font-bold leading-[1.1] tracking-[-0.02em] text-ink"
          >
            {@activity.name}
          </h2>
          <div :if={has_detail_line?(@activity)} class="flex items-baseline gap-2">
            <span
              :if={present?(@activity.category)}
              class="flex-none rounded-full border-[1.5px] border-ink/45 px-2 py-0.5 text-[11.5px] font-semibold text-ink"
            >
              {category_text(@activity.category)}
            </span>
            <span
              :if={present?(@activity.address)}
              id={"#{@id}-address"}
              class="min-w-0 flex-1 font-mono text-[11.5px] leading-[1.45] text-muted"
            >
              {@activity.address}
            </span>
          </div>
          <p
            :if={present?(@activity.description)}
            id={"#{@id}-description"}
            class="text-[15px] leading-[1.5] text-ink-soft [text-wrap:pretty]"
          >
            {@activity.description}
          </p>
          <a
            :if={present?(@activity.source_url)}
            id={"#{@id}-website"}
            href={@activity.source_url}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex min-h-11 items-center gap-1.5 self-start rounded-[14px] border-2 border-ink bg-white px-4 text-[14px] font-bold text-ink shadow-sticker-2 press-2 hover:bg-yellow active:bg-yellow"
          >
            Website <span aria-hidden="true">↗</span>
          </a>
          <.osm_credit :if={osm_derived?(@activity)} id={"#{@id}-osm-credit"} />
        </div>
      </.focus_wrap>
    </div>
    """
  end

  # Seven decimals, OSM's precision, without float noise in the URL.
  defp coordinate(value), do: :erlang.float_to_binary(value, [:compact, decimals: 7])

  defp present?(value), do: is_binary(value) and value != ""
end
