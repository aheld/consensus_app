defmodule ConsensusWeb.AboutLive do
  @moduledoc """
  `/about` — one of the three standing pages `ConsensusWeb.Chrome.footer/1` links to.

  There is **no design frame** for this page; plan ruling 7 settles only that `/about`
  and `/privacy` are "short, honest, real pages". So it borrows `00b`'s shell — surface
  background, 30px `h1`, the same column padding — and says two things: what the product
  is for, and what it deliberately does not do. The second half is not modesty, it is the
  copy rule: this app has no place search, no notifications and no saved friend groups,
  all three are Post-MVP by CLAUDE.md's scope discipline, and a marketing page that
  implies otherwise sets somebody up to go looking for them.

  `back` is `@return_to`, not `~p"/"` — this page is reachable from the footer of every
  screen in the app, so a hard-coded `/` sends an organizer mid-wizard to the home list.
  No `context` on the header: the body's eyebrow already says "About us" (plan ruling 9).
  """

  use ConsensusWeb, :live_view

  import ConsensusWeb.CurrentPath, only: [return_to: 1]

  alias Consensus.Feedback.Entry

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "About")
     |> assign(:og_title, "About Consensus")
     |> assign(
       :og_description,
       "A small tool for settling where a group is eating. Built in Philadelphia."
     )
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
      <div class="flex flex-1 flex-col gap-[18px] px-5 pb-3 pt-[18px]">
        <div class="flex flex-col gap-[7px]">
          <.eyebrow>About us</.eyebrow>
          <h1 class="text-[30px] font-bold leading-[1.05] tracking-[-0.03em]">
            Stop the group chat spiral.
          </h1>
          <p class="text-[13.5px] leading-[1.45] text-ink-soft">
            Somebody puts the options up, everybody taps the ones they'd be happy with,
            and a hard deadline picks the winner. Nobody has to be the person who decides,
            and nobody has to install anything to vote.
          </p>
        </div>

        <.sticker_card class="flex flex-col gap-2 p-3.5">
          <.eyebrow>What it doesn't do</.eyebrow>
          <p class="flex gap-[9px] text-[12.5px] leading-[1.4]">
            <span class="font-bold text-violet" aria-hidden="true">·</span>
            <span>
              It doesn't search for restaurants. You add the options yourself, by name or
              by pasting a link.
            </span>
          </p>
          <p class="flex gap-[9px] text-[12.5px] leading-[1.4]">
            <span class="font-bold text-violet" aria-hidden="true">·</span>
            <span>
              It doesn't send notifications or texts. The share link is how people find out.
            </span>
          </p>
          <p class="flex gap-[9px] text-[12.5px] leading-[1.4]">
            <span class="font-bold text-violet" aria-hidden="true">·</span>
            <span>
              It doesn't remember your friends between sessions. Every vote starts from one link.
            </span>
          </p>
        </.sticker_card>

        <p class="text-[12.5px] leading-[1.45] text-muted">
          Built in Philadelphia. It's early — if something is broken or confusing, the two
          faces in the footer go straight to the people working on it. (The voting screens
          leave them off on purpose: every link off a ballot would discard the picks you
          had made.)
        </p>

        <%!-- One forward action and no body-level back: the header's `‹` is this
              screen's only way back (plan ruling 1) and it returns to wherever the
              footer link was tapped, which `~p"/"` could not.

              No `mt-auto`: it opened 215px of void between the last paragraph and the
              button at 420×900. `/how-it-works` had the same wrapper removed for a third
              of that gap, and leaving it here made the three standing pages disagree
              about where their CTA sits.

              `return_to: ~p"/about"` and not `@return_to`, which is for the header's `‹`
              alone. Passing the inherited value on an *outgoing* link sends the reader
              somewhere that thinks they came from wherever /about was opened from, so
              its `‹` skips the page they were just reading. --%>
        <div class="flex flex-col gap-3 pt-1">
          <.button
            variant="primary"
            class="w-full"
            navigate={~p"/how-it-works?#{[return_to: ~p"/about"]}"}
          >
            See how it works <span aria-hidden="true">→</span>
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
