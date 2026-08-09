defmodule ConsensusWeb.GroupLive.Share do
  @moduledoc """
  Design frame `04 · share` — `/groups/:id/share`.

  The wizard's last screen. Publishing already happened on `03` (`Activities.publish_group/2`
  at "Get the share link"), so this screen only ever *shows* the link — a bottom sheet over a
  dimmed, inert preview of the live session behind it.

  A `:draft` group has no live link yet, so reaching this route directly (bookmark, back
  button, a stale tab) bounces back to `03`.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, id)

    if group.status == :draft do
      {:ok, push_navigate(socket, to: ~p"/groups/#{group}/review")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Share · #{group.title}")
       |> assign(:group, group)
       |> assign(:activity_count, length(group.activities))
       |> assign(:now, DateTime.utc_now())
       |> assign_tz_offset()
       |> assign(:organizer_username, socket.assigns.current_scope.user.username)
       |> assign(:join_url, join_url(group))}
    end
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Link copied")}
  end

  def handle_event("copy_failed", _params, socket) do
    {:noreply, put_flash(socket, :info, "Select the link above to copy it")}
  end

  defp assign_tz_offset(socket) do
    offset =
      case connected?(socket) && get_connect_params(socket) do
        %{"tz_offset" => offset} when is_integer(offset) -> offset
        _ -> 0
      end

    assign(socket, :tz_offset, offset)
  end

  defp join_url(group), do: ConsensusWeb.Endpoint.url() <> ~p"/join/#{group.slug}"

  defp spots_line(group, activity_count, now, tz_offset) do
    "#{activity_count} #{pluralize(activity_count, "spot")} · #{closes_phrase(group, now, tz_offset)}"
  end

  defp closes_phrase(%{deadline_at: nil}, _now, _offset), do: "no deadline set"

  # The review footer uses `Deadlines.label_for/3` verbatim ("Closes Thu 6:00 PM") — that
  # wording is correct there. This card is a compact invite preview ("5 spots · closes Thu
  # 6pm"), which `label_for/3` doesn't produce, so this is its own small formatter rather
  # than a second mode bolted onto the shared one.
  defp closes_phrase(%{deadline_at: at}, now, offset) do
    local_at = shift(at, offset)
    local_now = shift(now, offset)
    "closes #{compact_day(local_at, local_now)} #{compact_clock(local_at)}"
  end

  defp shift(dt, offset_minutes), do: DateTime.add(dt, offset_minutes * 60, :second)

  defp compact_day(local_at, local_now) do
    at_date = DateTime.to_date(local_at)
    now_date = DateTime.to_date(local_now)

    cond do
      Date.compare(at_date, now_date) == :eq -> "today"
      Date.compare(at_date, Date.add(now_date, 1)) == :eq -> "tomorrow"
      true -> weekday_abbrev(at_date)
    end
  end

  defp weekday_abbrev(date) do
    elem({"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}, Date.day_of_week(date) - 1)
  end

  # "6pm", "12pm", "6:30pm" — no colon or leading zero for the on-the-hour case, matching
  # the reference card. `Deadlines.label_for/3`'s "6:00 PM" is deliberately not reused here.
  defp compact_clock(%DateTime{hour: hour, minute: minute}) do
    {display_hour, period} =
      cond do
        hour == 0 -> {12, "am"}
        hour == 12 -> {12, "pm"}
        hour > 12 -> {hour - 12, "pm"}
        true -> {hour, "am"}
      end

    if minute == 0 do
      "#{display_hour}#{period}"
    else
      "#{display_hour}:#{String.pad_leading(Integer.to_string(minute), 2, "0")}#{period}"
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative flex flex-1 flex-col overflow-hidden">
        <%!-- The live session behind the sheet. Real data, not lorem — just dimmed and
              inert, since it is decoration behind a modal-like sheet. --%>
        <div aria-hidden="true" inert class="flex-1 px-5 py-4 saturate-50 opacity-40">
          <h1 class="mb-2.5 text-[27px]/[1.1] font-bold text-ink">Session is live</h1>
          <p class="text-sm font-semibold text-ink-soft">{@group.title}</p>
          <p class="mt-1 text-sm text-ink-soft">
            {spots_line(@group, @activity_count, @now, @tz_offset)}
          </p>
        </div>

        <div class="absolute inset-x-0 bottom-0 flex flex-col gap-3.5 rounded-[26px_26px_32px_32px] border-t-2 border-ink bg-canvas px-[18px] pb-5 pt-4 shadow-sheet">
          <div class="h-[5px] w-11 self-center rounded-full bg-ink/25" aria-hidden="true"></div>

          <div class="overflow-hidden rounded-2xl border-2 border-ink bg-white shadow-sticker-3">
            <div class="flex h-[88px] items-center bg-[linear-gradient(105deg,var(--color-violet)_0_55%,var(--color-tangerine)_55%_100%)] px-4">
              <div>
                <p class="text-[19px]/[1.15] font-bold tracking-[-0.02em] text-white">
                  {@group.title}
                </p>
                <p class="font-mono text-[12.5px] text-white/90">
                  {spots_line(@group, @activity_count, @now, @tz_offset)}
                </p>
              </div>
            </div>
            <div class="flex flex-col gap-[3px] px-3.5 py-[11px]">
              <p class="text-[13.5px] font-semibold text-ink">
                {@organizer_username} set up a vote. Tap to pick.
              </p>
              <p id="join-url" class="truncate font-mono text-[11px] font-medium text-muted">
                {@join_url}
              </p>
            </div>
          </div>

          <div
            id="native-share"
            phx-hook="NativeShare"
            data-share-title={@group.title}
            data-share-text={"#{@organizer_username} set up a vote. Tap to pick."}
            data-share-url={@join_url}
            class="flex justify-between gap-1.5"
          >
            <button type="button" class="flex flex-col items-center gap-1.5">
              <span
                aria-hidden="true"
                class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-mint"
              >
                <.icon name="hero-chat-bubble-left-right" class="size-6 text-ink" />
              </span>
              <span class="text-[10.5px] font-medium text-ink">Messages</span>
            </button>
            <button type="button" class="flex flex-col items-center gap-1.5">
              <span
                aria-hidden="true"
                class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-yellow-soft"
              >
                <.icon name="hero-paper-airplane" class="size-6 text-ink" />
              </span>
              <span class="text-[10.5px] font-medium text-ink">WhatsApp</span>
            </button>
            <button type="button" class="flex flex-col items-center gap-1.5">
              <span
                aria-hidden="true"
                class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-violet-soft"
              >
                <.icon name="hero-hashtag" class="size-6 text-ink" />
              </span>
              <span class="text-[10.5px] font-medium text-ink">Slack</span>
            </button>
            <button type="button" class="flex flex-col items-center gap-1.5">
              <span
                aria-hidden="true"
                class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-white"
              >
                <.icon name="hero-ellipsis-horizontal" class="size-6 text-ink" />
              </span>
              <span class="text-[10.5px] font-medium text-ink">More</span>
            </button>
          </div>

          <div class="flex gap-[9px]">
            <button
              type="button"
              id="copy-link"
              phx-hook="Clipboard"
              data-copy={@join_url}
              data-copy-fallback-id="join-url"
              class="flex-1 rounded-2xl border-2 border-ink bg-ink p-4 text-center text-[14.5px] font-bold text-white transition-colors hover:bg-ink-soft"
            >
              Copy link
            </button>
            <button
              type="button"
              disabled
              title="Coming soon"
              class="flex flex-col items-center justify-center gap-0.5 rounded-2xl border-2 border-ink bg-white px-4 py-2.5 shadow-sticker-2 disabled:cursor-not-allowed"
            >
              <span class="text-[14.5px] font-bold text-ink">QR</span>
              <span class="font-mono text-[8px] font-semibold uppercase tracking-[0.06em] text-muted">
                Soon
              </span>
            </button>
          </div>

          <.link
            navigate={~p"/groups/#{@group.id}/results"}
            class="text-center text-[12.5px] font-semibold text-violet underline decoration-2 underline-offset-2 hover:text-tangerine"
          >
            See live results →
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
