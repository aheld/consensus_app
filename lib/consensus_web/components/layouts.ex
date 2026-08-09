defmodule ConsensusWeb.Layouts do
  @moduledoc """
  Layouts and the app shell.

  `app/1` is the canvas, the centred column, the flash group **and the global chrome**:
  `ConsensusWeb.Chrome.header/1` above the screen's content and
  `ConsensusWeb.Chrome.footer/1` below it (D-041, superseding D-032). It renders them
  itself rather than leaving it to each screen, so a new screen cannot ship without a
  way back or a way to the standing pages.

  What each screen still contributes is the *variable* part D-032's reasoning was
  really about: `back` (the one back affordance), `context` (the right-hand DM Mono
  slot — `STEP 2 OF 3`, `LIVE SESSION`, `ADMIN`), `variant` and `current_path`. The wizard's
  `Sticker.step_progress/1` bar, the option editor's Remove, the results screen's
  violet countdown block all still live in the screen's own body; the global header
  sits above them rather than replacing them.

  `avatar/1` is unchanged and still placed by the screens that want one in their body
  (`GroupLive.New`'s GROUP row). `account_menu/1` is gone — the header's `⋯` menu
  replaced it.
  """
  use ConsensusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

  `width` picks the column: `:phone` (the default) is the 440px column every design frame
  was drawn at; `:wide` is for the desktop organizer console, which is a genuinely
  different layout rather than the phone column stretched.

  `back`, `back_patch`, `context` and `variant` are handed straight to
  `ConsensusWeb.Chrome.header/1` — see that module for what each variant renders and when
  to pick which. `current_path` goes to both the header and the footer; pass
  `current_path={@current_path}`, which `ConsensusWeb.CurrentPath` puts in the assigns of
  every LiveView in this app.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :width, :atom, values: [:phone, :wide], default: :phone
  attr :background, :string, default: "bg-surface", doc: "canvas behind the column"

  attr :fill_viewport, :boolean,
    default: false,
    doc: """
    bound the column to the viewport (`.viewport-column`) instead of letting it grow
    (`min-h-dvh`), so a screen can put its own `min-h-0 overflow-y-auto` region inside
    `<main>` and have it actually scroll.

    Off by default, and it must stay off by default: on an ordinary screen the page is the
    scroller, which is what a phone browser handles best (the URL bar collapses, the
    momentum is native, nothing double-scrolls). Turn it on **only** for a screen whose
    design frame is itself a fixed-height device with `overflow:hidden` and one internal
    scroll track — today that is frame `1c-1`, the ballot's grid view and the swipe deck's
    end-of-deck summary, whose submit button is pinned below the pool by construction.
    Without a bound height somewhere in the chain, `flex-1 min-h-0 overflow-y-auto` on a
    descendant does nothing at all: an auto-height flex container grows to its content and
    there is never any overflow to scroll.

    **Two things a second adopter must do, and a third the class does for you.** Every
    sibling of the scroll track inside `<main>` needs `shrink-0`, or the browser will
    shrink the wrong thing; the track itself needs `min-h-0` *and* a `min-h-[…]` floor, so
    it cannot be squeezed to a slit. The third is the height gate: `.viewport-column`
    clamps only above 640px of viewport height and is a plain `min-height: 100dvh` below
    it, because `shrink-0` siblings are exactly what breaks a short viewport — an
    unconditional clamp pushed the ballot's submit button 59px past `<main>` and onto the
    footer on any phone in landscape. See the rule's own comment in `assets/css/app.css`.

    **This attribute does not, by itself, keep a screen's actions on screen, and reading it
    that way is what shipped D-049 §4.** Below the gate the page is the scroller and the
    submit block went back under the fold — 330.7px under it at 375×553, an iPhone SE in
    Safari. The companion is `.ballot-actions` / `.results-actions` in `assets/css/app.css`:
    `position: sticky; bottom: 0` on the block of controls, with the ballot's opt-out inside
    the **same** `@media (min-height: 640px)` block as the clamp so the two ranges cannot
    drift apart. A screen whose actions sit under a region that grows wants that class
    whether or not it wants this attribute — `ResultsComponents.results_panel/1` takes the
    class and passes no `fill_viewport` at all.
    """

  attr :variant, :atom, values: [:app, :public, :marketing], default: :app
  attr :back, :string, default: nil, doc: "the screen's one back affordance; nil omits it"

  attr :back_patch, :string,
    default: nil,
    doc: "the same control as a `live_patch`, when back lands in this same LiveView"

  attr :context, :string, default: nil, doc: "the header's right-hand DM Mono slot"

  attr :pill, :boolean,
    default: true,
    doc:
      "`:public` only — `false` drops the `Create your own →` pill; see `Chrome.header/1`'s attr"

  attr :pill_confirm, :string,
    default: nil,
    doc: "`:public` only — a `data-confirm` for the `Create your own →` pill; see `Chrome`"

  attr :back_confirm, :string,
    default: nil,
    doc: """
    a `data-confirm` for the header's `‹`; see `Chrome.header/1`. Pass it wherever you pass
    `footer_confirm` — the two are one decision, and the `‹` is the control nearer the form.
    """

  attr :footer_confirm, :string,
    default: nil,
    doc: """
    a `data-confirm` for **every** control in the footer — both mood faces, the three
    standing links and the outbound credit. Every one of them is a `navigate`, so on a
    screen holding unsaved text a tap remounts the LiveView and the typing is gone with no
    confirm and no undo, and the `?return_to=` then returns the visitor to an emptied form.
    Pass a prompt from any screen with a draft in it, and only while there is something to
    lose — the shape `JoinLive.Ballot` already uses for `pill_confirm`.
    """

  attr :current_path, :string,
    default: nil,
    doc:
      "`@current_path`, from `ConsensusWeb.CurrentPath` — drives return_to and self-link suppression"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- The outer element is a plain `<div>` and `<main>` holds only the screen's own
          content: the chrome's `<header>` is the page's `banner` landmark and its
          `<footer>` is `contentinfo`, and neither is either while nested inside `<main>`.
          Screens draw their own `<header>` rows too (HomeLive's "Your sessions"), which
          stay generic inside `<main>` exactly as they should. --%>
    <%!-- `.viewport-column`, not a bare `h-dvh`: the clamp is gated on the viewport being
          at least 640px tall, and below that the column falls back to `min-height: 100dvh`
          and the page is the scroller again. See the rule and its measurements in
          `assets/css/app.css` — an unconditional `h-dvh` painted `#submit-ballot` on top
          of the footer on any phone in landscape. --%>
    <div class={[
      "flex flex-col",
      @fill_viewport && "viewport-column",
      !@fill_viewport && "min-h-dvh",
      @background
    ]}>
      <div class={[
        "mx-auto flex w-full flex-col",
        @fill_viewport && "viewport-column",
        !@fill_viewport && "min-h-dvh",
        @width == :phone && "max-w-[440px]",
        @width == :wide && "max-w-[1280px]"
      ]}>
        <Chrome.header
          variant={@variant}
          back={@back}
          back_patch={@back_patch}
          context={@context}
          pill={@pill}
          pill_confirm={@pill_confirm}
          back_confirm={@back_confirm}
          current_scope={@current_scope}
          current_path={@current_path}
        />
        <%!-- The flash sits inside this column, between the header and the screen's own
              content, and is `sticky` rather than `fixed`. A `fixed` card at any hard-coded
              `top` collides with whatever each screen puts first: measured at `top-[56px]`
              it covered the `<h1>` on `/`, `/users/log-in`, `/admin/users` and step 2 of
              the wizard — and a flash is shown on exactly the screen a user lands on right
              after acting, which is the screen whose title matters most. It also centred
              itself on `document.scrollWidth` rather than the viewport, so on a page with
              any horizontal overflow its dismiss ✕ sat off-screen. See
              `ConsensusWeb.CoreComponents.flash/1` and `flash_group/1` below for why it is
              `sticky top-[40px] z-30` and not `static`. --%>
        <.flash_group flash={@flash} />
        <%!-- `min-h-0` so a screen that wants an internally-scrolling region gets one;
              `flex-1` so a short screen still pins the footer to the bottom edge and a
              tall one grows the page instead of double-scrolling inside it. --%>
        <main class="flex min-h-0 flex-1 flex-col">
          {render_slot(@inner_block)}
        </main>
        <Chrome.footer variant={@variant} current_path={@current_path} confirm={@footer_confirm} />
      </div>
    </div>
    """
  end

  @doc """
  The circular avatar the design puts in the top right of the home screen.

  Renders the first character of the username, so it is stable and needs no upload.
  """
  attr :user, :map, required: true
  attr :size, :integer, default: 34
  attr :class, :string, default: nil
  attr :rest, :global

  def avatar(assigns) do
    ~H"""
    <span
      class={[
        "grid shrink-0 place-items-center rounded-full border-2 border-ink bg-peach font-bold",
        @class
      ]}
      style={"width:#{@size}px;height:#{@size}px;font-size:#{round(@size * 0.38)}px"}
      aria-hidden="true"
      {@rest}
    >{initial(@user)}</span>
    """
  end

  defp initial(%{username: username}) when is_binary(username) and username != "",
    do: String.upcase(String.first(username))

  defp initial(_), do: "?"

  @doc """
  Shows the flash group with standard titles and content.

  **It is `sticky top-[40px] z-30`, and must not become `static` again.** In the flow it
  scrolls away with the page, and a flash is by definition shown right after an action —
  which on a page taller than the viewport is very often taken while scrolled down.
  Measured at 420×900 on `/admin/users` (`scrollHeight` 1177): from `scrollY = 345`,
  pressing Promote rendered the card at `top: -297px`, entirely above the viewport, so a
  privileged, audit-logged write produced no visible confirmation at all. The same
  container holds LiveView's `#client-error` / `#server-error` reconnect banners, so a
  dropped socket was silent for a scrolled reader too — including a guest mid-ballot.

  `40px` is `48px` — `Chrome.header/1`'s fixed height, measured — minus the `mt-2` that
  `CoreComponents.flash/1` carries, so the **card** parks at exactly 48px, flush under the
  header's bottom border. Offsetting the container by the header height instead pinned the
  card at 56px and left an 8px transparent slit that the page scrolled through: measured at
  420×400 on `/`, the row above showed its clipped title in the gap, which reads as a
  rendering fault rather than as spacing. The 8px lives above the container's pinned top,
  behind the header, where nothing can be seen through it. At rest nothing moves — the
  container's natural top is already 48px, so sticky only engages once the page scrolls.

  The two reconnect banners' titles are **not** the generator's. "Something went wrong!" was
  the only exclamation mark in this container, named nothing that had gone wrong and offered
  no way to fix it (three survive elsewhere — `UserSessionController`'s "Account created
  successfully!", "Welcome back!" and "Password updated successfully!", and the second of
  those renders *inside this container*, so do not read the removal as a house rule about
  punctuation); "We can't find the internet" asserted a cause it cannot know, blaming the
  reader's connection for what is usually the server or a dropped socket.

  Each title now names what the browser actually observed, and the two are deliberately
  **not** interchangeable. `#client-error` fires on `phx-disconnected` — the socket to this
  server is gone, hence "Lost the connection". `#server-error` fires when the server *answers*
  and rejects or errors the join, which is a crashed LiveView far more often than a network
  fault, so it says "This page hit an error"; calling that a dropped connection would be the
  same invented cause the generator's copy was replaced for. The useful half — "Attempting to
  reconnect" — is unchanged on both, because LiveView retries either way.

  `z-30` is deliberately **below** the header's `z-40` (the header is the only way back on
  every screen and nothing may cover it) and above anything a screen's own body stacks —
  the highest is `z-10`, in `JoinLive.Entry` and the ballot's veto badge.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="sticky top-[40px] z-30">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Lost the connection")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("This page hit an error")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
