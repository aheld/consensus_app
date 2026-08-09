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
        {:noreply, put_flash(socket, :error, "This group has already finished.")}
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
    |> stream(:activities, group.activities, reset: true)
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="px-5 pb-3.5 pt-4">
        <h1 class="text-[27px]/[1.1] font-bold tracking-[-0.025em] text-ink">Your pool</h1>
        <p class="text-[12.5px] leading-[1.4] text-muted">
          <%!-- The comp reads "Drag to reorder. Friends can still add." Friends adding
          options to someone else's pool is not built (out of scope, and D-037 freezes the
          pool the moment the vote opens), so that sentence promises something the app
          refuses to do. Deliberate copy deviation from frame 03 — do not "restore" it. --%>
          {if @editable,
            do: "Drag to reorder. This is what everyone votes on.",
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
            <span
              :if={@editable}
              class="cursor-grab select-none font-mono text-[13px] text-muted"
              aria-hidden="true"
            >
              ⠿
            </span>

            <div :if={@editable} class="flex flex-col gap-0.5">
              <button
                type="button"
                phx-click="move_up"
                phx-value-id={activity.id}
                disabled={activity.position == 1}
                aria-label={"Move #{activity.name} up"}
                class="text-[10px] leading-none text-muted hover:text-ink disabled:cursor-not-allowed disabled:text-faint"
              >
                ▲
              </button>
              <button
                type="button"
                phx-click="move_down"
                phx-value-id={activity.id}
                disabled={activity.position == @activity_count}
                aria-label={"Move #{activity.name} down"}
                class="text-[10px] leading-none text-muted hover:text-ink disabled:cursor-not-allowed disabled:text-faint"
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

            <button
              :if={@editable}
              type="button"
              phx-click="remove_activity"
              phx-value-id={activity.id}
              aria-label={"Remove #{activity.name}"}
              class="shrink-0 text-muted hover:text-tangerine"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <.sticker_card tone={:violet_tint} depth={2} class="mt-1 flex items-center gap-3 px-3.5 py-3">
          <div class="flex-1">
            <p class="text-[13.5px] font-bold text-ink">Anonymous voting</p>
            <p class="text-[11px] leading-[1.35] text-ink-soft">
              Nobody sees who picked what — totals only.
            </p>
          </div>
          <span class="shrink-0 font-mono text-[11px] font-semibold text-violet">ALWAYS ON</span>
        </.sticker_card>

        <div
          :if={@group.veto_allowed}
          class="flex items-center gap-2 rounded-2xl border-2 border-dashed border-ink px-3 py-2.5 text-[11.5px] leading-[1.35] text-ink-soft"
        >
          <span class="font-mono text-xs font-semibold text-tangerine">1×</span>
          Everyone gets one veto. Vetoed places drop out.
        </div>
      </div>

      <div class="flex flex-col gap-2.5 px-5 pb-5 pt-3">
        <button
          type="button"
          phx-click="cancel"
          data-confirm={"Cancel " <> @group.title <> "? This cannot be undone."}
          class="self-center text-[12px] font-medium text-muted hover:text-tangerine hover:underline"
        >
          Cancel this group
        </button>

        <div class="flex items-center justify-between border-t-2 border-ink-12 pt-3 font-mono text-[11.5px] text-ink-soft">
          <span>{closes_label(@group, @now, @tz_offset)}</span>
          <span class="text-tangerine" aria-label={countdown_aria(@group, @now)}>
            {countdown_text(@group, @now)}
          </span>
        </div>

        <.button variant="primary" type="button" phx-click="publish">
          {if @editable, do: "Get the share link", else: "See the share link"}
        </.button>
      </div>
    </Layouts.app>
    """
  end
end
