defmodule ConsensusWeb.FeedbackLive do
  @moduledoc """
  `/feedback` — design frame `00c`, where the two faces in `ConsensusWeb.Chrome.footer/1`
  land.

  Two states in one route, not two routes: the form, and — after a successful write —
  a **full-page thank-you** that replaces it (plan ruling 7). A flash strip over a screen
  that still looks like the form reads as "nothing happened", which is the failure this
  whole piece of work exists to remove.

  The thank-you is `push_patch`ed to `?sent=1` **with `replace: true`** rather than being
  held only in socket assigns, and both halves of that matter.

  Holding it only in assigns, on a URL that never changed, meant a reload dropped the
  sender onto an empty form with no evidence anything had been sent — the same "reads as
  nothing happened" failure displaced by one action. `?sent=1` fixes that.

  `replace: true` fixes the other half, and it was still broken after the first fix.
  Without it the pre-submit URL stays in history *underneath* the thank-you, so one press
  of the browser Back button — the most natural gesture on a phone, on a screen whose
  only other control is a forward button — pops back to a form still holding every word
  the sender typed, with a live tangerine **Send feedback** and nothing anywhere saying it
  had already gone. Measured during review: that walk left byte-identical duplicate rows
  35 seconds apart. Replacing the entry means Back leaves `/feedback` for the screen the
  face was tapped on, which is where the thank-you's own button goes anyway. Belt and
  braces, `handle_params/3` also keeps `sent?` true whenever this process still holds the
  row it wrote, so no popstate can resurrect a form for a submission already made.

  A cold visit to `/feedback?sent=1` (a bookmark, a typed URL, a restored tab) still
  renders a thank-you, because a reload after a real send is indistinguishable from it and
  the reload case is the one worth serving. What it must **not** do is assert a stored
  record that may never have existed: `Your note is saved.` and the "included the screen
  you were on" line are both gated on `@sent_entry`, the row *this process* wrote. Without
  it the card says only what is true of feedback in general. There is deliberately no
  `?sent=<id>`: an id in the URL would mean reading a stranger's entry — and printing
  their `page_path` — on an unauthenticated page.

  ## What arrives in the URL

  `mood` (`?mood=happy` / `?mood=sad`) is read in `handle_params/3` rather than `mount/3`
  so a patch that changes it re-seeds the radio group without discarding anything already
  typed. The footer does not compete for that control: `Chrome.show_mood_pair?/2` drops
  the pair entirely on `/feedback`, so the in-page radio group is the only mood control on
  this screen.

  That is true of the **mood pair only**, and this paragraph used to over-claim it as "and
  there is no footer tap that can remount this LiveView and lose a draft". The other five
  footer controls — the three standing links, the outbound credit — and the header `‹` are
  all still `navigate`s, and they did exactly that: measured at 420×900, 54 characters into
  WHAT HAPPENED, a tap on the footer's Privacy discarded the draft with no prompt and
  `history.back()` returned an empty textarea. `draft?/1` below now feeds both
  `footer_confirm` and `back_confirm` (D-045), which is what makes the claim true.

  The mood is a **default, not a lock** — frame `00c`'s own caption is "From the footer —
  tap to switch" — so both faces render as a two-state radio group and either is one tap
  away. A visit with no `mood` at all is legitimate (a typed URL, a shared link): both
  faces render unpicked, the caption says so, and
  `Consensus.Feedback.Entry.changeset/2` refuses to store anything until one is chosen.
  Anything that is not one of the two known moods is treated as none.

  `return_to` rides along the same way and is read back through `safe_back/1`, which is
  `ConsensusWeb.CurrentPath.return_to/1` plus `Entry.safe_page_path/1` — the parameter is
  attacker-controlled and a `navigate` or a `back` built straight from it would be an open
  redirect wearing this app's chrome. The shared helper alone is not sufficient; see
  `safe_back/1` and `origin_path/1`.

  ## The screen the sender was on

  The "include the screen I was on" box is **default-on and actually honoured**: ticked,
  `Consensus.Feedback.submit/2` stores `return_to` as `page_path`; unticked, it stores
  `nil`. The decision lives in the changeset (`Entry.put_page_path/2`), not here, so the
  test that proves it is a context test.

  The frame's parenthetical is `(Dinner Friday? · voting)` — a session title and status.
  We do not resolve those: reading a group out of the database on a path that any visitor
  can type would print a stranger's session title to a signed-out page. What the row shows
  instead is a **route-derived label** from `page_label/1` plus the literal path beneath
  it. The label is computed from the shape of the path alone — no query, no database, so
  nothing leaks — and it exists because the literal path on its own is frequently
  unreadable: the footer's faces are tapped from the home page more than anywhere else,
  where the entire evidence was the single character `/` floating in a dashed box. The
  path stays as the small mono line under it, because the label is a description and the
  path is what is actually stored.

  Nothing else is captured: no user agent, no IP, no referrer — the checkbox does not
  describe those. The path itself is filtered through `Entry.safe_page_path/1` on the way
  in *and* on the way to the screen, so a control character smuggled between two slashes
  (`/\t/evil.example/x`, which the WHATWG URL parser strips before resolving, making it
  protocol-relative) can neither be stored nor rendered as a link an administrator is
  invited to press.

  ## No `Cancel`

  Frame `00c` draws `Cancel` beside `Send feedback`. Plan ruling 1 is explicit that a
  form's Cancel resolving to the same route as the header's `‹` is the duplicate back
  affordance this work removes, and this one would: both go to `return_to`. The action
  bar is the one tangerine `Send feedback`, and the `‹` is the way out. On the
  thank-you state the `‹` is dropped instead, because there the *body* carries the way
  back and two of them would be the same duplication the other way round.

  The bar itself **is** pinned, as IMPORT-NOTES §6.5 specifies — `sticky bottom-0`. It
  shipped in ordinary flow on the argument that a nested scroller is the one thing a phone
  handles badly, which is true and is not what §6.5 asks for. Measured at the frame's own
  420×700: the one tangerine forward action sat 84px below the fold and ended 144px past
  it, on a screen with no Cancel and whose only other control is a 29px header circle.
  `sticky` needs no nested scroller and costs nothing here, because
  `ConsensusWeb.Chrome.footer/1` is deliberately *not* sticky (D-041) — so there is never
  a second pinned surface competing for the bottom edge, and the footer still lands below
  the bar at the end of the scroll.

  Pinning it has four consequences the first version did not pay for, and all four are
  handled where they happen rather than by unpinning:

    * the scroll body reserves the bar's height (`pb-[172px]`), because an opaque pinned
      bar over a body with no reserved space simply deletes that much live content —
      16.4px of a 110px textarea was visible at 360×640, and focusing it did not scroll;
    * **`WHAT HAPPENED` moved above the optional `NAME`/`EMAIL` pair**, which frame `00c`
      draws it below. Reserving the bar's height fixed the scrolled geometry and left the
      *arrival* state worse: with 530px of content above it, none of the message field was
      visible at `scrollY === 0` on a 640px viewport while `Send feedback` was fully
      painted, so the screen showed a Send and no field to write feedback in. Padding
      cannot fix that; ordering can, and asking for the one required thing first is the
      better form anyway;
    * a rejected submit **scrolls and focuses the field it rejected** (`push_event
      "reveal-error"` → the `RevealError` hook). With a pinned Send, the sender can be
      looking at the button while the error renders off-screen: measured at 360×640, the
      press moved `scrollY` not at all, moved focus not at all, and produced identical
      screenshots either side of it;
    * the capture-consent row moved **into** the bar. A `sticky` Send is reachable without
      scrolling by construction, so a consent row anywhere in the body can be skipped
      unseen — which is the same lie as a checkbox the app ignores, told from the other
      side. See the comment on `#feedback-context` and D-046.
  """

  use ConsensusWeb, :live_view

  alias Consensus.Feedback
  alias Consensus.Feedback.Entry

  import ConsensusWeb.CurrentPath, only: [return_to: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Feedback")
     |> assign(:og_title, "Send feedback · Consensus")
     |> assign(:og_description, "Something broken, confusing, or missing? Tell us here.")
     |> assign(:sent?, false)
     |> assign(:sent_entry, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    mood = parse_mood(params["mood"])

    # `sent_entry` is the belt to `replace: true`'s braces. A popstate onto the pre-submit
    # URL must not re-show a form for a row this process already wrote, however it got
    # there — that walk is what produced byte-identical duplicate rows in review.
    sent? = params["sent"] == "1" or socket.assigns[:sent_entry] != nil

    socket =
      socket
      |> assign(:return_to, safe_back(params))
      |> assign(:origin_path, origin_path(params))
      |> assign(:mood_from_url?, mood != nil)
      |> assign(:sent?, sent?)

    # A patch from the other face re-seeds the mood without discarding anything already
    # typed: the mood is put on the *current* form params, not on a fresh changeset.
    # The patch this module makes for itself — to `?sent=1` — must not touch the form at
    # all; the thank-you owns the screen from there.
    socket =
      cond do
        sent? and socket.assigns[:form] -> socket
        socket.assigns[:form] -> assign_form(socket, put_mood(current_params(socket), mood))
        true -> assign_form(socket, seed_params(socket, mood))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"entry" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("save", %{"entry" => params}, socket) do
    case Feedback.submit(params,
           user_id: user_id(socket),
           page_path: socket.assigns.origin_path
         ) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> assign(:sent_entry, entry)
         |> assign(:sent?, true)
         # `replace: true`, not a plain patch: the form's URL must leave the history
         # stack, or one press of Back restores a fully-populated form that reads as
         # unsent and invites a duplicate submission. See the moduledoc.
         |> push_patch(to: sent_path(socket), replace: true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Re-rendering the form with its errors is not, by itself, an observable outcome.
        # The pinned action bar means the sender may be looking at a Send button with the
        # rejected field a screenful above it: measured at 360×640, the error `tell us what
        # happened` rendered at y 680 in a 640px viewport, `scrollY` stayed 0, focus did not
        # move, and before/after screenshots of the press were identical. The `RevealError`
        # hook scrolls the first errored field to the middle of the viewport — the one
        # placement that clears both the sticky header and the sticky bar — and focuses it.
        {:noreply,
         socket
         |> assign(:form, to_form(Map.put(changeset, :action, :validate)))
         |> push_event("reveal-error", %{id: first_error_field_id(changeset)})}

      {:error, {:database_busy, _message}} ->
        # Deliberately not "the database was busy": this screen is reachable signed out
        # from the footer of the app, and the two existing strings for this exact tuple
        # on the other public write path (`JoinController` and `JoinLive.Ballot`) name no
        # server component either.
        {:noreply,
         put_flash(
           socket,
           :error,
           "Couldn't save that just now — press Send feedback again. " <>
             "Everything you typed is still here."
         )}
    end
  end

  # The DOM id `Phoenix.HTML.Form` gives the first field the changeset rejected. Ordered by
  # the form's own field order rather than by `changeset.errors`, whose order is an artefact
  # of which validation ran first — the reader should be taken to the earliest thing wrong
  # on the screen, not the earliest thing the changeset happened to notice. `mood` has no
  # focusable input (it is a radio group whose inputs are `sr-only`), so it points at its
  # first radio's label wrapper via the same id `feedback_form`'s markup uses.
  defp first_error_field_id(%Ecto.Changeset{errors: errors}) do
    case Enum.find([:message, :name, :email, :mood], &Keyword.has_key?(errors, &1)) do
      nil -> nil
      :mood -> "feedback-mood-happy"
      field -> "entry_#{field}"
    end
  end

  # `?sent=1` keeps `return_to`, so the thank-you's own button still knows where the
  # sender came from after a reload.
  defp sent_path(socket) do
    query =
      [sent: "1"] ++
        if(socket.assigns.origin_path, do: [return_to: socket.assigns.origin_path], else: [])

    ~p"/feedback?#{query}"
  end

  defp put_mood(params, mood), do: Map.put(params, "mood", mood_param(mood))

  defp assign_form(socket, params) do
    changeset = Feedback.change_entry(%Entry{}, params)
    assign(socket, :form, to_form(changeset))
  end

  defp current_params(socket), do: socket.assigns.form.params || %{}

  # A signed-in sender starts with their username in the Name field — frame `00c` draws
  # that field filled with `Jordan` and nothing else in the design explains where the
  # value came from. A guest starts blank.
  defp seed_params(socket, mood) do
    base = %{"mood" => mood_param(mood)}

    case socket.assigns[:current_scope] do
      %{user: %{username: username}} when is_binary(username) -> Map.put(base, "name", username)
      _ -> base
    end
  end

  defp user_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} -> id
      _ -> nil
    end
  end

  defp parse_mood("happy"), do: :happy
  defp parse_mood("sad"), do: :sad
  defp parse_mood(_other), do: nil

  defp mood_param(nil), do: ""
  defp mood_param(mood), do: to_string(mood)

  # `return_to/1` falls back to `"/"` so the `‹` always has somewhere to go. That
  # fallback is *not* an origin: nobody was "on `/`" just because they typed this URL,
  # and storing `/` as the screen they came from would be a fact we invented. So the
  # checkbox row is only rendered, and the path only captured, when the parameter was
  # really there.
  #
  # `Entry.safe_page_path/1` on top of `safe_return_to/1` is not belt-and-braces for its
  # own sake. `safe_return_to/1` rejects a literal `//` or `/\` prefix, but an ASCII tab
  # or newline *between* the two slashes survives it — and browsers strip those before
  # resolving a URL, so `/\t/evil.example/x` resolves as `//evil.example/x`, off-site.
  # Here that value would be stored and then rendered as an `href` on `/admin/feedback`,
  # turning a transient assign into an off-site link planted by an unauthenticated
  # stranger on a page an administrator is invited to click. The shared helper should
  # reject it too — that file belongs to another piece — but this write path refuses it
  # on its own account either way.
  # Where the header's `‹` goes. `CurrentPath.return_to/1` is not enough on its own for
  # the reason spelled out on `origin_path/2` below — it accepts a control character
  # between the two slashes, which browsers strip, making `/\t/evil.example/x` resolve as
  # an off-site protocol-relative URL. Rendered on `back` that is an open redirect wearing
  # this app's header. The single durable fix is one line in
  # `ConsensusWeb.CurrentPath.safe_return_to/1`, which belongs to another piece; until it
  # lands, every standing page in this piece refuses it on its own account.
  defp safe_back(params), do: Entry.safe_page_path(return_to(params)) || "/"

  defp origin_path(params) do
    params["return_to"]
    |> ConsensusWeb.CurrentPath.safe_return_to()
    |> Entry.safe_page_path()
  end

  defp message_length(form), do: form[:message].value |> to_string() |> String.length()

  ## The unsaved-draft guard (D-045)
  #
  # `Chrome.show_mood_pair?/2` drops the footer's mood pair on this screen, but the three
  # standing links, the outbound credit and the header `‹` are all still `navigate`s that
  # remount this LiveView. Measured before this landed: 54 characters into WHAT HAPPENED,
  # a tap on the footer's Privacy took the draft with no prompt, and `history.back()`
  # returned `textarea.value === ""`.
  #
  # `name` is included even though a signed-in sender's is seeded from their username —
  # `seed_params/2` puts it in `form.params`, so an untouched form compares equal to
  # itself and the prompt stays disarmed. A mood that arrived in the URL is excluded: it
  # is not typing, and it comes back on its own from the same `?mood=` on the way in.
  defp draft?(%{sent?: true}), do: false

  defp draft?(%{form: form} = assigns) do
    typed_text?(form, assigns[:current_scope]) or
      (not assigns.mood_from_url? and present?(form[:mood].value))
  end

  defp typed_text?(form, scope) do
    present?(form[:message].value) or present?(form[:email].value) or
      trimmed(form[:name].value) != trimmed(seeded_name(scope))
  end

  # What `seed_params/2` put in the Name field before anyone touched it, so an untouched
  # signed-in form compares equal to itself.
  defp seeded_name(%{user: %{username: username}}) when is_binary(username), do: username
  defp seeded_name(_scope), do: ""

  defp present?(value), do: trimmed(value) != ""

  defp trimmed(value), do: value |> to_string() |> String.trim()

  defp discard_prompt, do: "Leave without sending? What you typed here isn't saved yet."

  defp mood_error(form) do
    case form[:mood].errors do
      [] -> nil
      [{message, _opts} | _] -> message
    end
  end

  defp checked_mood?(form, mood), do: to_string(form[:mood].value) == to_string(mood)

  # Three states, and each of the two obvious two-state versions says something false.
  #
  # Keyed on the *origin* it lied both ways: a footer tap arrives with a face already
  # selected and was told to "tap one", and a `?return_to=` link with no mood arrived with
  # neither face picked and was told to "switch" a selection that did not exist. Keyed on
  # the *picked mood* it lied in the mirror case, which is the one review caught: load
  # `/feedback` bare, tap a face, and the caption claimed "From the footer" although
  # nobody came from the footer and the URL still said so.
  #
  # So the "From the footer" half is keyed on the mood having actually arrived in the URL
  # — `mood_from_url?`, set in `handle_params/3` and untouched by an in-page tap — and the
  # "tap one" half on nothing being picked yet.
  defp mood_caption(form, from_url?) do
    cond do
      not (checked_mood?(form, :happy) or checked_mood?(form, :sad)) ->
        "Tap one — it tells us which way this went."

      from_url? ->
        "From the footer — tap to switch."

      true ->
        "Tap to switch."
    end
  end

  # A label for the captured screen, derived from the *shape* of the path and nothing
  # else — no query, no database read, so it cannot leak a stranger's session title the
  # way resolving the frame's `(Dinner Friday? · voting)` would. It exists because the
  # bare path is often unreadable to the person being asked to consent to it: the footer's
  # faces are tapped from the home page more than anywhere else, and there the whole
  # evidence was the single character `/`.
  defp page_label(path) when is_binary(path) do
    case path |> String.split("?") |> hd() |> String.split("/", trim: true) do
      [] -> "Home"
      ["how-it-works"] -> "How it works"
      ["about"] -> "About"
      ["privacy"] -> "Privacy"
      ["feedback"] -> "Feedback"
      ["users", "register"] -> "Sign up"
      ["users", "log-in" | _] -> "Log in"
      ["users", "settings" | _] -> "Settings"
      ["admin" | _] -> "Admin"
      ["groups", "new"] -> "Starting a session"
      ["groups", _id, "edit"] -> "Session setup"
      ["groups", _id, "options" | _] -> "Adding options"
      ["groups", _id, "review"] -> "Reviewing the pool"
      ["groups", _id, "share"] -> "Sharing the link"
      ["groups", _id, "results"] -> "Live results"
      ["join", _slug] -> "Joining a vote"
      ["join", _slug, "vote"] -> "The ballot"
      ["join", _slug, "results"] -> "Live results"
      _ -> "a screen in this app"
    end
  end

  defp account_name(%{user: %{username: username}}) when is_binary(username), do: username
  defp account_name(_scope), do: nil

  # The two mouths from `docs/design/IMPORT-NOTES.md` §4.2: exact reflections of each
  # other. Same paths `Chrome.footer/1`'s 16px faces use, drawn here at 20px.
  @happy_mouth "M8 14.6c1 1.2 2.4 1.8 4 1.8s3-.6 4-1.8"
  @sad_mouth "M8 16.4c1-1.2 2.4-1.8 4-1.8s3 .6 4 1.8"

  # `checked_fill` holds the whole variant string, not just the colour, because Tailwind
  # v4 finds classes by scanning source text: `"peer-checked:" <> mood.fill` is assembled
  # at runtime and produces no literal for it to find, so the rule would never be
  # generated. The same reason `Sticker.tone_class/1` returns complete class strings.
  defp moods do
    [
      %{
        value: "happy",
        label: "Something's going well",
        mouth: @happy_mouth,
        checked_fill: "peer-checked:bg-mint"
      },
      %{
        value: "sad",
        label: "Something's wrong",
        mouth: @sad_mouth,
        checked_fill: "peer-checked:bg-peach"
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      variant={if @current_scope, do: :app, else: :marketing}
      back={if @sent?, do: nil, else: @return_to}
      back_confirm={draft?(assigns) && discard_prompt()}
      footer_confirm={draft?(assigns) && discard_prompt()}
    >
      <.sent_screen :if={@sent?} entry={@sent_entry} return_to={@return_to} />
      <.feedback_form
        :if={!@sent?}
        form={@form}
        origin_path={@origin_path}
        mood_from_url?={@mood_from_url?}
        account_name={account_name(@current_scope)}
      />
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :origin_path, :string, default: nil
  attr :mood_from_url?, :boolean, default: false
  attr :account_name, :string, default: nil

  defp feedback_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="feedback-form"
      phx-change="validate"
      phx-submit="save"
      phx-hook="RevealError"
      class="flex flex-1 flex-col"
    >
      <%!-- **`pb-[172px]` reserves the pinned bar's own height, and it is not spacing
            taste.** The bar below is `sticky bottom-0` and opaque, and this body had
            `pb-5` and no nested scroller — so wherever the bar was stuck it ate its full
            height of live content off the bottom of the viewport with nothing scrollable
            underneath to recover it. Measured at `scrollY === 0` against the
            `#entry_message` textarea: **16.4px of 110 visible at 360×640** (the
            placeholder entirely hidden), 40.4 at 390×664, 76.4 at the frame's own 420×700.
            Focus did not rescue it either — Chrome will not scroll a partially-visible
            element and knows nothing about an overlay, so at 360×640 `scrollY` stayed 0
            after `#entry_message.focus()` and the caret line stayed occluded *while
            typing*. And the bar's 2px ink top border reads as the end of the page, so
            nothing suggested there was more.

            Reserving beats reverting the bar to ordinary flow, which is what shipped
            first: that put the one tangerine forward action 84px below the fold on a
            screen with no Cancel. `mt-auto` on the bar means a tall viewport is unchanged
            — `flex-1` already absorbs the padding when there is spare room, so this only
            adds document height once the content actually overflows, which is exactly when
            it is needed. --%>
      <div class="flex flex-1 flex-col gap-4 px-5 pb-[172px] pt-4">
        <%!-- No `<.eyebrow>Feedback</.eyebrow>`. Frame `00c` opens the title block with
              the `h1` and carries FEEDBACK in the *header* slot instead — and that slot
              stays empty here, because plan ruling 9 keeps it for state rather than the
              page's name. An eyebrow the frame does not draw is not a free addition: it
              pushed the `h1` from 18px below the header to 39.5px below it, which is the
              whole title block's rhythm. --%>
        <div class="flex flex-col gap-[7px]">
          <%!-- The frame stacks this title on two lines and the block reads noticeably
                lighter as one running line, so the break is explicit at the frame's own
                word boundary rather than left to the viewport. --%>
          <h1 class="text-[27px] font-bold leading-[1.06] tracking-[-0.025em]">
            Tell us how<br />to improve
          </h1>
          <p class="text-[13px] leading-[1.45] text-muted">
            Bugs, confusing steps, things you wish it did. It goes straight to the people
            working on this app.
          </p>
        </div>

        <%!-- A two-state radio group, not a toggle: frame `00c` keeps both faces on
              screen and its caption says "tap to switch", so the mood the footer sent is
              a default the sender can correct. The circle sits inside a larger label so
              the tap target clears the phone minimum without the circle growing.

              **40px, not 36 — the frame's painted total.** Frame `00c` is content-box
              (no reset), so its `width:36px; border-top-width:2px` paints 40×40; this app
              is `box-sizing: border-box`, so `size-9 border-2` painted 36. D-041's amended
              rule is that the border-box reading only stands where a frame's *container*
              dimension depends on it — the 48px header, the 97px footer — and nothing
              here does: the label owns the touch target either way, so the 4px was pure
              loss against the drawing. `size-12` on the label, not `size-11`, because the
              gutter is the other half of the frame's geometry: at a 48px label a 40px
              circle leaves 4px of inset each side, which with `gap-px` reproduces `00c`'s
              9px circle-to-circle gap exactly (a 44px label would have collapsed it to
              5px). 48 ≥ 44, so the touch minimum is still clear.

              `-ml-1` pulls the row back into the page's 20px type column: the circle sits
              centred in the label with 4px of inset, so without it the first face starts
              4px right of the eyebrow, the h1 and every field box, which is visible as a
              wobble in the left edge. It is the inset, so it does not change with the
              diameter. --%>
        <div class="flex flex-col gap-1.5">
          <div class="-ml-1 flex items-center gap-px" role="radiogroup" aria-label="How is it going?">
            <label
              :for={mood <- moods()}
              id={"feedback-mood-#{mood.value}"}
              class="grid size-12 shrink-0 cursor-pointer place-items-center"
            >
              <input
                type="radio"
                name={@form[:mood].name}
                value={mood.value}
                checked={checked_mood?(@form, mood.value)}
                class="peer sr-only"
              />
              <span class="sr-only">{mood.label}</span>
              <span class={[
                "grid size-10 place-items-center rounded-full border-2 text-ink transition-all",
                "border-ink/35 bg-white opacity-55",
                "peer-checked:border-ink peer-checked:opacity-100 peer-checked:shadow-sticker-2",
                mood.checked_fill,
                "peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-violet"
              ]}>
                <.face mouth={mood.mouth} />
              </span>
            </label>
            <p class="ml-2 text-[11.5px] leading-[1.35] text-muted">
              {mood_caption(@form, @mood_from_url?)}
            </p>
          </div>
          <p :if={mood_error(@form)} class="text-sm font-semibold text-tangerine">
            {mood_error(@form)}
          </p>
        </div>

        <%!-- **WHAT HAPPENED comes before NAME and EMAIL, and frame `00c` draws it last.**
              Reserving the pinned bar's height fixed the *scrolled* geometry and left the
              arrival state worse: with the two optional fields and their explanatory
              paragraph above it, `#entry_message` started at y 530 on a 640px viewport with
              a 167px bar stuck over the bottom, so **none** of the field was visible at
              `scrollY === 0` while the tangerine `Send feedback` was fully painted and
              hit-testable. A sender arriving on a phone saw a heading, two optional fields,
              a ticked consent box and a Send — and no field to write feedback in, under a
              2px ink border that reads as the end of the page.

              No amount of bottom padding can fix that: it is 530px of content above the one
              required field. Ordering is the fix, and it is the better order anyway — the
              screen's one required field is the first thing it asks for, and the two
              optional ways to identify yourself follow. --%>
        <%!-- No `maxlength` (CLAUDE.md invariant 11 / D-026). The cap is
              `Entry.max_message_length/0` in the changeset and the counter below reads
              the same function, counting graphemes the way `validate_length/3` does —
              a browser counts UTF-16 code units and would silently truncate a paste. --%>
        <div class="flex flex-col gap-2">
          <div class="flex items-baseline justify-between gap-3">
            <.eyebrow>What happened</.eyebrow>
            <span
              id="feedback-counter"
              aria-live="polite"
              class={[
                "font-mono text-[10px]",
                if(message_length(@form) > Entry.max_message_length(),
                  do: "font-semibold text-tangerine",
                  else: "text-muted"
                )
              ]}
            >
              {message_length(@form)}/{Entry.max_message_length()}
            </span>
          </div>
          <%!-- `min-h-[138px]`, not 110. Frame `00c` paints this box 138px tall: its
                `min-height:110px` is a *content* box on top of `padding:14px` and a 2px
                border each side, and Tailwind's box model here is border-box. At 110 the
                screen's main field was ~1.5 lines shorter than drawn. --%>
          <.input
            field={@form[:message]}
            type="textarea"
            class="min-h-[138px]"
            placeholder="I got stuck after adding my options…"
          />
        </div>

        <div class="flex flex-col gap-2">
          <.eyebrow>Name</.eyebrow>
          <.input field={@form[:name]} type="text" placeholder="Optional" />
        </div>

        <div class="flex flex-col gap-2">
          <.eyebrow>Email</.eyebrow>
          <.input field={@form[:email]} type="email" placeholder="you@example.com" />
          <%!-- Two different true sentences, because one of them used to be false.
                `Feedback.submit/2` is passed `user_id:` unconditionally for a signed-in
                sender and the queue prints their username, so "leave it blank to stay
                anonymous" was a promise the write path cannot keep for them. It is kept
                for a signed-out visitor, where it is exactly true.

                "the app never emails you" was the other false absolute, and it was shown
                to exactly the readers it is false for: this app does send mail to account
                holders — magic-link log-in, confirmation, email-change. Scoped to what
                this form does, which is what the sentence was reaching for. --%>
          <p class="text-[11px] leading-[1.4] text-muted">
            Only so a person can write back by hand — sending this puts you on no mailing
            list and triggers no mail of its own.
            <%= if @account_name do %>
              You're signed in, so this arrives under your account, <span class="font-semibold">{@account_name}</span>, either way.
            <% else %>
              Leave it blank to stay anonymous.
            <% end %>
          </p>
        </div>
      </div>

      <%!-- Frame `00c` §6.5 pins this bar above the global footer, white against the
            footer's surface, both with a 2px ink top border — and pinned is what it has
            to be. In ordinary flow the one tangerine forward action measured 84px below
            the fold at the frame's own 420×700, on a screen with no Cancel.

            `sticky bottom-0` rather than a `flex:none` bar over an `overflow-y:auto`
            body: it needs no nested scroller (which is the thing a phone handles badly,
            and was the original objection), and nothing competes with it for the viewport
            edge because `Chrome.footer/1` is deliberately not sticky (D-041). The footer
            still lands below the bar at the end of the scroll. `mt-auto` stays so a short
            viewport puts the bar at the bottom of the column rather than under the last
            field. --%>
      <div class="sticky bottom-0 z-20 mt-auto flex flex-col gap-2.5 border-t-2 border-ink bg-white px-5 pb-5 pt-3">
        <%!-- Default-on, and honoured: `Feedback.submit/2` stores the path only while
              this stays ticked. Rendered only when there is an origin to include —
              a direct visit to `/feedback` has nothing to attach and a box promising
              otherwise would be the lie this row exists to avoid.

              **It sits in the pinned bar, which frame `00c` §6.4 does not draw.** In the
              frame's position — last child of the scroll body — it was the mirror image of
              the lie it exists to prevent: measured at 420×700 with `scrollY=0`, its top
              was at 663.6 in a 700px viewport with everything below 606 behind the opaque
              bar, while `Send feedback` sat at 620–680 fully hit-testable, and
              `elementFromPoint` aimed at the label's centre returned the bar. A sender
              could therefore submit without ever seeing that "Include the screen I was on"
              was ticked. Reserving space in the body (above) makes the row *reachable*, but
              a `sticky` Send is by construction always reachable without scrolling, so
              reachable is not the same as seen. Consent belongs adjacent to the action it
              qualifies; putting it here is the only arrangement in which the two are
              guaranteed on screen together. Recorded in DESIGN-SPEC under `00c` and in
              D-046.

              Frame `00c` §6.4 still governs the row itself: `align-items:center`, radius
              14, and the label at `400 11.5px/1.35` in `--ink-soft` with the context
              *inline* in a parenthetical — one ~44px row, not a heading with a second line
              under it. `<.input>`'s own checkbox label is `text-sm font-semibold text-ink`
              and `items-start`, so the frame's type is restored from the wrapper with child
              selectors rather than by touching `core_components.ex`.

              `[&_label]:min-h-[44px]` on the wrapper rather than a `class` on `<.input>`:
              that attribute lands on the `<input>` itself, and the thing a thumb has to
              hit is the `<label>` around it, which the component sizes to its 22px box
              and one line of text — 24px tall, well under the phone minimum.

              The literal path stays as a mono line beneath — the frame's one row plus one
              — because the parenthetical is a *description* and the path is what actually
              gets stored, and a row that proves what it will attach should show both. --%>
        <%!-- **Solid, where frame `00c` line 43 draws `2px dashed rgba(23,33,28,.35)`.**
              In this repo dashed is the documented "not built yet" treatment — CLAUDE.md
              invariant 12 has `Bars` and `Movies` "render dashed and inert", D-046 draws
              every inert control that way, and D-047 §4 changed `03 review`'s veto row
              specifically because it must *not* read as unbuilt. This row is a live,
              functional, default-on consent control on a screen whose consent has already
              been the subject of two critic findings; drawing it in the treatment reserved
              for dead controls is the one place the frame and the convention genuinely
              disagree, and the convention wins because it is the one a reader of *this
              app* has been taught. Recorded in DESIGN-SPEC's `00c` deviation block. --%>
        <div
          :if={@origin_path}
          id="feedback-context"
          class={[
            "rounded-[14px] border-2 border-ink/35 bg-white px-3",
            "[&>div]:mb-0 [&_label]:min-h-[44px] [&_label]:items-center",
            "[&_label>span:last-child]:text-[11.5px] [&_label>span:last-child]:font-normal",
            "[&_label>span:last-child]:leading-[1.35] [&_label>span:last-child]:text-ink-soft"
          ]}
        >
          <.input
            field={@form[:include_page]}
            type="checkbox"
            label={"Include the screen I was on (#{page_label(@origin_path)})"}
          />
          <p class="-mt-1.5 break-all pb-2 pl-[32px] font-mono text-[10px] leading-[1.3] text-faint">
            {@origin_path}
          </p>
        </div>

        <.button
          type="submit"
          variant="primary"
          class="w-full"
          phx-disable-with="Sending…"
        >
          Send feedback
        </.button>
      </div>
    </.form>
    """
  end

  attr :entry, :map, default: nil
  attr :return_to, :string, required: true

  defp sent_screen(assigns) do
    ~H"""
    <%!-- `justify-center`: IMPORT-NOTES §6.6 settles the undrawn post-submit state as a
          *centred* confirmation replacing the scroll body. Top-aligned it left 420px of
          empty surface below the last element — more than the confirmation itself
          occupies. No eyebrow here either, for the same reason as the form. --%>
    <div id="feedback-sent" class="flex flex-1 flex-col justify-center gap-5 px-5 pb-6 pt-6">
      <h1 class="text-[27px] font-bold leading-[1.06] tracking-[-0.025em]">
        Got it — thank you.
      </h1>

      <%!-- Two cards, because `?sent=1` cannot tell a reload after a real send from a
            typed URL or a restored tab, and only one of those stored anything. `@entry`
            is the row *this process* wrote. With it, the card asserts the record. Without
            it, it says only what is true of feedback in general — a cold visit used to
            read "Your note is saved." for a note nobody ever wrote. --%>
      <.sticker_card tone={:mint} class="flex items-start gap-3 p-4">
        <span class="grid size-7 shrink-0 place-items-center rounded-full border-2 border-ink bg-white">
          <.icon name="hero-check" class="size-4" />
        </span>
        <div class="flex flex-col gap-1.5 text-[13px] leading-[1.45] text-ink">
          <p class="text-[15px] font-bold leading-snug">
            {if @entry,
              do: "Your note is saved.",
              else: "Feedback lands with the people building this."}
          </p>
          <p>
            <%= if @entry do %>
              It goes to the people working on this app. Nothing was emailed to anyone —
              if you left an address, a reply would be a person writing back by hand.
            <% else %>
              Nothing is emailed to anyone — if you left an address, a reply would be a
              person writing back by hand. If you came here to send something new, the
              form is one tap away.
            <% end %>
          </p>
        </div>
      </.sticker_card>

      <%!-- Only rendered when this process still holds the row it wrote. A reload of
            `?sent=1` is still a thank-you, but it cannot honestly name a screen it no
            longer has in hand. `break-all` because the path is user-supplied and may be
            one long token. --%>
      <p :if={@entry} class="break-all text-[11.5px] leading-[1.45] text-muted">
        <%= if @entry.page_path do %>
          Included the screen you were on: {page_label(@entry.page_path)}
          <span class="font-mono text-[10px] text-faint">{@entry.page_path}</span>
        <% else %>
          No screen was included — just your message.
        <% end %>
      </p>

      <%!-- The way to send another one, and the only reason it is here: on a cold
            `?sent=1` the card above says the form is one tap away, and a screen that says
            that without offering the tap is the dead end this work removes. Secondary, so
            the tangerine stays the one forward action. --%>
      <.link
        :if={!@entry}
        navigate={~p"/feedback"}
        id="feedback-again"
        class="-my-2 inline-flex min-h-[44px] w-fit items-center text-[12.5px] font-semibold text-ink underline decoration-2 underline-offset-2 hover:text-tangerine"
      >
        Send us something
      </.link>

      <%!-- The one way off this screen, which is why the header's `‹` is dropped here:
            both would go to exactly the same place (plan ruling 1). It sits in the
            column's ordinary flow rather than on `mt-auto`, which opened 360px of void
            between the last line and the button on a 900px viewport. --%>
      <div class="flex flex-col gap-3 pt-1">
        <.button variant="primary" navigate={@return_to} id="feedback-done">
          {if @return_to == "/",
            do: "Back to Consensus",
            else: "Back to what you were doing"} <span aria-hidden="true">→</span>
        </.button>
      </div>
    </div>
    """
  end

  # The frame's faces at 20px. Inline SVG rather than `<.icon>` for the same reason
  # `Chrome.footer/1` does it: heroicons has no smiling/frowning face at this weight and
  # the frame fixes the geometry exactly (viewBox 0 0 24 24, 2.2 stroke, r=1.2 eyes).
  attr :mouth, :string, required: true

  defp face(assigns) do
    ~H"""
    <svg
      width="20"
      height="20"
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
      <path d={@mouth} />
    </svg>
    """
  end
end
