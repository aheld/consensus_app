defmodule ConsensusWeb.JoinLive.Ballot do
  @moduledoc """
  The sticker-grid ballot — `/join/:slug/vote` (`docs/design/screens/1b-4-sticker-grid-kept-in-play.html`).

  Approval voting only: "Tap all you'd be happy with · Pick as many as you like." There
  is no ranking anywhere in here — ranked-choice is explicitly Post-MVP
  (`docs/plans/voting-loop.md`).

  `ConsensusWeb.JoinAuth`'s `:resolve_participant` hook has already assigned `@group`
  (with `:activities` preloaded, in position order — see
  `Consensus.Activities.get_group_by_slug/1`) and `@participant` (`nil` when the
  visitor has not joined) before `mount/3` runs here, and it deliberately does **not**
  enforce the two guards this screen owns:

    * **No participant yet.** A visitor who lands on `/join/:slug/vote` without having
      gone through `06 entry` (`POST /join/:slug/enter`) first has no ballot to cast —
      sent back to `/join/:slug` to join.
    * **The ballot is locked (D-036).** `participant.voted_at` set means
      `Consensus.Voting.cast_ballot/3` will refuse with `{:error, :already_voted}` no
      matter what this screen renders, so re-entering this route once it is set
      redirects straight to results. This is a route-level fact checked in `mount/3`,
      not a `disabled` button — the same shape D-021's sudo-mode UI and D-037's frozen
      pool use elsewhere in this app.

  ## Selection state is local until submit

  `@approved` (a `MapSet` of activity ids) and `@veto_id` (an integer or `nil` — at
  most one veto, per `Consensus.Voting.tally/1`'s rule, "everyone gets one veto") live
  only in this socket's assigns until "Send my votes" is pressed. Nothing is written
  to the database, and nothing is broadcast, until `cast_ballot/3` runs — a mis-tap
  costs nothing before submit, which is the only recovery this screen offers (D-036:
  there is no recovery *after* submit).

  Vetoing a card that was approved un-approves it, and vice versa — a card can never
  read as both at once (`ensure_no_veto_conflict/2` in `Consensus.Voting` would refuse
  it server-side regardless, but the UI never lets the client build that state to begin
  with). Clicking a second card's veto control **moves** the single veto rather than
  refusing the click; the footer's "N VETOES LEFT" always reads 0 or 1, honestly.

  ## Deviations from the comp, and why

  See the moduledoc-level notes inline below for each: the dashed "Add your own" tile
  is omitted (out of scope — friends adding options to someone else's pool is a
  separate feature), the meta line under each name is the activity's description
  rather than the comp's fictitious `$$$ · 4.5★` (this schema carries no price/rating —
  Yelp/Places is Post-MVP), the unselected hover uses the existing `hover:bg-yellow`
  token instead of the comp's literal `#FFF6DC` (no raw hex in HEEx — design-system
  skill), and there is an explicit veto control the comp only implies through its
  copy ("1 VETO LEFT") with no visible affordance for it.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities.Activity
  alias Consensus.Voting

  @impl true
  def mount(_params, _session, socket) do
    %{group: group, participant: participant} = socket.assigns

    cond do
      is_nil(participant) ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}")}

      not is_nil(participant.voted_at) ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}/results")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Vote · #{group.title}")
         |> assign(:approved, MapSet.new())
         |> assign(:veto_id, nil)}
    end
  end

  ## Events

  @impl true
  def handle_event("toggle_approve", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        socket =
          if id == socket.assigns.veto_id do
            # The approve button is `disabled` for a vetoed card, but a disabled attribute
            # is a client-side hint, not enforcement (D-021's own reasoning) — ignore a
            # pushed event for a vetoed card rather than letting it slip past the UI's
            # own "never both" rule.
            socket
          else
            toggle_set(socket, :approved, id)
          end

        {:noreply, socket}

      _not_an_integer ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_veto", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        current_veto = socket.assigns.veto_id

        {new_veto_id, approved} =
          if current_veto == id do
            {nil, socket.assigns.approved}
          else
            # Moves the single veto rather than refusing the click — "everyone gets one
            # veto" (Consensus.Voting), and moving it is friendlier than making the voter
            # un-veto the old card before they can veto a different one. Un-approves the
            # newly-vetoed card so the two states can never coexist.
            {id, MapSet.delete(socket.assigns.approved, id)}
          end

        {:noreply, socket |> assign(:veto_id, new_veto_id) |> assign(:approved, approved)}

      _not_an_integer ->
        {:noreply, socket}
    end
  end

  def handle_event("submit_ballot", _params, socket) do
    %{participant: participant, group: group, approved: approved, veto_id: veto_id} =
      socket.assigns

    case Voting.cast_ballot(participant, MapSet.to_list(approved), veto_id) do
      {:ok, _voted_participant} ->
        {:noreply, push_navigate(socket, to: ~p"/join/#{group.slug}/results")}

      {:error, reason} ->
        {:noreply, handle_cast_error(socket, group, reason)}
    end
  end

  defp toggle_set(socket, key, id) do
    set = Map.fetch!(socket.assigns, key)
    updated = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
    assign(socket, key, updated)
  end

  # Every refusal `Consensus.Voting.cast_ballot/3` documents, handled explicitly —
  # CLAUDE.md invariant 4: a voter must never see this escape as a crash. The first
  # three are "the vote is over, one way or another" and send the voter on to results;
  # the rest are "fix this and try again", so they stay on the ballot with a flash.
  defp handle_cast_error(socket, group, :already_voted) do
    socket
    |> put_flash(:info, "Your vote is already in.")
    |> push_navigate(to: ~p"/join/#{group.slug}/results")
  end

  defp handle_cast_error(socket, group, reason) when reason in [:not_open, :deadline_passed] do
    socket
    |> put_flash(:info, "Voting has closed.")
    |> push_navigate(to: ~p"/join/#{group.slug}/results")
  end

  defp handle_cast_error(socket, group, :not_found) do
    socket
    |> put_flash(:error, "We lost track of you — join again to vote.")
    |> push_navigate(to: ~p"/join/#{group.slug}")
  end

  defp handle_cast_error(socket, _group, :empty_ballot) do
    put_flash(socket, :error, "Pick at least one, or veto one, before sending.")
  end

  defp handle_cast_error(socket, _group, :veto_conflict) do
    put_flash(socket, :error, "That option can't be both approved and vetoed.")
  end

  defp handle_cast_error(socket, _group, :unknown_activity) do
    put_flash(socket, :error, "Something in the pool changed — refresh and try again.")
  end

  defp handle_cast_error(socket, _group, :veto_not_allowed) do
    put_flash(socket, :error, "Vetoes aren't allowed in this group.")
  end

  defp handle_cast_error(socket, _group, {:database_busy, _message}) do
    put_flash(socket, :error, "Lots of people are voting right now — try again in a second.")
  end

  defp handle_cast_error(socket, _group, _other) do
    put_flash(socket, :error, "Something went wrong — try again.")
  end

  ## View helpers

  defp approved?(id, approved), do: MapSet.member?(approved, id)
  defp vetoed?(id, veto_id), do: veto_id == id

  defp submit_disabled?(approved, veto_id),
    do: MapSet.size(approved) == 0 and is_nil(veto_id)

  # The comp's meta line reads "$$$ · 4.5★" — a price and a rating this schema has no
  # field for (Yelp/Places is Post-MVP, CLAUDE.md scope discipline). The description an
  # organizer typed or a link preview filled in is the closest real data to that slot;
  # `activity_fixture/2`-created options and a typed-with-no-description option both
  # fall back to plain text rather than an empty line.
  defp meta_line(%Activity{description: description})
       when is_binary(description) and description != "" do
    description
  end

  defp meta_line(%Activity{}), do: "No details yet"

  defp ballot_status_text(approved, veto_id, veto_allowed?) do
    picked_text = "#{MapSet.size(approved)} PICKED"

    if veto_allowed? do
      veto_left = if veto_id, do: 0, else: 1
      veto_word = if veto_left == 1, do: "VETO", else: "VETOES"
      "#{picked_text} · #{veto_left} #{veto_word} LEFT"
    else
      picked_text
    end
  end

  defp veto_button_label(%Activity{name: name}, veto_id, id) do
    if veto_id == id, do: "Remove veto on #{name}", else: "Veto #{name}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} background="bg-canvas">
      <div class="flex min-h-dvh flex-col">
        <div class="px-4 pb-2 pt-4">
          <h1 class="text-[19px] font-bold leading-[1.1] tracking-[-0.025em] text-ink">
            Tap all you'd be happy with
          </h1>
          <p class="mt-1 text-[11.5px] text-ink-soft">Pick as many as you like.</p>
        </div>

        <div class="grid flex-1 grid-cols-2 content-start gap-2.5 px-4 py-2">
          <%!-- `min-w-0` is load-bearing: a grid item defaults to `min-width: auto`, which lets a
          long description force the column wider than its track instead of being clipped, so
          the meta line spilled past the card's own border. Same trap D-024 records for flex. --%>
          <div
            :for={activity <- @group.activities}
            class="relative min-w-0"
            id={"activity-#{activity.id}"}
          >
            <button
              type="button"
              phx-click="toggle_approve"
              phx-value-id={activity.id}
              disabled={vetoed?(activity.id, @veto_id)}
              aria-pressed={to_string(approved?(activity.id, @approved))}
              class={[
                "relative flex min-h-[96px] w-full flex-col gap-1.5 rounded-2xl border-2 border-ink p-2.5",
                "text-left shadow-sticker-3 press-3 transition-colors",
                "disabled:cursor-not-allowed disabled:opacity-60 disabled:shadow-none",
                cond do
                  vetoed?(activity.id, @veto_id) -> "bg-white"
                  approved?(activity.id, @approved) -> "bg-mint"
                  true -> "bg-white hover:bg-yellow"
                end
              ]}
            >
              <span
                :if={approved?(activity.id, @approved)}
                class="absolute right-2 top-2 grid size-[21px] place-items-center rounded-full border-2 border-ink bg-ink text-[11px] font-semibold text-white"
                aria-hidden="true"
              >
                ✓
              </span>
              <.photo_frame
                src={activity.image_url}
                alt={activity.name}
                height="h-[38px]"
                bare
                class="rounded-[9px] border-[1.5px] border-ink"
              />
              <p class={[
                "pr-5 text-[13px] font-bold leading-[1.15]",
                if(vetoed?(activity.id, @veto_id),
                  do: "text-muted line-through",
                  else: "text-ink"
                )
              ]}>
                {activity.name}
              </p>
              <div class="mt-auto w-full min-w-0">
                <.pill :if={vetoed?(activity.id, @veto_id)} tone={:tangerine}>Vetoed</.pill>
                <%!-- `truncate` needs a block box to clip against; on a bare inline <span> the
                ellipsis never applies and a 140-character description runs off the card. --%>
                <span
                  :if={!vetoed?(activity.id, @veto_id)}
                  class="block truncate font-mono text-[10.5px] text-ink-soft"
                >
                  {meta_line(activity)}
                </span>
              </div>
            </button>

            <button
              :if={@group.veto_allowed}
              type="button"
              phx-click="toggle_veto"
              phx-value-id={activity.id}
              aria-label={veto_button_label(activity, @veto_id, activity.id)}
              aria-pressed={to_string(vetoed?(activity.id, @veto_id))}
              class={[
                "absolute left-2 top-2 z-10 grid size-6 place-items-center rounded-full border-2 border-ink",
                if(vetoed?(activity.id, @veto_id),
                  do: "bg-tangerine text-white",
                  else: "bg-white text-ink-soft hover:bg-yellow"
                )
              ]}
            >
              <.icon name="hero-no-symbol" class="size-3.5" />
            </button>
          </div>
        </div>

        <div class="flex flex-col gap-2 px-4 pb-6 pt-2">
          <p
            class="text-center font-mono text-[11px] text-ink-soft"
            aria-live="polite"
            id="ballot-status"
          >
            {ballot_status_text(@approved, @veto_id, @group.veto_allowed)}
          </p>
          <.button
            id="submit-ballot"
            variant="primary"
            type="button"
            phx-click="submit_ballot"
            disabled={submit_disabled?(@approved, @veto_id)}
          >
            Send my votes
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
