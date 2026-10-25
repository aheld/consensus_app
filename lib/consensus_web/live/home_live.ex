defmodule ConsensusWeb.HomeLive do
  @moduledoc """
  `/` — one route with two faces (see `docs/plans/creation-flow.md` decision 1).

  `:splash` renders design frame `00a`, the public splash. `:list` renders frame `00`,
  the organizer's home list, and reflows to the desktop organizer console
  (`1b-4-made-with-in-philadelphia.html` — the filename is the extractor's caption, not a
  description; see `docs/design/IMPORT-NOTES.md` §2.2's "`1b-4` filename trap") at `md:` and
  up. It was `1b-2` until the 2026-08-08 re-import renumbered the section, and `1b-2` now
  names an entirely different frame: the phone home.
  `@current_scope` may be `nil` (see `ConsensusWeb.UserAuth`'s `:mount_current_scope` hook,
  wired for this route in the router's `:current_user` `live_session`).

  ## Which face, for whom (D-058)

  Organizing needs no account, so "signed in" is no longer the question. The list is for
  anyone who organizes: a signed-in user always, and an organizer with no account once
  they own at least one session — their identity arrives as `@organizer_scope` from
  `ConsensusWeb.OrganizerAuth`'s read-only `:mount_organizer_scope` hook, never as
  `@current_scope`, which stays user-or-nil so the chrome and every other template keep
  reading it as "signed in". `mount/3` turns that into one `@home_mode` (`:splash` or
  `:list`) and the template asks nothing else. The one thing the list itself says
  differently for an organizer with no account is the quiet "Only in this browser — save
  these" line under its heading (plan §7.1), since nothing but this browser's cookie holds
  their sessions until an account claims them.

  The splash's **Start something** goes to `/groups/new` for everyone: it used to go to
  `/users/register`, while organizing still cost an account.

  Real-time (CLAUDE.md product invariant 4): once connected, the list
  subscribes to every active group's `Consensus.Activities` topic and refreshes the list on
  any broadcast, and a single page-level timer relabels the countdowns every minute. Both
  the group list and the countdown are plain assigns rather than streams — the list is at
  most a handful of rows for one organizer, so a full reset on every tick or broadcast is
  simpler than stream bookkeeping and never re-renders more than this one page.
  """
  use ConsensusWeb, :live_view

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Activities.Group

  @tick_interval :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    # Whichever identity is present: a signed-in user, else the organizer with no account
    # that `OrganizerAuth`'s `:mount_organizer_scope` resolved from this browser's cookie
    # (D-058). Never both — that hook leaves `@organizer_scope` nil for a signed-in user.
    owner_scope = socket.assigns.current_scope || socket.assigns.organizer_scope
    groups = if owner_scope, do: Activities.list_groups(owner_scope), else: []
    home_mode = home_mode(socket.assigns.current_scope, groups)

    socket =
      socket
      |> assign(:owner_scope, owner_scope)
      |> assign(:home_mode, home_mode)
      # Without this, `root.html.heex`'s `<.live_title default="Consensus" suffix=" ·
      # Consensus">` collided with itself and the app's front door named itself
      # "Consensus · Consensus" in the tab, the history entry and every bookmark of it.
      # `HomeLive` was the only user-facing LiveView assigning no `:page_title`.
      |> assign(:page_title, page_title(home_mode))
      |> assign(:active_groups, [])
      |> assign(:past_groups, [])
      |> assign(:now, DateTime.utc_now())

    socket = if home_mode == :list, do: mount_list(socket, groups), else: socket

    {:ok, socket}
  end

  # One decision drives the whole page — title, column width, background, chrome variant
  # and splash-vs-list — where there used to be eight separate `if @current_scope` tests.
  # A signed-in organizer always gets the list (an empty one says "Nothing yet"); an
  # organizer with no account gets it only once they own something. That second half is
  # the point: a drive-by visit to `/groups/new` mints an identity, and pressing `‹` from
  # there must still land on the `00a` splash with `:marketing` chrome rather than an
  # empty "Your sessions" for someone who has made nothing.
  defp home_mode(current_scope, groups) do
    if Scope.authenticated?(current_scope) or groups != [], do: :list, else: :splash
  end

  defp page_title(:list), do: "Your sessions"
  defp page_title(:splash), do: "Decide together"

  defp mount_list(socket, groups) do
    {active_groups, past_groups} = split_groups(groups)

    if connected?(socket) do
      Enum.each(active_groups, &Activities.subscribe_group(&1.id))
      :timer.send_interval(@tick_interval, self(), :tick)
    end

    socket
    |> assign(:active_groups, active_groups)
    |> assign(:past_groups, past_groups)
  end

  # `list_active_groups/1` and `list_past_groups/1` are each `list_groups/1` plus a status
  # filter, so splitting the one list `mount/3` already loaded saves a second query.
  defp split_groups(groups),
    do: Enum.split_with(groups, &(&1.status in [:draft, :voting]))

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:group_updated, _group}, socket), do: {:noreply, refresh_groups(socket)}
  def handle_info({:activity_added, _activity}, socket), do: {:noreply, refresh_groups(socket)}
  def handle_info({:activity_updated, _activity}, socket), do: {:noreply, refresh_groups(socket)}

  def handle_info({:activities_changed, _activities}, socket),
    do: {:noreply, refresh_groups(socket)}

  # `Consensus.Voting` broadcasts on the *same* `Activities.topic/1` this screen is
  # subscribed to (see its moduledoc — deliberately one topic per group, not two), so an
  # organizer sitting on `/` receives every guest join and every ballot cast on any of
  # their live groups. Without these two clauses `handle_info/2` had no matching head and
  # the organizer's home LiveView terminated with a `FunctionClauseError` the moment
  # anyone voted. Pre-existing since the voting loop landed, and observed in the browser
  # while verifying the chrome; the fix is the same cheap re-fetch every other clause
  # does, because a ballot can complete a group and move it from active to past.
  def handle_info({:participant_joined, _group_id}, socket),
    do: {:noreply, refresh_groups(socket)}

  def handle_info({:ballot_cast, _group_id}, socket), do: {:noreply, refresh_groups(socket)}

  # Cheap re-fetch rather than a targeted update: a broadcast on any subscribed group's
  # topic can move that group between the active and past lists (a deadline-triggered
  # completion), so both lists are reloaded together from the same scope.
  defp refresh_groups(socket) do
    {active_groups, past_groups} =
      socket.assigns.owner_scope |> Activities.list_groups() |> split_groups()

    socket
    |> assign(:active_groups, active_groups)
    |> assign(:past_groups, past_groups)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `/` is the top of the app, so there is no `back`. The splash takes the
          `:marketing` header (plan ruling 3) — a plain Log in link, because the
          tangerine "Start something" below already is the forward action and a second
          header pill would only compete with it. The list is an ordinary `:app` screen
          and needs the `⋯` menu that replaced `Layouts.account_menu/1`. `@current_scope`
          is user-or-nil here even for an organizer with no account (their identity is
          `@organizer_scope`), so the menu they get is the signed-out one. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      width={if @home_mode == :list, do: :wide, else: :phone}
      background={if @home_mode == :list, do: "bg-surface", else: "bg-canvas"}
      variant={if @home_mode == :list, do: :app, else: :marketing}
    >
      <.splash :if={@home_mode == :splash} />
      <.home
        :if={@home_mode == :list}
        active_groups={@active_groups}
        past_groups={@past_groups}
        now={@now}
        saved={Scope.authenticated?(@current_scope)}
      />
    </Layouts.app>
    """
  end

  ## Design frame 00a — the splash

  defp splash(assigns) do
    ~H"""
    <div id="home-hero" class="flex flex-1 flex-col gap-[26px] px-[26px] py-10">
      <div class="flex flex-col gap-3">
        <%!-- The eyebrow wordmark that used to sit here is gone: the global header
              carries the wordmark on every screen now (D-041), and repeating it 20px
              below itself read as a duplicate rather than a brand. --%>
        <h1 class="text-pretty text-[40px] font-bold leading-[1.02] tracking-[-.035em]">
          Decide<br />and Dine
        </h1>
        <p class="max-w-[250px] text-[14.5px] leading-[1.45] text-ink-soft">
          <%!-- "let everyone rank" in frame `00a` is the same false promise as step 3 below;
                the ballot has no ranking control. IMPORT-NOTES.md §5.2 already carries the
                copy-accuracy warning for it. --%>
          Stop the group chat spiral. Put the options up, let everyone pick, get an answer.
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
          navigate={~p"/groups/new"}
          id="home-start"
          class="block rounded-2xl border-2 border-ink bg-tangerine p-4 text-center text-base font-bold text-white shadow-sticker-4 press-4"
        >
          <%!-- Straight into the wizard, for everyone (D-058). This went to
                `~p"/users/register"` while organizing cost an account; now the account is
                only what *saves* a session, so the front door's forward action is the
                session itself. Same label and same destination as `/how-it-works`,
                `/privacy` and the ⋯ menu. --%>
          Start something
        </.link>
        <%!-- The one line on this splash addressed to a *voter* used to link to
              `/users/log-in` — the single thing product invariant 1 says a voter must
              never be shown, and now the landing spot for anyone who wandered off a
              share link. It says the true thing instead: the link they were sent is the
              way in, and there is nothing to sign into. --%>
        <p class="text-center text-[12.5px] font-medium text-ink-soft">
          Sent a link? Open that link — voting needs no account.
          <.link navigate={~p"/how-it-works"} class="text-ink underline">How it works →</.link>
        </p>
      </div>
    </div>
    """
  end

  defp onboarding_steps do
    [
      # Step 1 names the deadline, because `/how-it-works` step 1 does and because
      # `/groups/new` — where `Start something` lands two taps later — asks for exactly these
      # two things and nothing else. This card used to be "Add anything / Type a name or
      # paste a link", so the app's front door and its own walkthrough gave a reader two
      # different first steps for one product, and neither mentioned the deadline that
      # step 3 then leans on. Three cards against five steps is fine — a splash is a
      # shorter telling — as long as no card contradicts a step.
      {1, "bg-yellow", "Name it, set a deadline", "Then add options: type or paste a link."},
      {2, "bg-violet-soft", "Share one link", "No app, no account to vote."},
      # Not "Everyone ranks". Nobody ranks anything: `Consensus.Voting.Vote` is a set of
      # `:approve` rows plus at most one `:veto`, with deliberately no rank or weight column
      # (D-034), and `/how-it-works` already says "Tap every option you'd be happy with".
      # The splash promised a control the ballot does not have, one tap before the ballot.
      # Not a bare "Anonymous.", which is the unqualified version of a claim D-049 had to
      # correct in five other places: who has voted is readable by anyone with the link,
      # and only the picks are secret. Three words is enough room to say the half that is
      # true rather than the word that covers both.
      {3, "bg-peach", "Everyone taps what works",
       "Nobody sees who picked what. The deadline picks the winner."}
    ]
  end

  ## Design frame 00 — the organizer's home (phone) / 1b-4 — desktop console reflow

  attr :active_groups, :list, required: true
  attr :past_groups, :list, required: true
  attr :now, :any, required: true
  attr :saved, :boolean, required: true, doc: "false for an organizer with no account (D-058)"

  defp home(assigns) do
    ~H"""
    <div
      id="home-sessions"
      class="mx-auto flex w-full max-w-[440px] flex-1 flex-col md:max-w-none md:flex-row"
    >
      <aside class="hidden shrink-0 flex-col gap-6 border-r-2 border-ink bg-canvas p-5 md:flex md:w-[210px]">
        <%!-- The console's own wordmark block is gone for the same reason the splash's
              eyebrow is: the global header sits directly above this sidebar and already
              carries it. --%>
        <.link
          navigate={~p"/groups/new"}
          class="flex items-center justify-between rounded-2xl border-2 border-ink bg-tangerine p-3.5 text-white shadow-sticker-4 press-4"
        >
          <span class="text-[15px] font-bold">Start something</span>
          <span class="text-base font-bold" aria-hidden="true">＋</span>
        </.link>
      </aside>

      <div class="flex flex-1 flex-col">
        <%!-- Was a wordmark plus `Layouts.account_menu/1`. Both moved into the global
              header (D-041), so what is left is the page's own h1 — and it says what
              this screen actually is rather than repeating the brand a third time. --%>
        <header class="flex items-center px-5 pb-4 pt-3.5 md:px-6 md:pt-6">
          <h1 class="text-[27px] font-bold leading-none tracking-[-.025em]">Your sessions</h1>
        </header>

        <%!-- The quiet `00` version of `04 share`'s warning (plan §7.1): this list lives in
              this browser's organizer cookie and nowhere else until an account claims it.
              One muted line, never a gate and never a second tangerine — "Start something"
              owns the screen's forward action. Registering is the door, because a log-in
              from this browser claims these sessions just the same and the register form
              links to it. --%>
        <p
          :if={!@saved}
          id="home-unsaved"
          class="px-5 pb-3 text-[12.5px] font-medium text-muted md:px-6"
        >
          Only in this browser —
          <.link
            navigate={~p"/users/register"}
            id="home-unsaved-register"
            class="-my-3 inline-flex min-h-[44px] items-center font-semibold text-ink underline decoration-2 underline-offset-2"
          >save these</.link>
        </p>

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
  # (step 1) if it doesn't. A `:voting` group, and a finished one (`:completed`/
  # `:cancelled`), go to the live results screen — the one place the tally, the winner
  # and the booking CTA actually render (see docs/plans/voting-loop.md's acceptance bar).
  defp group_href(%Group{status: :draft, activities: []} = group),
    do: ~p"/groups/#{group.id}/edit"

  defp group_href(%Group{status: :draft} = group), do: ~p"/groups/#{group.id}/options"
  defp group_href(%Group{status: :voting} = group), do: ~p"/groups/#{group.id}/results"

  defp group_href(%Group{status: status} = group) when status in [:completed, :cancelled],
    do: ~p"/groups/#{group.id}/results"

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
