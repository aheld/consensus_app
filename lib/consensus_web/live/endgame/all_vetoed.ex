defmodule ConsensusWeb.Endgame.AllVetoed do
  @moduledoc """
  The All Vetoed takeover (`docs/design/all-vetoed.dc.html`,
  `docs/plans/endgame-screens.md`) — the designed state that replaces the whole results
  panel on both results screens when a `:completed` group's every option was vetoed and
  nothing has resolved it yet. `ConsensusWeb.EndgameComponents.takeover/2` is the
  trigger both callers share; this LiveComponent is everything inside it: the fire
  scene, the poke toy, THE CARNAGE list, and the two exits.

  ## Who sees what

  `role={:organizer}` (from `ConsensusWeb.GroupLive.Results`, which also passes the
  `%Scope{}` the writes need) gets the two real exits the design draws — **Add new
  options** (→ `Consensus.Activities.reopen_group/2`, then `/groups/:id/options`) and
  **Let the app pick one at random** (→ `Activities.rescue_group/2`, whose
  `{:group_updated, group}` broadcast flips every open results screen to the ordinary
  winner ending at once). `role={:guest}` (from `ConsensusWeb.JoinLive.Results`) gets
  the same scene, headline and carnage, a waiting line naming the organizer as the one
  who can fix it, and the join tree's standing `Create your own →` exit — never the
  organizer's buttons, which are writes on the organizer's group. The poke toy is
  everyone's: it is client-visible socket state and writes nothing.

  ## The carnage list shows counts, never names — a deliberate design deviation

  The design's sample rows attribute each veto to a person (`MAYA`, `DEV`). D-035 makes
  that structurally impossible — `Consensus.Voting.tally/1` returns totals only, and no
  query exists that could say who vetoed what — so the same mono slot carries the veto
  *count* (`1 VETO`, `2 VETOES`). Same slot, same type, honest data.

  ## Refusals flash, and the parent renders the flash

  A `put_flash` in a LiveComponent is discarded unless it rides a redirect, so the two
  writes report through the parent instead: `{:endgame_flash, kind, message}` asks the
  parent LiveView to flash, and `:endgame_refresh` asks it to reload — which is how a
  stale tab that presses **Let the app pick** after another tab already settled the
  group (the window between the commit and PubSub delivery) gets an honest flash *and*
  flips to the winner ending it missed. Only `ConsensusWeb.GroupLive.Results` carries
  the two `handle_info/2` clauses, because only the organizer role can reach a write —
  the guest branch renders neither button, and a forged event from a guest socket
  matches the ignore clauses below and does nothing.

  Stage 2's subline says "restaurants" — the design's verbatim copy. Screen copy in the
  web layer, not a branch on `activity_type`; CLAUDE.md invariant 12 is untouched.
  """

  use ConsensusWeb, :live_component

  alias Consensus.Activities

  import ConsensusWeb.EndgameComponents

  # The four poke stages, verbatim from the design source's `stages` array. Tapping the
  # hero cycles 0 → 1 → 2 → 3 → 0 (`(pokes + 1) % 4`, exactly the design's `onPoke`).
  @stages [
    {"Nobody wanted anything.", "Every single option got vetoed. That is genuinely hard to do."},
    {"Still nothing.",
     "The group has now rejected more restaurants than most people visit in a year."},
    {"This is fine.", "It is not fine. Somebody has to pick a place eventually."},
    {"Total anarchy achieved.", "Congratulations. You have unlocked the worst possible outcome."}
  ]

  @impl true
  def mount(socket), do: {:ok, assign(socket, :pokes, 0)}

  @impl true
  def handle_event("poke", _params, socket) do
    {:noreply, update(socket, :pokes, &rem(&1 + 1, 4))}
  end

  def handle_event("add_options", _params, %{assigns: %{role: :organizer}} = socket) do
    case Activities.reopen_group(socket.assigns.scope, socket.assigns.group) do
      {:ok, group} ->
        # The flash survives because it rides the navigation — the one case a
        # LiveComponent's own `put_flash` works. It must mention the deadline: the old
        # one is cleared (`reopen_group/2`), and `publish_group/2` will refuse without
        # a fresh one set on `/groups/:id/edit`.
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The pool is open again — add new options, then set a new deadline " <>
             "before you publish round 2."
         )
         |> push_navigate(to: ~p"/groups/#{group}/options")}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  # A forged event from a socket that was never offered the button (a guest's).
  def handle_event("add_options", _params, socket), do: {:noreply, socket}

  def handle_event("app_rescue", _params, %{assigns: %{role: :organizer}} = socket) do
    case Activities.rescue_group(socket.assigns.scope, socket.assigns.group) do
      {:ok, group} ->
        # The broadcast already flipped this tab (and every other one) to the winner
        # ending; the flash names the pick so the organizer's own tab says what just
        # happened rather than silently re-rendering.
        send(
          self(),
          {:endgame_flash, :info,
           "The app picked #{rescued_name(socket, group)} at random — that's the final result."}
        )

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("app_rescue", _params, socket), do: {:noreply, socket}

  defp refuse(socket, reason) do
    send(self(), {:endgame_flash, :error, refusal_message(reason)})
    # The refusal usually means another tab already changed the group and this tab's
    # PubSub message is late or lost — re-reading is what flips this screen to the
    # state the refusal is about, instead of leaving a takeover that no longer applies.
    send(self(), :endgame_refresh)
    socket
  end

  defp refusal_message(:already_resolved),
    do: "Someone already settled this session — what's on screen now is the final result."

  defp refusal_message(:not_completed),
    do: "This session is no longer closed, so there is nothing to settle here."

  defp refusal_message(_reason),
    do: "This session has changed and no longer needs a rescue."

  defp rescued_name(socket, %{resolved_activity_id: id}) do
    case Enum.find(socket.assigns.tally, &(&1.activity.id == id)) do
      %{activity: %{name: name}} -> name
      nil -> "an option"
    end
  end

  # `VETOES N/N` where N is the pool size — every option is vetoed here by definition —
  # plus one per poke, which is the design's comic increment (`(6+p)/(6+p)`).
  defp counter(tally, pokes) do
    n = length(tally) + pokes
    "VETOES #{n}/#{n}"
  end

  defp veto_label(1), do: "1 VETO"
  defp veto_label(n), do: "#{n} VETOES"

  @impl true
  def render(assigns) do
    {headline, subline} = Enum.at(@stages, assigns.pokes)

    assigns =
      assigns
      |> assign(:headline, headline)
      |> assign(:subline, subline)
      |> assign(:counter, counter(assigns.tally, assigns.pokes))

    ~H"""
    <div id={@id} class="flex flex-col gap-[18px] px-5 pb-6 pt-[22px]">
      <.endgame_hero
        as="button"
        type="button"
        id="endgame-hero"
        phx-click="poke"
        phx-target={@myself}
        aria-label="Poke the guy in the fire"
        counter={@counter}
        label="TAP THE GUY"
      >
        <.fire_scene />
      </.endgame_hero>

      <.endgame_headline headline={@headline} subline={@subline} />

      <.endgame_list title="THE CARNAGE" id="endgame-carnage">
        <div
          :for={row <- @tally}
          class="flex items-center gap-2.5 px-[13px] py-[9px]"
          data-role="carnage-row"
        >
          <%!-- `size-[19px]`, not the doc's literal `width:15px`: the doc has no
                box-sizing reset, so its 15px is content-box and the 2px border renders
                the badge at 19×19 — a border-box 19px reproduces it exactly (same 15px
                content area for the ✕). Same trap as the tie rows' `size-6` dots. --%>
          <span
            class="grid size-[19px] shrink-0 place-items-center rounded-full border-2 border-tangerine text-[9px] font-bold leading-none text-tangerine"
            aria-hidden="true"
          >
            ✕
          </span>
          <span class="min-w-0 flex-1 truncate text-[13px] font-medium text-faint line-through">
            {row.activity.name}
          </span>
          <%!-- The count, never a name — see the moduledoc (D-035). --%>
          <span class="shrink-0 font-mono text-[10px] font-medium text-tangerine">
            {veto_label(row.vetoes)}
          </span>
        </div>
      </.endgame_list>

      <div :if={@role == :organizer} class="flex flex-col gap-[9px]">
        <%!-- Ink text on tangerine, unlike the app's usual white-on-tangerine primary —
              the design draws this one button that way and the plan says to follow it. --%>
        <button
          type="button"
          id="endgame-add-options"
          phx-click="add_options"
          phx-target={@myself}
          class="press-4 rounded-2xl border-2 border-ink bg-tangerine p-3.5 text-[15px] font-bold text-ink shadow-sticker-4"
        >
          Add new options
        </button>
        <button
          type="button"
          id="endgame-rescue"
          phx-click="app_rescue"
          phx-target={@myself}
          class="rounded-2xl border-2 border-ink bg-white p-3 text-sm font-semibold text-ink transition-colors hover:bg-yellow active:bg-yellow"
        >
          Let the app pick one at random
        </button>
        <p class="text-center font-mono text-[11.5px] text-muted">
          or accept that pizza was always the answer
        </p>
      </div>

      <div :if={@role == :guest} class="flex flex-col gap-[9px]">
        <p
          id="endgame-waiting"
          class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3.5 text-[12.5px] leading-[1.45] text-ink-soft"
        >
          Only {@organizer_username} can fix this — they can add new options, or let the
          app pick one at random. This page flips on its own the moment they do.
        </p>
        <.button navigate={~p"/"} id="results-start-your-own" variant="primary" class="w-full">
          Create your own <span aria-hidden="true">→</span>
        </.button>
      </div>
    </div>
    """
  end

  # ── The fire scene, transcribed exactly from `docs/design/all-vetoed.dc.html` ────────
  #
  # Geometry, transforms, animation durations and delays are the design's own numbers.
  # Colours land as classes rather than raw hex (`fill-tangerine`, `fill-yellow`,
  # `stroke-ink`, `fill-peach`, and `.endgame-flame-back` in app.css for the scene-paint
  # ember red); the keyframes (`flick`, `flick2`, `bob`, `ember`, `buzz`) live in
  # `assets/css/app.css`, each element carrying its own duration/delay inline exactly as
  # the design does — nine flames and four embers on different clocks are what keep the
  # fire from reading as a loop. The arms wave via SMIL `<animateTransform>`, also
  # verbatim.
  #
  # The SVG is a **fixed-aspect box bottom-centered in the card, not a full-bleed fill.**
  # The design's hero is 346px wide, so its `xMidYMax slice` renders the 350×250 viewBox
  # at scale ≈ 1 — a ~66px band of clear night sky above the guy's fists. Our hero is
  # ~400px at the 440px app column, and full-bleed `slice` there lets the *width* govern
  # the scale (400/350 ≈ 1.14): the figure blows up, the top 35 viewBox-units of sky are
  # cropped, and at the bob's peak his fists graze the chip row. (Extending the viewBox
  # upward alone fixes nothing — the width still governs.) Pinning the scene to the
  # design's own 350:250 aspect at the card's height reproduces the design's framing at
  # every width; the backdrop span paints the whole card behind it, and `overflow-visible`
  # lets the edge flames bleed into the side gutters exactly as they bleed past the
  # design's own viewBox edges.
  defp fire_scene(assigns) do
    ~H"""
    <span class="endgame-fire-bg absolute inset-0" aria-hidden="true"></span>
    <svg
      viewBox="0 0 350 250"
      preserveAspectRatio="xMidYMax slice"
      class="absolute bottom-0 left-1/2 aspect-[7/5] h-full -translate-x-1/2 overflow-visible"
      aria-hidden="true"
      focusable="false"
    >
      <g opacity=".55">
        <.flame
          variant={:back}
          transform="translate(38,256) scale(1.05)"
          animation="flick2 1.5s ease-in-out infinite"
        />
        <.flame
          variant={:back}
          transform="translate(132,258) scale(1.35)"
          animation="flick 1.9s ease-in-out infinite .4s"
        />
        <.flame
          variant={:back}
          transform="translate(238,256) scale(1.15)"
          animation="flick2 1.7s ease-in-out infinite .9s"
        />
        <.flame
          variant={:back}
          transform="translate(320,258) scale(1.25)"
          animation="flick 2.1s ease-in-out infinite .2s"
        />
      </g>

      <g class="endgame-bob">
        <g transform="translate(175,214)">
          <path
            d="M-30,10 C-34,-22 -30,-46 -25,-58 L25,-58 C30,-46 34,-22 30,10 Z"
            class="fill-tangerine stroke-ink"
            stroke-width="5"
            stroke-linejoin="round"
          />
          <g>
            <path
              d="M-25,-56 C-48,-70 -63,-96 -70,-124"
              fill="none"
              class="stroke-ink"
              stroke-width="16"
              stroke-linecap="round"
            />
            <path
              d="M-25,-56 C-48,-70 -63,-96 -70,-124"
              fill="none"
              class="stroke-tangerine"
              stroke-width="8"
              stroke-linecap="round"
            />
            <circle cx="-70" cy="-124" r="12" class="fill-yellow stroke-ink" stroke-width="5" />
            <animateTransform
              attributeName="transform"
              type="rotate"
              values="-12 -25 -56;9 -25 -56;-12 -25 -56"
              dur="0.62s"
              repeatCount="indefinite"
            />
          </g>
          <g>
            <path
              d="M25,-56 C48,-70 63,-96 70,-124"
              fill="none"
              class="stroke-ink"
              stroke-width="16"
              stroke-linecap="round"
            />
            <path
              d="M25,-56 C48,-70 63,-96 70,-124"
              fill="none"
              class="stroke-tangerine"
              stroke-width="8"
              stroke-linecap="round"
            />
            <circle cx="70" cy="-124" r="12" class="fill-yellow stroke-ink" stroke-width="5" />
            <animateTransform
              attributeName="transform"
              type="rotate"
              values="10 25 -56;-11 25 -56;10 25 -56"
              dur="0.62s"
              repeatCount="indefinite"
            />
          </g>
          <circle cx="0" cy="-96" r="46" class="fill-tangerine stroke-ink" stroke-width="5" />
          <circle cx="-18" cy="-104" r="15" class="fill-white stroke-ink" stroke-width="4.5" />
          <circle cx="18" cy="-104" r="15" class="fill-white stroke-ink" stroke-width="4.5" />
          <circle cx="-14" cy="-101" r="6" class="fill-ink" />
          <circle cx="22" cy="-101" r="6" class="fill-ink" />
          <path d="M-36,-124 L-22,-128" class="stroke-ink" stroke-width="5" stroke-linecap="round" />
          <path d="M36,-124 L22,-128" class="stroke-ink" stroke-width="5" stroke-linecap="round" />
          <path d="M-17,-80 C-13,-60 13,-60 17,-80 C 7,-73 -7,-73 -17,-80 Z" class="fill-ink" />
        </g>
      </g>

      <.flame
        variant={:front}
        transform="translate(20,254) scale(1.1)"
        animation="flick 1.05s ease-in-out infinite"
      />
      <.flame
        variant={:front}
        transform="translate(92,256) scale(1.5)"
        animation="flick2 .86s ease-in-out infinite .2s"
      />
      <.flame
        variant={:front}
        transform="translate(175,254) scale(1.15)"
        animation="flick 1.25s ease-in-out infinite .5s"
      />
      <.flame
        variant={:front}
        transform="translate(258,256) scale(1.45)"
        animation="flick2 .96s ease-in-out infinite .35s"
      />
      <.flame
        variant={:front}
        transform="translate(334,254) scale(1.2)"
        animation="flick 1.15s ease-in-out infinite .7s"
      />

      <circle
        cx="52"
        cy="168"
        r="4.5"
        class="endgame-ember fill-yellow"
        style="animation:ember 2.6s linear infinite"
      />
      <circle
        cx="146"
        cy="164"
        r="3.5"
        class="endgame-ember fill-peach"
        style="animation:ember 3.2s linear infinite .8s"
      />
      <circle
        cx="243"
        cy="166"
        r="5"
        class="endgame-ember fill-yellow"
        style="animation:ember 2.9s linear infinite 1.5s"
      />
      <circle
        cx="308"
        cy="170"
        r="3"
        class="endgame-ember fill-peach"
        style="animation:ember 3.5s linear infinite .4s"
      />
    </svg>
    """
  end

  # One flame: the design's shared lick path under a per-flame transform and animation
  # clock. `:back` is the dimmed ember-red row behind the guy; `:front` is the tangerine
  # row with the yellow core.
  attr :variant, :atom, required: true, values: [:back, :front]
  attr :transform, :string, required: true
  attr :animation, :string, required: true

  defp flame(assigns) do
    ~H"""
    <g transform={@transform}>
      <g class="endgame-scene-part" style={"animation:#{@animation}"}>
        <path
          d="M-30,4 C-36,-26 -22,-50 -11,-71 C-6,-82 -3,-91 -1,-101 C 5,-87 14,-71 22,-57 C 31,-42 35,-16 30,4 Z"
          class={if @variant == :back, do: "endgame-flame-back", else: "fill-tangerine"}
        />
        <path
          :if={@variant == :front}
          d="M-14,4 C-19,-18 -10,-38 -4,-56 C 0,-46 8,-36 12,-24 C 16,-13 16,-4 14,4 Z"
          class="fill-yellow"
        />
      </g>
    </g>
    """
  end
end
