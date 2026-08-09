defmodule ConsensusWeb.Chrome do
  @moduledoc """
  The global header and footer every screen in this app now wears (D-041).

  Built from design frame `4a`
  (`docs/design/screens/4a-0-pair-in-the-footer-header-drops-to-recommended.html`) and
  the rulings in `docs/plans/chrome-and-feedback.md`, which together reversed D-032's
  "every screen draws its own header". The header keeps to two controls — a back circle
  and an overflow `⋯` — with the wordmark between them and a right-aligned DM Mono
  context slot that is the one thing each screen still fills in for itself
  (`STEP 2 OF 3`, `LIVE SESSION`, `ADMIN`) — and only *that*: a context string that
  repeats what the screen's own eyebrow already says is the same word twice in the same
  treatment, so where the body names the screen, the slot stays empty. The footer carries
  the feedback pair, the three standing links, and the two credit lines — except on
  `:public`, where it is the credits alone.

  ## Three variants

    * `:app` — this app's own screens, signed in or out. Back circle (when `back` is
      given), wordmark, context slot, and the `⋯` menu, whose contents adapt: a
      signed-in visitor gets their email, Admin (administrators only), Settings and Log
      out; a signed-out one gets Log in and Start something (plan ruling 4). The auth
      screens are `:app` too — they are app screens a signed-out person is standing on,
      not marketing.
    * `:public` — the `/join` tree, reached from a shared link by someone who may have
      no account and needs none (CLAUDE.md product invariant 1). No `⋯`, and the
      context slot is replaced by the yellow **Create your own →** pill (plan ruling 2).
      Yellow at rest, not tangerine: tangerine is the one forward action on a screen,
      and on the ballot that is "Send my votes". It goes tangerine on hover, which is
      a hover state rather than a second resting call to action. The wordmark is inert
      here — see "The `/join` tree is not a place you leave by accident" below.
    * `:marketing` — `/`, `/about`, `/privacy`, `/how-it-works` and `/feedback` **while
      signed out** (plan ruling 3). Same shape as `:public` but with a plain `Log in`
      link in place of the pill (labelled `Sign in` until D-048 gave the destination one
      name across all four controls that reach it): on `/` the tangerine belongs to "Start something", and a
      second pill offering the same thing would only compete with it. Signed in, those
      same routes render `:app` instead, because a signed-in person needs the account
      menu and has nothing to sign into.

  **The `⋯` a signed-in reader gets on the four standing pages is deliberate, and it is
  the one place a critic keeps reading it as a slip**, because neither `00b` nor `00c`
  draws it and ruling 3 drops it on `:marketing`. It is kept for the reason D-032/D-041
  settled the whole chrome on: **this app has no global navigation bar**, so the `⋯` is
  the only route anywhere to Settings, Admin and Log out. The standing pages are reached
  from the footer of *every* screen, including mid-flow ones, so dropping it there would
  mean a tap on "Privacy" silently removes the reader's only way to reach their account or
  sign out until they find their way back into the app — a way out that disappears is the
  "no way back" failure, and it would be caused by the control that is supposed to prevent
  it. Ruling 3's argument is specifically about the *signed-out* header, where the second
  door would compete with the body's own "Start something"; a signed-in reader has no such
  competing control and nothing to sign into.

  ## Not a `Layouts.app/1` caller's job to remember

  `ConsensusWeb.Layouts.app/1` renders both of these itself, around the screen's own
  content, so a new screen cannot forget them. A screen contributes `back` (or
  `back_patch`), `context`, `variant` and `current_path` through `Layouts.app/1`'s
  attributes of the same names; the components here are public and imported app-wide so
  a test (or a future non-`Layouts.app` surface) can render them directly.

  ## Nothing in this bar points at where you already are

  `current_path` comes from `ConsensusWeb.CurrentPath`, an `on_mount` hook declared once
  in `ConsensusWeb.live_view/0` so no `live_session` has to remember it. Four things here
  need it, and the rule behind all four is the same — a control that goes nowhere is the
  confusion this chrome exists to remove, not a harmless no-op:

    * the `⋯` menu drops the entry pointing at the page you are standing on. **All of
      them**: Log in on the log-in form, Start something on the register form, Settings on
      Settings, Admin on `/admin/users`. The signed-in pair shipped without the guard and
      the docs claimed it anyway;
    * the whole `⋯` is dropped when it would open on a single entry. Signed out it holds
      only Log in and Start something, so on either auth screen one survives — and that one
      duplicates the form's own "Already have one? Log in" 40px below it;
    * the wordmark goes inert (see `wordmark_link?/1`) on any screen that has a `‹` at all,
      and on `/` itself. It is a link home only where there is no back control, which is
      where a home affordance earns its place;
    * `footer/1` drops the standing link for the page being rendered, drops the whole mood
      pair on `/feedback` itself, and hangs `?return_to=` off the rest so a
      standing page comes back to where it was tapped rather than to `/`. An inbound
      `return_to` is passed through rather than wrapped, so three footer hops still return
      to the wizard step the visitor started from, and no link is ever handed a `return_to`
      pointing at its own route (see `return_to_for/2`);
    * the `⋯` drops Settings **and** Admin while a signed-in visitor is standing on
      `/users/log-in`, which happens only when an expired sudo window bounced them there to
      re-authenticate (see `reauth_screen?/2`).

  **One route in this app does not wear the chrome, and it cannot:**
  `/admin/dashboard` is `Phoenix.LiveDashboard`, a third-party LiveView that declares
  its own `live_session` *and its own layout*, so `Layouts.app/1` never runs for it and
  wrapping it means forking somebody else's LiveView. It has no configurable "back to
  your app" link either (`home_app:` only labels the app on its own home page — checked
  in a browser). Accepted, not worked around: nothing in `lib/` links there, it is
  reachable only by typing the URL, and an administrator who typed a URL has a back
  button. The two places that *do* tell an operator to open it — `README.md`'s route
  table and `TODO.md`'s first-deploy checklist — now say so and name the back button, so
  the exemption is stated where somebody actually meets it rather than only here. Read
  "every screen" in this moduledoc as "every screen this app renders".

  ## One back affordance, and it lives here

  Plan ruling 1: the frames stack two back controls on the wizard steps, and that is a
  mistake in the comp. `Sticker.step_progress/1` has lost its chevron and the route it
  carried is now this header's `back`; `02b`'s `✕` is this header's `back` as well. A
  screen that draws its own second way back is a regression — including a body-level
  "Back to …" link or a form's "Cancel" that resolves to the same route as the `‹`.

  `back` is a `navigate` by default. A screen whose back destination is *itself* — the
  option editor closing to its own pool — passes `back_patch` instead, so the socket,
  its streams and any in-flight `start_async` survive.

  ## The `/join` tree is not a place you leave by accident

  A guest's ballot lives entirely in socket assigns until `Voting.cast_ballot/3` runs,
  and a guest has no account and no history of the group: every link off that screen
  throws the selections away and there is no route back except the original share link
  in whatever chat app they came from. So on `:public` the header's wordmark is plain
  text rather than a link to `/`, and `footer/1` drops the feedback pair and the three
  standing links, keeping only the credits. The `Create your own →` pill is the one
  deliberate door out, and it is labelled as one. Product invariant 1 and the "guest
  drop-off under 5%" metric are both measured on exactly this screen.

  The pill is also the *loudest* control on the ballot — ink border and `shadow-sticker-2`
  while "Send my votes" is a disabled peach until a card is tapped — so on that one screen
  it carries a `data-confirm` (`pill_confirm`) once anything has been selected. Ruling 8
  settles that the pill is present; it does not settle that a reflexive tap may discard a
  ballot silently. `JoinLive.Ballot` passes the prompt and only while there is something to
  lose: on `/join/:slug` and `/join/:slug/results` there is nothing unsent, and the pill is
  a plain link there.

  ## The header is sticky; the footer is not

  `sticky top-0 z-40` on the header. Since plan ruling 1 deleted every screen's own back
  control, this header is the only way back and the only account menu on every screen in
  the app — a page taller than the viewport scrolling it away is a navigation dead end,
  not a cosmetic difference. The footer stays in the flow: pinning both would spend
  ~168px of a 760px phone viewport on chrome (48px header + 120.25px footer, measured at
  420×900 — the one number, also in D-041 and D-032's annotation).

  The flash group is `sticky top-[40px] z-30`, inside the same column and directly under
  this bar — see `ConsensusWeb.Layouts.flash_group/1` for why `fixed` failed here twice
  and why `static` failed a third time. `z-30` is below this header's `z-40` on purpose:
  the header is the only way back on every screen and nothing may cover it.

  ## Every dimension here is a border-box total, and the frames are content-box

  The design frames are standalone inline-styled HTML with no CSS reset, so a frame's
  `width:29px; border:2px solid …` **paints 33px**; this app runs Tailwind's preflight, so
  the same declaration written as `size-[29px] border-2` paints 29px. Every bordered
  control in this module reads the frame's number as the *painted total* — 29px circles,
  26px faces, a 2px border inside each — which is 4px tighter than the frame renders.

  **That is binding here specifically, and the reason is a container dimension, not
  uniformity.** `IMPORT-NOTES.md` §3.1 derives the header's 48px height from exactly this
  arithmetic (`29 + 8 + 9 + 2`), so a 33px `‹` makes frame `4a` contradict its own stated
  header height at 52px; §4.2's 97px footer is a set with its 26px faces, and this footer
  is already 23px over that budget. Both circles and both faces additionally carry
  expanded hit boxes, so the 4px buys no touch safety either. **Do not "fix" one of these
  four to the frame's painted size** — but do not read that as a rule about the app.
  D-041's blanket version of it was amended by D-046 and D-047, which re-cut four controls
  elsewhere (`1c-0`'s deck buttons, `00b`'s step badge, `00c`'s textarea and its mood pair)
  because the 4px there cost a touch target, a line of a field or a repeated element's
  rhythm and no container depended on it. Read D-041's table before assuming either way.

  ## Name collision, on purpose

  `header/1` here and `ConsensusWeb.CoreComponents.header/1` are both imported by
  `ConsensusWeb.html_helpers/0`, so a bare `<.header>` would be an ambiguous call.
  Nothing in `lib/` calls `CoreComponents.header/1` — it is the generator's page-title
  block and this design has never used it — and `<Chrome.header>` (the alias, also set
  up in `html_helpers/0`) is how `Layouts.app/1` reaches this one. If you ever want the
  CoreComponents one, call it fully qualified.
  """

  # NOT `use ConsensusWeb, :html`: html_helpers/0 imports this module, and a module that
  # imports itself while still being compiled fails — the same reason
  # `ConsensusWeb.Sticker` and `ConsensusWeb.CoreComponents` use `Phoenix.Component`
  # directly. Verified routes are therefore wired up by hand here too.
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ConsensusWeb.Endpoint,
    router: ConsensusWeb.Router,
    statics: ConsensusWeb.static_paths()

  alias Consensus.Accounts.Scope
  alias Phoenix.LiveView.JS

  @doc """
  The global header — back circle, wordmark, and then whatever the variant calls for.

  `back` is a path and is the screen's **only** back affordance. Omitted entirely when
  `nil` rather than rendered as a dead circle. `back_patch` is the same control done as
  a `live_patch`, for a screen whose back destination is its own LiveView; give one or
  the other, never both.

  ## Examples

      <Chrome.header back={~p"/"} context="STEP 1 OF 3" current_scope={@current_scope} />
      <Chrome.header back_patch={~p"/groups/12/options"} />
      <Chrome.header variant={:public} />
      <Chrome.header variant={:marketing} back={~p"/"} />
  """
  attr :variant, :atom,
    default: :app,
    values: [:app, :public, :marketing],
    doc: "see the moduledoc — `:app`, the `/join` tree's `:public`, or signed-out `:marketing`"

  attr :back, :string, default: nil, doc: "a path to navigate to; the control is omitted when nil"

  attr :back_patch, :string,
    default: nil,
    doc: "same control, as a `live_patch` — for a back destination inside the same LiveView"

  attr :context, :string,
    default: nil,
    doc: """
    the right-hand DM Mono slot — the frame's "LIVE SESSION". `:app` only, and it must
    never repeat a string the screen's own body already shows: it is for session or step
    state ("STEP 2 OF 3", "LIVE SESSION", "ADMIN"), not for the page's name, which the
    body's `<.eyebrow>` and `<h1>` are already saying 40px lower.
    """

  attr :current_scope, :map, default: nil, doc: "drives the ⋯ menu's contents"

  attr :current_path, :string,
    default: nil,
    doc: "suppresses any header link pointing at the page you are already standing on"

  attr :pill, :boolean,
    default: true,
    doc: """
    `:public` only — set `false` on the one screen whose *body* already carries the same
    offer at full size. `/join/:slug/results` does: its footer renders
    `#results-start-your-own`, a `Create your own →` to `/`, in every one of
    `footer_state/3`'s ten cells, and the pill above it was the identical label pointing at
    the identical path — one destination named twice on a screen whose only two controls
    those were (plan confusion class 5). The pill stays on `/join/:slug` and
    `/join/:slug/vote`, where the body has no such link and a guest mid-flow has no other
    route to the product.
    """

  attr :pill_confirm, :string,
    default: nil,
    doc: """
    `:public` only — a `data-confirm` prompt for the `Create your own →` pill. The ballot
    passes one once a guest has tapped anything, because the pill is a `navigate` to `/`
    and `@approved`/`@veto_id` live only in socket assigns.
    """

  attr :back_confirm, :string,
    default: nil,
    doc: """
    a `data-confirm` prompt for the `‹` control **and for every entry in the `⋯` menu**,
    the third member of the set with `pill_confirm` above and `Chrome.footer/1`'s
    `confirm`. `back` is a `navigate` (or a `patch` that re-seeds the form from storage),
    so on a screen holding unsaved text it throws the typing away exactly as a footer tap
    does — and it is the *closest* control to the form, so it is the one a reader reaches
    for first. A screen that passes `footer_confirm` and not this one has plugged the far
    door and left the near one open. Pass the same prompt to both, and only while there is
    something to lose.

    The `⋯` entries are on it because they are exits from this screen too: measured on
    `/groups/new` holding a typed title, the page carried seven `data-confirm` elements
    (the `‹` and six footer links) and the menu's Admin / Settings / Log out carried none —
    tapping Settings took the draft with it, silently. **`:marketing`'s `Log in` link
    (`#chrome-sign-in`) is on it too, and it was the last hole**: on `/feedback` signed out,
    with 100 characters typed, every other escape control on the page carried the prompt and
    that one carried `null`; clicking it and pressing Back returned an empty textarea. Every
    door out of a screen with a draft in it takes the same prompt, or the guard is
    decoration.
    """

  attr :class, :any, default: nil
  attr :rest, :global

  def header(assigns) do
    assigns =
      assigns
      |> assign(:wordmark_link?, wordmark_link?(assigns))
      |> assign(:padding_x, header_padding_x(assigns))

    ~H"""
    <%!-- `min-h-[48px]`: the height is otherwise set by the tallest child, so a screen
          with neither circle (signed-out `/`) rendered a 37.75px header and navigating
          to one that has them shifted the whole page down 10px. Frame `4a`'s header is a
          constant 48px. `sticky top-0 z-40` — see the moduledoc. The horizontal padding
          is not a constant — see `header_padding_x/1`. --%>
    <header
      class={[
        "sticky top-0 z-40 flex min-h-[48px] shrink-0 items-center gap-[9px]",
        "border-b-2 border-ink bg-white pb-[9px] pt-2",
        @padding_x,
        @class
      ]}
      {@rest}
    >
      <.link
        :if={@back || @back_patch}
        navigate={@back}
        patch={@back_patch}
        id="chrome-back"
        aria-label="Back"
        data-confirm={@back_confirm}
        class={[
          "relative grid size-[29px] shrink-0 place-items-center rounded-full border-2 border-ink",
          "text-[15px] font-semibold leading-none transition-colors",
          circle_hit_area(),
          "hover:bg-yellow active:bg-yellow"
        ]}
      >
        <span aria-hidden="true">‹</span>
      </.link>

      <%!-- Inert on `:public` (tapping the logo is the most reflexive gesture on a phone,
            and on the ballot it would throw away an unsent ballot — see the moduledoc) and
            inert whenever it would point at somewhere the header already goes: the `‹` sits
            9px to its left, and on the eight screens whose `back` is `/` the bar carried two
            links to `/` side by side, which is plan ruling 1's duplicate back affordance and
            confusion class 5. Also inert on `/` itself, where it is a link to the page you
            are standing on. See `wordmark_link?/1`. --%>
      <span
        :if={not @wordmark_link?}
        id="chrome-wordmark"
        class="inline-flex shrink-0 items-center gap-1.5"
      >
        <.wordmark variant={@variant} />
      </span>

      <.link
        :if={@wordmark_link?}
        navigate={~p"/"}
        id="chrome-wordmark"
        class="inline-flex shrink-0 items-center gap-1.5"
      >
        <.wordmark variant={@variant} />
      </.link>

      <span
        :if={@variant == :app}
        id="chrome-context"
        class="min-w-0 flex-1 truncate text-right font-mono text-[10.5px] font-medium text-muted"
      >
        {@context}
      </span>

      <%!-- Plan ruling 2. Yellow at rest so it never competes with the screen's own
            tangerine forward action; tangerine only on hover, alongside the 1px press. --%>
      <%!-- `data-confirm` when the screen asked for one: the pill is the loudest control
            on the ballot and one reflexive tap would discard an unsent ballot. It stays a
            pill rather than disappearing there, because plan ruling 8 makes it the guest's
            one labelled door out. --%>
      <%!-- `before:-inset-y-[10.5px]`: this is the only header control a signed-out guest
            on a phone ever sees, and it painted 117.5×27.8 — 16px under the 44px touch
            minimum. `box-sizing: border-box` plus `border-2` means the pseudo-element's
            containing block is the 23.8px *padding* box, so the inset is (44 − 23.8) / 2,
            not (44 − 27.8) / 2; see `circle_hit_area/0` for the same trap costing 4px
            there. 23.8 + 21 = 44.8, and the pill sits at y 8.6–36.4 in a 48px header, so
            the box lands at 0.1–44.9 and the header does not grow. --%>
      <.link
        :if={@variant == :public and @pill}
        navigate={~p"/"}
        id="chrome-create-your-own"
        data-confirm={@pill_confirm}
        class="press-2 relative ml-auto shrink-0 whitespace-nowrap rounded-full border-2 border-ink bg-yellow px-2.5 py-1 text-[10.5px] font-bold text-ink shadow-sticker-2 transition-colors before:absolute before:-inset-x-1 before:-inset-y-[10.5px] before:content-[''] hover:bg-tangerine hover:text-white"
      >
        Create your own <span aria-hidden="true">→</span>
      </.link>

      <%!-- Plan ruling 3: on a signed-out marketing page the forward action already
            lives in the body ("Start something"), so the header only offers the other door.
            No `on_path?` guard here: `/users/log-in` is an `:app` screen (D-041's variant
            table), so `:marketing` can never render on it and the guard was dead code. --%>
      <%!-- `min-h-[44px] px-2` with `-my-2` to cancel it: frame `00a` draws bare 600/11.5
            text with no border or background, which measured ~40×17px — under the 44px
            touch minimum, in the top-right corner of a phone, which is the hardest corner
            of a phone to hit accurately. A static mock cannot surface that. The negative
            margin keeps the anchor's *margin box* at 28px so this 48px header does not
            grow, while the hit area overflows into the header's own padding; the text
            itself does not move. `hover:text-tangerine` is frame `00a`'s
            `style-hover="color:#FF6A2B"` — the app had `hover:underline`, which was the
            one place a reader could tell the frame from the app — and `active:` beside it
            for the same reason the two circles carry `active:bg-yellow`: hover does not
            exist on touch, so on a phone this acknowledged a tap in no way at all. --%>
      <%!-- `data-confirm={@back_confirm}`, like the `‹` and every `⋯` entry. This was the
            **last** unguarded exit in the chrome and it is on the one standing page that is
            a form: measured on `/feedback` with 100 characters typed into `#entry_message`,
            every other escape control carried
            `data-confirm="Leave without sending? What you typed here isn't saved yet."` —
            the header `‹`, all three standing links, both mood faces and the outbound
            credit — and this one carried `null`. Clicking it and pressing Back returned
            `#entry_message.value === ""`. It is a `navigate`, so it destroys a draft exactly
            as its siblings do; a guard with one hole in it is decoration. --%>
      <.link
        :if={@variant == :marketing}
        navigate={~p"/users/log-in"}
        id="chrome-sign-in"
        data-confirm={@back_confirm}
        class="-my-2 ml-auto inline-flex min-h-[44px] shrink-0 items-center whitespace-nowrap px-2 text-[11.5px] font-semibold text-ink transition-colors hover:text-tangerine active:text-tangerine"
      >
        <%!-- **"Log in", not "Sign in".** One destination must not have two names one tap
              apart: this header's link, the `⋯` menu entry, `/users/register`'s in-page
              link and the destination's own `h1` all point at `~p"/users/log-in"`, and
              this was the only one of the four calling it something else. Same rule the
              register link three blocks down follows, and the same reasoning
              `privacy_live.ex` records for its own CTA — three affixes on one action makes
              a reader wonder what the third one does differently. --%>
        Log in
      </.link>

      <%!-- A `<details>` rather than a JS dropdown, carried over unchanged from the
            `Layouts.account_menu/1` this replaces (D-032): it works before LiveView
            connects and closes on Escape without any code of ours. --%>
      <%!-- `phx-click-away` closes it by tapping the page behind the panel, which on a
            phone is the gesture everyone reaches for first — `<details>` gives us Escape
            for free but there is no Escape key on a phone, and the only other dismissal
            was hitting the 29px ⋯ again. `JS.remove_attribute` rather than a backdrop
            element so nothing is layered over the screen's own controls. --%>
      <details
        :if={@variant == :app and menu_worth_opening?(@current_scope, @current_path)}
        id="chrome-menu"
        class="relative shrink-0"
        phx-click-away={JS.remove_attribute("open", to: "#chrome-menu")}
      >
        <summary class={[
          "relative grid size-[29px] cursor-pointer list-none place-items-center rounded-full",
          "border-2 border-ink text-[13px] font-bold leading-none transition-colors",
          circle_hit_area(),
          "hover:bg-yellow active:bg-yellow [&::-webkit-details-marker]:hidden"
        ]}>
          <span aria-hidden="true">⋯</span>
          <span class="sr-only">{menu_label(@current_scope)}</span>
        </summary>
        <div class="absolute right-0 top-[37px] z-30 w-56 rounded-2xl border-2 border-ink bg-white p-2 shadow-sticker-3">
          <%!-- Every entry, in both branches, is dropped when it points at the page you
                are already standing on. "Settings" while you are on Settings and "Admin"
                while you are on Admin are links to nowhere, exactly as "Log in" on the
                log-in form was; the signed-in pair simply shipped without the guard the
                signed-out pair had. --%>
          <%= if signed_in?(@current_scope) do %>
            <p class="truncate px-3 pb-2 pt-1 font-mono text-[11px] text-muted">
              {@current_scope.user.email}
            </p>
            <.link
              :if={
                Scope.admin?(@current_scope) and not on_path?(@current_path, ~p"/admin/users") and
                  not reauth_screen?(@current_scope, @current_path)
              }
              navigate={~p"/admin/users"}
              data-confirm={@back_confirm}
              class={menu_item_class()}
            >
              Admin
            </.link>
            <.link
              :if={
                not on_path?(@current_path, ~p"/users/settings") and
                  not reauth_screen?(@current_scope, @current_path)
              }
              href={~p"/users/settings"}
              data-confirm={@back_confirm}
              class={menu_item_class()}
            >
              Settings
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              data-confirm={@back_confirm}
              class={menu_item_class()}
            >
              Log out
            </.link>
          <% else %>
            <.link
              :if={not on_path?(@current_path, ~p"/users/log-in")}
              navigate={~p"/users/log-in"}
              data-confirm={@back_confirm}
              class={menu_item_class()}
            >
              Log in
            </.link>
            <.link
              :if={not on_path?(@current_path, ~p"/users/register")}
              navigate={~p"/users/register"}
              data-confirm={@back_confirm}
              class={menu_item_class()}
            >
              <%!-- D-047 §4 renamed this destination's label to `Start something` on `/`,
                    `/how-it-works` and `/privacy` and recorded it as "everywhere"; this
                    entry was the one that did not move, so the app's front door and the
                    menu one tap above it named the same registration screen two ways. --%>
              Start something
            </.link>
          <% end %>
        </div>
      </details>
    </header>
    """
  end

  # The icon-plus-name pair, extracted only because it is rendered twice — once inside a
  # `<.link>` and once inside a plain `<span>` on `:public`.
  attr :variant, :atom, required: true

  defp wordmark(assigns) do
    ~H"""
    <img
      src={~p"/images/icon.svg"}
      alt=""
      aria-hidden="true"
      width={wordmark_icon_px(@variant)}
      height={wordmark_icon_px(@variant)}
      style={"width:#{wordmark_icon_px(@variant)}px;height:#{wordmark_icon_px(@variant)}px"}
    />
    <span class={["font-bold text-ink", wordmark_text_class(@variant)]}>Consensus</span>
    """
  end

  # Frame `4a` draws the app wordmark at 19px/13px, and so does frame `00a`, which
  # ruling 3 makes the signed-out marketing header. Only frame `1c` — ruling 2's
  # `/join` header — draws it a touch smaller at 18px/12.5px.
  #
  # `:marketing` sat on the 18px pair until the cleanup round, which meant `/` grew its
  # own wordmark by 1px the moment you signed in and the same bar changed size under a
  # visitor who had done nothing to it. `:marketing` and `:app` are the same routes
  # (`/`, `/about`, `/privacy`, `/how-it-works`, `/feedback`) seen signed out and signed
  # in, so they must draw the wordmark identically; `:public` is a different set of
  # screens and keeps its own size.
  defp wordmark_icon_px(:public), do: 18
  defp wordmark_icon_px(_variant), do: 19

  defp wordmark_text_class(:public), do: "text-[12.5px]"
  defp wordmark_text_class(_variant), do: "text-[13px]"

  # The frames do not use one horizontal header padding, and the difference is not arbitrary:
  # `IMPORT-NOTES.md` §3.2's variant table gives **13px** to every header that opens with a
  # 29px circle (the wizard steps, `00b`, `00c`, frame `4a` itself) and **20px** to the two
  # that do not (`00a` splash `6px 20px 8px`, `00` home signed in `8px 20px 10px`), with the
  # `1c` public header at 14px. 13px is where a *circle* has to sit for its glyph to line up
  # with the 20px page gutter below; on a header with no circle it puts the wordmark 7px left
  # of every card in the body, which is the one place the bar visibly leaves the content grid.
  # Applying 13px to all three variants is what shipped, and `/` — the app's most-visited
  # screen, signed in and signed out — is exactly the case it got wrong.
  defp header_padding_x(%{back: back}) when is_binary(back), do: "px-[13px]"
  defp header_padding_x(%{back_patch: patch}) when is_binary(patch), do: "px-[13px]"
  defp header_padding_x(%{variant: :public}), do: "px-[14px]"
  defp header_padding_x(_assigns), do: "px-5"

  # `current_path` carries the query string (`/feedback?mood=sad`), because the footer
  # needs it verbatim as a `return_to`. Route comparisons want it gone.
  defp on_path?(nil, _path), do: false

  defp on_path?(current_path, path) when is_binary(current_path),
    do: path_only(current_path) == path

  defp path_only(current_path), do: current_path |> String.split("?", parts: 2) |> hd()

  # The wordmark is a link home only on a screen that has no back control at all — which is
  # where a "home" affordance actually earns its place. Four cases make it inert:
  #
  #   * `:public` — the ballot case in the moduledoc: a reflexive tap on the logo would
  #     discard an unsent ballot;
  #   * **any** `back`, and any `back_patch`. The first cut only suppressed `back == "/"`,
  #     so mid-wizard (`/groups/:id/options`, `/groups/:id/review`) the bar carried two
  #     unlabelled exits 9px apart going to *different* places — the `‹` one step back, the
  #     wordmark abandoning the wizard entirely. That is ruling 1's duplicate back
  #     affordance and confusion class 5 in a subtler form than two identical destinations,
  #     not a milder one: a user who cannot predict which of two adjacent controls does what
  #     is worse off than one who cannot tell them apart. The `‹` is the screen's one exit;
  #   * `/` itself, where it would be a link to the page you are standing on.
  defp wordmark_link?(%{variant: :public}), do: false
  defp wordmark_link?(%{back: back}) when is_binary(back), do: false
  defp wordmark_link?(%{back_patch: back_patch}) when is_binary(back_patch), do: false
  defp wordmark_link?(%{current_path: current_path}), do: not on_path?(current_path, "/")

  # A `⋯` that opens to reveal a single link the body already carries 40px lower reads as
  # broken. Signed in the menu always earns its place (the email line plus Log out are never
  # suppressed); signed out it holds only Log in and Start something, so on either auth screen
  # exactly one entry survives `on_path?` — and that one duplicates "Already have one? Log
  # in" / "Don't have an account? Sign up" in the form below it.
  defp menu_worth_opening?(scope, current_path) do
    if signed_in?(scope) do
      true
    else
      not (on_path?(current_path, "/users/log-in") or on_path?(current_path, "/users/register"))
    end
  end

  # `/users/log-in` renders for a *signed-in* visitor in exactly one situation: a sudo
  # window expired and `UserAuth`'s `:require_sudo_mode` hook bounced them here to
  # re-enter their password. The rendered path is then `/users/log-in`, so `on_path?/2`
  # comparing against `/users/settings` never fired and the ⋯ kept offering Settings —
  # tapping which bounced straight back to this identical screen with the identical
  # flash. A two-tap loop with no signal that it was one.
  #
  # Admin goes with it. It does not loop (an administrator may read `/admin/users`
  # without sudo), but it is the other half of the same trap: both entries lead to
  # screens that will refuse the work the visitor came to do until this form is filled
  # in, and offering them from the screen that exists to collect the credential is
  # offering a way to abandon the task. The email line and Log out stay, so the menu
  # still earns its place.
  defp reauth_screen?(scope, current_path),
    do: signed_in?(scope) and on_path?(current_path, "/users/log-in")

  defp signed_in?(%{user: user}) when not is_nil(user), do: true
  defp signed_in?(_scope), do: false

  defp menu_label(scope) do
    if signed_in?(scope), do: "Account menu for #{scope.user.username}", else: "Menu"
  end

  # `min-h-[44px]` and `flex`, not `block` + `py-2`: these measured 204×36, and unlike the
  # deadline chips (wide, in a row of same-kind choices) these are three stacked entries in a
  # narrow panel where the neighbours do different things and one of them is Log out. Ruling 4
  # calls the `⋯` menu undrawn — there is no frame height to deviate from here.
  defp menu_item_class,
    do:
      "flex min-h-[44px] items-center rounded-xl px-3 text-sm font-semibold hover:bg-yellow active:bg-yellow"

  @doc """
  The global footer — the feedback pair, the three standing links, the two credits.

  Both faces link to the same `/feedback` form, pre-set to a mood, so one tap already
  says which way the visitor feels. Every link carries `?return_to=` when `current_path`
  is given, so a tap from step 2 of the wizard comes back to step 2 rather than dumping
  the organizer at `/`.

  **On `:public` the pair and the standing links are not rendered at all** — only the two
  credit lines are. See the moduledoc: on the `/join` tree these five links are five ways
  to silently discard an unsent ballot, on the one screen the product's own drop-off
  metric is measured on, for a guest who has no account and no route back.

  **On `/feedback` the pair is not rendered either**, for the narrower version of the same
  reason — see `show_mood_pair?/2`.

  **Every one of these is a `navigate`,** so on a screen holding text nobody has saved yet
  a tap remounts the LiveView and the typing is gone with no confirm and no undo — and the
  `?return_to=` then brings the visitor back to an *emptied* form, which is what makes the
  round trip read as safe. `confirm` is the escape hatch, the same mechanism
  `Chrome.header/1`'s `pill_confirm` gives the ballot: a screen with unsaved input passes a
  prompt and every control in this footer picks it up.

  ## Examples

      <Chrome.footer current_path={@current_path} />
      <Chrome.footer variant={:public} />
      <Chrome.footer current_path={@current_path} confirm={@draft != "" && "Discard what you typed?"} />
  """
  attr :variant, :atom, default: :app, values: [:app, :public, :marketing]

  attr :current_path, :string,
    default: nil,
    doc: "where to come back to; omitted from the links when nil"

  attr :confirm, :string,
    default: nil,
    doc: """
    a `data-confirm` prompt applied to **every** control in this footer — both mood faces,
    the three standing links and the outbound credit. Pass one from any screen that holds
    text the visitor has not saved, and only while there is something to lose, exactly as
    `JoinLive.Ballot` passes `pill_confirm` only once a card has been tapped. `nil` (the
    default) leaves the footer as plain links.
    """

  attr :class, :any, default: nil
  attr :rest, :global

  def footer(assigns) do
    # Computed once: `standing_links/1` was called twice per render, once in a `:if` that
    # could never be false (it rejects at most one of three entries, so the list is never
    # empty) and once in the `:for` beside it.
    assigns =
      assigns
      |> assign(:standing_links, standing_links(assigns.current_path))
      |> assign(:show_mood_pair?, show_mood_pair?(assigns.variant, assigns.current_path))

    ~H"""
    <%!-- `pt-[7px] pb-[9px]` and the 26px/15px/8px row below: `docs/design/IMPORT-NOTES.md`
          §4.2 resolves the one measurement frame `4a` disagrees with all eleven real screen
          frames on — `4a` draws the pair at 28px with a 16px glyph, a 9px gutter, an 11px
          label and `10px 14px 11px` of container padding, and the note rules that "4a is an
          enlarged schematic of the pattern, not a screen. Build the 26px version." This
          footer was built from `4a` and is now the screen frames'.

          The one part of §4.2 deliberately **not** taken is the container's `gap:2px`, which
          stays at `gap-2` (8px). The three link rows carry 26px hit boxes made out of
          `min-h` plus a cancelling negative margin, and for those the overlap between two
          adjacent rows is exactly `2 × margin − gap`: at `-my-1` and an 8px gap that is 0
          (measured — `About us` ends at y=1173 and the `marketfinder` line starts at
          y=1173), and at the frame's 2px gap it would be 6px of every link row silently
          owned by the row beneath it. Taking the frame here would reinstate the defect the
          padding was added to remove; the cost is 18px of footer height, recorded in D-041. --%>
    <footer
      class={[
        "flex shrink-0 flex-col items-center gap-2 border-t-2 border-ink bg-surface",
        "px-[14px] pb-[9px] pt-[7px]",
        @class
      ]}
      {@rest}
    >
      <div :if={@show_mood_pair?} class="flex items-center gap-2 pb-[2px]">
        <span class="text-[10.5px] font-semibold text-ink-soft">How's this going?</span>
        <%!-- The two faces get their own `gap-6` rather than sharing the row's `gap-2`,
              and it buys the one thing that actually matters here. The frame's 8px gutter
              left each face's hit box able to grow only 4px sideways before the two met,
              so two targets that file **opposite** moods had about a pixel of clearance
              between them — a thumb landing in the middle filed the wrong one. 24px lets
              each box take 8px a side (`-inset-x-2` on `mood_face/1`) and still leaves 8px
              of dead space between them. The painted circles and the footer's height are
              unchanged; the row grows 16px, which at 360px wide it has (measured: the pair
              plus its caption occupies 194 of the 332px inside the footer's gutters). --%>
        <div class="flex items-center gap-6">
          <.mood_face
            mood="happy"
            href={with_return_to(~p"/feedback?mood=happy", @current_path)}
            confirm={@confirm}
            fill="bg-mint"
            label="Something's going well — tell us"
            mouth="M8 14.6c1 1.2 2.4 1.8 4 1.8s3-.6 4-1.8"
          />
          <.mood_face
            mood="sad"
            href={with_return_to(~p"/feedback?mood=sad", @current_path)}
            confirm={@confirm}
            fill="bg-peach"
            label="Something's wrong — tell us"
            mouth="M8 16.4c1-1.2 2.4-1.8 4-1.8s3 .6 4 1.8"
          />
        </div>
      </div>

      <%!-- The entry for the page you are standing on is dropped, and the `·` separators
            are rendered *between* what survives rather than hard-coded around three fixed
            links. Left in, "How it works" in the footer of `/how-it-works` navigated to
            `/how-it-works?return_to=/how-it-works?return_to=…` — after which the header's
            `‹` landed on a byte-identical screen and the real destination was two presses
            away with nothing on screen saying so. --%>
      <%!-- `hover:text-tangerine`, not `hover:underline`: frames `00a`
            (`1b-0-00a-intro-start-page.html`) and `03 review pool`
            (`1a-4-03-review-pool.html`) both carry `style-hover="color:#FF6A2B"` on these,
            and the underline was the one place in the chrome a reader could tell the app
            from the frame. (Frame `4a` carries no `color:#FF6A2B` at all — its only two
            `style-hover` values are the footer faces' press transform — so do not cite it
            here.) Tangerine appearing here does not spend the screen's one tangerine — that
            rule is about a *resting* call to action, and the pill on `:public` already goes
            tangerine on hover for the same reason. --%>
      <%!-- `-my-1 py-1 min-h-[26px]`: as bare 10.5px text these three measured ~15.8px tall —
            under WCAG 2.5.8 AA's 24px floor, and close enough to the marketfinder link below
            (22.8px centre to centre) that even the spacing exception did not save them. The
            negative margin cancels the padding, so the footer's height and the frame's 10.5px
            type are both unchanged. 26px is still 18px under the 44px platform minimum and
            there is no cheap way to close that — the row pitch *is* 26px, so any 44px box
            overlaps its neighbour by 18px whatever technique builds it. The deviation from
            p1-cleanup §9b ("pad them the way section 7 pads Sign in") is stated in D-041
            rather than papered over.

            **The vertical numbers here and the container's `gap-2` are one set — do not tune
            either alone.** Two stacked rows built this way overlap by `2 × margin − gap`, and
            an overlap is not cosmetic: the later element in DOM order wins `elementFromPoint`,
            so with `-my-1.5 min-h-[30px]` (an earlier cut) the bottom 4px of all three links
            navigated to the *outbound* marketfinder link instead. At `-my-1` and `gap-2` it
            is exactly 0 — re-measured at 420×900 on `/`: the links run y 1147–1173 and the
            marketfinder line 1173–1199, and an `elementFromPoint` sweep of every overlap
            rectangle finds none.

            The **horizontal** half was not part of that set and was tuned wrong. `gap-x-3`
            (12px) plus `px-1` on each link put 16px between "About us" and the `·` where
            `IMPORT-NOTES.md` §4.3 transcribes `gap:8px`, so the dots floated mid-gap instead
            of binding the row into one phrase, and the row measured 218px against the frame's
            178px. Horizontal boxes in a flex row cannot overlap however small the gutter is,
            so none of that extra width bought any touch safety: the 26px `min-h` is the whole
            touch target. `gap-x-2` and no `px-1`. --%>
      <nav
        :if={@variant != :public}
        aria-label="About this app"
        class="flex flex-wrap items-center justify-center gap-x-1 gap-y-2 text-[10.5px] font-semibold"
      >
        <span :for={{{label, path}, index} <- Enum.with_index(@standing_links)} class="contents">
          <span :if={index > 0} class="text-faint-soft" aria-hidden="true">·</span>
          <%!-- `px-1` **paired with `gap-x-1`**, which is why this is not the `px-1` the
                comment above threw out. That version kept `gap-x-3`, so the visual space
                between a label and its `·` went to 16px against IMPORT-NOTES §4.3's
                `gap:8px` and the dots floated mid-gap. 4px of padding plus a 4px gap is
                still exactly 8px of visual space — the frame is unchanged to the pixel —
                and each link's hit box is 8px wider for it. `Privacy` painted 36×26, 936px²
                and the smallest target in the chrome. Horizontal boxes in a flex row cannot
                overlap however small the gutter, so this axis is free; the vertical one is
                not, and D-041 records why. Do not change either number without the other.
                --%>
          <.link
            navigate={with_return_to(path, @current_path)}
            data-confirm={@confirm}
            class="-my-1 inline-flex min-h-[26px] items-center px-1 py-1 text-ink transition-colors hover:text-tangerine active:text-tangerine"
          >
            {label}
          </.link>
        </span>
      </nav>

      <p class="text-center font-mono text-[9.5px] text-muted">
        <.link
          href="https://marketfinder.us"
          target="_blank"
          rel="noopener noreferrer"
          data-confirm={@confirm}
          class="-my-1 inline-flex min-h-[26px] items-center py-1 text-violet transition-colors hover:text-tangerine active:text-tangerine"
        >
          also check out marketfinder.us
        </.link>
      </p>

      <p class="text-center font-mono text-[9.5px] text-muted">Made with ❤️ in Philadelphia</p>
    </footer>
    """
  end

  # One of the two faces. Both are plain links now — there is no inert branch, because the
  # one screen that needed one no longer renders the pair at all. See `show_mood_pair?/2`.
  attr :mood, :string, required: true
  attr :href, :string, required: true
  attr :fill, :string, required: true
  attr :label, :string, required: true
  attr :mouth, :string, required: true
  attr :confirm, :string, default: nil

  # The hit area grows on all four sides **by a different amount on each**, because every
  # direction runs out of room somewhere different and none of the neighbours may be damaged
  # to reach a round number. The painted face stays 26px (the screen frames' size, §4.2) and
  # the pseudo-element's containing block is the **22px padding box** (`box-sizing: border-box`
  # + `border-2`), the same trap `circle_hit_area/0` documents.
  #
  #   * sideways, `-inset-x-2` → 22 + 8 + 8 = **38px**, against a 24px gutter between the two
  #     faces (`gap-6` on their own wrapper in `footer/1`). These two mean *opposite*
  #     things, so an overlapping box would file the wrong mood — worse than a small target
  #     — and at the frame's 8px gutter the widest non-overlapping box was 30px with the two
  #     boxes touching, i.e. roughly a pixel of clearance between "this is going well" and
  #     "this is broken". Widening the gutter is what bought both the bigger box and 8px of
  #     dead space between them. Verified with an `elementFromPoint` sweep of the whole
  #     pair: zero points resolve to both faces.
  #   * up, `-top-[9px]`. The footer's own `border-t-2` + `pt-[7px]` is exactly 9px, so the box
  #     reaches the footer's outer edge and stops. One pixel more and a positioned
  #     pseudo-element would start winning taps on the screen's last line of content.
  #   * down, `-bottom-[6px]`. The standing-link row's box begins 6px below the face
  #     (`pb-[2px]` + the container's 8px `gap-2`, less the links' own `-my-1`). At the 11px
  #     that would make this 44px tall, the faces took 3px off all three links — measured, and
  #     `Privacy` fell to **23px**, under WCAG 2.5.8 AA's 24px floor. A positioned
  #     pseudo-element beats a static sibling regardless of DOM order, so the links cannot
  #     defend themselves.
  #
  # Net: a 26×26 painted circle in a **38 wide × 37 tall** hit box (22 + 8 + 8 across,
  # 22 + 9 + 6 down), up from 26×26 painted in 30×37, and 26×26 painted with no box at all
  # before that. An `elementFromPoint` sweep reports these one larger in each axis (39×38),
  # because it samples inclusive pixel centres — quote the CSS arithmetic, not the sweep,
  # and do not read "38×37" as width-last.
  #
  # 44×44 is still unreachable and the blocker is vertical, not horizontal: the standing-link
  # row starts 6px below the face, and the 11px of extra height 44 needs took 3px off all
  # three links, dropping `Privacy` to a measured **23px** — under WCAG 2.5.8 AA's 24px
  # floor. A positioned pseudo-element beats a static sibling regardless of DOM order, so
  # the links cannot defend themselves. The deviation is stated in D-041 rather than rounded
  # up to 44 in a comment.
  defp mood_face(assigns) do
    ~H"""
    <.link
      navigate={@href}
      id={"feedback-#{@mood}"}
      aria-label={@label}
      data-confirm={@confirm}
      class={[
        "press-2 relative grid size-[26px] shrink-0 place-items-center rounded-full border-2",
        "border-ink text-ink shadow-sticker-2",
        "before:absolute before:-inset-x-2 before:-top-[9px] before:-bottom-[6px]",
        "before:content-['']",
        @fill
      ]}
    >
      <.face mouth={@mouth} />
    </.link>
    """
  end

  # The pair is dropped whole on `/feedback`, the way `standing_links/1` drops the link for
  # the page it is standing on, and for a sharper version of the same reason: **`/feedback`
  # already carries this control.** The form's own two-state radio group is the mood, 44×44,
  # captioned "tap to switch" (frame `00c`); the footer pair three centimetres below it is a
  # second copy of one value, which is confusion class 5, and the two disagree the instant
  # the form's picker is used — the footer reads the *URL*, and the form deliberately does
  # not re-navigate when the radio changes.
  #
  # The first cut kept both faces and rendered the current mood inert instead. That fixed
  # the self-link but left the other face live — and it is a `navigate`, so tapping it
  # remounted `FeedbackLive` and silently destroyed whatever the visitor had typed.
  # Measured: 23 keystrokes into the message, one tap on the footer's opposite face, and the
  # textarea came back empty with no confirm and no undo. `FeedbackLive`'s own moduledoc
  # asks for exactly this fix and names `chrome.ex` as where it belongs.
  #
  # `:public` drops the pair for the wider version of the same rule (the moduledoc).
  defp show_mood_pair?(:public, _current_path), do: false
  defp show_mood_pair?(_variant, current_path), do: not on_path?(current_path, "/feedback")

  # The three standing links, minus whichever one points at the page being rendered.
  defp standing_links(current_path) do
    [{"About us", ~p"/about"}, {"How it works", ~p"/how-it-works"}, {"Privacy", ~p"/privacy"}]
    |> Enum.reject(fn {_label, path} -> on_path?(current_path, path) end)
  end

  # The two 29px header circles (`#chrome-back`, `#chrome-menu`'s `<summary>`) are the two
  # controls present on the most screens, and both measured 29×29 — 15px under the 44px
  # platform minimum. The painted circle must stay 29px: frame `4a`'s header is a constant
  # 48px and a 44px circle inside `pt-2`/`pb-[9px]` does not fit. So the *hit area* grows
  # instead, via a transparent pseudo-element inset on every side.
  #
  # **The inset is measured off the 25px padding box, not the 29px border box**, and getting
  # that wrong is what shipped a 40px hit area behind a comment claiming 44. An absolutely
  # positioned pseudo-element's containing block is its parent's *padding* box; these circles
  # are `box-sizing: border-box` with `border-2`, so 29 − 2 − 2 = 25 is what `inset` grows
  # from. 25 + 9.5 + 9.5 = 44 (verified in the browser: `getComputedStyle(el, '::before')`
  # reports 44×44 for both circles, and a 44×44 `elementFromPoint` sweep centred on each one
  # resolves entirely to the control). Growing from the padding box also means the box
  # reaches *less* far than the raw number suggests and nothing collides: measured on
  # `/groups/3/options`, `#chrome-back` paints to x=42, its `::before` ends at x=49.5, and
  # the wordmark starts at x=51.
  #
  # **Deliberately not `press-2` / `shadow-sticker-2`, against p1-cleanup.md §9b.** That
  # instruction was written from the app rather than the frame. Every 29px header circle in
  # `4a` and `4b` is `border:2px solid #17211C; border-radius:50%` with **no** `box-shadow` —
  # the only hard shadows in `4a` are on the two 28px footer faces. `shadow-sticker-2` would
  # paint a resting 2px shadow the frame does not have, and `press-2` alone is worse: its
  # `:hover` rule *adds* `--shadow-sticker-1` to an element that has none, so the circle would
  # grow a shadow on hover and lose it again on press.
  #
  # The gap §9b correctly identified is real, though — `hover:` does not exist on touch, so
  # these two gave no acknowledgement at all when tapped on a phone. `active:bg-yellow` closes
  # it using the colour frame `4b` already hovers these circles to (`#FFD84D` = `--color-yellow`),
  # so pointer and touch now agree and nothing is invented.
  defp circle_hit_area do
    "before:absolute before:-inset-[9.5px] before:content-['']"
  end

  # `?return_to=<where you were>`, appended to a path that may already carry a query
  # (`/feedback?mood=sad`). Nothing is appended when the path is unknown — the standing
  # pages fall back to `/`, which is what they did before this existed. The four standing
  # pages read it back through `ConsensusWeb.CurrentPath.safe_return_to/1`, which is what
  # keeps a hand-crafted `?return_to=https://elsewhere` from becoming an open redirect.
  #
  # When the current page is *itself* carrying a `return_to`, that value is passed through
  # rather than wrapped: hopping `/about` → `/how-it-works` → `/privacy` from a footer
  # otherwise nested one encoded URL inside the next, and each hop pushed the wizard step
  # the visitor actually came from one more `‹` press away.
  defp with_return_to(path, nil), do: path

  defp with_return_to(path, current_path) when is_binary(current_path) do
    case return_to_for(path, current_path) do
      nil ->
        path

      target ->
        separator = if String.contains?(path, "?"), do: "&", else: "?"
        path <> separator <> URI.encode_query(return_to: target)
    end
  end

  # `nil` means "append nothing", and there are two reasons for it.
  #
  # **A link never carries a `return_to` pointing at its own route.** On
  # `/feedback?mood=happy` the happy face emitted
  # `/feedback?mood=happy&return_to=%2Ffeedback%3Fmood%3Dhappy`: a link to the page being
  # rendered, whose `‹` then pointed at a byte-identical screen, so the real way out was two
  # presses away with nothing saying so. That particular case is gone — `show_mood_pair?/2`
  # drops the pair on `/feedback` outright — but the guard is the general form and it is not
  # dead: on `/about?return_to=%2Fprivacy` it is what stops the footer's Privacy link
  # carrying a `return_to` to Privacy, i.e. a `‹` back to the screen you just left to get
  # here. Pinned by "a link never inherits a return_to that points at itself" in
  # `chrome_test.exs`, which fails if this clause is removed.
  #
  # **`/feedback` is never an origin.** It is the one standing page that is a form, and the
  # only one the footer offers two doors into. Coming "back" to a form somebody already
  # navigated away from returns them to an empty form, not to what they were doing — so a
  # visitor who reached `/feedback` from step 2 of the wizard keeps step 2 as the origin
  # (that is `inherited_return_to/1`), and one who opened `/feedback` cold has no origin at
  # all and the standing pages fall back to `/`, exactly as they did before `return_to`
  # existed.
  #
  # **The cost, stated rather than hidden: on a page reached *from* `/feedback` the `‹` and
  # the device's own Back gesture go to different places.** From
  # `/feedback?mood=sad&return_to=%2Fgroups%2F19%2Foptions`, tapping `About us` lands on
  # `/about?return_to=%2Fgroups%2F19%2Foptions`, whose `‹` goes to the wizard step while
  # `history.back()` goes to `/feedback`. Two back affordances disagreeing is plan ruling 1's
  # own objection with the OS gesture standing in for the second control. It is accepted here
  # because the alternative is worse in the direction that matters: making `/feedback` an
  # origin sends the `‹` to an empty form the visitor already left, which is a `‹` that
  # *appears* to restore work and does not. Recorded in D-041.
  defp return_to_for(path, current_path) do
    target = inherited_return_to(current_path)

    cond do
      is_nil(target) -> nil
      path_only(target) == path_only(path) -> nil
      true -> target
    end
  end

  defp inherited_return_to(current_path) do
    with %URI{query: query} when is_binary(query) <- URI.parse(current_path),
         %{"return_to" => inherited} <- URI.decode_query(query),
         path when is_binary(path) <- ConsensusWeb.CurrentPath.safe_return_to(inherited) do
      path
    else
      _ -> if on_path?(current_path, "/feedback"), do: nil, else: current_path
    end
  end

  # The two feedback faces. An inline `<svg>` rather than `CoreComponents.icon/1`
  # because heroicons carries no smiling/frowning face at this weight, and the frame
  # specifies the geometry exactly (15px, viewBox 0 0 24 24, 2.2 stroke, r=1.2 eyes —
  # `IMPORT-NOTES.md` §4.2's screen-frame numbers, not `4a`'s enlarged 16px).
  # `currentColor` rather than the frame's literal `#17211C`, so no raw hex lands in a
  # template — the parent link carries `text-ink`.
  attr :mouth, :string, required: true

  defp face(assigns) do
    ~H"""
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
      <path d={@mouth} />
    </svg>
    """
  end
end
