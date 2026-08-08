defmodule ConsensusWeb.HomeLive do
  @moduledoc """
  `/` — one route with two faces (see `docs/plans/creation-flow.md` decision 1).

  Signed out renders design frame `00a`, the public splash. Signed in renders frame `00`,
  the organizer's home list, and reflows to the `1b-2` desktop console at `md:` and up.
  `@current_scope` may be `nil` (see `ConsensusWeb.UserAuth`'s `:mount_current_scope` hook,
  wired for this route in the router's `:current_user` `live_session`), so every branch below
  keys off it rather than assuming a signed-in user.

  Real-time (CLAUDE.md product invariant 4): once connected, the signed-in branch
  subscribes to every active group's `Consensus.Activities` topic and refreshes the list on
  any broadcast, and a single page-level timer relabels the countdowns every minute. Both
  the group list and the countdown are plain assigns rather than streams — the list is at
  most a handful of rows for one organizer, so a full reset on every tick or broadcast is
  simpler than stream bookkeeping and never re-renders more than this one page.
  """
  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Activities.Group

  @tick_interval :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:active_groups, [])
      |> assign(:past_groups, [])
      |> assign(:now, DateTime.utc_now())

    socket = if current_scope, do: mount_signed_in(socket, current_scope), else: socket

    {:ok, socket}
  end

  defp mount_signed_in(socket, scope) do
    active_groups = Activities.list_active_groups(scope)
    past_groups = Activities.list_past_groups(scope)

    if connected?(socket) do
      Enum.each(active_groups, &Activities.subscribe_group(&1.id))
      :timer.send_interval(@tick_interval, self(), :tick)
    end

    socket
    |> assign(:active_groups, active_groups)
    |> assign(:past_groups, past_groups)
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:group_updated, _group}, socket), do: {:noreply, refresh_groups(socket)}
  def handle_info({:activity_added, _activity}, socket), do: {:noreply, refresh_groups(socket)}
  def handle_info({:activity_updated, _activity}, socket), do: {:noreply, refresh_groups(socket)}

  def handle_info({:activities_changed, _activities}, socket),
    do: {:noreply, refresh_groups(socket)}

  # Cheap re-fetch rather than a targeted update: a broadcast on any subscribed group's
  # topic can move that group between the active and past lists (a deadline-triggered
  # completion), so both lists are reloaded together from the same scope.
  defp refresh_groups(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:active_groups, Activities.list_active_groups(scope))
    |> assign(:past_groups, Activities.list_past_groups(scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      width={if @current_scope, do: :wide, else: :phone}
      background={if @current_scope, do: "bg-surface", else: "bg-canvas"}
    >
      <.splash :if={!@current_scope} />
      <.home
        :if={@current_scope}
        current_scope={@current_scope}
        active_groups={@active_groups}
        past_groups={@past_groups}
        now={@now}
      />
    </Layouts.app>
    """
  end

  ## Design frame 00a — signed-out splash

  defp splash(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col gap-[26px] px-[26px] py-10">
      <div class="flex flex-col gap-3">
        <span class="font-mono text-[11px] font-semibold uppercase tracking-[.1em] text-ink-soft">
          Consensus
        </span>
        <h1 class="text-pretty text-[40px] font-bold leading-[1.02] tracking-[-.035em]">
          Decide<br />together,<br />in minutes.
        </h1>
        <p class="max-w-[250px] text-[14.5px] leading-[1.45] text-ink-soft">
          Stop the group chat spiral. Put the options up, let everyone rank, get an answer.
        </p>
      </div>

      <div class="flex flex-col gap-[11px]">
        <.sticker_card
          :for={{n, tone, title, desc} <- onboarding_steps()}
          radius={:sm}
          class="flex items-center gap-3 p-3.5"
        >
          <span class={[
            "grid size-[30px] shrink-0 place-items-center rounded-[9px] border-2 border-ink",
            "font-mono text-xs font-bold",
            tone
          ]}>
            {n}
          </span>
          <div>
            <p class="text-sm font-bold">{title}</p>
            <p class="text-[11.5px] leading-snug text-muted">{desc}</p>
          </div>
        </.sticker_card>
      </div>

      <%!-- `mt-auto` (not the parent's `justify-content`) pins this to the bottom edge —
           it degrades sanely on a short viewport by simply following the content instead
           of forcing extra space that isn't there. --%>
      <div class="mt-auto flex flex-col gap-3">
        <.link
          navigate={~p"/users/register"}
          class="block rounded-2xl border-2 border-ink bg-tangerine p-4 text-center text-base font-bold text-white shadow-sticker-4 press-4"
        >
          Get started
        </.link>
        <p class="text-center text-[12.5px] font-medium text-ink-soft">
          Have a link?
          <.link navigate={~p"/users/log-in"} class="text-ink underline">Open it →</.link>
        </p>
      </div>
    </div>
    """
  end

  defp onboarding_steps do
    [
      {1, "bg-yellow", "Add anything", "Type a name or paste a link."},
      {2, "bg-violet-soft", "Share one link", "No app, no account to vote."},
      {3, "bg-peach", "Everyone ranks", "Anonymous. One winner, no debate."}
    ]
  end

  ## Design frame 00 — signed-in home (phone) / 1b-2 — desktop console reflow

  attr :current_scope, :map, required: true
  attr :active_groups, :list, required: true
  attr :past_groups, :list, required: true
  attr :now, :any, required: true

  defp home(assigns) do
    ~H"""
    <div class="mx-auto flex w-full max-w-[440px] flex-1 flex-col md:max-w-none md:flex-row">
      <aside class="hidden shrink-0 flex-col gap-6 border-r-2 border-ink bg-canvas p-5 md:flex md:w-[210px]">
        <div class="flex items-center gap-2">
          <span
            class="size-[26px] rounded-[50%_50%_50%_12%] border-2 border-ink bg-tangerine"
            aria-hidden="true"
          />
          <span class="text-[17px] font-bold tracking-[-.03em]">Consensus</span>
        </div>
        <.link
          navigate={~p"/groups/new"}
          class="flex items-center justify-between rounded-2xl border-2 border-ink bg-tangerine p-3.5 text-white shadow-sticker-4 press-4"
        >
          <span class="text-[15px] font-bold">Start something</span>
          <span class="text-base font-bold" aria-hidden="true">＋</span>
        </.link>
      </aside>

      <div class="flex flex-1 flex-col">
        <header class="flex items-center px-5 pb-4 pt-3.5 md:px-6 md:pt-6">
          <h1 class="text-[27px] font-bold leading-none tracking-[-.025em] md:hidden">Consensus</h1>
          <div class="ml-auto">
            <Layouts.account_menu current_scope={@current_scope} />
          </div>
        </header>

        <div class="px-5 pb-4 md:hidden">
          <.link
            navigate={~p"/groups/new"}
            class="flex items-center justify-between rounded-2xl border-2 border-ink bg-tangerine py-4 px-[18px] text-white shadow-sticker-4 press-4"
          >
            <span class="text-[17px] font-bold">Start something</span>
            <span class="text-lg font-bold" aria-hidden="true">＋</span>
          </.link>
        </div>

        <div class="flex flex-1 flex-col gap-[18px] overflow-y-auto px-5 pb-6 md:px-6">
          <section class="flex flex-col gap-[9px]">
            <.eyebrow>Active</.eyebrow>

            <div
              :if={@active_groups == []}
              class="rounded-2xl border-2 border-dashed border-ink px-4 py-5 text-center text-[13px] text-muted"
            >
              Nothing yet. Start something above.
            </div>

            <div
              :if={@active_groups != []}
              class="flex flex-col gap-[9px] md:grid md:grid-cols-2 md:gap-3"
            >
              <.group_card :for={group <- @active_groups} navigate={group_href(group)} tone={:white}>
                <div class="flex flex-col gap-2">
                  <div class="flex items-baseline justify-between gap-2">
                    <span class="text-[15px] font-bold">{group.title}</span>
                    <span
                      :if={group.deadline_at}
                      class="shrink-0 font-mono text-[11px] font-medium text-violet"
                      aria-label={countdown_aria(group.deadline_at, @now)}
                    >
                      {countdown_text(group.deadline_at, @now)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-[11.5px] text-muted">You're organizing</span>
                    <.pill tone={status_tone(group.status)}>{status_label(group.status)}</.pill>
                  </div>
                </div>
              </.group_card>
            </div>
          </section>

          <section :if={@past_groups != []} class="flex flex-col gap-[9px]">
            <.eyebrow>Past</.eyebrow>

            <div class="flex flex-col gap-[9px] md:grid md:grid-cols-2 md:gap-3">
              <.group_card :for={group <- @past_groups} navigate={group_href(group)} tone={:muted}>
                <div class="flex items-center justify-between gap-2">
                  <div class="flex flex-col gap-0.5">
                    <span class="text-[14px] font-bold text-ink-soft">{group.title}</span>
                    <span class="text-[11px] text-muted">{past_subtitle(group)}</span>
                  </div>
                  <span class="text-[14px] font-medium text-muted" aria-hidden="true">›</span>
                </div>
              </.group_card>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end

  # A whole card is a real link (never a `div` with `phx-click`), so it works with a
  # keyboard and is announced as a link. `sticker_card/1` always renders a `div` and can't
  # be that outer element, so this wraps `.link` directly in the same border/shadow tokens
  # `sticker_card/1` uses for its `:white` and `:muted` tones.
  attr :navigate, :string, required: true
  attr :tone, :atom, required: true, values: [:white, :muted]
  slot :inner_block, required: true

  defp group_card(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["block rounded-2xl border-2", card_tone_class(@tone)]}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp card_tone_class(:white),
    do: "border-ink bg-white px-3.5 py-[13px] shadow-sticker-3 press-3"

  defp card_tone_class(:muted),
    do: "border-ink-30 bg-white/60 px-3.5 py-3 transition-colors hover:border-ink"

  # A `:draft` goes back into the wizard — `/options` if it already has a pool, `/edit`
  # (step 1) if it doesn't — a `:voting` group goes to the review/live screen, and a
  # finished group (`:completed`/`:cancelled`) goes there too: there is no dedicated past-
  # group screen yet (results are Post-MVP, see DESIGN-SPEC.md), and `/review` is the
  # closest thing to a read of the group that already exists.
  defp group_href(%Group{status: :draft, activities: []} = group),
    do: ~p"/groups/#{group.id}/edit"

  defp group_href(%Group{status: :draft} = group), do: ~p"/groups/#{group.id}/options"
  defp group_href(%Group{status: :voting} = group), do: ~p"/groups/#{group.id}/review"

  defp group_href(%Group{status: status} = group) when status in [:completed, :cancelled],
    do: ~p"/groups/#{group.id}/review"

  defp status_tone(:voting), do: :mint
  defp status_tone(:draft), do: :yellow

  defp status_label(:voting), do: "VOTING"
  defp status_label(:draft), do: "DRAFT"

  defp past_subtitle(%Group{status: :completed, completed_at: at}),
    do: "Completed · " <> format_past_date(at)

  defp past_subtitle(%Group{status: :cancelled, cancelled_at: at}),
    do: "Cancelled · " <> format_past_date(at)

  defp format_past_date(nil), do: ""
  defp format_past_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")

  # Computed server-side and relabelled by the page's `:tick` timer rather than stored —
  # see the moduledoc for why this is a plain assign refresh rather than a stream. Both
  # callers in the template are guarded by `:if={group.deadline_at}`, so `deadline_at` is
  # never nil here. `text` is the compact `font-mono` label the card shows; `aria` is the
  # full phrase an `aria-label` needs because "2d left" alone is not speakable.
  defp countdown_text(deadline_at, now), do: deadline_at |> classify_countdown(now) |> elem(0)
  defp countdown_aria(deadline_at, now), do: deadline_at |> classify_countdown(now) |> elem(1)

  defp classify_countdown(%DateTime{} = deadline_at, %DateTime{} = now) do
    seconds = DateTime.diff(deadline_at, now, :second)

    cond do
      seconds < 60 ->
        {"Closing now", "Closing now"}

      seconds < 3600 ->
        minutes = div(seconds, 60)
        {"#{minutes}m", "closes in #{pluralize(minutes, "minute")}"}

      seconds < 86_400 ->
        hours = div(seconds, 3600)
        minutes = div(rem(seconds, 3600), 60)

        {"#{hours}h #{minutes}m",
         "closes in #{pluralize(hours, "hour")} #{pluralize(minutes, "minute")}"}

      true ->
        days = div(seconds, 86_400)
        {"#{days}d left", "closes in #{pluralize(days, "day")}"}
    end
  end

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(n, unit), do: "#{n} #{unit}s"
end
