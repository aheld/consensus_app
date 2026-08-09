defmodule ConsensusWeb.GroupLive.Review do
  @moduledoc """
  Design frame `03 · review pool` — `/groups/:id/review`.

  The last stop before publishing. The organizer reorders the pool (drag, or the ↑/↓
  buttons for anyone without a mouse), sees the anonymity and veto rules, and either gets
  the share link — which is what actually moves the group `:draft -> :voting` via
  `Consensus.Activities.publish_group/2` — or cancels the whole thing.

  A friend can still be adding options while the organizer is on this screen (the
  subtitle says so), so this LiveView subscribes to the group's PubSub topic
  (`Consensus.Activities.subscribe_group/1`) and reloads on every broadcast rather than
  trusting whatever it mounted with.

  **This screen outlives the draft**, and that is why it has an `@editable` assign:
  `ConsensusWeb.HomeLive` sends a `:voting` group here too, since it is the closest thing
  to a live view of a group until `GroupLive.Results` exists. Once the group leaves
  `:draft` the pool is frozen (D-037) and every reorder or removal control is dropped —
  the drag handle, the ↑/↓ pair, the `Sortable` hook and the `×`. That is a courtesy, not
  the enforcement: `Consensus.Activities` refuses those writes regardless, which is what
  protects ballots that have already been cast from a `phx-click` pushed at a socket the
  organizer can still mount.

  The anonymity card is a **statement, not a switch** (D-035). MVP voting is
  unconditionally anonymous — `Consensus.Voting.tally/1` is structurally incapable of
  returning per-participant choices in either mode — so a toggle here would have promised
  attribution the engine will never produce.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Voting

  @tick_interval :timer.seconds(60)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Activities.subscribe_group(group.id)
      Process.send_after(self(), :tick, @tick_interval)
    end

    {:ok,
     socket
     |> assign(:page_title, "Review · #{group.title}")
     |> assign(:now, DateTime.utc_now())
     |> assign_tz_offset()
     |> assign_group(group)}
  end

  @impl true
  def handle_event("reorder", %{"ids" => ids}, socket) do
    case parse_ids(ids) do
      {:ok, ordered_ids} ->
        Activities.reorder_activities(
          socket.assigns.current_scope,
          socket.assigns.group,
          ordered_ids
        )

      :error ->
        :ok
    end

    # The hook already reordered the DOM optimistically. Whatever just happened —
    # accepted or refused — reloading from storage is what makes the stored order the
    # truth: on success this reflects the new order, and on refusal it snaps the DOM
    # back to the order that was actually saved, undoing the client's guess.
    {:noreply, reload(socket)}
  end

  def handle_event("move_up", %{"id" => id}, socket), do: move(socket, id, -1)
  def handle_event("move_down", %{"id" => id}, socket), do: move(socket, id, 1)

  def handle_event("remove_activity", %{"id" => id}, socket) do
    case find_activity(socket, id) do
      nil -> :ok
      activity -> Activities.delete_activity(socket.assigns.current_scope, activity)
    end

    {:noreply, reload(socket)}
  end

  def handle_event("publish", _params, socket) do
    case Activities.publish_group(socket.assigns.current_scope, socket.assigns.group) do
      {:ok, group} ->
        {:noreply, push_navigate(socket, to: ~p"/groups/#{group}/share")}

      {:error, :no_activities} ->
        {:noreply, put_flash(socket, :error, "Add at least one option first.")}

      {:error, :no_deadline} ->
        {:noreply, put_flash(socket, :error, "Pick when voting closes first.")}

      {:error, :not_draft} ->
        # Already live — there is nothing left to refuse, just take them to the link.
        {:noreply, push_navigate(socket, to: ~p"/groups/#{socket.assigns.group}/share")}
    end
  end

  def handle_event("cancel", _params, socket) do
    group = socket.assigns.group

    case Activities.cancel_group(socket.assigns.current_scope, group) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{group.title} was cancelled.")
         |> push_navigate(to: ~p"/")}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "This session has already finished.")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:group_updated, _group}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_added, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_updated, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activities_changed, _activities}, socket), do: {:noreply, reload(socket)}

  # `Consensus.Voting` publishes on the **same** `"activity_group:<id>"` topic this screen
  # subscribes to, and this LiveView had no clause for either of its messages — so an
  # organizer sitting on the review screen of a live group crashed to "This page hit an
  # error. Attempting to reconnect." the moment anybody joined or voted. Found by a test
  # added for the cancel confirm, which creates a participant. They matter here as well as
  # crashing here: `@voted_count` is what the cancel confirm counts.
  def handle_info({:participant_joined, _group_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:ballot_cast, _group_id}, socket), do: {:noreply, reload(socket)}

  # -- reordering -------------------------------------------------------------------

  defp move(socket, id, delta) do
    with {id, ""} <- Integer.parse(id) do
      current_ids = Enum.map(socket.assigns.group.activities, & &1.id)
      index = Enum.find_index(current_ids, &(&1 == id))
      target = index && index + delta

      if index && target && target >= 0 && target < length(current_ids) do
        reordered = current_ids |> List.delete_at(index) |> List.insert_at(target, id)

        Activities.reorder_activities(
          socket.assigns.current_scope,
          socket.assigns.group,
          reordered
        )
      end
    end

    {:noreply, reload(socket)}
  end

  defp parse_ids(ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Integer.parse(id) do
        {int, ""} -> {:cont, {:ok, [int | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp parse_ids(_ids), do: :error

  defp find_activity(socket, id) do
    case Integer.parse(id) do
      {int_id, ""} -> Enum.find(socket.assigns.group.activities, &(&1.id == int_id))
      _ -> nil
    end
  end

  # -- assigns ------------------------------------------------------------------------

  defp assign_group(socket, group) do
    socket
    |> assign(:group, group)
    |> assign(:activity_count, length(group.activities))
    |> assign(:editable, group.status == :draft)
    |> assign(:voted_count, voted_count(group))
    |> stream(:activities, group.activities, reset: true)
  end

  # A `:draft` group cannot have a participant — nobody can reach `/join/:slug` until it is
  # published — so the read is skipped rather than answered by the database.
  defp voted_count(%{status: :draft}), do: 0
  defp voted_count(group), do: group |> Voting.participants() |> Enum.count(& &1.voted?)

  # Cancelling is irreversible and it destroys work other people did. The confirm used to
  # say only "Cancel <title>? This cannot be undone." on a live group with ballots already
  # in it — `/admin/users`' Delete confirm enumerates its whole cascade, and this is the
  # same class of loss with strangers on the other end of it.
  defp cancel_confirm(group, 0), do: "Cancel #{group.title}? This cannot be undone."

  defp cancel_confirm(group, 1),
    do:
      "Cancel #{group.title}? 1 person has already voted; their ballot is discarded and " <>
        "no winner is picked. This cannot be undone."

  defp cancel_confirm(group, n),
    do:
      "Cancel #{group.title}? #{n} people have already voted; their ballots are discarded " <>
        "and no winner is picked. This cannot be undone."

  defp assign_tz_offset(socket) do
    offset =
      case connected?(socket) && get_connect_params(socket) do
        %{"tz_offset" => offset} when is_integer(offset) -> offset
        _ -> 0
      end

    assign(socket, :tz_offset, offset)
  end

  # Re-reads the group from storage. This is the single mechanism behind three
  # different requirements at once: a rejected reorder must not leave the DOM lying, a
  # friend's PubSub-broadcast addition must show up without a refresh, and every write
  # in this module already re-authorizes through `Consensus.Activities` — reloading
  # afterward means the render always reflects exactly what got persisted, never what
  # the client optimistically assumed.
  defp reload(socket) do
    group = Activities.get_group!(socket.assigns.current_scope, socket.assigns.group.id)
    assign_group(socket, group)
  end

  # Cycles the five placeholder stripe variants app.css defines down the list by row
  # position, in the design's own order, for the same reason `Sticker.position_badge/1`
  # cycles its three fill colours: a list of every-row-identical placeholders reads as one
  # flat block and the eye stops separating the rows. A row with a real `image_url` never
  # reaches this. Five, not two — a pool of five is the design's own example, and a
  # two-cycle repeats before the list ends, which is most of the effect lost.
  @stripes ~w(stripes-mint stripes-violet stripes-peach stripes-yellow stripes-blue)

  defp stripe_class(position), do: Enum.at(@stripes, rem(position - 1, length(@stripes)))

  # -- deadline formatting --------------------------------------------------------------

  defp closes_label(%{deadline_at: nil}, _now, _offset), do: "NO DEADLINE SET"

  defp closes_label(%{deadline_at: at}, now, offset),
    do: at |> Deadlines.label_for(now, offset) |> String.upcase()

  defp countdown_text(%{deadline_at: nil}, _now), do: "—"
  defp countdown_text(%{deadline_at: at}, now), do: Deadlines.countdown(at, now)

  defp countdown_aria(%{deadline_at: nil}, _now), do: "No deadline set yet"
  defp countdown_aria(%{deadline_at: at}, now), do: spoken_countdown(at, now)

  defp spoken_countdown(at, now) do
    diff = DateTime.diff(at, now, :second)

    if diff <= 0 do
      "Closing now"
    else
      days = div(diff, 86_400)
      hours = diff |> rem(86_400) |> div(3600)
      minutes = diff |> rem(3600) |> div(60)

      [{days, "day"}, {hours, "hour"}, {minutes, "minute"}]
      |> Enum.filter(fn {n, _unit} -> n > 0 end)
      |> Enum.map(fn {n, unit} -> "#{n} #{unit}#{if n != 1, do: "s"}" end)
      |> case do
        [] -> "less than a minute left"
        parts -> Enum.join(parts, " ") <> " left"
      end
    end
  end

  # Step 3's back goes to step 2 — but only while the group is still a draft.
  # `ConsensusWeb.GroupLive.Options` bounces a `:voting`/`:completed`/`:cancelled`
  # group straight back here (D-037: the pool is frozen), so pointing a live group's
  # back control at `/options` would be a two-hop loop that lands the organizer where
  # they started with a flash they did not ask for. `/` is the honest way out of a
  # group that can no longer be edited.
  defp back_path(group, true), do: ~p"/groups/#{group}/options"
  defp back_path(_group, false), do: ~p"/"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back={back_path(@group, @editable)}
      context={if @editable, do: "STEP 3 OF 3", else: "LIVE SESSION"}
    >
      <div class="px-5 pb-3.5 pt-4">
        <h1 class="text-[27px]/[1.1] font-bold tracking-[-0.025em] text-ink">Your pool</h1>
        <p class="text-[12.5px] leading-[1.4] text-muted">
          <%!-- The comp reads "Drag to reorder. Friends can still add." Friends adding
          options to someone else's pool is not built (out of scope, and D-037 freezes the
          pool the moment the vote opens), so that sentence promises something the app
          refuses to do. Deliberate copy deviation from frame 03 — do not "restore" it.

          "Drag to reorder" on its own was the *other* half of that problem and is gone
          too (D-045). `Sortable` in assets/js/hooks.js binds `dragstart`/`dragover`/
          `dragend` and nothing else, and no mobile browser fires HTML5 drag-and-drop from
          a finger — so on the device this app is designed for, the one instruction on the
          screen was unfollowable. The ▲▼ pair is what works everywhere, so it is what the
          sentence names; dragging is mentioned second and qualified, and the ⠿ handle is
          hidden outright on a device with no hover (see the row below). --%>
          {if @editable,
            do: "Tap ▲▼ to reorder — or drag, on a computer. This is what everyone votes on.",
            else: "Voting is open — the pool is locked."}
        </p>
      </div>

      <div class="flex min-h-0 flex-1 flex-col gap-[7px] px-5">
        <div
          id="pool-list"
          phx-update="stream"
          phx-hook={@editable && "Sortable"}
          class="flex flex-col gap-[7px]"
        >
          <div
            :for={{dom_id, activity} <- @streams.activities}
            id={dom_id}
            data-sortable-id={activity.id}
            draggable={to_string(@editable)}
            class="flex items-center gap-2.5 rounded-2xl border-2 border-ink bg-white px-[11px] py-[9px] shadow-sticker-2"
          >
            <%!-- Hidden wherever there is no hover, i.e. on a touch device, because
                  `Sortable` binds HTML5 drag events only and a finger fires none of them.
                  A `cursor-grab` ⠿ that cannot be grabbed is an unreadable affordance
                  (confusion class 1) in the one place the screen tells you to act. --%>
            <span
              :if={@editable}
              class="cursor-grab select-none font-mono text-[13px] text-muted [@media(hover:none)]:hidden"
              aria-hidden="true"
            >
              ⠿
            </span>

            <%!-- **Stacked, 44×44 each, in a single 44px-wide column.** They painted
                  7.8×10 with hit boxes of 8×11.5 and 8×13 and a **2.0px** gap: unhittable
                  with a finger, and adjacent enough that a miss did the opposite of what
                  was intended. The first fix put them side by side, which cost the option
                  name 72px of a 360px row — measured at 120px, narrower than "Superiority
                  Burger" (123px at the row's own 700/14px), so ordinary fixture names
                  ellipsised on the last screen before an irreversible publish, under a
                  subhead reading "This is what everyone votes on". Stacking gives the
                  horizontal space back (the name measures ~172px at 360) and buys the
                  vertical separation by letting the row grow to ~92px, which the card can
                  afford at four or five options.
                  `gap-1`: 4px of dead space between the two, so a near-miss at the shared
                  boundary is a miss rather than the opposite action. --%>
            <div :if={@editable} class="flex shrink-0 flex-col items-center gap-1">
              <button
                type="button"
                phx-click="move_up"
                phx-value-id={activity.id}
                disabled={activity.position == 1}
                aria-label={"Move #{activity.name} up"}
                class="grid size-11 place-items-center text-[10px] leading-none text-muted hover:text-ink active:text-ink disabled:cursor-not-allowed disabled:text-faint"
              >
                ▲
              </button>
              <button
                type="button"
                phx-click="move_down"
                phx-value-id={activity.id}
                disabled={activity.position == @activity_count}
                aria-label={"Move #{activity.name} down"}
                class="grid size-11 place-items-center text-[10px] leading-none text-muted hover:text-ink active:text-ink disabled:cursor-not-allowed disabled:text-faint"
              >
                ▼
              </button>
            </div>

            <div class={[
              "size-9 shrink-0 overflow-hidden rounded-lg border-2 border-ink",
              is_nil(activity.image_url) && stripe_class(activity.position)
            ]}>
              <img
                :if={activity.image_url}
                src={activity.image_url}
                alt={activity.name}
                loading="lazy"
                class="size-full object-cover"
                onerror={"this.style.display='none';this.parentElement.classList.add('#{stripe_class(activity.position)}')"}
              />
            </div>

            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-bold text-ink">{activity.name}</p>
              <p class="truncate text-[11px] text-muted">
                {activity.description || "No details yet"}
              </p>
            </div>

            <%!-- Was 16×24 with `data-confirm` null — the *smaller, harder-to-hit* copy of
                  the same destructive action `/groups/:id/options` renders at 28×36 with
                  "Remove X from the pool?", on the screen immediately before publishing
                  freezes the pool for good. Both halves are fixed: the same confirmation
                  string, and the pseudo-element hit-area pattern `Chrome.header/1` uses for
                  its circles, so the glyph keeps painting at 16px while the box reaches
                  44×44. Nothing else sits within 44px of it — the arrows are at the far
                  left of the row — so there is no neighbour for the box to steal from. --%>
            <button
              :if={@editable}
              type="button"
              phx-click="remove_activity"
              phx-value-id={activity.id}
              data-confirm={"Remove #{activity.name} from the pool?"}
              aria-label={"Remove #{activity.name}"}
              class="relative shrink-0 text-muted transition-colors before:absolute before:-inset-[14px] before:content-[''] hover:text-tangerine active:text-tangerine"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <.sticker_card tone={:violet_tint} depth={2} class="mt-1 flex items-center gap-3 px-3.5 py-3">
          <div class="flex-1">
            <p class="text-[13.5px] font-bold text-ink">Anonymous voting</p>
            <%!-- Both halves, in the order every other place in this app now states them
                  (D-049). The old line said only the second, which is true but is the half
                  an organizer will assume anyway — and this is the last screen before they
                  hand the link out, so it is the last chance to tell them that the link
                  also exposes the guest list. `JoinLive.Results` renders WHO'S VOTED for a
                  visitor with no participant token at all. --%>
            <p class="text-[11px] leading-[1.35] text-ink-soft">
              Anyone with the link sees who voted. Nobody sees what they picked — you
              included.
            </p>
          </div>
          <span class="shrink-0 font-mono text-[11px] font-semibold text-violet">ALWAYS ON</span>
        </.sticker_card>

        <%!-- **Solid, not dashed, and this is a deliberate departure from frame `1a-4`,
              which draws it dashed** (recorded in DESIGN-SPEC beside the `00b`/`00c`
              deviations). In this repo a dashed border is the documented "not built yet"
              treatment — `Bars` and `Movies` on `02 add options`, `Custom…` on `01 setup`,
              all `disabled` and captioned "Coming soon", per plan ruling 1's convention.
              This row states a rule that is live and enforced on every ballot in the app,
              one screen after those, and it sits directly under an equally immutable rule
              (`Anonymous voting · ALWAYS ON`) drawn as a solid violet card. A reader
              should not have to guess which of the two a dashed border means. It is now
              the anonymity card's sibling: same shape, same `ALWAYS ON`-style constant on
              the right, a different tone so the two are still tellable apart.

              `:canvas`, not `:yellow`. Both are solid and both read as built, but
              `--yellow` is the header pill's resting CTA fill and a full-width card of it
              sat louder than the tangerine `See the share link` it shares the screen with —
              a rule statement out-shouting the screen's forward action. `--canvas` is the
              page's own green against this screen's `--surface`, so the card is clearly a
              surface without asking to be pressed. --%>
        <.sticker_card
          :if={@group.veto_allowed}
          tone={:canvas}
          depth={2}
          class="flex items-center gap-3 px-3.5 py-3"
        >
          <div class="flex-1">
            <p class="text-[13.5px] font-bold text-ink">One veto each</p>
            <%!-- "option", not "places". PRD product invariant 2 says the engine is
                  activity-agnostic and this is the one sentence that states the veto rule
                  to the organizer — it should not be dining vocabulary, and it should not
                  disagree with how the same rule reaches the voter one screen later ("it
                  drops an option for everyone", on `/join/:slug/vote`). --%>
            <p class="text-[11px] leading-[1.35] text-ink-soft">
              A vetoed option drops out for everyone.
            </p>
          </div>
          <span class="shrink-0 font-mono text-[11px] font-semibold text-ink">1×</span>
        </.sticker_card>
      </div>

      <div class="flex flex-col gap-2.5 px-5 pb-5 pt-3">
        <%!-- 97.8×18 paint, 98×19 hit, styled with nothing but `text-[12px] text-muted
              hover:text-tangerine` — verbatim the treatment condemned on `/admin/users`'
              Delete, on a control that destroys a live session and everybody's ballots in
              it. `hover:` does not exist on touch, so nothing distinguished it from body
              text and nothing acknowledged a tap. Now a real 44px box (`-my-3` cancels the
              growth so the row spacing does not move), with `active:` beside `hover:` so a
              finger gets the same feedback a mouse does. --%>
        <button
          type="button"
          phx-click="cancel"
          data-confirm={cancel_confirm(@group, @voted_count)}
          class="-my-3 inline-flex min-h-[44px] items-center justify-center self-center px-3 text-[12px] font-medium text-muted underline decoration-2 underline-offset-2 transition-colors hover:text-tangerine active:text-tangerine"
        >
          Cancel this session
        </button>

        <div class="flex items-center justify-between border-t-2 border-ink-12 pt-3 font-mono text-[11.5px] text-ink-soft">
          <span>{closes_label(@group, @now, @tz_offset)}</span>
          <span class="text-tangerine" aria-label={countdown_aria(@group, @now)}>
            {countdown_text(@group, @now)}
          </span>
        </div>

        <%!-- Publishing is one of the three moments the plan says must warn in advance, and
              this screen did the opposite: it teaches that the pool is editable — ▲▼ and a ✕
              on every row — and then took that away permanently on one unwarned tap
              (D-037 / invariant 16). "Cancel this session" 90px above already carries a
              `data-confirm`, which made the omission read as an oversight rather than a
              decision. A line of copy rather than a second dialog: two `data-confirm`s on
              one screen trains people to dismiss both, and this one is a forward action,
              not a destructive one. `:if={@editable}` because on a group that has already
              been published there is nothing left to lock.

              **It named the wrong trigger until D-045.** "Once you share this…" says the
              lock happens when the link is sent; it does not. `handle_event("publish", …)`
              flips the group to `:voting` the instant the button 12px below is pressed, and
              D-037 freezes the pool on that status change, before any link has left the
              screen. An organizer reading it literally taps "Get the share link", assumes
              the pool stays editable until they paste it into the group chat, and finds `‹`
              goes back to a review page with no ▲▼ and no ✕. A warning that names the wrong
              moment defeats the reason it exists.

              The second sentence is product invariant 3 said out loud at the moment it
              becomes binding: the deadline closes the vote and picks a winner with no
              organizer action at all, and nothing said so on this screen. --%>
        <p :if={@editable} class="text-center text-[11.5px] leading-[1.4] text-ink-soft">
          Tapping this opens voting — the options lock now: no adding, removing or reordering.
          Voting then closes itself at the deadline and picks the winner; you don't have to
          be here.
        </p>

        <.button variant="primary" type="button" phx-click="publish">
          {if @editable, do: "Get the share link", else: "See the share link"}
        </.button>
      </div>
    </Layouts.app>
    """
  end
end
