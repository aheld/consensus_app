defmodule ConsensusWeb.JoinLive.Entry do
  @moduledoc """
  The recipient's front door — `/join/:slug` (design frame `06`,
  `docs/design/screens/1a-8-06-recipient-s-first-view.html`).

  CLAUDE.md product invariant 1: voter friction is zero. A guest never sees a signup, a
  password, or an email field — the only ask here is an optional first name, and even
  that has a `skip →` escape hatch. The name/skip/join-as-yourself controls all end in a
  **real browser `POST /join/:slug/enter`** (`ConsensusWeb.JoinController`), never a
  `phx-submit` that stays on the socket — a LiveView cannot write the session cookie that
  carries the participant's token, which is the whole reason that controller exists.

  ## Why this screen still has `handle_event/3` clauses despite that

  The primary path (typing a name, or nothing, and pressing "Start voting") needs no
  LiveView involvement at all: the `<form>` below carries a plain `action`/`method` and no
  `phx-submit`, so a click on a `type="submit"` button is an ordinary, un-intercepted
  browser submission. `phx-change="validate_name"` on the same form only drives the live
  character counter (CLAUDE.md invariant 11 — see below) and never blocks that submission.

  `skip →` and "Continue as `<username>`" are different: both must override what the
  *browser* is about to submit (force the name blank, or switch `kind` to `"user"`) before
  the POST happens, and a plain HTML control cannot rewrite a sibling field's value on its
  own. Both go through the same `phx-trigger-action` trick `ConsensusWeb.UserLive.Login`
  already uses for its password form: a `phx-click` sets the assigns that make `@form`
  render the right hidden values, flips `@trigger_submit`, and *that* is what makes
  `ConsensusWeb.JoinAuth`'s live-updated `<form>` perform one genuine, uncaptured POST —
  not a second, LiveView-shaped one.

  ## Two guards this screen owns, that `ConsensusWeb.JoinAuth` deliberately leaves to it

  `JoinAuth`'s `:resolve_participant` hook only ever assigns `@participant` (possibly
  `nil`) — it does not decide what a screen does with one. Mirroring the `cond` shape
  `ConsensusWeb.JoinLive.Ballot` already uses for the same two facts, in the opposite
  direction:

    * **Already voted** (`participant.voted_at` set) — the ballot is locked (D-036), so
      showing this join form again would be pointless at best. Sent straight to results.
    * **Already joined, not yet voted** — sent straight to the ballot rather than
      re-rendering this form. This is not just tidiness: `ConsensusWeb.JoinController`'s
      guest branch calls `Consensus.Voting.create_participant/2` **unconditionally** on
      every POST (there is no "resume" check for a guest the way there is for `kind:
      "user"`, since a guest has no `user_id` to look one up by) — resubmitting this form
      with an existing session token would silently mint a *second*, orphaned participant
      row rather than resuming the first. Not showing the form again is what keeps that
      from ever happening through the one path a real visitor can reach.

  ## Deviations from the comp, and why

  * **No maxlength, and a counter the comp doesn't draw.** CLAUDE.md invariant 11: no
    free-text field gets a `maxlength` attribute — a browser's `maxlength` counts UTF-16
    code units, `Ecto.Changeset.validate_length/3` counts graphemes, and a browser's way
    of disagreeing is a silent truncated paste. `Consensus.Voting.Participant` already
    exposes `max_display_name_length/0` (40) for exactly this counter, documented there as
    "for the same reason `Activity.max_description_length/0` is" — this screen is what
    finally reads it, the way `ConsensusWeb.GroupLive.Options` reads the activity one.
  * **The "Continue as `<username>`" line.** The comp draws only the guest path; a
    signed-in visitor additionally gets this one-line affordance (never a requirement —
    the guest form above it still works) so the brief's "or logging in as a known user"
    has somewhere to live. Placed above the name field, not inside it, so it reads as an
    alternative rather than a variant of the same control.
  * **The organizer/deadline/spot-count formatting is duplicated from
    `ConsensusWeb.GroupLive.Share`, not shared with it.** `Share`'s compact "5 spots ·
    closes Thu 6pm" formatter is a handful of small private functions with no public
    counterpart, and this pass touches only this file — see this LiveView's task report
    for the follow-up suggestion (extract a shared `Consensus.Deadlines` helper) rather
    than editing `Share` or `Deadlines` out from under a sibling change in flight.
  * **The overlapping voted-avatars row is hand-built, not `Sticker.participant_avatar_row/1`.**
    That component's own doc says its label-under-each-avatar layout is for `05`/`05b`;
    `06`'s compact overlap-with-a-"+N"-bubble treatment is a different shape entirely, and
    `participant_avatar/1`'s `show_label={false}` flag exists precisely so a screen like
    this one can compose it directly instead of stretching the row component to cover a
    layout it was never built for. Hidden entirely when nobody has voted yet — the comp's
    copy ("3 friends already voted") has no sensible zero form, and a freshly published
    group has no voters to show.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Voting
  alias Consensus.Voting.Participant

  @impl true
  def mount(_params, _session, socket) do
    %{group: group, participant: participant} = socket.assigns

    cond do
      is_nil(participant) ->
        {:ok, assign_entry(socket, group)}

      not is_nil(participant.voted_at) ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}/results")}

      true ->
        {:ok, push_navigate(socket, to: ~p"/join/#{group.slug}/vote")}
    end
  end

  defp assign_entry(socket, group) do
    voted_participants = group |> Voting.participants() |> Enum.filter(& &1.voted?)

    socket
    |> assign(:page_title, group.title)
    |> assign(:organizer, Accounts.get_user!(group.organizer_id))
    |> assign(:activity_count, length(group.activities))
    |> assign(:voted_participants, voted_participants)
    |> assign(:voted_count, length(voted_participants))
    |> assign(:now, DateTime.utc_now())
    |> assign_tz_offset()
    |> assign(:form, join_form(%{"display_name" => "", "kind" => "guest"}))
    |> assign(:trigger_submit, false)
  end

  # Same connect-params idiom `ConsensusWeb.GroupLive.Share` uses: `assets/js/app.js` sends
  # `tz_offset` for every LiveView, signed in or not, so this needs no auth to read.
  defp assign_tz_offset(socket) do
    offset =
      case connected?(socket) && get_connect_params(socket) do
        %{"tz_offset" => offset} when is_integer(offset) -> offset
        _ -> 0
      end

    assign(socket, :tz_offset, offset)
  end

  defp join_form(params), do: to_form(params)

  ## Events
  #
  # None of these write anything — `Consensus.Voting.create_participant/2` is only ever
  # called from `ConsensusWeb.JoinController`, after the real POST these events prepare
  # for. See the moduledoc for why the primary "Start voting" submit needs no clause here
  # at all (no `phx-submit` on the form) while these two do.

  @impl true
  def handle_event("validate_name", %{"display_name" => name}, socket) do
    {:noreply, assign(socket, :form, join_form(%{"display_name" => name, "kind" => "guest"}))}
  end

  def handle_event("skip", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, join_form(%{"display_name" => "", "kind" => "guest"}))
     |> assign(:trigger_submit, true)}
  end

  def handle_event("join_as_user", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, join_form(%{"display_name" => "", "kind" => "user"}))
     |> assign(:trigger_submit, true)}
  end

  ## Display helpers

  defp name_length(form) do
    form[:display_name].value |> to_string() |> String.length()
  end

  defp organizer_initial(%{username: username}) when is_binary(username) and username != "" do
    String.upcase(String.first(username))
  end

  defp organizer_initial(_organizer), do: "?"

  defp subhead(activity_count) do
    "#{activity_count} #{pluralize(activity_count, "spot")}, one tap each. Your picks stay anonymous."
  end

  defp spots_pill_text(count), do: "#{count} #{pluralize(count, "spot")}"

  defp friends_caption(count), do: "#{count} #{pluralize(count, "friend")} already voted"

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  # "closes today 6pm" / "closes tomorrow 6pm" / "closes thu 6pm" — deliberately the same
  # compact shape `ConsensusWeb.GroupLive.Share`'s private `closes_phrase/3` produces
  # (rather than `Consensus.Deadlines.label_for/3`'s "Closes Thu 6:00 PM", which is right
  # for that screen's full sentence and wrong for this pill's few characters). Rendered
  # uppercase via the pill's own CSS class, not by shouting in the string.
  defp closes_pill_text(%{deadline_at: nil}, _now, _offset), do: "closes soon"

  defp closes_pill_text(%{deadline_at: at}, now, offset) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} background="bg-white">
      <div class="relative flex min-h-dvh flex-col overflow-hidden">
        <%!-- The two soft blob shapes from the comp — purely decorative, so both are
              `aria-hidden` and `pointer-events-none`. Positioned relative to the whole
              screen rather than a fixed 700px mockup frame, per DESIGN-SPEC.md's own
              caveat that the phone frame sizes aren't real app widths. --%>
        <div
          aria-hidden="true"
          class="pointer-events-none absolute -right-[80px] -top-[70px] size-[280px] rounded-[62%_38%_47%_53%/48%_55%_45%_52%] bg-yellow-soft"
        />
        <div
          aria-hidden="true"
          class="pointer-events-none absolute -left-[70px] bottom-[120px] size-[200px] rounded-[44%_56%_61%_39%/57%_41%_59%_43%] bg-violet-soft"
        />

        <div class="relative z-10 flex flex-1 flex-col gap-[18px] px-[22px] pt-[22px]">
          <div class="inline-flex w-fit items-center gap-2 rounded-full border-2 border-ink bg-white py-[5px] pl-[6px] pr-3 shadow-sticker-2">
            <span
              aria-hidden="true"
              class="grid size-6 shrink-0 place-items-center rounded-full border-2 border-ink bg-yellow text-[10px] font-bold text-ink"
            >
              {organizer_initial(@organizer)}
            </span>
            <span class="text-xs font-semibold text-ink">{@organizer.username} invited you</span>
          </div>

          <h1 class="text-pretty text-[36px] font-bold leading-[1.02] tracking-[-0.032em] text-ink">
            {@group.title}
          </h1>

          <p class="max-w-[250px] text-[14.5px] leading-[1.45] text-ink-soft">
            {subhead(@activity_count)}
          </p>

          <div class="flex flex-wrap gap-[9px]">
            <span class="rounded-full border-2 border-ink bg-white px-3 py-[6px] font-mono text-[11.5px] font-semibold uppercase text-ink">
              {spots_pill_text(@activity_count)}
            </span>
            <span class="rounded-full border-2 border-ink bg-white px-3 py-[6px] font-mono text-[11.5px] font-semibold uppercase text-ink">
              {closes_pill_text(@group, @now, @tz_offset)}
            </span>
            <span class="rounded-full border-2 border-ink bg-white px-3 py-[6px] font-mono text-[11.5px] font-semibold uppercase text-ink">
              ~10 sec
            </span>
          </div>

          <div :if={@voted_count > 0} class="flex items-center gap-[9px]">
            <div class="flex">
              <%!-- `participant_avatar/1` always wraps itself in its own
                    `<div class="flex flex-col items-center gap-1">` (for the label slot
                    underneath), so a `class` passed *to the component* lands on the inner
                    circle, not on the flex item this row overlaps by margin. Wrapping each
                    call in a div of our own gives the overlap something to actually shift. --%>
              <div :for={p <- Enum.take(@voted_participants, 2)} class="-ml-[7px] first:ml-0">
                <.participant_avatar
                  participant_id={p.id}
                  initial={p.initial}
                  state={:voted}
                  size={29}
                  show_label={false}
                  ring={false}
                />
              </div>
              <div :if={@voted_count > 2} class="-ml-[7px]">
                <span
                  aria-hidden="true"
                  class="grid size-[29px] shrink-0 place-items-center rounded-full border-2 border-ink bg-white text-[10.5px] font-semibold text-ink"
                >
                  +{@voted_count - 2}
                </span>
              </div>
            </div>
            <span class="text-xs font-medium text-ink-soft">{friends_caption(@voted_count)}</span>
          </div>
        </div>

        <div class="relative z-10 flex flex-col gap-3 px-[22px] pb-6 pt-[18px]">
          <button
            :if={@current_scope && @current_scope.user}
            type="button"
            phx-click="join_as_user"
            class="self-start font-mono text-[11px] font-semibold text-violet underline decoration-2 underline-offset-2 hover:text-tangerine"
          >
            Continue as {@current_scope.user.username} →
          </button>

          <.form
            for={@form}
            id="join-form"
            action={~p"/join/#{@group.slug}/enter"}
            method="post"
            phx-change="validate_name"
            phx-trigger-action={@trigger_submit}
            class="flex flex-col gap-1.5"
          >
            <%!-- Hand-built rather than `<.input>`: the comp puts the "skip →" control
                  *inside* the same bordered field, which `<.input>`'s label+error column
                  layout has no slot for (design-system skill: build by hand when no
                  variant fits, same as the pool-row example there). --%>
            <div class="flex items-center gap-2 rounded-2xl border-2 border-ink bg-white px-4 py-[14px] shadow-field">
              <input
                type="text"
                name={@form[:display_name].name}
                id={@form[:display_name].id}
                value={@form[:display_name].value}
                placeholder="Your first name"
                autocomplete="given-name"
                class="w-full flex-1 border-0 bg-transparent p-0 text-[15px] font-medium text-ink outline-none placeholder:text-muted"
              />
              <button
                type="button"
                phx-click="skip"
                class="shrink-0 font-mono text-[11px] text-violet hover:text-tangerine"
              >
                skip →
              </button>
            </div>
            <.input field={@form[:kind]} type="hidden" />

            <div class="flex justify-end px-1">
              <span
                class={[
                  "font-mono text-[10px]",
                  if(name_length(@form) > Participant.max_display_name_length(),
                    do: "font-semibold text-tangerine",
                    else: "text-muted"
                  )
                ]}
                aria-live="polite"
              >
                {name_length(@form)}/{Participant.max_display_name_length()}
              </span>
            </div>

            <.button variant="primary" type="submit" class="w-full">
              Start voting
            </.button>
          </.form>

          <p class="text-center font-mono text-[11px] font-medium uppercase text-muted">
            No app · no account · no password
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
