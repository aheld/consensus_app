defmodule ConsensusWeb.PrivacyLive do
  @moduledoc """
  `/privacy` — one of the three standing pages `ConsensusWeb.Chrome.footer/1` links to.

  **No design frame** (plan ruling 7: short, honest, real). Every sentence below is
  checkable against this repo, and was checked when it was written:

    * organizers — `Consensus.Accounts.User` stores `email`, `username` and a bcrypt
      hash, nothing else;
    * voters — `Consensus.Voting.Participant` stores an optional `display_name` and a
      server-minted `token`, and no account is ever required (product invariant 1);
    * anonymity — and this one is narrower than the page used to claim, in **two**
      directions. The first is what is public: `participants/1` returns names, and
      `ConsensusWeb.JoinLive.Results` renders the WHO'S VOTED row for a visitor with no
      participant token, so anyone holding the share link reads the guest list without
      joining (D-049). The page says so rather than letting the heading imply otherwise.
      The second is the old one. `Consensus.Voting`
      is **structurally anonymous at the API surface**: `tally/1` returns per-option
      totals, `participants/1` returns names and whether someone voted but never what they
      picked, the PubSub message carries nothing about a ballot, and there is no public
      function anywhere in the context that maps a participant to their approvals (D-035).
      That is *not* the same as the link being absent from the database, which the page
      asserted until a copy review checked: `Consensus.Voting.Vote` `belongs_to
      :participant`, `Consensus.Voting.Participant` carries `display_name` and a nullable
      `user_id`, and `ConsensusWeb.JoinController` sets that `user_id` to the real account
      for a signed-in voter. One SQL join over the volume produces "who approved what". So
      the page says what is true — no screen, no export, no admin page, and no code in the
      app can produce it — and does not say it is impossible;
    * feedback — `Consensus.Feedback.Entry` stores the message and mood, an optional
      name and email, `user_id` whenever the sender was signed in (it is passed
      unconditionally by `ConsensusWeb.FeedbackLive` and is not something the sender can
      decline by leaving the name and email blank — this page said "nothing else" while
      omitting it until a copy review caught it), and the path of the screen the sender
      was on **only** when the box on `/feedback` was left ticked (D-042);
    * no analytics — there is no analytics, tracking or error-reporting dependency in
      `mix.exs` and no tracker in `assets/`; verified by grep before this page shipped;
    * two cookies, and the count is the point — `ConsensusWeb.Endpoint`'s session cookie
      `_consensus_key`, plus `@remember_me_cookie` (`_consensus_web_user_remember_me`,
      `max_age` 14 days) in `ConsensusWeb.UserAuth`, which is written only when the
      log-in form's "Log in and stay logged in" submits `remember_me: "true"`. This page
      said "one cookie" until a copy review counted; if a third ever appears, say three;
    * one third-party request — `root.html.heex` loads Instrument Sans and DM Mono from
      Google Fonts, which is the only host a page here fetches from. Saying "no third
      parties" while the browser calls out for two typefaces would be exactly the kind
      of privacy-page claim that is technically about intent and factually false.

  If any of those change, this page changes with them. Do not add a claim the code does
  not back.
  """

  use ConsensusWeb, :live_view

  import ConsensusWeb.CurrentPath, only: [return_to: 1]

  alias Consensus.Feedback.Entry

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Privacy")
     |> assign(:return_to, safe_back(params))}
  end

  # `card` promotes a section into a `<.sticker_card>`. Two of the seven take it, and the
  # reason is legibility rather than decoration: this page was 1341px of seven identical
  # eyebrow-over-paragraph blocks in which the only element carrying a shadow was the CTA
  # at the very bottom. Every token on it was correct and it still read as un-designed
  # beside `/about`, which uses cards for exactly this. Two is the right number — card
  # everything and the emphasis is back to nothing — and these are the two a reader comes
  # here for: the anonymity limit (the one claim on the page that is deliberately narrower
  # than people expect) and how to get your data deleted (the one section that asks the
  # reader to *do* something).
  attr :title, :string, required: true
  attr :card, :boolean, default: false
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <.sticker_card :if={@card} class="flex flex-col gap-1.5 p-3.5">
      <.eyebrow>{@title}</.eyebrow>
      <p class="text-[12.5px] leading-[1.5] text-ink-soft">{render_slot(@inner_block)}</p>
    </.sticker_card>
    <div :if={!@card} class="flex flex-col gap-1.5">
      <.eyebrow>{@title}</.eyebrow>
      <p class="text-[12.5px] leading-[1.5] text-ink-soft">{render_slot(@inner_block)}</p>
    </div>
    """
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
      <div class="flex flex-1 flex-col gap-[18px] px-5 pb-3 pt-[18px]">
        <div class="flex flex-col gap-[7px]">
          <.eyebrow>Privacy</.eyebrow>
          <h1 class="text-[30px] font-bold leading-[1.05] tracking-[-0.03em]">
            We ask for as little as we can.
          </h1>
          <p class="text-[13.5px] leading-[1.45] text-ink-soft">
            Here is everything this app stores about you, in plain words. It is short
            because the list is short.
          </p>
        </div>

        <div class="flex flex-col gap-4">
          <.section title="If you vote">
            No account, no password and no email address — a first name is optional and
            you can leave it blank. If you give one, it goes in the list of who has voted,
            which anyone holding that link can see; what you picked is a different question
            and the card below answers it. Your browser is given a random token so you can
            come back to the same vote. We do keep the votes themselves:
            the options you tapped and the one you vetoed are stored against your entry in
            that vote, and against your account if you were signed in when you joined.
          </.section>

          <.section title="If you organize">
            The email address and username you signed up with, and your password stored as
            a bcrypt hash — we can't read it back. Plus the sessions you create and the
            options in them.
          </.section>

          <%!-- The title changed with the copy (D-049). "Votes are anonymous" over a
                paragraph that has to begin by saying the guest list is public was the
                heading doing the over-claiming the sentences had just been corrected for.
                Two things, and only one of them is private, is the actual shape of it. --%>
          <%!-- Every line break here is load-bearing: the phrases this page is pinned on
                ("no admin page shows who picked", "rows are still in the database") must
                not be split across a line, because HEEx puts the template's own indentation
                into the text node. Same whitespace-significant-string trap CLAUDE.md
                invariant 11 / D-026 records. Re-wrap with the tests open. --%>
          <.section title="Who voted, and what they picked" card>
            These are two different things and only the second is private. Who has voted is
            not a secret: anyone holding the share link can open the results and read the
            list, under whatever name each person typed. What they picked is. Results are
            totals — no screen, no export and no admin page shows who picked what, and
            there is no code in this app that can work it out, so it isn't a setting
            somebody could switch on. Being straight with you about the limit: the
            rows are still in the database, so whoever runs the server could read them
            with a database query. Anonymous means nobody using the app can see it, not
            that the information was thrown away.
          </.section>

          <.section title="If you send feedback">
            What you wrote and which face you tapped. Your name and email only if you
            filled them in, and the address of the screen you were on only while the
            "include the screen I was on" box stays ticked. If you are signed in when you
            send it, we also store which account it came from, so an admin knows who to
            answer. Nothing else — not your browser, not your location.
          </.section>

          <.section title="Cookies and other sites">
            Two cookies. One keeps you signed in and remembers which vote you are in. The
            other is written only if you choose "Log in and stay logged in", and it keeps
            you signed in on this device for 14 days.
            There is no analytics, no advertising and no tracker of any kind in this app.
            Pages do fetch two typefaces from Google Fonts, so Google sees that request.
            The <span class="whitespace-nowrap">marketfinder.us</span>
            line in the footer is an ordinary link — nothing loads from it until you tap it.
          </.section>

          <%!-- Three corrections a copy review forced, all of them things this page
                promised and the app does not do.

                No `mood: "sad"` on the link. Pre-selecting the frowning face filed a
                routine "please close my account" in the admin queue as a complaint, and
                the arriving form's caption then read "From the footer — tap to switch"
                although nobody came from the footer.

                `return_to: ~p"/privacy"`, not `@return_to`. Handing an outgoing link the
                `return_to` this page *inherited* made the feedback form record a screen
                the sender was never on — open `/privacy?return_to=/groups/3/options` and
                the dashed row offered to attach `/groups/3/options`. That is the exact
                lie the checkbox exists not to tell. `@return_to` is for the header's `‹`
                and nothing else.

                And the sentence itself: feedback survives account deletion by design
                (`user_id` is `nilify_all` so a deleted account does not destroy the bug
                report it filed), the `name` and `email` the sender typed are untouched by
                the delete, and nothing about this request notifies anybody. --%>
          <.section title="Getting rid of it" card>
            Send us a note through the
            <.link
              navigate={~p"/feedback?#{[return_to: ~p"/privacy"]}"}
              class="-my-3 inline-flex min-h-[44px] items-center font-semibold underline decoration-2 underline-offset-2"
            >feedback form</.link>
            asking us to close your account, and leave an email address so we can write
            back. Nobody is notified automatically and there is no delete button — a
            person does it by hand, so give it a few days. Deleting an account also
            deletes the sessions you organized and frees your email address to be used
            again. Feedback you already sent is kept, with your name and email on it if
            you filled them in, but it stops being connected to your account. None of it
            is sold or shared.
          </.section>
        </div>

        <%!-- This was a second **How it works** button, 53px above the footer's own "How
              it works" link — measured — with the same words and different back
              behaviour, which is the "ambiguous duplication" confusion and the one the
              larger control lost. Pointing both at the same place does not fix it either,
              because the footer's link is built in `chrome.ex` and carries whatever
              `return_to` this page was *handed*, not this page's own path.

              So the page gets a forward action the footer does not already offer. It
              knows who is reading it, the way `/how-it-works`' CTA does: creating a
              session needs an account and voting in one never does, and sending a
              signed-out reader into a login wall unannounced is the "unpredictable
              outcome" failure. (`/about` keeps its **See how it works** — its CTA is
              246px clear of the footer and About → How it works is a real reading order,
              not a duplicate.)

              No `mt-auto`; it opened a void on the sibling pages.

              **No `→`.** This read `Start something →` while `/how-it-works`' identical
              button read `Start something` and the home bar reads `Start something +` —
              three affixes on one action, which makes a reader wonder what the third one
              does differently. The two standing pages now agree on the bare label. Home
              keeps its `+`: frame `00` draws it, and it is a *create* glyph on the app's
              primary create control rather than a directional affix on a link to it. --%>
        <div class="flex flex-col gap-2 pt-1">
          <.button
            variant="primary"
            class="w-full"
            id="privacy-cta"
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
