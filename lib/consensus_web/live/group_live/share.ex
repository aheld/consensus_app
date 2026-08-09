defmodule ConsensusWeb.GroupLive.Share do
  @moduledoc """
  Design frame `04 · share` — `/groups/:id/share`.

  The wizard's last screen. Publishing already happened on `03` (`Activities.publish_group/2`
  at "Get the share link"), so this screen only ever *shows* the link — a summary of the
  now-live session, and under it the sheet carrying the invite card and the share controls.

  The comp draws that sheet over a dimmed scrim and the built version copied the dim; it is
  gone (see the comment in `render/1`). Nothing here is modal — the sheet is in the column's
  normal flow and the global chrome above it is fully interactive — so the dim only made the
  page look broken.

  A `:draft` group has no live link yet, so reaching this route directly (bookmark, back
  button, a stale tab) bounces back to `03` — **with a flash saying why** (D-045). It used
  to bounce silently: the organizer asked for the share link and, with no explanation and
  nothing on the destination screen referring to the request, simply got a different
  screen. "The user asked for X and got Y with no account of it" is the plan's unpredictable
  outcome, and it is worse here than elsewhere because `03 review` looks like a step
  backwards in the wizard, so the reasonable reading is "something failed".
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, id)

    if group.status == :draft do
      {:ok,
       socket
       |> put_flash(
         :info,
         "There's no share link yet — #{group.title} hasn't been published. " <>
           "Tap “Get the share link” below to open voting."
       )
       |> push_navigate(to: ~p"/groups/#{group}/review")}
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
  rescue
    # Same rescue, and the same reason, as `GroupLive.Results.mount/3` — see its comment.
    # `get_group!/2` is organizer-scoped, so "somebody else's group" and "no such group"
    # arrive here identically, and a bare 404 tells the reader neither what happened nor
    # where to go.
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(
         :error,
         "That session isn't yours, or it no longer exists. Here is everything you organize."
       )
       |> push_navigate(to: ~p"/")}
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
    <%!-- **The dim is gone.** The comp draws `04 share` as a sheet over a dimmed session
          screen, but nothing here is modal: the sheet is in this column's normal flow, the
          chrome above it is fully interactive, and the "scrim" was 40% opacity on four
          lines of real text. Dimmed content under an undimmed, clickable global header
          reads as a rendering bug rather than a deliberate scrim — and dimming the header
          with it would hide the only way off the screen to buy a modal feeling the markup
          never had. The session summary is just the top of the page now. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back={~p"/groups/#{@group}/review"}
      context="SHARE"
    >
      <div class="flex flex-1 flex-col">
        <%!-- Real data, and now readable: it tells the organizer the session is live and
              how many spots are in it, which is the one thing this screen confirms. --%>
        <%!-- Centred in whatever room is left above the sheet rather than pinned to the
              top of it. At the design's 760px the two are the same; on a taller phone —
              and on any browser without `navigator.share`, where the `NativeShare` hook
              hides the four share targets and the sheet gets shorter — pinning left a
              visible void between four lines of text and the sheet. --%>
        <div class="flex flex-1 flex-col justify-center px-5 py-4">
          <h1 class="mb-2.5 text-[27px]/[1.1] font-bold text-ink">Session is live</h1>
          <p class="text-sm font-semibold text-ink-soft">{@group.title}</p>
          <p class="mt-1 text-sm text-ink-soft">
            {spots_line(@group, @activity_count, @now, @tz_offset)}
          </p>
        </div>

        <%!-- `mt-auto` in the flow rather than `absolute inset-x-0 bottom-0` inside an
              `overflow-hidden` parent. Same result — the sheet sits on the bottom edge of
              the content area, under the session summary — but with ~167px of the column
              now spent on the global header and footer (measured at 390×760: 48 + 119),
              an absolutely-positioned sheet taller than its container clips its own top
              off on a short viewport, and silently: the drag handle and the invite card
              just stop existing. In the flow it pushes the page instead. --%>
        <div class="mt-auto flex flex-col gap-3.5 rounded-[26px_26px_32px_32px] border-t-2 border-ink bg-canvas px-[18px] pb-5 pt-4 shadow-sheet">
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

          <%!-- **One control, because there is one behaviour.** The frame draws four tiles
                labelled Messages / WhatsApp / Slack / More, and the app shipped them as four
                separate `<button>`s — none of which carried a `phx-click`, an `onclick` or an
                `href`. The single click listener lives on this wrapper (`NativeShare` in
                assets/js/hooks.js) and calls `navigator.share`, so tapping "WhatsApp" did not
                open WhatsApp: it opened the generic OS sheet, from which you then had to find
                WhatsApp yourself. Four affordances, one outcome, three of the labels naming a
                destination the code never goes to — plan confusion class 5 (ambiguous
                duplication) on the one screen whose entire job is "send this link".

                Real per-target intents were the alternative (`sms:?&body=`, `https://wa.me/?text=`)
                and were rejected: Slack has no dependable web share intent for arbitrary text,
                so the row would have gone back to being three real doors and one fake one.
                The four coloured tiles stay as **decoration** — they are the frame's shape and
                they truthfully preview what the sheet offers — but they are `aria-hidden`
                inside one button whose label says what actually happens. --%>
          <%!-- `hidden` in the server-rendered markup, removed by the `NativeShare` hook
                wherever `navigator.share` exists. The other way round (render it visible,
                let `mounted()` hide it) is what shipped and it came back on the first
                LiveView patch — pressing this screen's own `Copy link` was enough. The
                reasoning is on the hook in assets/js/hooks.js; the attribute is here
                because progressive enhancement has to start from the server's markup. --%>
          <button
            type="button"
            id="native-share"
            hidden
            phx-hook="NativeShare"
            data-share-title={@group.title}
            data-share-text={"#{@organizer_username} set up a vote. Tap to pick."}
            data-share-url={@join_url}
            class="press-2 flex w-full flex-col items-center gap-2 rounded-2xl border-2 border-ink bg-white p-2.5 shadow-sticker-2 transition-colors hover:bg-yellow"
          >
            <span aria-hidden="true" class="flex justify-center gap-1.5">
              <span class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-mint">
                <.icon name="hero-chat-bubble-left-right" class="size-6 text-ink" />
              </span>
              <span class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-yellow-soft">
                <.icon name="hero-paper-airplane" class="size-6 text-ink" />
              </span>
              <span class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-violet-soft">
                <.icon name="hero-hashtag" class="size-6 text-ink" />
              </span>
              <span class="grid size-[54px] place-items-center rounded-2xl border-2 border-ink bg-white">
                <.icon name="hero-ellipsis-horizontal" class="size-6 text-ink" />
              </span>
            </span>
            <span class="text-[12.5px] font-semibold text-ink">
              Open your phone's share sheet <span aria-hidden="true">→</span>
            </span>
          </button>

          <div class="flex gap-[9px]">
            <button
              type="button"
              id="copy-link"
              phx-hook="Clipboard"
              data-copy={@join_url}
              data-copy-fallback-id="join-url"
              class="flex-1 rounded-2xl border-2 border-ink bg-ink p-4 text-center text-[14.5px] font-bold text-white transition-colors hover:bg-ink-soft active:bg-ink-soft"
            >
              Copy link
            </button>
            <%!-- Dashed and flat, the treatment `02 add options`' `Bars`/`Movies` chips and
                  the nudge marker on `05 results` already use for something unbuilt. It
                  shipped with the full enabled sticker treatment — 2px ink border, white
                  fill, `shadow-sticker-2` — which at 57.6×59.8 is indistinguishable from
                  the live "Copy link" beside it, and its only non-label cue was a `title`
                  tooltip, which does not exist on touch. The `title` is gone with it:
                  `SOON` on the label already carries the meaning, and an explanation only a
                  mouse can reach is not an explanation on a phone. --%>
            <button
              type="button"
              disabled
              class="flex flex-col items-center justify-center gap-0.5 rounded-2xl border-2 border-dashed border-ink/35 bg-white px-4 py-2.5 text-muted disabled:cursor-not-allowed"
            >
              <span class="text-[14.5px] font-bold">QR</span>
              <span class="font-mono text-[8px] font-semibold uppercase tracking-[0.06em]">
                Soon
              </span>
            </button>
          </div>

          <%!-- Padded to the 44px touch minimum with `-my-2` cancelling it, so the text
                does not move — the shape `Chrome.header/1` uses for its `Log in` link. It measured
                324×18.8, and it is the **only** forward control on this screen: a
                tangerine sweep here returns an empty array, because "Copy link" is ink and
                the share sheet is white. --%>
          <.link
            navigate={~p"/groups/#{@group.id}/results"}
            id="share-see-results"
            class="-my-2 inline-flex min-h-[44px] items-center justify-center text-center text-[12.5px] font-semibold text-violet underline decoration-2 underline-offset-2 hover:text-tangerine active:text-tangerine"
          >
            See live results →
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
