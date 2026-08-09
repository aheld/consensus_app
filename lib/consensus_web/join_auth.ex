defmodule ConsensusWeb.JoinAuth do
  @moduledoc """
  The `on_mount` hook for the recipient's public join flow — `/join/:slug`,
  `/join/:slug/vote` and `/join/:slug/results` (`ConsensusWeb.JoinLive.{Entry,Ballot,Results}`).

  This is the participant-side sibling of `ConsensusWeb.UserAuth`, and deliberately not
  part of it: the unit of identity here is a `Consensus.Voting.Participant`'s token, not
  an `Consensus.Accounts.User`'s session, and most visitors who reach it have no account
  at all (CLAUDE.md product invariant 1 — voter friction is zero). It lives beside
  `user_auth.ex` rather than under `live/` or `components/`, the same placement
  `ConsensusWeb.UserAuth` itself uses for a router-wide `on_mount` hook.

  ## What it does, in order

  1. Looks the group up by the route's `:slug` (`Consensus.Activities.get_group_by_slug/1`,
     which — via `Consensus.Activities.maybe_complete_group/1` — lazily flips a `:voting`
     group whose deadline has passed to `:completed` on this very read; see D-029). A
     slug that matches nothing sends the visitor home with a flash.
  2. Applies the `/join` tree's status guard from `docs/plans/voting-loop.md`: a `:draft`
     group (not published yet) sends the visitor home with a flash; a `:completed` or
     `:cancelled` group sends them straight to `/join/:slug/results` — *unless* they are
     already mounting `ConsensusWeb.JoinLive.Results`, which is where that redirect would
     otherwise loop.
  3. Resolves the session's participant token — stored **keyed by group id**, since one
     browser may join more than one group's vote over time (see
     `ConsensusWeb.JoinController.participant_session_key/1`, which this module reuses) —
     into `@participant`, or `nil` when the visitor has not joined yet (the ordinary case
     for a fresh visit to `06 entry`). This module does not require a participant to
     exist; it only resolves one if the session has it. A screen that needs one (the
     ballot, results) is responsible for redirecting when `@participant` is `nil`.

  `@group` and `@participant` are the only two assigns this hook adds. `@current_scope`
  is *not* set here — chain `{ConsensusWeb.UserAuth, :mount_current_scope}` ahead of this
  hook in the `live_session`'s `on_mount` list (the router does), which is how `06`'s
  "join as your account" affordance gets `@current_scope` without a second, duplicate
  `live_session` (AGENTS.md: a `live_session` name may only be declared once).

  ## What this hook deliberately does *not* do

  It does not redirect a `Consensus.Voting.Participant` with `voted_at` already set away
  from `/join/:slug/vote` — that lock (D-036) is `ConsensusWeb.JoinLive.Ballot`'s own
  route-level guard, not a property of every `/join` screen (`/join/:slug/results` is
  exactly where a voted participant is *supposed* to be). Keeping it out of this shared
  hook is deliberate, not an oversight.
  """

  use ConsensusWeb, :verified_routes

  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Voting
  alias Consensus.Voting.Participant

  @doc """
  The Phoenix session key one group's participant token is stored under.

  Keyed by group id so a single browser session can hold a distinct participant token
  per group it has joined, rather than one token overwriting another. Shared between
  this module (which reads it, below) and `ConsensusWeb.JoinController.enter/2` (which
  writes it) — the only two call sites, and they must agree on the shape.
  """
  @spec participant_session_key(integer()) :: String.t()
  def participant_session_key(group_id) when is_integer(group_id) do
    "participant_token:#{group_id}"
  end

  @doc false
  def on_mount(:resolve_participant, %{"slug" => slug}, session, socket) do
    case Activities.get_group_by_slug(slug) do
      nil ->
        {:halt, redirect_home(socket, "That link doesn't look right.")}

      %Group{status: :draft} ->
        {:halt, redirect_home(socket, "This vote isn't open yet.")}

      %Group{status: status} = group when status in [:completed, :cancelled] ->
        if socket.view == ConsensusWeb.JoinLive.Results do
          {:cont, assign_group_and_participant(socket, group, session)}
        else
          {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/join/#{slug}/results")}
        end

      %Group{status: :voting} = group ->
        {:cont, assign_group_and_participant(socket, group, session)}
    end
  end

  defp assign_group_and_participant(socket, %Group{} = group, session) do
    socket
    |> Phoenix.Component.assign(:group, group)
    |> Phoenix.Component.assign(:participant, resolve_participant(group, session))
  end

  defp resolve_participant(%Group{id: group_id}, session) do
    with token when is_binary(token) <- session[participant_session_key(group_id)],
         %Participant{group_id: ^group_id} = participant <-
           Voting.get_participant_by_token(token) do
      participant
    else
      _not_found -> nil
    end
  end

  defp redirect_home(socket, message) do
    socket
    |> Phoenix.LiveView.put_flash(:error, message)
    |> Phoenix.LiveView.redirect(to: ~p"/")
  end
end
