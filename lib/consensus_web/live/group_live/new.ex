defmodule ConsensusWeb.GroupLive.New do
  @moduledoc """
  `01 setup` — step 1 of 3 in the creation wizard (see `docs/design/DESIGN-SPEC.md` and
  `docs/plans/creation-flow.md`).

  One module, two live actions: `:new` at `/groups/new` builds a fresh `:draft` group;
  `:edit` at `/groups/:id/edit` edits one already in progress (still a draft, or later —
  the same form works either way). Both share one form: a title and a hard deadline,
  the latter picked from three chips computed by `Consensus.Deadlines` in the visitor's
  own time zone (there is no time zone database — see that module's moduledoc).

  Submitting creates or updates the group and moves on to step 2 (`GroupLive.Options`).
  Publishing — the point a draft's share link starts working — happens later, on step 3
  (see `docs/plans/creation-flow.md`, decision 5).
  """

  use ConsensusWeb, :live_view

  alias Consensus.Activities
  alias Consensus.Activities.Group
  alias Consensus.Deadlines

  @impl true
  def mount(params, _session, socket) do
    tz_offset = read_tz_offset(socket)
    now = DateTime.utc_now()
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:tz_offset, tz_offset)
      |> assign(:now, now)
      |> assign(:scope, scope)
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp read_tz_offset(socket) do
    case get_connect_params(socket) do
      %{"tz_offset" => offset} when is_integer(offset) -> offset
      %{"tz_offset" => offset} when is_float(offset) -> round(offset)
      _ -> 0
    end
  end

  defp apply_action(socket, :new, _params) do
    group = %Group{organizer_id: socket.assigns.scope.user.id}

    socket
    |> assign(:page_title, "New group")
    |> assign(:group, group)
    |> assign(:selected_key, nil)
    |> assign(:chips, Deadlines.options(socket.assigns.now, socket.assigns.tz_offset))
    |> assign_form(Activities.change_group(socket.assigns.scope, group))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case fetch_group(socket.assigns.scope, id) do
      {:ok, group} ->
        chips =
          build_chips(
            Deadlines.options(socket.assigns.now, socket.assigns.tz_offset),
            group.deadline_at,
            socket.assigns.now,
            socket.assigns.tz_offset
          )

        socket
        |> assign(:page_title, "Edit group")
        |> assign(:group, group)
        |> assign(:selected_key, selected_key_for(chips, group.deadline_at))
        |> assign(:chips, chips)
        |> assign_form(Activities.change_group(socket.assigns.scope, group))

      :error ->
        socket
        |> put_flash(:error, "That group could not be found.")
        |> push_navigate(to: ~p"/")
    end
  end

  defp fetch_group(scope, id) do
    {:ok, Activities.get_group!(scope, id)}
  rescue
    Ecto.NoResultsError -> :error
    Ecto.Query.CastError -> :error
  end

  # Appends a fourth, non-canonical chip — labelled from `Deadlines.label_for/3` —
  # when the group's stored deadline no longer matches any of the three live-computed
  # options, so "never make me re-enter anything" holds even after time has moved on.
  defp build_chips(canonical_chips, nil, _now, _tz_offset), do: canonical_chips

  defp build_chips(canonical_chips, stored_deadline, now, tz_offset) do
    if Enum.any?(canonical_chips, &deadline_matches?(&1.at, stored_deadline)) do
      canonical_chips
    else
      canonical_chips ++
        [
          %{
            key: :stored,
            label: Deadlines.label_for(stored_deadline, now, tz_offset),
            at: stored_deadline
          }
        ]
    end
  end

  defp deadline_matches?(at, stored), do: DateTime.compare(at, stored) == :eq

  defp selected_key_for(_chips, nil), do: nil

  defp selected_key_for(chips, stored) do
    case Enum.find(chips, &deadline_matches?(&1.at, stored)) do
      %{key: key} -> key
      nil -> nil
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"group" => group_params}, socket) do
    changeset =
      socket.assigns.scope
      |> Activities.change_group(socket.assigns.group, group_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("select_deadline", %{"key" => key}, socket) do
    case resolve_selection(key, socket) do
      nil -> {:noreply, socket}
      {atom_key, at} -> {:noreply, apply_deadline_selection(socket, atom_key, at)}
    end
  end

  def handle_event("save", %{"group" => group_params}, socket) do
    save_group(socket, socket.assigns.live_action, group_params)
  end

  # Re-resolved fresh at click time (never the value computed at mount) — see
  # `Deadlines.resolve/3`'s moduledoc for why that matters for the canonical chips.
  # `"stored"` is not resolvable that way: it is a literal already-persisted instant,
  # not a computed one, so it is looked up straight from the group in hand.
  defp resolve_selection("this_evening", socket),
    do:
      {:this_evening,
       Deadlines.resolve(:this_evening, DateTime.utc_now(), socket.assigns.tz_offset)}

  defp resolve_selection("tomorrow", socket),
    do: {:tomorrow, Deadlines.resolve(:tomorrow, DateTime.utc_now(), socket.assigns.tz_offset)}

  defp resolve_selection("next_thursday", socket),
    do:
      {:next_thursday,
       Deadlines.resolve(:next_thursday, DateTime.utc_now(), socket.assigns.tz_offset)}

  defp resolve_selection("stored", socket) do
    case socket.assigns.group.deadline_at do
      nil -> nil
      at -> {:stored, at}
    end
  end

  defp resolve_selection(_other, _socket), do: nil

  defp apply_deadline_selection(socket, key, at) do
    params = Map.put(socket.assigns.form.params, "deadline_at", DateTime.to_iso8601(at))

    changeset =
      socket.assigns.scope
      |> Activities.change_group(socket.assigns.group, params)
      |> Map.put(:action, :validate)

    socket
    |> assign(:selected_key, key)
    |> assign_form(changeset)
  end

  defp save_group(socket, action, group_params) do
    if deadline_blank?(group_params) do
      {:noreply, assign_form(socket, missing_deadline_changeset(socket, group_params))}
    else
      case perform_save(action, socket.assigns.scope, socket.assigns.group, group_params) do
        {:ok, group} ->
          {:noreply, push_navigate(socket, to: ~p"/groups/#{group.id}/options")}

        {:error, changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    end
  end

  defp deadline_blank?(group_params), do: group_params["deadline_at"] in [nil, ""]

  defp missing_deadline_changeset(socket, group_params) do
    socket.assigns.scope
    |> Activities.change_group(socket.assigns.group, group_params)
    |> Ecto.Changeset.add_error(:deadline_at, "Pick when voting closes")
    |> Map.put(:action, :insert)
  end

  defp perform_save(:new, scope, _group, params), do: Activities.create_group(scope, params)

  defp perform_save(:edit, scope, group, params),
    do: Activities.update_group(scope, group, params)

  defp deadline_error_message(form) do
    case form[:deadline_at].errors do
      [] -> nil
      [{message, _opts} | _] -> message
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-1 flex-col gap-5 px-5 pb-6 pt-4">
        <.step_progress total={3} current={1} back={~p"/"} />

        <h1 class="text-[31px] font-bold leading-[1.08] tracking-[-0.025em]">
          What's the<br />plan?
        </h1>

        <.form
          for={@form}
          id="group-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-1 flex-col gap-5"
        >
          <div class="flex flex-col gap-2">
            <.eyebrow>Session title</.eyebrow>
            <.input
              field={@form[:title]}
              type="text"
              placeholder="Dinner Friday?"
              phx-mounted={JS.focus()}
            />
          </div>

          <div class="flex flex-col gap-2">
            <.eyebrow>Votes close</.eyebrow>
            <.input type="hidden" field={@form[:deadline_at]} />
            <div class="flex flex-wrap gap-2" role="group" aria-label="When voting closes">
              <.chip
                :for={chip <- @chips}
                phx-click="select_deadline"
                phx-value-key={chip.key}
                selected={@selected_key == chip.key}
              >
                {chip.label}
              </.chip>
              <.chip disabled title="Coming soon">Custom…</.chip>
            </div>
            <p :if={deadline_error_message(@form)} class="text-sm font-semibold text-tangerine">
              {deadline_error_message(@form)}
            </p>
            <p class="text-[11.5px] leading-[1.4] text-muted">
              Hard deadline. Voting locks itself and picks the winner.
            </p>
          </div>

          <div class="flex flex-col gap-2">
            <.eyebrow>Group</.eyebrow>
            <div class="flex items-center gap-2">
              <Layouts.avatar user={@current_scope.user} size={30} />
              <span class="text-xs text-muted">Just you so far · invite by link</span>
            </div>
          </div>

          <div class="mt-auto flex flex-col gap-2.5 pt-2">
            <.button type="submit" variant="primary" phx-disable-with="Saving…">
              Add the options →
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
