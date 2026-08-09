defmodule ConsensusWeb.JoinController do
  @moduledoc """
  `POST /join/:slug/enter` — the only path that mints a `Consensus.Voting.Participant`.

  This exists as a controller, not a LiveView `handle_event`, because a LiveView cannot
  write a session cookie: `ConsensusWeb.JoinLive.Entry` (design frame `06`) renders the
  name form, and submitting it does a real form `POST` here rather than a `phx-submit`.
  `enter/2` creates the participant, puts their token in the session **keyed by group**
  (`ConsensusWeb.JoinAuth.participant_session_key/1` — one browser may join several
  groups' votes over time), and redirects to the ballot.

  ## Params

  `slug` comes from the path. The body carries at most two fields, both optional:

    * `"display_name"` — the typed name. Blank, whitespace-only, or absent all mean
      anonymous; `Consensus.Voting.create_participant/2` normalises any of those to
      `nil` itself, so this controller does not special-case a `skip` value — leaving
      the field blank *is* skip.
    * `"kind"` — `"user"` requests joining as the signed-in account (`06`'s "or join as
      yourself" affordance); anything else, or no signed-in `@current_scope.user`,
      means an ordinary guest. A spoofed `"kind" => "user"` from a signed-out visitor is
      silently treated as a guest request rather than honoured or rejected — never a
      signup prompt, per CLAUDE.md product invariant 1.

  A signed-in user who has already joined this group resumes their existing
  participant (`Consensus.Voting.get_participant_for_user/2`) rather than hitting the
  partial unique index on `(group_id, user_id)` and failing.

  ## Why every branch redirects rather than rendering

  This is a plain `POST` handler with no template of its own — every outcome, success
  or refusal, ends in a redirect (to the ballot, to results, or back to `06` with a
  flash), which is what makes the guest never see a raw error page here. See D-034: a
  guest hitting a busy database at this exact front door — before they have even seen
  the pool — is the scenario `Consensus.Voting.create_participant/2`'s
  `{:error, {:database_busy, _}}` tuple exists to let a caller render instead of crash.
  """

  use ConsensusWeb, :controller

  alias Consensus.Accounts.Scope
  alias Consensus.Accounts.User
  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Voting
  alias Consensus.Voting.Participant
  alias ConsensusWeb.JoinAuth

  def enter(conn, %{"slug" => slug} = params) do
    case Activities.get_group_by_slug(slug) do
      nil ->
        conn
        |> put_flash(:error, "That link doesn't look right.")
        |> redirect(to: ~p"/")

      %Group{status: :draft} ->
        conn
        |> put_flash(:error, "This vote isn't open yet.")
        |> redirect(to: ~p"/")

      %Group{status: status} = group when status in [:completed, :cancelled] ->
        redirect(conn, to: ~p"/join/#{group.slug}/results")

      %Group{status: :voting} = group ->
        do_enter(conn, group, params)
    end
  end

  defp do_enter(conn, %Group{} = group, params) do
    case resolve_participant(conn, group, params) do
      {:ok, %Participant{} = participant} ->
        conn
        |> put_session(JoinAuth.participant_session_key(group.id), participant.token)
        |> redirect(to: ~p"/join/#{group.slug}/vote")

      {:error, reason} ->
        handle_enter_error(conn, group, reason)
    end
  end

  # A signed-in visitor who chose "join as yourself" and already has a participant in
  # this group resumes it instead of racing the partial unique index on
  # `(group_id, user_id)` — see `Consensus.Voting.create_participant/2`'s docs.
  defp resolve_participant(conn, %Group{} = group, %{"kind" => "user"}) do
    case conn.assigns[:current_scope] do
      %Scope{user: %User{id: user_id}} ->
        case Voting.get_participant_for_user(group, user_id) do
          %Participant{} = participant -> {:ok, participant}
          nil -> Voting.create_participant(group, %{kind: :user, user_id: user_id})
        end

      # Not actually signed in (`@current_scope.user` is nil, or `@current_scope` is
      # missing entirely) — a spoofed "kind" param never turns into an account
      # requirement (product invariant 1). Fall through to an ordinary guest join.
      _signed_out ->
        resolve_guest(conn, group, nil)
    end
  end

  defp resolve_participant(conn, %Group{} = group, params) do
    resolve_guest(conn, group, params["display_name"])
  end

  # A guest has no `user_id` to resume by, so — unlike the `kind: "user"` branch above —
  # the only thing that can say "this browser already joined" is the participant token
  # already sitting in its own session. Without this check, a second POST from the same
  # browser (a double-click, a resubmit after going back) called
  # `Voting.create_participant/2` unconditionally and minted a second, orphaned
  # participant every time — inflating the organizer's voted/waiting counts with a
  # phantom that can never vote, since the session token only ever points at the newest
  # row. Re-reading by token rather than trusting anything cached is the same "don't
  # trust the struct in hand" idiom `ConsensusWeb.JoinAuth.resolve_participant/2` already
  # uses for the very same session key.
  defp resolve_guest(conn, %Group{} = group, display_name) do
    case existing_participant(conn, group) do
      %Participant{} = participant -> {:ok, participant}
      nil -> Voting.create_participant(group, %{display_name: display_name, kind: :guest})
    end
  end

  defp existing_participant(conn, %Group{id: group_id}) do
    with token when is_binary(token) <-
           get_session(conn, JoinAuth.participant_session_key(group_id)),
         %Participant{group_id: ^group_id} = participant <- Voting.get_participant_by_token(token) do
      participant
    else
      _not_found -> nil
    end
  end

  defp handle_enter_error(conn, %Group{} = group, {:database_busy, _message}) do
    conn
    |> put_flash(:error, "Lots of people are joining right now — try again in a second.")
    |> redirect(to: ~p"/join/#{group.slug}")
  end

  # `Voting.create_participant/2` returns the raw `%Ecto.Changeset{}` on a validation
  # failure (never on this guest path except `:display_name` — `:kind` is a literal
  # `:guest` this controller sets, and `:token`/`:group_id` are programmatic). The
  # catch-all below used to swallow this into a generic "try again" flash that named
  # neither the field nor the limit, so a name over the cap dead-ended: the visitor had
  # no idea what to change and retyping the same name failed identically.
  defp handle_enter_error(conn, %Group{} = group, %Ecto.Changeset{} = changeset) do
    message =
      if Keyword.has_key?(changeset.errors, :display_name) do
        "That name is too long — #{Participant.max_display_name_length()} characters max."
      else
        "We couldn't get you in — try again."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/join/#{group.slug}")
  end

  defp handle_enter_error(conn, %Group{} = group, _reason) do
    conn
    |> put_flash(:error, "We couldn't get you in — try again.")
    |> redirect(to: ~p"/join/#{group.slug}")
  end
end
