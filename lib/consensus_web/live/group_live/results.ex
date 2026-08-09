defmodule ConsensusWeb.GroupLive.Results do
  @moduledoc """
  Design frame `05 · live results (organizer)` — `/groups/:id/results`.

  The organizer's half of the shared `ConsensusWeb.ResultsComponents.results_panel/1`
  (see that module for everything the two `results` screens have in common — header,
  avatar row, the completed/cancelled outcome section, the tally, the anonymity
  caption). This LiveView is only the mount, the reload plumbing, and the footer that
  is organizer-only: **Nudge N friends** and **Close now** while the vote is open.

  Reached from `HomeLive`'s group list and from `GroupLive.Share`'s "session is live"
  preview — see `docs/plans/voting-loop.md`. Sits in the router's existing
  `:require_authenticated_user` live_session (not a new one — AGENTS.md), so
  `Consensus.Activities.get_group!/2`'s organizer scoping is what keeps a stranger
  from reading someone else's tally: it raises `Ecto.NoResultsError` for any id that
  is not this signed-in user's own group.

  ## Live updates — the acceptance bar

  `Consensus.Voting.subscribe/1` on mount (the same `"activity_group:<id>"` topic
  `Consensus.Activities` already publishes group/activity changes on), plus a 30s
  `:tick` for the countdown text. Every message this topic can carry —
  `{:ballot_cast, group_id}`, `{:participant_joined, group_id}`, `{:group_updated,
  group}`, and the three activity messages (harmless here:
  `Consensus.Activities.add_activity/3` and friends already refuse once the pool leaves
  `:draft`, D-037) — reloads the group and re-tallies. This is the one behaviour the
  brief calls out by name: a guest's vote, cast in a second browser tab, must appear
  here **without this tab navigating** — and so must a guest simply joining, so the
  avatar row and the "Nudge N friends" count never sit stale for up to 30 seconds.

  ## A `:draft` group has no results yet

  Bounces to `03 review`, the same redirect `GroupLive.Share` uses for the same
  reason — nothing has been published, so there is no tally and no share link either.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Voting

  import ConsensusWeb.ResultsComponents

  @tick_interval :timer.seconds(30)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    group = Activities.get_group!(socket.assigns.current_scope, id)

    if group.status == :draft do
      {:ok, push_navigate(socket, to: ~p"/groups/#{group}/review")}
    else
      if connected?(socket) do
        Voting.subscribe(group.id)
        Process.send_after(self(), :tick, @tick_interval)
      end

      {:ok,
       socket
       |> assign(:page_title, "Results · #{group.title}")
       |> assign(:now, DateTime.utc_now())
       |> load_group(group)}
    end
  end

  @impl true
  def handle_event("nudge", _params, socket) do
    # No mail provider in production (CLAUDE.md "known gap") — flash a confirmation
    # of the click without claiming a notification actually went out.
    {:noreply,
     put_flash(
       socket,
       :info,
       "There's no notification system yet — share the link again to remind them."
     )}
  end

  def handle_event("close_now", _params, socket) do
    case Activities.complete_group(socket.assigns.current_scope, socket.assigns.group) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Voting is closed.")
         |> reload()}

      {:error, :already_finished} ->
        {:noreply, put_flash(socket, :error, "This session has already finished.")}
    end
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Summary copied")}
  end

  def handle_event("copy_failed", _params, socket) do
    {:noreply, put_flash(socket, :info, "Couldn't copy automatically — select the text above")}
  end

  @impl true
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_interval)
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> reload()}
  end

  def handle_info({:ballot_cast, _group_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:participant_joined, _group_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:group_updated, _group}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_added, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activity_updated, _activity}, socket), do: {:noreply, reload(socket)}
  def handle_info({:activities_changed, _activities}, socket), do: {:noreply, reload(socket)}

  defp load_group(socket, group) do
    tally = Voting.tally(group)

    socket
    |> assign(:group, group)
    |> assign(:tally, tally)
    |> assign(:outcome, Voting.outcome(tally))
    |> assign(:participants, Voting.participants(group))
  end

  defp reload(socket) do
    group = Activities.get_group!(socket.assigns.current_scope, socket.assigns.group.id)
    load_group(socket, group)
  end

  defp waiting_count(participants), do: Enum.count(participants, &(!&1.voted?))

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.results_panel
        group={@group}
        tally={@tally}
        outcome={@outcome}
        participants={@participants}
        avatar_caption="TAP TO NUDGE"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
      >
        <:footer>
          <div :if={@group.status == :voting} class="flex gap-[9px]">
            <%!-- Hand-built rather than `<.button>`: the comp draws this flat — no shadow —
                  same as "Close now" beside it, and `<.button>`'s default variant always
                  adds `shadow-sticker-2`/`press-2`. --%>
            <button
              type="button"
              phx-click="nudge"
              class="flex-1 rounded-2xl border-2 border-ink bg-white px-4 py-3.5 text-center text-[14px] font-bold text-ink transition-colors hover:bg-yellow"
            >
              Nudge {waiting_count(@participants)} {pluralize(
                waiting_count(@participants),
                "friend"
              )}
            </button>
            <button
              type="button"
              phx-click="close_now"
              data-confirm="Close voting now? This can't be undone."
              class="rounded-2xl border-2 border-ink px-4 py-3.5 text-[14px] font-semibold text-ink-soft hover:bg-white"
            >
              Close now
            </button>
          </div>

          <p :if={@group.status == :cancelled} class="text-center text-sm text-muted">
            This session was cancelled.
          </p>
        </:footer>
      </.results_panel>
    </Layouts.app>
    """
  end
end
