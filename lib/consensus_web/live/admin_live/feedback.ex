defmodule ConsensusWeb.AdminLive.Feedback do
  @moduledoc """
  Admin → Feedback. The triage queue for what the footer's two faces collect (D-043).

  Authorization is the router's, twice over: the `:require_admin_user` plug rejects the
  HTTP request and the `:require_admin` on_mount hook rejects the LiveView socket mount,
  because a plug pipeline does not run for the websocket connection (CLAUDE.md invariant
  1). This module assumes an admin scope, exactly as `ConsensusWeb.AdminLive.Users` does,
  and the two writes it makes are additionally guarded by the function heads of
  `Consensus.Feedback.set_read/3` and `annotate/3`.

  ## Two deliberate omissions

  **No sudo-mode gate.** Sudo protects `Accounts.set_admin/3` and `delete_user/2`, which
  change privileges and destroy accounts irreversibly. Marking a message read and typing
  a note beside it are undone in one click and touch nothing outside their own row.
  Asking for a password to triage a bug report is how a real sudo prompt stops being
  read. Recorded in D-043 so this reads as a decision rather than an oversight.

  **Nothing here notifies anybody.** No mail, no webhook, no state change beyond the row
  — and the screen says so, in the note field's own helper line rather than only in a
  comment, because an administrator typing "replied to them" needs to know the app did
  not.

  ## Mark-as-read is reversible, and that is the point

  A one-way toggle on a list you are triaging is a trap: one mis-tap and the row you had
  not read yet is indistinguishable from the forty you had. `read_at` is a nullable
  timestamp, so unmarking is a write of `NULL`, and both directions are one button in the
  same place.

  ## An unsaved note is never thrown away

  Every row carries its own note form in `:note_forms`. `load_entries/2` takes the list
  of ids it is allowed to reseed from the database, and every other row's draft is
  carried forward untouched — because the natural triage order is "read it, write down
  what I did, mark it read", so an implementation that rebuilt all the forms on every
  event would destroy the note on the *normal* path, silently and with no undo. The
  over-long-note branch of `save_note` reloads nothing at all for the same reason: the
  text the flash is asking the admin to trim is still in the textarea.

  The same concern is why the "was on" link opens in a new tab. It used to be a same-tab
  `href` with no way back to the queue, so following it both stranded the administrator on
  a page whose `‹` goes to `/` and discarded every note being typed on this one.

  ## The note editor is collapsed, and `open` is server state

  Rendering every row's editor expanded cost 460px a row — 11 viewport heights for 15
  messages at 360×640, 44% of it empty textarea — on the one screen whose entire job is
  scanning. Closed, a row is mood, sender, message, metadata and two buttons.

  It is **not** a `<details>` element, although that is the no-JS idiom the `⋯` menu uses.
  `open` on a `<details>` is a DOM attribute the server also renders, and every row here
  lives inside a `:for` comprehension that re-renders whenever `:note_forms` changes —
  which is on every keystroke, because the grapheme counter is server-rendered. The patch
  would reset the attribute and collapse the editor under the admin's hands as they typed.
  So `:open_notes` is a `MapSet` of ids in assigns, toggled by an event, seeded once at
  mount from the rows that already carry a note; after that the administrator's own
  toggles are respected rather than re-derived.

  ## Reaching it

  `/admin/users` carries a cross-link here and this screen carries one back. **The
  header's `⋯` menu does not offer it** — that menu lives in `ConsensusWeb.Chrome`, which
  this piece does not own; the entry still needs adding beside "Admin" there.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Feedback
  alias Consensus.Feedback.Entry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Feedback")
     |> load_entries([])}
  end

  @impl true
  def handle_event("set_read", %{"id" => id, "read" => read}, socket)
      when is_binary(id) and is_binary(read) do
    # Everything here arrives from the client, so it is parsed rather than trusted: a
    # non-numeric id would otherwise raise inside Ecto and take the LiveView down.
    with {entry_id, ""} <- Integer.parse(id),
         %Entry{} = entry <- Feedback.get_entry(entry_id),
         {:ok, _updated} <- Feedback.set_read(socket.assigns.current_scope, entry, read == "true") do
      # Reseed nothing: marking a row read must not throw away a note somebody is
      # halfway through typing on this row or any other. See `load_entries/2`.
      {:noreply, load_entries(socket, [])}
    else
      # SQLite raises rather than returning a tuple when a write cannot take the lock, so
      # `Consensus.Feedback` rescues it into this tuple. Reloading nothing is the point:
      # the admin can press the button again, and every unsaved note on the page is still
      # where they left it.
      {:error, {:database_busy, _message}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't write that just now — press it again. Nothing else on this page changed."
         )}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update that message. Reload the page and try again.")
         |> load_entries([])}
    end
  end

  def handle_event("toggle_note", %{"id" => id}, socket) when is_binary(id) do
    case Integer.parse(id) do
      {entry_id, ""} ->
        {:noreply,
         update(socket, :open_notes, fn open ->
           if MapSet.member?(open, entry_id),
             do: MapSet.delete(open, entry_id),
             else: MapSet.put(open, entry_id)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_note", %{"entry_id" => id, "note" => %{"body" => body}}, socket) do
    {:noreply, put_draft(socket, id, body)}
  end

  def handle_event("save_note", %{"entry_id" => id, "note" => %{"body" => body}}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         %Entry{} = entry <- Feedback.get_entry(entry_id),
         {:ok, _updated} <- Feedback.annotate(socket.assigns.current_scope, entry, body) do
      # Only the row that was just written reseeds from the database — that is what makes
      # "clear the note" and the blank-to-nil trim visibly land. Every other row keeps
      # whatever its admin was typing.
      {:noreply,
       socket
       |> put_flash(:info, note_saved_flash(body))
       |> load_entries([entry_id])}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        # The only thing `admin_changeset/2` can refuse is an over-long note, and the
        # text is still in the textarea in front of the admin. Reloading the list here
        # would delete the very thing the flash is asking them to trim, and the generic
        # "reload the page" copy below would be advice to destroy it — so this branch
        # neither reloads nor advises it.
        {:noreply, put_flash(socket, :error, note_refused_flash(changeset, body))}

      # Same reasoning as `set_read` above, and more acute: the note this branch failed to
      # write is still in the textarea and reloading would delete it.
      {:error, {:database_busy, _message}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't save that just now — press Save note again. What you typed is still here."
         )}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not save that note. Reload the page and try again.")
         |> load_entries([])}
    end
  end

  defp note_saved_flash(body) do
    if String.trim(to_string(body)) == "" do
      "Note cleared. Nobody was emailed."
    else
      "Note saved. Nobody was emailed."
    end
  end

  defp note_refused_flash(changeset, body) do
    typed = body |> to_string() |> String.length()
    max = Entry.max_admin_note_length()

    if typed > max do
      "That note is #{typed} characters and the limit is #{max}. Trim it and press " <>
        "Save note again — what you typed is still here."
    else
      reason =
        changeset
        |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
        |> Map.values()
        |> List.flatten()
        |> Enum.join(", ")

      "That note was refused (#{reason}). What you typed is still here."
    end
  end

  # One form per row, held in assigns rather than rebuilt in the template, so the
  # grapheme counter beside each note updates as the admin types (CLAUDE.md invariant 11
  # — the textarea carries no `maxlength`, so the counter is the whole warning).
  #
  # `reseed_ids` is the whole reason this takes an argument. Rebuilding every form from
  # the database on every event is the obvious implementation and it silently destroys
  # unsaved notes: the natural triage order is "read it, write down what I did, mark it
  # read", so the *normal* path would wipe the note. A row is reseeded only when this
  # event actually wrote it; everything else carries its draft forward untouched. A row
  # that appears for the first time (someone sent feedback while this page was open)
  # has no draft to keep, so it seeds from what is stored.
  defp load_entries(socket, reseed_ids) do
    entries = Feedback.list_entries()
    drafts = socket.assigns[:note_forms] || %{}

    note_forms =
      Map.new(entries, fn entry ->
        stored = note_form(entry.admin_note)

        if entry.id in reseed_ids do
          {entry.id, stored}
        else
          {entry.id, Map.get(drafts, entry.id, stored)}
        end
      end)

    socket
    |> assign(:entries, entries)
    |> assign(:unread_count, Feedback.count_unread())
    |> assign(:note_forms, note_forms)
    |> assign(:open_notes, open_notes(socket, entries))
  end

  # Seeded once — a row that already carries a note opens with it visible, because that
  # note is the record of what was done and hiding it behind a click on first load would
  # be the "invisible state" confusion. After that the administrator's own toggles win:
  # re-deriving this on every event would spring a row they deliberately collapsed back
  # open on the next keystroke anywhere on the page.
  defp open_notes(socket, entries) do
    case socket.assigns[:open_notes] do
      nil -> entries |> Enum.filter(& &1.admin_note) |> MapSet.new(& &1.id)
      existing -> existing
    end
  end

  defp note_open?(open_notes, entry), do: MapSet.member?(open_notes, entry.id)

  # The label has to answer "is there a note here?" without the editor being open, or
  # collapsing it would hide the one thing this screen records.
  defp note_toggle_label(open_notes, entry, form) do
    cond do
      note_open?(open_notes, entry) -> "Hide note"
      draft_length(form) > 0 -> "Note · #{draft_length(form)} characters"
      true -> "Add a note"
    end
  end

  defp note_form(body), do: to_form(%{"body" => body || ""}, as: :note)

  defp put_draft(socket, id, body) do
    case Integer.parse(to_string(id)) do
      {entry_id, ""} -> update(socket, :note_forms, &Map.put(&1, entry_id, note_form(body)))
      _ -> socket
    end
  end

  defp draft_length(form), do: form.params["body"] |> to_string() |> String.length()

  ## The unsaved-note guard (D-045)
  #
  # D-041 already states as a rule that "an unsaved admin note is never thrown away", and
  # `load_entries/2`'s `reseed_ids` is what keeps that true across *this screen's own*
  # events. It was still false across a **navigation**: every control in the global footer
  # and the header `‹` is a `navigate`, which remounts this LiveView and rebuilds every
  # note form from `entry.admin_note`. Measured: a note typed into `#note-body-22`, a tap
  # on the footer's About us, `‹` back — and the field held the previously *saved* value.
  #
  # The comparison the brief offers as a fallback ("prompt whenever `@open_notes` is
  # non-empty") is deliberately not used: `open_notes/2` seeds itself open for every row
  # that already carries a note, so on a triaged inbox it would prompt on every navigation
  # with nothing at stake — a warning that is usually wrong is one people learn to dismiss,
  # which is the confusion this guard exists to prevent. The real comparison is cheap:
  # a row is dirty when its draft differs from what is stored, whether that means text
  # added, edited, or cleared.
  defp unsaved_notes?(%{entries: entries, note_forms: note_forms}) do
    Enum.any?(entries, fn entry ->
      case Map.fetch(note_forms, entry.id) do
        {:ok, form} -> stored_body(form) != stored_body(entry.admin_note)
        :error -> false
      end
    end)
  end

  defp stored_body(%Phoenix.HTML.Form{} = form), do: stored_body(form.params["body"])
  defp stored_body(value), do: value |> to_string() |> String.trim()

  defp discard_prompt,
    do: "Leave without saving? A note you typed here isn't stored yet."

  # The mood is shown as the *same face* the sender tapped in the footer, at the footer's
  # own 26px resting treatment — mint smile, peach frown — rather than as a coloured pill.
  # Two reasons. A pill would have to be tangerine to read as "not good" against the
  # yellow unread card, and tangerine is the one forward action on a screen (this one has
  # none, but three tangerine badges still read as three alarms). And the smile/frown is a
  # *shape*, so the state survives being read in greyscale, where two pastel pills would
  # not — "colour is never the only signal".
  #
  # The paths are copied from `ConsensusWeb.Chrome.footer/1` rather than shared: `face/1`
  # there is private, and the alternative is a public component in `Sticker` that this
  # piece does not own.
  @happy_mouth "M8 14.6c1 1.2 2.4 1.8 4 1.8s3-.6 4-1.8"
  @sad_mouth "M8 16.4c1-1.2 2.4-1.8 4-1.8s3 .6 4 1.8"

  defp mood_fill(:happy), do: "bg-mint"
  defp mood_fill(:sad), do: "bg-peach"
  defp mood_mouth(:happy), do: @happy_mouth
  defp mood_mouth(:sad), do: @sad_mouth
  defp mood_label(:happy), do: "Said it is going well"
  defp mood_label(:sad), do: "Said something is wrong"

  defp sent_at(entry), do: Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M UTC")

  defp summary(0, 0), do: "Nothing yet."

  defp summary(0, total),
    do: "#{total} #{ngettext("message", "messages", total)}, all read."

  defp summary(unread, total),
    do: "#{total} #{ngettext("message", "messages", total)}, #{unread} unread."

  # `min-h-[44px]` and not just vertical padding: 12.5px of line-height plus `py-3` plus
  # two 2px borders measures 40.5px, which is under the phone tap minimum every other
  # control in this piece was held to.
  defp action_button_class,
    do:
      "press-2 inline-flex min-h-[44px] items-center rounded-full border-2 border-ink bg-white px-3.5 py-3 text-[12.5px] font-semibold leading-none shadow-sticker-2 hover:bg-yellow"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      background="bg-canvas"
      back={~p"/"}
      back_confirm={unsaved_notes?(assigns) && discard_prompt()}
      footer_confirm={unsaved_notes?(assigns) && discard_prompt()}
      context="ADMIN"
    >
      <%!-- `px-6`, matching `AdminLive.Users`. The two screens carry a cross-link to each
            other in both directions, and at `px-5` the title and every card edge jumped
            4px sideways on every navigation between them. --%>
      <div class="mx-auto flex w-full flex-1 flex-col gap-6 px-6 pb-10 pt-6">
        <%!-- No `<.eyebrow>Admin</.eyebrow>`: the header's context slot already says
              ADMIN in the same uppercase DM Mono ~110px above (plan ruling 9). The h1
              says which admin screen this is, which the header does not carry. --%>
        <div class="flex flex-col gap-2">
          <h1 class="text-[27px] font-bold leading-[1.15] tracking-[-0.025em]">Feedback</h1>
          <p class="text-[13.5px] leading-[1.5] text-ink-soft">
            {summary(@unread_count, length(@entries))} Everything the two faces in the footer
            collect lands here. The voting screens deliberately have no footer pair, so
            nothing from a guest mid-ballot ever arrives — silence from voters is not
            evidence that nothing is wrong. Marking one read, or writing a note on it,
            changes nothing outside this page — nobody is emailed either way.
          </p>
          <%!-- The same prompt the header `‹` and all six footer controls carry. It is a
                `navigate`, so it remounts this LiveView and takes **every** open note draft
                on the page with it — the exact hazard `target="_blank"` closes on the
                "was on" link below, and the one the confirm sweep put on every other
                control here and then missed on the single in-page one. An unqualified
                sweep is what missed it, so `admin_live/feedback_test.exs` now enumerates
                every `<a>` on the page rather than naming this link. --%>
          <.link
            navigate={~p"/admin/users"}
            id="admin-users-link"
            data-confirm={unsaved_notes?(assigns) && discard_prompt()}
            class="-my-3 inline-flex min-h-[44px] w-fit items-center text-[12.5px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
          >
            Go to Admin → Users
          </.link>
        </div>

        <p
          :if={@entries == []}
          id="feedback-empty"
          class="rounded-2xl border-2 border-dashed border-ink px-4 py-5 text-center text-[13px] leading-[1.45] text-muted"
        >
          Nobody has sent anything yet. When they do it shows up here, newest first,
          with the unread ones tinted violet.
        </p>

        <ul id="feedback-entries" class="flex flex-col gap-2.5">
          <li :for={entry <- @entries} id={"feedback-#{entry.id}"}>
            <%!-- Unread rows are violet-tinted, read rows white: the state has to be
                  legible without reading a pill, because the whole job of this screen is
                  scanning. The pill is there too — colour is never the only signal, and
                  it is the same violet, so fill and pill say one thing rather than two.

                  Not `:yellow`, which is what shipped. A full `--yellow` card fill already
                  means "warning" one click away, on `/admin/users`, where the only
                  yellow-filled card is the default-password banner — and ten of fifteen
                  rows unread here made the screen read as ten alarms. --%>
            <.sticker_card
              depth={2}
              tone={if Entry.read?(entry), do: :white, else: :violet_tint}
              class="flex flex-col gap-2.5 p-3.5"
            >
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span
                  class={[
                    "grid size-[26px] shrink-0 place-items-center rounded-full border-2 border-ink text-ink shadow-sticker-2",
                    mood_fill(entry.mood)
                  ]}
                  title={mood_label(entry.mood)}
                >
                  <span class="sr-only">{mood_label(entry.mood)}</span>
                  <svg
                    width="15"
                    height="15"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.2"
                    stroke-linecap="round"
                    aria-hidden="true"
                    focusable="false"
                  >
                    <circle cx="9" cy="10" r="1.2" fill="currentColor" stroke="none" />
                    <circle cx="15" cy="10" r="1.2" fill="currentColor" stroke="none" />
                    <path d={mood_mouth(entry.mood)} />
                  </svg>
                </span>
                <.pill :if={not Entry.read?(entry)} tone={:violet}>unread</.pill>
                <span class="min-w-0 break-words font-bold text-ink">
                  {Entry.sender_label(entry)}
                </span>
              </div>

              <%!-- `break-words`, not the browser default `overflow-wrap: normal`: a
                    pasted share link is the single most likely thing to appear in a bug
                    report, and one unbroken 90-character token painted straight through
                    the card's right border and made the whole document scroll sideways
                    (measured: `documentElement.scrollWidth` 515 against a 360 client
                    width). The email line below already carried `break-all`; this one
                    was the omission. --%>
              <p class="min-w-0 whitespace-pre-line break-words text-[13.5px] leading-[1.45] text-ink">
                {entry.message}
              </p>

              <p :if={entry.email} class="break-all text-[12px] leading-snug text-ink-soft">
                Reply by hand to {entry.email}
              </p>

              <%!-- "no account linked" rather than "signed out" on the nil branch, which
                    is a change from what shipped. `feedback.user_id` is
                    `on_delete: :nilify_all` — deliberately, so deleting an account does
                    not destroy the bug report it filed (D-042) — so a row written by a
                    signed-in sender whose account was later deleted silently relabelled
                    itself "signed out", asserting something false about how it arrived on
                    a screen whose whole posture is that it prints only what is true.
                    Distinguishing the two would need a column written at submit time;
                    this phrasing is exactly true in all three cases without one. --%>
              <p class="font-mono text-[10.5px] uppercase tracking-[0.06em] text-muted">
                {sent_at(entry)} · {if entry.user_id, do: "signed in", else: "no account linked"}
              </p>

              <%!-- A plain `href`, not `navigate`: the stored path may or may not be a
                    LiveView route. `Entry.safe_page_path/1` again at render time even
                    though the same guard ran before the value was written — this is the
                    `href` a hostile stored path would become, so it does not depend on
                    the write path having been correct on the day the row landed.

                    `target="_blank"`, and that is not a preference. Followed in this tab
                    it stranded the administrator — the destination's `‹` goes to `/`,
                    not back to the queue — and unloading this page throws away every
                    unsaved note on it. Measured: 56 characters typed into one row's
                    textarea were gone on return. A `data-confirm` would not help; the
                    note is lost either way if they proceed.

                    The whole row is the link, not just the path inside it: the most
                    common captured path is `/` (the footer's faces sit on the home page
                    more than anywhere else), and `/` set in 10.5px mono is a 6px-wide
                    tap target. --%>
              <.link
                :if={Entry.safe_page_path(entry.page_path)}
                href={Entry.safe_page_path(entry.page_path)}
                target="_blank"
                rel="noopener"
                class="-my-2 inline-flex min-h-[44px] w-full items-center font-mono text-[10.5px] leading-snug text-muted hover:text-tangerine"
              >
                <span class="min-w-0">
                  was on
                  <span class="break-all text-violet underline decoration-2 underline-offset-2">
                    {entry.page_path}
                  </span>
                  <span class="whitespace-nowrap">(opens a new tab)</span>
                </span>
              </.link>

              <div class="flex flex-wrap items-center gap-2">
                <button
                  type="button"
                  phx-click="set_read"
                  phx-value-id={entry.id}
                  phx-value-read={to_string(not Entry.read?(entry))}
                  class={action_button_class()}
                >
                  {if Entry.read?(entry), do: "Mark unread", else: "Mark read"}
                </button>
                <%!-- The editor is collapsed by default; see the moduledoc for why this
                      is a server-state toggle and not a `<details>`. The label carries
                      the note's length when there is one, so a closed row still says
                      whether anything was written here. --%>
                <button
                  type="button"
                  id={"note-toggle-#{entry.id}"}
                  phx-click="toggle_note"
                  phx-value-id={entry.id}
                  aria-expanded={to_string(note_open?(@open_notes, entry))}
                  aria-controls={"note-form-#{entry.id}"}
                  class={action_button_class()}
                >
                  {note_toggle_label(@open_notes, entry, @note_forms[entry.id])}
                </button>
              </div>

              <%!-- No `maxlength` on the textarea (CLAUDE.md invariant 11 / D-026): the
                    cap is `Entry.max_admin_note_length/0` in `admin_changeset/2` and the
                    counter beside the label reads the same function, counting graphemes
                    the way `validate_length/3` does. --%>
              <.form
                :if={note_open?(@open_notes, entry)}
                for={@note_forms[entry.id]}
                id={"note-form-#{entry.id}"}
                phx-change="validate_note"
                phx-submit="save_note"
                class="flex flex-col gap-1.5 border-t-2 border-ink-12 pt-2.5"
              >
                <input type="hidden" name="entry_id" value={entry.id} />
                <div class="flex items-baseline justify-between gap-3">
                  <.eyebrow>Admin note</.eyebrow>
                  <span
                    id={"note-counter-#{entry.id}"}
                    aria-live="polite"
                    class={[
                      "font-mono text-[10px]",
                      if(draft_length(@note_forms[entry.id]) > Entry.max_admin_note_length(),
                        do: "font-semibold text-tangerine",
                        else: "text-muted"
                      )
                    ]}
                  >
                    {draft_length(@note_forms[entry.id])}/{Entry.max_admin_note_length()}
                  </span>
                </div>
                <%!-- An explicit id: every row's form is `note[body]`, so the id
                      `<.input>` derives from the field name would be the same on every
                      card, and LiveView patches the wrong textarea. --%>
                <%!-- No `text-[12.5px]` override. It took the longest field on this
                      screen further below the 16px at which iOS Safari auto-zooms the
                      viewport on focus, and it was this piece's own addition; the
                      primitive's 13.5px is a `core_components.ex` concern and that file
                      belongs to another piece. --%>
                <.input
                  id={"note-body-#{entry.id}"}
                  field={@note_forms[entry.id][:body]}
                  type="textarea"
                  class="min-h-[56px]"
                  placeholder="What you did about it. Private to admins."
                />
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <%!-- Shortened, and it now renders only for a row whose editor is
                        actually open rather than fifteen times down the page. The full
                        statement lives once in the page summary above. --%>
                  <p class="text-[11px] leading-[1.35] text-muted">
                    Private to admins. Saving emails nobody.
                  </p>
                  <button type="submit" class={action_button_class()} phx-disable-with="Saving…">
                    Save note
                  </button>
                </div>
              </.form>
            </.sticker_card>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
