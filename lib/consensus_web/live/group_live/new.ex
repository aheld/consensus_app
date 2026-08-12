defmodule ConsensusWeb.GroupLive.New do
  @moduledoc """
  `01 setup` — step 1 of 3 in the creation wizard (see `docs/design/DESIGN-SPEC.md` and
  `docs/plans/creation-flow.md`).

  One module, two live actions: `:new` at `/groups/new` builds a fresh `:draft` group;
  `:edit` at `/groups/:id/edit` edits one already in progress (still a draft, or later —
  the same form works either way). Both share one form: a title and a hard deadline,
  the latter either picked from three chips computed by `Consensus.Deadlines` in the
  visitor's own time zone, or typed into the custom picker (D-055).

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
    clock = Deadlines.clock_from_params(get_connect_params(socket))
    now = DateTime.utc_now()
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:clock, clock)
      |> assign(:now, now)
      |> assign(:scope, scope)
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    group = %Group{organizer_id: socket.assigns.scope.user.id}

    socket
    |> assign(:page_title, "New session")
    |> assign(:group, group)
    |> assign(:selected_key, nil)
    |> assign(:selected_at, nil)
    |> assign(:chips, Deadlines.options(socket.assigns.now, socket.assigns.clock))
    |> assign_custom(nil)
    |> assign_form(Activities.change_group(socket.assigns.scope, group))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case fetch_group(socket.assigns.scope, id) do
      {:ok, group} ->
        chips =
          build_chips(
            Deadlines.options(socket.assigns.now, socket.assigns.clock),
            group.deadline_at,
            socket.assigns.now,
            socket.assigns.clock
          )

        socket
        |> assign(:page_title, "Edit session")
        |> assign(:group, group)
        |> assign(:selected_key, selected_key_for(chips, group.deadline_at))
        |> assign(:selected_at, group.deadline_at)
        |> assign(:chips, chips)
        |> assign_custom(group.deadline_at)
        |> assign_form(Activities.change_group(socket.assigns.scope, group))

      :error ->
        socket
        |> put_flash(:error, "That session could not be found.")
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
  defp build_chips(canonical_chips, nil, _now, _clock), do: canonical_chips

  defp build_chips(canonical_chips, stored_deadline, now, clock) do
    if Enum.any?(canonical_chips, &deadline_matches?(&1.at, stored_deadline)) do
      canonical_chips
    else
      canonical_chips ++
        [
          %{
            key: :stored,
            label: Deadlines.label_for(stored_deadline, now, clock),
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

  # The picker starts closed on both actions — the chips are the fast path and the design
  # gives them the row. On `:edit` the field is nevertheless pre-filled from the stored
  # deadline, so opening it shows what is already set instead of an empty box the
  # organizer has to re-derive. `apply_custom_deadline/3`'s closed-picker clause is what
  # makes carrying that value while the field is unrendered safe.
  defp assign_custom(socket, stored_deadline) do
    clock = socket.assigns.clock

    socket
    |> assign(:custom_open?, false)
    |> assign(:custom_value, stored_deadline && datetime_local_value(stored_deadline, clock))
    |> assign(:custom_min, datetime_local_value(socket.assigns.now, clock))
  end

  # `datetime-local` wants exactly `YYYY-MM-DDTHH:MM` — it ignores a seconds component on
  # some browsers and rejects the value outright on others.
  defp datetime_local_value(at, clock) do
    at
    |> Deadlines.wall_clock(clock)
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  @impl true
  def handle_event("validate", %{"group" => group_params} = params, socket) do
    {socket, group_params} = apply_custom_deadline(socket, params, group_params)

    changeset =
      socket.assigns.scope
      |> Activities.change_group(
        socket.assigns.group,
        keep_selected_deadline(group_params, socket)
      )
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("select_deadline", %{"key" => key}, socket) do
    case resolve_selection(key, socket) do
      nil ->
        {:noreply, socket}

      {atom_key, at} ->
        # Picking a chip abandons whatever is in the custom picker. Clearing
        # `@custom_value` re-renders the input empty, which is what stops the next
        # `validate` — a keystroke in the title, say — from reading a stale wall-clock
        # string and overwriting the chip the organizer just pressed.
        {:noreply,
         socket
         |> assign(:custom_value, nil)
         |> apply_deadline_selection(atom_key, at)}
    end
  end

  def handle_event("toggle_custom", _params, socket) do
    {:noreply, assign(socket, :custom_open?, !socket.assigns.custom_open?)}
  end

  def handle_event("save", %{"group" => group_params} = params, socket) do
    {socket, group_params} = apply_custom_deadline(socket, params, group_params)

    save_group(socket, socket.assigns.live_action, keep_selected_deadline(group_params, socket))
  end

  # -- the custom picker ---------------------------------------------------------------

  # Turns whatever is in the `datetime-local` field into `deadline_at`, and is a no-op
  # unless it *changed*. The unchanged case is the common one: this runs on every
  # `phx-change` the form fires, which includes every keystroke in the title.
  #
  # `nil` (the field is not rendered — the picker is closed) and `""` are deliberately
  # the same "empty" for the comparison. Without that, pressing a chip — which sets
  # `@custom_value` to `nil` and re-renders the input empty — would arrive here as a
  # change from `nil` to `""` and clear the chip the organizer had just chosen.
  # With the picker closed the field is not rendered and therefore has no opinion. Saying
  # so explicitly is what makes it safe to pre-fill `@custom_value` on `:edit`: without
  # this clause, a closed picker holding a pre-filled value would read the absent param as
  # a change from that value to `""` and clear the organizer's saved deadline on the first
  # keystroke in the title.
  defp apply_custom_deadline(%{assigns: %{custom_open?: false}} = socket, _params, group_params),
    do: {socket, group_params}

  defp apply_custom_deadline(socket, params, group_params) do
    raw = params["custom_deadline"]

    if blank(raw) == blank(socket.assigns.custom_value) do
      {socket, group_params}
    else
      set_custom_deadline(socket, raw, group_params)
    end
  end

  defp set_custom_deadline(socket, raw, group_params) do
    case parse_wall_clock(raw, socket.assigns.clock) do
      {:ok, at} ->
        {socket
         |> assign(:custom_value, raw)
         |> assign(:selected_key, :custom)
         |> assign(:selected_at, at),
         Map.put(group_params, "deadline_at", DateTime.to_iso8601(at))}

      :cleared ->
        # The organizer emptied the field. **This is the case that killed the old
        # `keep_selected_deadline/2` premise** — see its comment. A blank can now mean
        # "cleared", so the selection is dropped rather than restored, and the submit
        # error the empty form produces is the correct outcome rather than a lost patch.
        {socket
         |> assign(:custom_value, nil)
         |> assign(:selected_key, nil)
         |> assign(:selected_at, nil), Map.put(group_params, "deadline_at", "")}

      :error ->
        # An unparseable value — a browser with no native picker and a hand-typed
        # string, or a forged param. Keep it on screen so the organizer can see and fix
        # what they typed, and leave the stored deadline alone; `deadline_at` stays
        # whatever it was, and the form's own required-deadline error covers the rest.
        {assign(socket, :custom_value, raw), group_params}
    end
  end

  # `datetime-local` posts `"2026-11-08T19:00"` (or `":00"` seconds on some browsers).
  # The wall clock is the organizer's; `Consensus.Deadlines` supplies the zone (D-055).
  defp parse_wall_clock(raw, clock) do
    trimmed = raw |> to_string() |> String.trim()

    if trimmed == "" do
      :cleared
    else
      with {:ok, naive} <- parse_naive(trimmed),
           {:ok, at} <- Deadlines.from_wall_clock(naive, clock) do
        {:ok, DateTime.truncate(at, :second)}
      else
        _ -> :error
      end
    end
  end

  # `NaiveDateTime.from_iso8601/1` requires seconds; the field usually omits them.
  defp parse_naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, naive}
      {:error, _} -> NaiveDateTime.from_iso8601(value <> ":00")
    end
  end

  defp blank(nil), do: ""
  defp blank(value), do: value |> to_string() |> String.trim()

  # The chips write `deadline_at` into a hidden input by patching the DOM from the server.
  # A `phx-change="validate"` fired *before* that patch lands — pick a chip, then type in the
  # title within the same tick, which is one gesture on a phone — serialises the still-empty
  # hidden field, and the server took the browser's blank over the selection it had just
  # made. Reproduced: chip click and title `input` in the same tick left `deadline_at`
  # empty and all three chips at `aria-pressed="false"`, and the subsequent submit failed
  # with "Pick when voting closes"; with 2.5s between them both survived. Self-correcting
  # (the chip visibly deselects) but the reaction is "I did pick one", and the window widens
  # on a slow connection.
  #
  # **This used to rest on a premise D-055 deleted.** It read: "a blank `deadline_at` can
  # never mean 'the organizer cleared it': the only controls that write it are the three
  # chips, and `Custom…` is disabled. So a blank always means the form went out before the
  # patch came back." The custom picker is a fourth writer, and it is one the organizer can
  # genuinely empty — so a blank now has two possible meanings and this function can no
  # longer tell them apart on its own.
  #
  # The resolution is that it no longer has to. `apply_custom_deadline/3` runs **first**,
  # on the same params, and a genuine clear is the one case that writes `""` into
  # `group_params` *and* drops `@selected_at` to `nil` in the same breath. So by the time
  # this sees a blank, either the organizer cleared it (and there is no `selected_at` left
  # to restore — the clause below falls through) or the patch was lost (and `selected_at`
  # still holds the server's own selection, which wins, exactly as before).
  #
  # The race itself is unchanged and still real: pick a chip, then type in the title within
  # the same tick — one gesture on a phone — and the still-empty hidden field serialises
  # first. Reproduced before the guard: chip click and title `input` in the same tick left
  # `deadline_at` empty and all three chips at `aria-pressed="false"`, and the subsequent
  # submit failed with "Pick when voting closes"; with 2.5s between them both survived.
  # Self-correcting, but the reaction is "I did pick one", and the window widens on a slow
  # connection.
  defp keep_selected_deadline(group_params, socket) do
    case {deadline_blank?(group_params), socket.assigns.selected_at} do
      {true, %DateTime{} = at} -> Map.put(group_params, "deadline_at", DateTime.to_iso8601(at))
      _ -> group_params
    end
  end

  # Re-resolved fresh at click time (never the value computed at mount) — see
  # `Deadlines.resolve/3`'s moduledoc for why that matters for the canonical chips.
  # `"stored"` is not resolvable that way: it is a literal already-persisted instant,
  # not a computed one, so it is looked up straight from the group in hand.
  defp resolve_selection("this_evening", socket),
    do:
      {:this_evening, Deadlines.resolve(:this_evening, DateTime.utc_now(), socket.assigns.clock)}

  defp resolve_selection("tomorrow", socket),
    do: {:tomorrow, Deadlines.resolve(:tomorrow, DateTime.utc_now(), socket.assigns.clock)}

  defp resolve_selection("next_thursday", socket),
    do:
      {:next_thursday,
       Deadlines.resolve(:next_thursday, DateTime.utc_now(), socket.assigns.clock)}

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
    |> assign(:selected_at, at)
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

  # -- the unsaved-draft guard (D-045) -------------------------------------------------

  # Nothing on this step is written until "Add the options →". The global footer and the
  # header `‹` are both `navigate`s, so a tap on either remounts this LiveView and the
  # title is gone with no confirm and no undo. Measured: typing a title, tapping the
  # footer's About us and pressing back returned an empty field.
  #
  # `:new` and `:edit` are both covered by comparing against what is *stored* rather than
  # by testing for emptiness — on `:edit` the form arrives pre-filled, so "non-empty"
  # would arm the prompt on a form nobody has touched.
  defp draft?(assigns) do
    typed_title(assigns.form) != stored_title(assigns.group) or
      deadline_moved?(assigns.selected_at, assigns.group.deadline_at)
  end

  defp typed_title(form), do: form[:title].value |> to_string() |> String.trim()
  defp stored_title(group), do: group.title |> to_string() |> String.trim()

  defp deadline_moved?(nil, nil), do: false
  defp deadline_moved?(nil, _stored), do: false
  defp deadline_moved?(_selected, nil), do: true
  defp deadline_moved?(selected, stored), do: DateTime.compare(selected, stored) != :eq

  defp discard_prompt,
    do: "Leave without saving this session? The title and deadline aren't stored yet."

  defp deadline_error_message(form) do
    case form[:deadline_at].errors do
      [] -> nil
      [{message, _opts} | _] -> message
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The route this step's `‹` used to carry moved into the global header (plan
          ruling 1); `step_progress/1` keeps only the bar and the counter. --%>
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      back={~p"/"}
      back_confirm={draft?(assigns) && discard_prompt()}
      footer_confirm={draft?(assigns) && discard_prompt()}
      context="STEP 1 OF 3"
    >
      <div class="flex flex-1 flex-col gap-5 px-5 pb-6 pt-4">
        <.step_progress total={3} current={1} />

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
            <%!-- The chips alone read as optional filters, not a required field — usability
                  feedback: organizers reached "Add the options →" without realising a
                  deadline had to be picked, and met the requirement only as a submit error.
                  This line states it up front; the muted caption below stays the mechanics
                  footnote. Not in design frame 01 — recorded in DESIGN-SPEC.md. --%>
            <p class="flex items-start gap-2 text-[13px] font-medium leading-[1.4] text-tangerine">
              <%!-- Decorative: the sentence beside it carries the whole meaning, so the badge
                    is hidden from assistive tech rather than read out as a bare "!". --%>
              <span
                aria-hidden="true"
                class="mt-px grid size-5 shrink-0 place-items-center rounded-full border-2 border-ink bg-tangerine text-[12px] font-bold leading-none text-white"
              >
                !
              </span>
              Pick when votes close — the session can't run without an end time.
            </p>
            <div class="flex flex-wrap gap-2" role="group" aria-label="When voting closes">
              <.chip
                :for={chip <- @chips}
                phx-click="select_deadline"
                phx-value-key={chip.key}
                selected={@selected_key == chip.key}
              >
                {chip.label}
              </.chip>
              <%!-- Live since D-055. It was dashed and `disabled` with a `title="Coming
                    soon"` that cannot fire on touch, so on the device this app is built for
                    it read as a button that simply does nothing when tapped, and the row's
                    caption explained the deadline rather than the dead control. Both the
                    inert treatment and that caption are gone with it. --%>
              <.chip
                phx-click="toggle_custom"
                selected={@selected_key == :custom}
                aria-expanded={to_string(@custom_open?)}
                aria-controls="custom-deadline"
              >
                Custom…
              </.chip>
            </div>

            <%!-- **A native `datetime-local`, not a bespoke day/time grid.** It brings the
                  platform's own picker on iOS and Android — the two browsers this product
                  is actually used in — for no JavaScript and no date library.

                  `text-base` is not a style choice: invariant 18 puts a 16px floor under
                  every field in this app, because iOS Safari zooms the page when a focused
                  input computes below it and never zooms back out. A date field is exactly
                  where that hurts most, since the picker opens over a page that has just
                  jumped.

                  `min` is a courtesy that stops the obvious mistake at the widget; the real
                  refusal is `Group.changeset/2`'s (D-055), because a `min` attribute is a
                  client-side hint and the value can be posted anyway. Same split as the
                  `maxlength` rule in invariant 11. It carries no `max`: a year out is a
                  guard against a mistyped year, not a date range worth drawing. --%>
            <div :if={@custom_open?} id="custom-deadline" class="flex flex-col gap-1.5">
              <label for="custom-deadline-input" class="eyebrow">Pick a date and time</label>
              <input
                type="datetime-local"
                id="custom-deadline-input"
                name="custom_deadline"
                value={@custom_value}
                min={@custom_min}
                class="w-full rounded-2xl border-2 border-ink bg-white px-3.5 py-3 text-base font-semibold text-ink shadow-sticker-2 focus:outline-none focus:shadow-mint-focus"
              />
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
