defmodule ConsensusWeb.JoinLive.Results do
  @moduledoc """
  Design frame `05b · same screen, after anyone votes` — `/join/:slug/results`.

  The participant's half of the shared `ConsensusWeb.ResultsComponents.results_panel/1`
  (see that module for everything the two `results` screens have in common). This
  LiveView is only the mount, the reload plumbing, and the footer/banner that are
  participant-only:

    * the mint **"Your ranking is in"** confirmation banner once this participant has
      voted (`participant.voted_at` set);
    * the muted **"Only `<organizer>` can nudge or close early"** notice in the
      footer, in place of that — **not** the "Change my ranking" button frame `05b`
      draws. D-036: the ballot is locked; there is no update path, so there is
      nothing here to wire up. Do not add one back.
    * a **"Cast your vote"** link when this browser has not voted yet and the group
      is still open — not drawn on `05b` (which assumes a voter who already has), but
      needed for anyone who reaches `/results` first (a direct link, or the
      `:completed`/`:cancelled` redirect `ConsensusWeb.JoinAuth` sends a non-voter
      through).

  `@group` and `@participant` arrive already assigned by `ConsensusWeb.JoinAuth`'s
  `:resolve_participant` on_mount hook, which also applies the `/join`-tree's status
  guards (a `:draft` group never reaches here; `:completed`/`:cancelled` land here
  directly rather than looping through `/join/:slug`). `@participant` is `nil` for a
  visitor this browser session has no token for.

  ## Live updates — the acceptance bar

  Same as `ConsensusWeb.GroupLive.Results`: `Consensus.Voting.subscribe/1` on mount, a
  30s `:tick` for the countdown, and a reload — re-fetching the group by slug (status
  can change), the tally, and this browser's own participant row — on every message
  the topic can carry. A guest sitting on this screen sees the tally move the instant
  anyone else submits a ballot, with no reload.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Accounts
  alias Consensus.Activities
  alias Consensus.Deadlines
  alias Consensus.Voting

  import ConsensusWeb.ResultsComponents

  @tick_interval :timer.seconds(30)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    group = socket.assigns.group

    if connected?(socket) do
      Voting.subscribe(group.id)
      Process.send_after(self(), :tick, @tick_interval)
    end

    organizer = Accounts.get_user!(group.organizer_id)

    {:ok,
     socket
     |> assign(:page_title, "Results · #{group.title}")
     |> assign(:now, DateTime.utc_now())
     |> assign(:slug, slug)
     |> assign(:organizer_username, organizer.username)
     |> load_tally()}
  end

  @impl true
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

  defp reload(socket) do
    case Activities.get_group_by_slug(socket.assigns.slug) do
      nil ->
        socket

      group ->
        socket
        |> assign(:group, group)
        |> refresh_participant()
        |> load_tally()
    end
  end

  defp refresh_participant(%{assigns: %{participant: nil}} = socket), do: socket

  defp refresh_participant(%{assigns: %{participant: participant}} = socket) do
    # A second tab could have cast this same participant's ballot since we mounted;
    # re-reading by token (rather than trusting the struct in hand) is the same
    # "don't trust it, re-check" idiom `Consensus.Voting.get_participant_by_token/1`'s
    # docs call for.
    assign(socket, :participant, Voting.get_participant_by_token(participant.token))
  end

  defp load_tally(socket) do
    group = socket.assigns.group
    tally = Voting.tally(group)

    socket
    |> assign(:tally, tally)
    |> assign(:outcome, Voting.outcome(tally))
    |> assign(:participants, Voting.participants(group))
  end

  defp voted?(nil), do: false
  defp voted?(%{voted_at: nil}), do: false
  defp voted?(%{voted_at: %DateTime{}}), do: true

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.results_panel
        group={@group}
        tally={@tally}
        outcome={@outcome}
        participants={@participants}
        current_participant_id={@participant && @participant.id}
        avatar_caption="ORGANIZER NUDGES"
        countdown_text={Deadlines.countdown(@group.deadline_at, @now)}
      >
        <:banner :if={voted?(@participant)}>
          <.sticker_card tone={:mint} depth={2} radius={:sm} class="flex items-center gap-2.5 p-3">
            <span
              class="grid size-[22px] shrink-0 place-items-center rounded-full bg-ink text-white"
              aria-hidden="true"
            >
              ✓
            </span>
            <span class="text-sm font-bold text-ink">Your ranking is in</span>
          </.sticker_card>
        </:banner>

        <:footer>
          <p
            :if={@group.status == :cancelled}
            class="rounded-2xl border-2 border-ink-30 bg-white/65 p-3 text-center text-sm text-muted"
          >
            This session was cancelled.
          </p>

          <p
            :if={@group.status != :cancelled && voted?(@participant)}
            class="rounded-2xl border-2 border-ink/30 bg-white/65 p-3 text-[11.5px]/[1.35] text-muted"
          >
            Only {@organizer_username} can nudge or close early.
          </p>

          <.link
            :if={@group.status == :voting && !voted?(@participant)}
            navigate={~p"/join/#{@group.slug}/vote"}
            class="block rounded-2xl border-2 border-ink bg-tangerine p-4 text-center font-bold text-white shadow-sticker-4 press-4"
          >
            Cast your vote
          </.link>
        </:footer>
      </.results_panel>
    </Layouts.app>
    """
  end
end
