defmodule ConsensusWeb.HowItWorksLive do
  @moduledoc """
  `/how-it-works` — design frame `00b`, reached from the footer of every screen.

  Five numbered steps on a dashed ink timeline, a "Good to know" card, and one tangerine
  **Start something**. The literal geometry is `docs/design/IMPORT-NOTES.md` §5.

  ## The frame's copy is wrong about this product, and it is not shipped

  Plan ruling 5 and IMPORT-NOTES Q-D: frame `00b` promises three things the app does not
  do, and each is a promise a reader would act on.

    * *"Anyone you invite can throw theirs in too"* — friends adding options to somebody
      else's pool is Post-MVP, and the pool freezes the moment voting opens (CLAUDE.md
      invariant 16 / D-037) because `votes.activity_id` cascades: an option added or
      removed under a cast ballot silently corrupts it.
    * *"Drag your top three"* — the ballot is approval voting with veto elimination
      (D-034), not a ranked drag. Nobody drags anything.
    * *"Change your ranking any time before the timer ends"* — a cast ballot is locked
      and there is no recast (D-036).

  The structure and the rhythm are the frame's; the beat count is not. The frame draws
  four, and the four leave out the first thing an organizer actually does — naming the
  session and setting the hard deadline — which the *last* step then refers back to
  ("when the timer runs out") and which the CTA's own destination asks for. That is a
  fifth step, not a rewording; see the comment on `@steps`. The sentences are
  rewritten to be true, and the two irreversible facts the frame denied — the pool
  freezing and the ballot locking — are stated instead, in the "Good to know" card,
  which is the one place on this screen a reader is looking for caveats. The
  substitution is recorded in `docs/design/DESIGN-SPEC.md` under `00b` the way `00a`'s
  is, and in D-042.

  ## The CTA has to know who is reading it

  Frame `00b`'s **Start something** links to `#1b`, the mockup's start page. A signed-in
  organizer goes to `/groups/new`; a signed-out visitor cannot, because creating a
  session needs an account. Sending them into a login wall with no warning is the "no way
  back / unpredictable outcome" pair from the acceptance bar, so the button says where it
  goes and a line beneath it says what it will ask for — and that voting itself never
  needs one, which is the thing a reader of this page most needs to know.
  """

  use ConsensusWeb, :live_view

  import ConsensusWeb.CurrentPath, only: [return_to: 1]

  alias Consensus.Feedback.Entry

  # Fills cycle yellow → violet-soft → peach → yellow-soft → mint: `00a`'s three-badge
  # cycle with mint appended (IMPORT-NOTES §5.2), plus one more when the missing first beat
  # was added. No two adjacent badges share a fill and mint still closes the timeline.
  #
  # **Step 1 is new, and its absence was the page's one real hole.** The four steps used to
  # start at "Add the options", so nothing anywhere on the page said the organizer names the
  # session and sets the hard deadline — then the last step opened "When the timer runs
  # out…", a definite article for an object no earlier sentence had introduced, and the
  # single tangerine **Start something** dropped the reader onto `/groups/new`, whose only
  # two inputs are exactly the two things the page never named. A page describing a
  # four-step product and handing the reader an unannounced fifth screen is the
  # "unpredictable outcome" failure, and it is the same standard the CTA's own sub-line
  # already applies to accounts.
  #
  # Every sentence here is checkable against the code: see the moduledoc for the three the
  # frame got wrong.
  @steps [
    %{
      n: 1,
      fill: "bg-yellow",
      title: "Name it and pick a deadline",
      # Three chips and a custom time, `GroupLive.New` / `Consensus.Deadlines`. "Hard" is
      # the operative word and PRD product invariant 3: the deadline is not a reminder,
      # it is what ends the vote, and nobody has to be the one who decides.
      body:
        "Give it a title — \"Dinner Friday?\" — and pick when voting closes. The deadline " <>
          "is what ends the vote, so nobody has to be the one who calls it."
    },
    %{
      n: 2,
      fill: "bg-violet-soft",
      title: "Add the options",
      body: "Type a name, or paste a link and we pull in the photo and the description."
    },
    %{
      n: 3,
      fill: "bg-peach",
      title: "Share one link",
      body: "Drop it in the group chat. Nobody needs an app, an account or a password to vote."
    },
    %{
      n: 4,
      fill: "bg-yellow-soft",
      title: "Everyone taps what works",
      body:
        "Tap every option you'd be happy with — as many as you like. Each person also gets " <>
          "one veto for a hard no."
    },
    %{
      n: 5,
      fill: "bg-mint",
      title: "The deadline decides",
      # Not "at the same moment". Completion is lazy and schedulerless (D-029) and both
      # results screens flip on their own 30-second tick, started at each socket's own
      # mount — so two people watching can see the winner up to half a minute apart. The
      # sentence's actual point is that nobody has to refresh, which is true.
      body:
        "When the deadline you set runs out, voting closes by itself, and the winner shows " <>
          "up on everybody's screen without anyone refreshing."
    }
  ]

  @good_to_know [
    # Both halves, in the order every other place in this app states them (D-049). This
    # said "Votes are anonymous. Everyone sees the totals, never who picked what." — the
    # second sentence true, the first one doing the over-claiming, on the page a reader
    # opens *to find out* what is and is not private. Who has voted is readable by anyone
    # holding the share link, with no account and no cookie.
    "Anyone with the link can see who has voted. Nobody sees what anyone picked — the " <>
      "results are totals.",
    # Two clauses that contradicted each other in plain reading — "only the organizer can
    # close voting early, **and nobody has to be the one who decides**": if the organizer
    # can close it early, somebody is deciding. The reassurance it was reaching for is
    # about the *winner*, not the close, and step 1 already carries it verbatim ("so nobody
    # has to be the one who calls it"), so this line keeps only the fact.
    "Only the organizer can close voting early — otherwise the deadline does it.",
    "Your picks are final once you send them, and the list of options is locked from the " <>
      "moment voting opens."
  ]

  # Stated on the page rather than left for someone to discover, because it is discoverable
  # in about ten seconds and finding it yourself in a product that never mentioned it reads
  # as a bug being hidden. The mechanism is exact: a guest's identity is the
  # `participant_token:<group_id>` session cookie `ConsensusWeb.JoinAuth` writes, so a fresh
  # private window is a fresh voter. A *signed-in* voter cannot do it —
  # `unique_index(:participants, [:group_id, :user_id], where: "user_id IS NOT NULL")` in
  # `20260808210450_create_voting_tables.exs` allows one participant row per account per
  # group — and that asymmetry is worth saying, because it is the only lever the product
  # currently has and a reader may reasonably want it.
  #
  # The ask at the end is real: the alternative on the table (one unique link per voter)
  # is not a free upgrade, it is a trade of the thing this app is built around — no phone
  # numbers, no address book, one link the organizer pastes once — and which side of that
  # trade people want is not something we can decide from here. It routes to `/feedback`,
  # which is where an answer can actually land.
  @honesty %{
    heading: "You could vote twice, and we know",
    body:
      "Voting takes no account, which means nothing stops somebody opening a private " <>
        "window and voting again. If you are signed in you get one vote per session, but " <>
        "a guest is just a browser.",
    trade:
      "We could give every voter their own link instead. That means collecting everyone's " <>
        "phone number, or the organizer sending the message one person at a time — and for " <>
        "deciding where five friends eat, that felt worse than the problem.",
    ask: "Think we called that wrong? Tell us."
  }

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "How it works")
     |> assign(:og_title, "How Consensus works")
     |> assign(
       :og_description,
       "Put the options up, share one link, everyone taps what they'd be happy with. " <>
         "The deadline picks the winner. No app, no account to vote."
     )
     |> assign(:steps, @steps)
     |> assign(:good_to_know, @good_to_know)
     |> assign(:honesty, @honesty)
     |> assign(:return_to, safe_back(params))}
  end

  # Where the header's `‹` goes. `CurrentPath.return_to/1` accepts a control character
  # between the two slashes (`/\t/evil.example/x`), and browsers strip those before
  # resolving a URL — so that value resolves off-site and `back` becomes an open redirect
  # wearing this app's header. The single durable fix is one line in
  # `ConsensusWeb.CurrentPath.safe_return_to/1`, which belongs to another piece; until it
  # lands, every standing page in this piece refuses it on its own account.
  defp safe_back(params), do: Entry.safe_page_path(return_to(params)) || "/"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_scope={@current_scope}
      variant={if @current_scope, do: :app, else: :marketing}
      back={@return_to}
    >
      <%!-- No `<.eyebrow>`, and no `context` on the header: frame `00b`'s own `h1` is
            "How it works", and plan ruling 9 keeps the header's DM Mono slot for state
            rather than the page's name. Three copies of the same three words in one
            viewport is confusion type 5, not emphasis. --%>
      <div class="flex flex-1 flex-col gap-[18px] px-5 pb-3 pt-[18px]">
        <div class="flex flex-col gap-[7px]">
          <h1 class="text-[30px] font-bold leading-[1.05] tracking-[-0.03em]">How it works</h1>
          <%!-- "takes about two minutes" was the one sentence on this page not checkable
                against the code, on a page whose whole stance (see the moduledoc) is that it
                prints nothing the code does not back — and it sat directly above the PRD's
                "Time to Consensus under 5 minutes" metric, where it reads as a commitment
                nobody has measured. Cut rather than guessed at again. --%>
          <p class="text-[13.5px] leading-[1.45] text-ink-soft">
            Five steps, start to finish.
          </p>
        </div>

        <ol class="flex flex-col">
          <li :for={step <- @steps} class="flex gap-[13px]">
            <div class="flex flex-none flex-col items-center">
              <%!-- `size-9` (36px), not `size-8`. Frame `00b` draws these 36px, and its
                    32px is the content box inside a 2px border each side — the same
                    content-box/border-box conversion the deck controls dropped. It is the
                    element repeated on every row, so it carries the timeline's rhythm. --%>
              <span class={[
                "grid size-9 flex-none place-items-center rounded-[10px] border-2 border-ink",
                "font-mono text-[13px] font-bold shadow-sticker-2",
                step.fill
              ]}>
                {step.n}
              </span>
              <%!-- The 5-on/5-off vertical ink dash between badges, not after the last.
                    An inline gradient because it is a repeating-linear-gradient with no
                    Tailwind equivalent and no existing `.stripes-*` class — it reads the
                    `--color-ink` token rather than the frame's literal #17211C, so no hex
                    lands in a template. --%>
              <span
                :if={step.n < length(@steps)}
                aria-hidden="true"
                class="my-1 w-0.5 flex-1"
                style="background:repeating-linear-gradient(var(--color-ink) 0 5px, transparent 5px 10px)"
              ></span>
            </div>
            <div class={["flex-1", step.n < length(@steps) && "pb-4"]}>
              <p class="text-[15px] font-bold leading-snug">{step.title}</p>
              <p class="mt-[3px] text-[12.5px] leading-[1.45] text-muted">{step.body}</p>
            </div>
          </li>
        </ol>

        <.sticker_card class="flex flex-col gap-2 p-3.5">
          <.eyebrow>Good to know</.eyebrow>
          <p :for={line <- @good_to_know} class="flex gap-[9px] text-[12.5px] leading-[1.4]">
            <span class="font-bold text-violet" aria-hidden="true">·</span>
            <span>{line}</span>
          </p>
        </.sticker_card>

        <%!-- Violet-tint rather than white: this is a caveat, not another fact in the list,
              and the design already uses `--violet-tint` for the one card on `03 review`
              that explains a rule rather than stating one. Not tangerine — the screen's one
              forward action is "Start something" below, and a warning colour would read as
              an error the reader has to fix. The `Tell us` link is a plain underlined link
              for the same reason: a second filled button here would compete with the CTA. --%>
        <.sticker_card tone={:violet_tint} class="flex flex-col gap-2 p-3.5" id="honest-limit">
          <.eyebrow>The honest bit</.eyebrow>
          <p class="text-[13.5px] font-bold leading-snug">{@honesty.heading}</p>
          <p class="text-[12.5px] leading-[1.45] text-ink-soft">{@honesty.body}</p>
          <p class="text-[12.5px] leading-[1.45] text-ink-soft">{@honesty.trade}</p>
          <p class="text-[12.5px] leading-[1.45]">
            {@honesty.ask}
            <.link
              id="honest-limit-feedback"
              navigate={~p"/feedback?#{[mood: "sad", return_to: ~p"/how-it-works"]}"}
              class="-my-1 inline-flex min-h-[26px] items-center font-semibold text-violet underline decoration-2 underline-offset-2 transition-colors hover:text-tangerine active:text-tangerine"
            >
              Send us a note
            </.link>
          </p>
        </.sticker_card>

        <%!-- The CTA is the last child of the scroll body in the frame's own 18px-gap
              column, not pinned to the bottom of the viewport: `mt-auto` opened 78px of
              void between the "Good to know" card and the button, which the frame does
              not have. IMPORT-NOTES §5.4 notes the frame is drawn so this falls below
              the fold. --%>
        <div class="flex flex-col gap-2">
          <.button
            variant="primary"
            class="w-full"
            id="how-it-works-cta"
            navigate={if @current_scope, do: ~p"/groups/new", else: ~p"/users/register"}
          >
            Start something
          </.button>
          <p :if={!@current_scope} class="text-center text-[11.5px] leading-[1.4] text-muted">
            Starting one asks for an email, a username and a password. Voting in someone
            else's never does.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
