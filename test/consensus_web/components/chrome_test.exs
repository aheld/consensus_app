defmodule ConsensusWeb.ChromeTest do
  @moduledoc """
  Coverage for `ConsensusWeb.Chrome` — the global header and footer D-041 put on every
  screen in this app — in two halves that catch genuinely different regressions.

  **The component half** (`header/1` and `footer/1` via `render_component/2`) pins the
  contract: which control exists in which variant, where each link points, which variant
  drops which control. `ConsensusWeb.Layouts.app/1` renders these for *every* LiveView, so
  a break here is a break on eighteen screens at once and belongs in one place rather than
  spread across the `live/` tree. Raw-HTML assertions rather than `element/2` because there
  is no LiveView to mount and the markup genuinely is the thing under test.

  **The route half** (`describe "the chrome each route asks for"`) pins the *wiring*, which
  the component half cannot see and which an earlier version of this file wrongly claimed
  the per-screen tests covered — they never mentioned a chrome id at all. Three concrete
  regressions were invisible until this table existed:

    * deleting `variant={:public}` from `join_live/ballot.ex` grows a guest's ballot a `⋯`
      account menu offering Log in / Start something, which product invariant 1 and plan ruling
      2 exist to prevent, and a footer full of links that discard an unsent ballot;
    * deleting `back` from `admin_live/users.ex` or `user_live/settings.ex` returns those
      screens to having no way out, which is the whole premise of D-041;
    * signed-out `/` falling back to `:app` puts a `⋯` on the marketing splash.

  All three left the suite green.
  """
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Accounts.Scope
  alias ConsensusWeb.JoinAuth

  defp signed_out, do: nil

  defp signed_in(attrs \\ %{}) do
    user =
      %Consensus.Accounts.User{
        id: 7,
        username: "alex",
        email: "alex@example.com",
        is_admin: false
      }
      |> struct(attrs)

    Scope.for_user(user)
  end

  defp header(assigns), do: render_component(&ConsensusWeb.Chrome.header/1, assigns)
  defp footer(assigns \\ %{}), do: render_component(&ConsensusWeb.Chrome.footer/1, assigns)

  describe "header/1 — the back control" do
    test "renders a back link when `back` is given" do
      html = header(%{back: "/groups/12/edit"})

      assert html =~ ~s(id="chrome-back")
      assert html =~ ~s(href="/groups/12/edit")
      assert html =~ ~s(aria-label="Back")
      assert html =~ "‹"
    end

    test "renders no back control at all when `back` is nil — never a dead circle" do
      html = header(%{back: nil})

      refute html =~ ~s(id="chrome-back")
      refute html =~ "‹"
    end

    test "`back_patch` renders the same control as a live_patch, not a redirect" do
      html = header(%{back_patch: "/groups/12/options"})

      # `patch` is what keeps the option editor's socket, stream and in-flight
      # link-preview task alive when it closes back to its own pool. Asserted on the
      # back link specifically — the wordmark beside it is a `navigate` either way.
      assert html =~
               ~s(href="/groups/12/options" data-phx-link="patch" data-phx-link-state="push" id="chrome-back")
    end

    test "is a constant 48px tall whether or not the circles render" do
      # The height was otherwise set by the tallest child, so signed-out `/` (no back,
      # no ⋯) drew a 37.75px header and navigating to any other screen shifted the page.
      for assigns <- [%{}, %{back: "/"}, %{variant: :public}, %{variant: :marketing}] do
        assert header(assigns) =~ "min-h-[48px]"
      end
    end

    test "is sticky and stacks above the flash group" do
      # `Layouts.flash_group/1` is `sticky top-[40px] z-30` and this is `z-40` — the header
      # is the only way back on every screen in the app and nothing may cover it, the flash
      # card least of all, since a flash is rendered on exactly the screen someone has just
      # landed on. The pair is asserted from both sides: see "it is sticky under the header"
      # below, which pins the `z-30` half against the rendered page.
      html = header(%{back: "/"})

      [attrs, _rest] =
        html |> String.split("<header", parts: 2) |> List.last() |> String.split(">", parts: 2)

      assert attrs =~ "sticky"
      assert attrs =~ "top-0"
      assert attrs =~ "z-40"
      refute attrs =~ "z-30"
    end

    test "both circles have a 44px hit area and acknowledge a tap" do
      # The painted circle stays 29px — frame `4a`'s header is a constant 48px — so the hit
      # area is a transparent `::before`. The inset is measured off the **25px padding box**
      # (`box-sizing: border-box` + `border-2`), not the 29px border box: `-inset-[7.5px]`
      # shipped once behind a comment claiming 44 and measured 40×40 in the browser.
      # 25 + 9.5 + 9.5 = 44. `active:` and not only `hover:`, because hover does not exist
      # on touch and these two were the only controls in the app that acknowledged a tap
      # with nothing at all.
      html = header(%{back: "/groups/12/review", current_scope: signed_in()})

      assert html =~ ~s(id="chrome-back")
      assert html =~ ~s(id="chrome-menu")

      # Once for the back circle, once for the ⋯ summary.
      assert html |> String.split("before:-inset-[9.5px]") |> length() == 3

      # Per circle, not app-wide. The first cut asserted `String.split("active:bg-yellow")
      # |> length() >= 3`, which `menu_item_class/0`'s two entries (Settings, Log out)
      # already satisfy on their own: stripping `active:bg-yellow` from BOTH circles left
      # the whole file green. `circle_hit_area/0` is the only thing on either circle, so
      # splitting on it isolates one circle per fragment.
      [_before, back_circle, menu_circle] = String.split(html, "before:-inset-[9.5px]")

      for {rest, which} <- [{back_circle, "back circle"}, {menu_circle, "⋯ summary"}] do
        # Everything up to the end of that element's own class attribute.
        rest_of_class = rest |> String.split(~s("), parts: 2) |> hd()

        assert rest_of_class =~ "active:bg-yellow",
               "the #{which} acknowledges a tap with nothing — hover does not exist on touch"
      end

      refute html =~ "before:-inset-[7.5px]"
      # Not `press-2` / `shadow-sticker-2`: every 29px header circle in frames `4a` and `4b`
      # is a 2px ink border with no box-shadow at all, and `press-2`'s hover rule *adds*
      # `--shadow-sticker-1`, so the circle would grow a shadow on hover and lose it on
      # press. See `circle_hit_area/0`.
      refute html =~ ~s(press-2 relative grid size-[29px])
    end

    test "the wordmark lines up with the page gutter on a header with no circle" do
      # `IMPORT-NOTES.md` §3.2's variant table gives 13px to every header that opens with a
      # 29px circle and 20px to the two that do not (`00a` `6px 20px 8px`, `00` home
      # `8px 20px 10px`), with the `1c` public header at 14px. 13px everywhere put the
      # wordmark 7px left of every card in the body on `/` — the app's most-visited screen,
      # signed in and signed out — which is the one place the bar leaves the content grid.
      for assigns <- [%{back: "/groups/12/review"}, %{back_patch: "/groups/12/options"}] do
        assert header(assigns) =~ "px-[13px]"
      end

      for assigns <- [%{}, %{variant: :marketing}, %{current_path: "/"}] do
        html = header(assigns)

        assert html =~ "px-5", "a header with no ‹ hangs the wordmark off the 20px gutter"
        refute html =~ "px-[13px]"
      end

      assert header(%{variant: :public}) =~ "px-[14px]"
    end
  end

  describe "header/1 — the :app variant" do
    test "renders the wordmark, the context slot and the ⋯ menu" do
      html = header(%{variant: :app, context: "STEP 2 OF 3", current_scope: signed_out()})

      assert html =~ ~s(id="chrome-wordmark")
      assert html =~ "Consensus"
      assert html =~ ~s(id="chrome-context")
      assert html =~ "STEP 2 OF 3"
      assert html =~ ~s(id="chrome-menu")
      assert html =~ "⋯"
    end

    test "is the default variant" do
      assert header(%{context: "ADMIN"}) =~ ~s(id="chrome-menu")
    end

    test "renders neither the public pill nor the marketing sign-in link" do
      html = header(%{variant: :app, current_scope: signed_in()})

      refute html =~ ~s(id="chrome-create-your-own")
      refute html =~ ~s(id="chrome-sign-in")
    end
  end

  describe "header/1 — the ⋯ menu's contents" do
    test "signed out offers the two ways in and nothing else" do
      html = header(%{current_scope: signed_out()})

      assert html =~ ~s(href="/users/log-in")
      assert html =~ "Log in"
      assert html =~ ~s(href="/users/register")
      # `Start something`, the label D-047 §4 gave this destination on `/`,
      # `/how-it-works` and `/privacy`. This entry was the one that did not move, so the
      # front door and the menu one tap above it named the same screen two ways.
      assert html =~ "Start something"
      refute html =~ "Get started"

      refute html =~ ~s(href="/users/settings")
      refute html =~ ~s(href="/users/log-out")
      refute html =~ ~s(href="/admin/users")
    end

    test "signed in offers the email, Settings and Log out — but not Admin" do
      html = header(%{current_scope: signed_in()})

      assert html =~ "alex@example.com"
      assert html =~ ~s(href="/users/settings")
      assert html =~ ~s(href="/users/log-out")
      assert html =~ "Account menu for alex"

      refute html =~ ~s(href="/admin/users")
      refute html =~ "Get started"
    end

    test "an administrator additionally gets the Admin link" do
      html = header(%{current_scope: signed_in(%{is_admin: true})})

      assert html =~ ~s(href="/admin/users")
      assert html =~ "Admin"
      assert html =~ ~s(href="/users/settings")
    end

    test "log out is a DELETE, not a plain link" do
      assert header(%{current_scope: signed_in()}) =~ ~s(data-method="delete")
    end

    test "drops the signed-in entry pointing at the page you are already standing on" do
      # This half shipped without the guard the signed-out half had, while both the
      # `Chrome` moduledoc and D-041 described the suppression as general. "Settings"
      # while you are on Settings is a link to nowhere.
      on_settings =
        header(%{current_scope: signed_in(%{is_admin: true}), current_path: "/users/settings"})

      refute on_settings =~ ~s(href="/users/settings")
      assert on_settings =~ ~s(href="/admin/users")
      assert on_settings =~ ~s(href="/users/log-out")

      on_admin =
        header(%{current_scope: signed_in(%{is_admin: true}), current_path: "/admin/users"})

      refute on_admin =~ ~s(href="/admin/users")
      assert on_admin =~ ~s(href="/users/settings")
    end

    test "a query string on the current path does not defeat the suppression" do
      html = header(%{current_scope: signed_in(), current_path: "/users/settings?foo=1"})

      refute html =~ ~s(href="/users/settings")
    end

    test "the whole menu is dropped when it would open on a single entry" do
      # Signed out the menu holds only Log in and Start something, so on either auth screen
      # exactly one survives — and that one duplicates the form's own "Already have
      # one? Log in" 40px below it. A ⋯ that opens to reveal one redundant link reads
      # as broken.
      for path <- ["/users/log-in", "/users/register"] do
        html = header(%{current_scope: signed_out(), current_path: path})

        refute html =~ ~s(id="chrome-menu"), "#{path} still renders a one-entry ⋯ menu"
      end

      # Anywhere else signed out, both entries survive and the menu earns its place.
      both = header(%{current_scope: signed_out(), current_path: "/groups/12/options"})
      assert both =~ ~s(id="chrome-menu")
      assert both =~ ~s(href="/users/log-in")
      assert both =~ ~s(href="/users/register")

      # Signed in it always earns its place: the email line and Log out are never
      # suppressed, whatever page you are on.
      assert header(%{current_scope: signed_in(), current_path: "/users/settings"}) =~
               ~s(id="chrome-menu")
    end

    test "drops Settings and Admin on the re-authentication screen" do
      # A signed-in visitor renders `/users/log-in` in exactly one situation: an expired
      # sudo window bounced them there. `on_path?/2` was comparing against
      # `/users/settings` while the rendered path was `/users/log-in`, so the ⋯ kept
      # offering Settings — and tapping it bounced straight back to this identical screen
      # with the identical flash. A two-tap loop with no signal that it was one.
      html =
        header(%{current_scope: signed_in(%{is_admin: true}), current_path: "/users/log-in"})

      assert html =~ ~s(id="chrome-menu")
      assert html =~ "alex@example.com"
      assert html =~ ~s(href="/users/log-out")

      refute html =~ ~s(href="/users/settings")
      refute html =~ ~s(href="/admin/users")
    end

    test "a signed-out visitor on the log-in form is unaffected — that menu is dropped whole" do
      refute header(%{current_scope: signed_out(), current_path: "/users/log-in"}) =~
               ~s(id="chrome-menu")
    end

    test "closes when the page behind it is tapped" do
      # `<details>` gives us Escape for free, and a phone has no Escape key: without
      # this the only dismissal was hitting the 29px ⋯ again.
      assert header(%{current_scope: signed_in()}) =~ "phx-click-away"
    end
  end

  describe "header/1 — the wordmark is inert where it would go nowhere new" do
    test "a `back` of / makes it plain text — the ‹ 9px away already goes there" do
      # Eight screens pass `back={~p"/"}`: the auth screens, /admin/users, /groups/new,
      # results, review-once-voting. They rendered two links to `/` in one 48px bar,
      # which is plan ruling 1's duplicate back affordance.
      html = header(%{back: "/"})

      assert html =~ ~s(<span id="chrome-wordmark")
      assert html |> String.split(~s(id="chrome-wordmark")) |> length() == 2
    end

    test "standing on / makes it plain text too — a link to the page you are on" do
      assert header(%{current_path: "/"}) =~ ~s(<span id="chrome-wordmark")
      assert header(%{variant: :marketing, current_path: "/"}) =~ ~s(<span id="chrome-wordmark")
    end

    test "ANY back makes it plain text, not only a back of /" do
      # The first cut only suppressed `back == "/"`, so mid-wizard the bar carried two
      # unlabelled exits 9px apart going to *different* places: `‹` one step back,
      # the wordmark abandoning the wizard for `/`. Both wizard steps are covered here.
      for assigns <- [
            %{back: "/groups/12/review", current_path: "/groups/12/share"},
            %{back: "/groups/12/options", current_path: "/groups/12/review"},
            %{back_patch: "/groups/12/options", current_path: "/groups/12/options/3"}
          ] do
        html = header(assigns)

        assert html =~ ~s(<span id="chrome-wordmark"),
               "#{inspect(assigns)} still renders a second exit beside the ‹"
      end
    end

    test "it is a link only on a screen with no back control at all" do
      # Which is where a "home" affordance actually earns its place: signed-in `/`
      # (no back), and any screen that simply passes none.
      html = header(%{current_path: "/some/screen/with/no/back"})

      assert html =~ ~s(<a )
      assert html =~ ~s(id="chrome-wordmark")
      refute html =~ ~s(<span id="chrome-wordmark")
    end
  end

  describe "header/1 — the wordmark is the same size signed in and signed out" do
    test ":app and :marketing draw 19px/13px; only :public is smaller" do
      # `/` is one route with two variants, so keying the size on `:app` alone grew the
      # wordmark by 1px the moment you signed in — the bar changed size under a visitor
      # who had done nothing to it. Frame `00a`, which ruling 3 cites for the marketing
      # header, draws 19/13 like `4a`; only ruling 2's `1c` header is the smaller pair.
      for variant <- [:app, :marketing] do
        html = header(%{variant: variant})

        assert html =~ ~s(width="19"), "#{variant} draws the icon at the wrong size"
        assert html =~ "text-[13px]", "#{variant} draws the wordmark at the wrong size"
      end

      public = header(%{variant: :public})

      assert public =~ ~s(width="18")
      assert public =~ "text-[12.5px]"
    end
  end

  describe "header/1 — the :public variant (the /join tree)" do
    test "renders the Create your own pill and drops the ⋯ menu entirely" do
      html = header(%{variant: :public, current_scope: signed_out()})

      assert html =~ ~s(id="chrome-create-your-own")
      assert html =~ "Create your own"
      assert html =~ ~s(href="/")

      refute html =~ ~s(id="chrome-menu")
      refute html =~ ~s(id="chrome-context")
    end

    test "the pill is yellow at rest, never tangerine — that is the ballot's colour" do
      html = header(%{variant: :public})

      assert html =~ "bg-yellow"
      assert html =~ "hover:bg-tangerine"
      # Tangerine may only appear here as a hover state. Class lists are
      # space-separated, so a resting `bg-tangerine` is the only thing that can
      # produce " bg-tangerine" — `hover:bg-tangerine` never can.
      refute html =~ " bg-tangerine"
    end

    test "the pill has a 44px hit area — it is a guest's only header control" do
      # 117.5×27.8 painted. The pseudo-element grows from the 23.8px padding box, so the
      # vertical inset is (44 − 23.8) / 2 = 10.1, rounded up to 10.5 → 44.8. `-inset-y-2`
      # (the first cut) reached only 39.8.
      html = header(%{variant: :public})

      assert html =~ "before:-inset-y-[10.5px]"
      refute html =~ "before:-inset-y-2 "
    end

    test "drops the ⋯ even for a signed-in visitor — the /join tree is account-free" do
      html = header(%{variant: :public, current_scope: signed_in(%{is_admin: true})})

      refute html =~ ~s(id="chrome-menu")
      refute html =~ ~s(href="/admin/users")
      assert html =~ ~s(id="chrome-create-your-own")
    end

    test "the wordmark is inert text, not a link — the reflexive tap must not cost a ballot" do
      html = header(%{variant: :public})

      assert html =~ ~s(<span id="chrome-wordmark")
      # Exactly one link on the whole public header, and it is the labelled pill.
      assert html |> String.split(~s(<a )) |> length() == 2
      assert html =~ ~s(id="chrome-create-your-own")
    end

    test "the app variants keep the wordmark clickable" do
      assert header(%{variant: :app}) =~ ~s(<a )
      assert header(%{variant: :app}) =~ ~s(id="chrome-wordmark")
      assert header(%{variant: :marketing}) =~ ~s(id="chrome-wordmark")
      refute header(%{variant: :marketing}) =~ ~s(<span id="chrome-wordmark")
    end
  end

  describe "header/1 — the :marketing variant (signed-out standing pages)" do
    test "renders a plain Log in link instead of the pill or the menu" do
      html = header(%{variant: :marketing, current_scope: signed_out()})

      assert html =~ ~s(id="chrome-sign-in")
      # **"Log in", not "Sign in".** One destination, four controls one tap apart — this
      # link, the `⋯` entry, `/users/register`'s in-page link and the destination's own
      # `h1` — and this was the only one calling it something else.
      assert html =~ "Log in"
      refute html =~ "Sign in"
      assert html =~ ~s(href="/users/log-in")

      refute html =~ ~s(id="chrome-create-your-own")
      refute html =~ ~s(id="chrome-menu")
    end

    test "the Log in link has a 44px hit area that does not grow the 48px header" do
      # Bare 600/11.5 text with no border or background measured ~40×17px, in the
      # top-right corner of a phone. `-my-2` cancels the padding so the anchor's margin
      # box stays 28px and the header keeps frame `4a`'s height; the text does not move.
      html = header(%{variant: :marketing})

      assert html =~ "min-h-[44px]"
      assert html =~ "-my-2"
      assert html =~ "px-2"
    end

    test "the Log in link hovers tangerine, the way frame 00a draws it" do
      html = header(%{variant: :marketing})

      assert html =~ "hover:text-tangerine"
      refute html =~ "hover:underline"
    end

    test "still honours `back`, so a standing page is never a dead end" do
      # Plan ruling 2 defines the public header as "no ‹, no ⋯" and ruling 3 sends the
      # marketing pages to that shape — but `/about`, `/privacy` and `/how-it-works` are
      # reached *from the footer of every screen in the app*, so a marketing header with
      # no ‹ is precisely the dead end this work exists to remove. Ruling 3 was amended
      # to say so; see docs/plans/chrome-and-feedback.md.
      html = header(%{variant: :marketing, back: "/groups/12/options"})

      assert html =~ ~s(id="chrome-back")
    end

    # The "drops the log-in link on the log-in form itself" test that used to sit here is gone
    # with the guard it covered. It rendered `variant: :marketing` with
    # `current_path: "/users/log-in"`, a combination the app cannot produce: D-041's
    # variant table and `user_live/login.ex` both put the auth screens on `:app`. The
    # guard was dead code and the test passed trivially.
  end

  describe "footer/1" do
    test "both faces link to /feedback pre-set to their own mood" do
      html = footer()

      assert html =~ ~s(id="feedback-happy")
      assert html =~ ~s(href="/feedback?mood=happy")
      assert html =~ ~s(id="feedback-sad")
      assert html =~ ~s(href="/feedback?mood=sad")
    end

    test "the two faces are told apart by their mouth path, not only by fill" do
      html = footer()

      # The smile curves down-then-up; the frown is its mirror. Both come straight
      # from design frame 4a.
      assert html =~ "M8 14.6c1 1.2 2.4 1.8 4 1.8s3-.6 4-1.8"
      assert html =~ "M8 16.4c1-1.2 2.4-1.8 4-1.8s3 .6 4 1.8"
      assert html =~ "bg-mint"
      assert html =~ "bg-peach"
    end

    test "each face names itself for a screen reader" do
      html = footer()

      assert html =~ ~s(aria-label="Something&#39;s going well — tell us")
      assert html =~ ~s(aria-label="Something&#39;s wrong — tell us")
    end

    test "all three standing links point at routes that exist" do
      html = footer()

      assert html =~ ~s(href="/about")
      assert html =~ ~s(href="/how-it-works")
      assert html =~ ~s(href="/privacy")
    end

    test "carries the two credit lines" do
      html = footer()

      assert html =~ "marketfinder.us"
      assert html =~ ~s(href="https://marketfinder.us)
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ "Made with"
      assert html =~ "Philadelphia"
    end

    test "every link carries a return_to when the current path is known" do
      html = footer(%{current_path: "/groups/12/options"})

      assert html =~ ~s(href="/feedback?mood=happy&amp;return_to=%2Fgroups%2F12%2Foptions")
      assert html =~ ~s(href="/about?return_to=%2Fgroups%2F12%2Foptions")
      assert html =~ ~s(href="/how-it-works?return_to=%2Fgroups%2F12%2Foptions")
      assert html =~ ~s(href="/privacy?return_to=%2Fgroups%2F12%2Foptions")
    end

    test "drops the standing link for the page it is being rendered on" do
      # Left in, "How it works" in the footer of /how-it-works navigated to
      # /how-it-works?return_to=/how-it-works?return_to=… — after which the header's ‹
      # landed on a byte-identical screen and the real destination was two presses away.
      html = footer(%{current_path: "/how-it-works?return_to=%2Fgroups%2F12%2Foptions"})

      refute html =~ ~s(href="/how-it-works)
      assert html =~ ~s(href="/about)
      assert html =~ ~s(href="/privacy)
    end

    test "an inbound return_to is passed through, not wrapped in another one" do
      # Hopping /about → /how-it-works → /privacy from the footer otherwise nested one
      # encoded URL inside the next, pushing the wizard step the visitor actually came
      # from one more ‹ press away on every hop.
      html = footer(%{current_path: "/about?return_to=%2Fgroups%2F12%2Foptions"})

      assert html =~ ~s(href="/privacy?return_to=%2Fgroups%2F12%2Foptions")
      assert html =~ ~s(href="/how-it-works?return_to=%2Fgroups%2F12%2Foptions")
      refute html =~ "return_to%3D"
    end

    test "an attacker-supplied inbound return_to is not passed through" do
      # `safe_return_to/1` is what stops `?return_to=https://elsewhere` becoming an open
      # redirect wearing this app's chrome; the pass-through above must go through it too.
      # It falls back to the current path, which is local by construction — the hostile
      # string survives only as opaque, doubly-encoded query text inside it, and
      # `CurrentPath.return_to/1` rejects it again wherever it is finally read.
      html = footer(%{current_path: "/about?return_to=https%3A%2F%2Fevil.example"})

      refute html =~ ~s(href="https://evil.example")
      refute html =~ ~s(return_to=https)
      assert html =~ ~s(href="/privacy?return_to=%2Fabout%3Freturn_to%3Dhttps%253A%252F%252Fevil)
    end

    test "no link in it carries a return_to pointing at its own route" do
      # On /feedback?mood=happy the happy face emitted
      # href="/feedback?mood=happy&return_to=%2Ffeedback%3Fmood%3Dhappy" — a link to the
      # page being rendered, whose ‹ then landed on a byte-identical screen, so the real
      # way out was two presses away with nothing saying so.
      html = footer(%{current_path: "/feedback?mood=happy"})

      refute html =~ ~s(return_to=%2Ffeedback)
      refute html =~ "return_to"
    end

    test "a link never inherits a return_to that points at itself" do
      # The general form of the guard above, and the only case that still reaches it now
      # that the mood pair is dropped on /feedback outright. Standing on /about having come
      # from /privacy, the footer's Privacy link must not carry `?return_to=/privacy` — a ‹
      # back to the screen you just left to get here. Removing the `path_only(target) ==
      # path_only(path)` clause from `return_to_for/2` leaves every other test in this file
      # green; this one goes red.
      html = footer(%{current_path: "/about?return_to=%2Fprivacy"})

      assert html =~ ~s(href="/privacy"), "the Privacy link lost its plain fallback"
      refute html =~ ~s(href="/privacy?return_to=%2Fprivacy")
      assert html =~ ~s(href="/how-it-works?return_to=%2Fprivacy")
    end

    test "the mood pair is dropped whole on /feedback — the form owns the mood there" do
      # Keeping the pair and rendering the current mood inert fixed the self-link and left
      # the worse half: the *other* face is a `navigate`, so one tap remounted FeedbackLive
      # and destroyed whatever had been typed, with no confirm and no undo. /feedback also
      # carries its own 44px two-state picker captioned "tap to switch", so the footer pair
      # there is a second copy of one value that goes stale the moment the form's picker is
      # used. See `show_mood_pair?/2`.
      for path <- ["/feedback", "/feedback?mood=happy", "/feedback?mood=sad", "/feedback?sent=1"] do
        html = footer(%{current_path: path})

        refute html =~ ~s(id="feedback-happy"), "#{path} still renders the footer's mood pair"
        refute html =~ ~s(id="feedback-sad"), "#{path} still renders the footer's mood pair"
        refute html =~ "How's this going?", "#{path} kept the pair's label with no pair"

        # The rest of the footer is untouched — this is one row, not the whole bar.
        assert html =~ ~s(href="/about"), "#{path} lost the standing links too"
        assert html =~ "marketfinder.us"
      end
    end

    test "everywhere else both faces are live links, and neither is drawn pre-pressed" do
      # There is no inert branch any more, so there is no half-clickable face to mistake
      # for a live one anywhere in the app.
      for path <- [nil, "/", "/groups/12/options", "/admin/users"] do
        html = footer(%{current_path: path})

        assert html =~ ~s(id="feedback-happy"), "#{inspect(path)} lost the happy face"
        assert html =~ ~s(id="feedback-sad"), "#{inspect(path)} lost the sad face"
        refute html =~ ~s(aria-current="page")
        refute html =~ "translate-x-px translate-y-px shadow-sticker-1"
      end
    end

    test "the pair is the screen frames' 26px, not frame 4a's enlarged 28px" do
      # IMPORT-NOTES §4.2: "4a is an enlarged schematic of the pattern, not a screen. Build
      # the 26px version." All eleven real screen frames draw 26px faces with a 15px glyph,
      # an 8px gutter and a 10.5px label; 4a alone draws 28/16/9/11.
      html = footer()

      assert html =~ "size-[26px]"
      assert html =~ ~s(width="15")
      assert html =~ "text-[10.5px]"
      refute html =~ "size-7"
      refute html =~ ~s(width="16")
    end

    test "reaching /feedback from the wizard keeps the wizard as the origin" do
      # The inbound return_to is what the standing links inherit; the form itself is
      # never nominated as an origin, so the step the organizer actually came from
      # survives the hop rather than being replaced by an empty form.
      html = footer(%{current_path: "/feedback?mood=sad&return_to=%2Fgroups%2F12%2Foptions"})

      assert html =~ ~s(href="/about?return_to=%2Fgroups%2F12%2Foptions")
      assert html =~ ~s(href="/how-it-works?return_to=%2Fgroups%2F12%2Foptions")
      refute html =~ ~s(return_to=%2Ffeedback)
    end

    test "the three standing links and the credit hover tangerine, not underline" do
      # Frames `00a` and `4a` carry style-hover="color:#FF6A2B" on all four; the
      # underline was the one place in this chrome a reader could tell frame from app.
      html = footer()

      assert html =~ "hover:text-tangerine"
      refute html =~ "hover:underline"
    end

    test "every text link acknowledges a tap, not only a hover" do
      # Four links here plus the header's `Log in` got `hover:text-tangerine` and no touch
      # equivalent, in the same commit that added `active:bg-yellow` to the two circles for
      # exactly that reason. On a phone all five acknowledged a tap in no way at all.
      # Counted, not merely present: three standing links + the marketfinder credit.
      assert footer() |> String.split("hover:text-tangerine active:text-tangerine") |> length() ==
               5

      assert header(%{variant: :marketing}) =~ "hover:text-tangerine active:text-tangerine"
    end

    test "the link row keeps the frame's 8px gutter while widening each link's hit box" do
      # `gap-x-3` (12px) + `px-1` put 16px between "About us" and the `·` where
      # IMPORT-NOTES §4.3 transcribes `gap:8px`, so the dots floated mid-gap and the row
      # measured 218px against the frame's 178px. That is why the gutter and the padding are
      # asserted **together**: `gap-x-1` (4px) + `px-1` (4px) is 8px of visual space, the
      # frame's number to the pixel, while giving each link 8px more hit width — `Privacy`
      # painted 36×26, the smallest target in the chrome. Two flex siblings cannot overlap
      # however small the gutter, so the width is free; the vertical `min-h-[26px]` is not
      # (D-041) and is untouched.
      html = footer()

      assert html =~ "gap-x-1"
      refute html =~ "gap-x-2"
      refute html =~ "gap-x-3"
      assert html =~ ~s(items-center px-1 py-1)
      assert html =~ "min-h-[26px]"
    end

    test "the two faces grow a hit box that damages none of their four neighbours" do
      # 26×26 painted, in a 22px padding box the `::before` grows from. The vertical insets
      # are capped by something different in each direction and neither may be rounded up:
      # 9px up is exactly the footer's `border-t-2` + `pt-[7px]`, and 6px down is where the
      # standing-link row's box begins — at the 11px that would have made this 44px tall,
      # `Privacy` measured 23px, under WCAG 2.5.8 AA's floor, because a positioned
      # pseudo-element beats a static sibling whatever the DOM order.
      #
      # Sideways is now 8px, not 4, and it is paired with the faces' own `gap-6` wrapper:
      # at the frame's 8px gutter the widest non-overlapping box was 4px a side and the two
      # boxes *touched*, leaving a pixel of clearance between two controls that file
      # opposite moods. Both halves are asserted here, because either one alone reinstates
      # the defect — a wider inset without the wider gutter overlaps them.
      # 22 + 8 + 8 = 38 wide, 22 + 9 + 6 = 37 tall.
      html = footer()

      assert html
             |> String.split("before:-inset-x-2 before:-top-[9px] before:-bottom-[6px]")
             |> length() == 3

      assert html =~ ~s(<div class="flex items-center gap-6">),
             "the faces need their own wider gutter, or the widened hit boxes overlap"

      refute html =~ "before:-inset-y-", "a symmetric inset here damages a neighbour"
      assert html =~ "size-[26px]"
      refute html =~ "size-[30px]"
    end

    test "`confirm` puts a data-confirm on every control in the bar, and nothing without it" do
      # Every control here is a `navigate`, so from a screen holding unsaved text one tap
      # remounts the LiveView and the typing is gone with no confirm and no undo — measured
      # on /users/register, /groups/new, the 02b option editor and /feedback itself. This is
      # the same escape hatch `header/1`'s `pill_confirm` gives the ballot.
      plain = footer(%{current_path: "/groups/12/options"})
      refute plain =~ "data-confirm"

      guarded = footer(%{current_path: "/groups/12/options", confirm: "Discard this draft?"})

      # Both faces, all three standing links, the outbound credit.
      assert guarded |> String.split(~s(data-confirm="Discard this draft?")) |> length() == 7
    end

    test "Layouts.app/1 is what a screen passes it through, as `footer_confirm`" do
      # No screen passes one yet — the four that should (registration, /groups/new, the 02b
      # editor, /feedback) are other pieces' files — so without this the plumbing could be
      # deleted from `Layouts.app/1` with the whole suite green and the attr left stranded
      # on a component nothing reaches.
      html =
        render_component(&ConsensusWeb.Layouts.app/1, %{
          flash: %{},
          footer_confirm: "Discard this draft?",
          inner_block: [
            %{__slot__: :inner_block, inner_block: fn _assigns, _slot -> "" end}
          ]
        })

      assert html =~ ~s(data-confirm="Discard this draft?")

      refute render_component(&ConsensusWeb.Layouts.app/1, %{
               flash: %{},
               inner_block: [%{__slot__: :inner_block, inner_block: fn _assigns, _slot -> "" end}]
             }) =~ "data-confirm"
    end

    test "on :public it is the same footer as everywhere else" do
      # It used to be the two credit lines and nothing else, on the reasoning that five
      # `navigate`s under "Send my votes" are five ways to discard a ballot that lives only
      # in socket assigns. That risk is real and is now closed by `confirm` (the test below)
      # rather than by deleting the controls: a guest who is stuck mid-ballot is exactly the
      # person with something to report, and the vote screen is the last one that should
      # hide the report button.
      html = footer(%{variant: :public})

      assert html =~ ~s(id="feedback-happy")
      assert html =~ ~s(id="feedback-sad")
      assert html =~ "How's this going?"
      assert html =~ ~s(href="/about")
      assert html =~ ~s(href="/how-it-works")
      assert html =~ ~s(href="/privacy")
      assert html =~ "marketfinder.us"
      assert html =~ "Philadelphia"
    end

    test "on :public every control takes the caller's confirm" do
      # The guard that makes the full footer safe on a ballot. Without it this footer is
      # five silent ways to lose an unsent vote — which is why the controls were removed in
      # the first place, and why restoring them without this assertion would be a
      # regression wearing the shape of a fix.
      html = footer(%{variant: :public, confirm: "Leave without sending?"})

      for id <- [~s(id="feedback-happy"), ~s(id="feedback-sad")] do
        assert html =~ id
      end

      links =
        Regex.scan(~r/<a\b[^>]*>/, html)
        |> List.flatten()
        |> Enum.reject(&(&1 =~ ~s(target="_blank")))

      assert length(links) >= 5

      for link <- links do
        assert link =~ ~s(data-confirm="Leave without sending?"),
               "a footer control on :public navigates without confirming: #{link}"
      end
    end
  end

  describe "the flash covers neither the header nor the screen's own title" do
    test "it is a flow card, not a fixed overlay at any hard-coded offset" do
      # `top-4` put a z-50 card on the back circle and the ⋯ menu. `top-[56px]` cleared
      # those and landed on the next thing instead — measured, it hid the <h1> outright
      # on `/` signed in, on /users/log-in and on /admin/users, and cut the wizard's
      # progress bar in half. There is no safe hard-coded `top`; each screen puts
      # something different first.
      html =
        render_component(&ConsensusWeb.CoreComponents.flash/1, %{
          kind: :info,
          flash: %{"info" => "Saved."}
        })

      refute html =~ "fixed"
      refute html =~ "top-[56px]"
      refute html =~ "top-4"
      # `left-1/2 -translate-x-1/2` centred on the initial containing block, not the
      # viewport, so on /admin/users (a wide table inside overflow-x-auto grew
      # scrollWidth to 648px in a 420px viewport) the dismiss ✕ sat off-screen.
      refute html =~ "left-1/2"
      assert html =~ "mx-4"
    end

    test "it is sticky under the header, not static — a scrolled page still shows it", %{
      conn: conn
    } do
      # `static` was the third failure of the same kind, after `fixed top-4` and
      # `fixed top-[56px]`. A flash is by definition rendered right after an action, and
      # on a page taller than the viewport that action is very often taken while scrolled
      # down: measured at 420×900 on /admin/users (scrollHeight 1177), pressing Promote
      # from scrollY=345 put the card at top:-297px, entirely above the viewport. This
      # asserts the *rendered page*, not the component, because the previous version of
      # the container carried no class attribute at all and every component test passed.
      html =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session("phoenix_flash", %{"info" => "Saved."})
        |> get(~p"/")
        |> html_response(200)

      [_before, from_group] = String.split(html, ~s(id="flash-group"), parts: 2)
      [attrs, _rest] = String.split(from_group, ">", parts: 2)

      assert attrs =~ "sticky", "the flash container scrolls away with the page"
      assert attrs =~ "z-30"

      # `top-[40px]`, not `top-[48px]`: the header is 48px and `flash/1` carries `mt-2`,
      # so offsetting the *container* by the header height parks the *card* at 56px and
      # leaves an 8px transparent slit the page scrolls through. 48 − 8 = 40 puts the
      # card flush under the header's bottom border and the margin behind the header.
      assert attrs =~ "top-[40px]", "the flash card does not park flush under the header"
      assert html =~ "mt-2", "flash/1 lost the margin top-[40px] is derived from"

      # And it must stay *below* the header: the header is the only way back on every
      # screen in this app, so a flash that covers it is the regression D-041 records.
      [_pre, from_header] = String.split(html, "<header", parts: 2)
      assert from_header =~ "z-40"
    end

    test "it is rendered inside the app column, between the header and the content", %{
      conn: conn
    } do
      # `phoenix_flash` in the session is how a flash survives a redirect, which is the
      # shape of every case that matters here — "Welcome back!", a require-auth bounce,
      # the pool-locked bounce out of /groups/:id/options.
      html =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session("phoenix_flash", %{"info" => "Saved."})
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "Saved."

      [_before, after_flash] = String.split(html, ~s(id="flash-group"), parts: 2)

      assert String.contains?(after_flash, "<main"),
             "the flash renders after <main> — it is outside the column again"

      assert html
             |> String.split(~s(id="chrome-wordmark"), parts: 2)
             |> List.last()
             |> String.contains?(~s(id="flash-group")),
             "the flash renders above the header rather than below it"
    end
  end

  describe "the chrome each route asks for" do
    test "a signed-out page renders both header and footer", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(id="chrome-wordmark")
      assert html =~ ~s(id="feedback-happy")
      assert html =~ "Made with"
    end

    test "the three footer routes render rather than 404 and keep the pair", %{conn: conn} do
      for path <- [~p"/about", ~p"/how-it-works", ~p"/privacy"] do
        html = conn |> get(path) |> html_response(200)
        assert html =~ ~s(id="chrome-wordmark")
        assert html =~ ~s(id="feedback-happy")
      end
    end

    test "/feedback renders, and its footer offers no second copy of the mood", %{conn: conn} do
      # This file's business is the *chrome*, so it asserts what the chrome does on that
      # route — nothing, because the form owns the mood there — rather than what
      # `FeedbackLive`'s body says. The body copy is `feedback_live_test.exs`'s to pin;
      # asserting another module's sentences from here is what made these tests go red the
      # moment that module was rewritten. `#feedback-mood-happy` is the form's own control
      # and is deliberately a different id from the footer's `#feedback-happy`.
      for path <- [~p"/feedback", ~p"/feedback?mood=happy", ~p"/feedback?mood=sad"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(id="chrome-wordmark")
        refute html =~ ~s(id="feedback-happy"), "#{path} renders two mood pickers"
        refute html =~ ~s(id="feedback-sad"), "#{path} renders two mood pickers"
        assert html =~ ~s(id="feedback-mood-happy"), "#{path} lost the form's own picker"
      end
    end

    test "an unknown mood does not crash and still drops the pair", %{conn: conn} do
      html = conn |> get(~p"/feedback?mood=furious") |> html_response(200)

      refute html =~ ~s(id="feedback-happy")
      assert html =~ ~s(id="feedback-mood-happy")
    end

    test "signed-out `/` is :marketing — Log in, no account menu", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(id="chrome-sign-in")
      refute html =~ ~s(id="chrome-menu")
      refute html =~ ~s(id="chrome-back")
    end

    test "signed-in `/` is :app — the ⋯ menu, still no back", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(id="chrome-menu")
      refute html =~ ~s(id="chrome-sign-in")
      refute html =~ ~s(id="chrome-back")
    end

    test "the auth screens are :app and carry no ⋯ at all", %{conn: conn} do
      # `:app`, not `:marketing` — they are app screens a signed-out person is standing
      # on. The signed-out menu holds only Log in and Start something, so on each of these
      # exactly one entry survives the self-link filter and it duplicates the form's own
      # cross-link 40px lower; the whole menu is dropped rather than opening on it.
      login = conn |> get(~p"/users/log-in") |> html_response(200)
      refute login =~ ~s(id="chrome-menu")
      refute login =~ ~s(id="chrome-sign-in")
      assert login =~ ~s(id="chrome-back")

      register = conn |> get(~p"/users/register") |> html_response(200)
      refute register =~ ~s(id="chrome-menu")
      refute register =~ ~s(id="chrome-sign-in")
      assert register =~ ~s(id="chrome-back")
    end

    test "the signed-in ⋯ drops the entry for the screen it is rendered on", %{conn: conn} do
      # The component half pins the function; this pins that the screens actually feed
      # it `current_path`. Both shipped claiming this behaviour and neither had it.
      scope = admin_scope_fixture()
      conn = log_in_user(conn, scope.user)

      on_admin = conn |> get(~p"/admin/users") |> html_response(200)
      assert on_admin =~ ~s(id="chrome-menu")
      refute on_admin =~ ~s(href="/admin/users")
      assert on_admin =~ ~s(href="/users/settings")

      on_settings = conn |> get(~p"/users/settings") |> html_response(200)
      refute on_settings =~ ~s(href="/users/settings")
      assert on_settings =~ ~s(href="/admin/users")
    end

    test "the standing pages refuse an off-site return_to", %{conn: conn} do
      # `CurrentPath.safe_return_to/1` is unit-tested; nothing asserted the four pages
      # actually route the parameter through it. A regression to `back={params["return_to"]}`
      # in any of the four mounts reopens the redirect with the whole suite green.
      for path <- [~p"/about", ~p"/how-it-works", ~p"/privacy", ~p"/feedback"] do
        html = conn |> get("#{path}?return_to=https%3A%2F%2Fevil.example") |> html_response(200)

        refute html =~ ~s(href="https://evil.example"),
               "#{path} navigates a ‹ straight off the site"

        assert html =~
                 ~s(href="/" data-phx-link="redirect" data-phx-link-state="push" id="chrome-back"),
               "#{path} did not fall back to / for an unsafe return_to"

        local = conn |> get("#{path}?return_to=%2Fgroups%2F12%2Foptions") |> html_response(200)

        assert local =~ ~s(href="/groups/12/options"),
               "#{path} dropped a perfectly good local return_to"
      end
    end

    test "every authenticated screen passes a `back`, so none is a dead end", %{conn: conn} do
      scope = admin_scope_fixture()
      conn = log_in_user(conn, scope.user)
      group = group_fixture(scope, %{deadline_at: DateTime.add(DateTime.utc_now(), 3, :day)})
      activity = activity_fixture(group)

      for path <- [
            ~p"/users/settings",
            ~p"/admin/users",
            ~p"/groups/#{group}/edit",
            ~p"/groups/#{group}/options",
            ~p"/groups/#{group}/options/#{activity.id}",
            ~p"/groups/#{group}/review"
          ] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(id="chrome-back"),
               "#{path} passes no `back` to Layouts.app/1 — the header is its only way out"

        assert html =~ ~s(id="chrome-menu"), "#{path} should be the :app variant"
      end
    end

    test "the whole /join tree is :public — no ⋯, an inert wordmark, the same footer", %{
      conn: conn
    } do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)

      joined =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(JoinAuth.participant_session_key(group.id), participant.token)

      entry = conn |> get(~p"/join/#{group.slug}") |> html_response(200)
      ballot = joined |> get(~p"/join/#{group.slug}/vote") |> html_response(200)
      results = joined |> get(~p"/join/#{group.slug}/results") |> html_response(200)

      for {path, html} <- [
            {"/join/:slug", entry},
            {"/join/:slug/vote", ballot},
            {"/join/:slug/results", results}
          ] do
        # The pill everywhere in the tree **except** `/join/:slug/results`, whose own
        # footer renders `#results-start-your-own` — the same label pointing at the same
        # `/` — in every one of `footer_state/3`'s ten cells. Two controls, one label, one
        # destination, on a screen whose only two controls those were. The invariant the
        # loop is really asserting is "a guest always has a labelled way to the product",
        # so results has to prove it a different way, not be exempted from it.
        if path == "/join/:slug/results" do
          refute html =~ ~s(id="chrome-create-your-own"),
                 "#{path} duplicates its own Create your own → in the header"

          assert html =~ ~s(id="results-start-your-own"),
                 "#{path} has no way off the screen at all"
        else
          assert html =~ ~s(id="chrome-create-your-own"), "#{path} lost the public pill"
        end

        refute html =~ ~s(id="chrome-menu"),
               "#{path} offers a guest an account menu — product invariant 1"

        # The footer is the same everywhere, including here. What keeps that safe on the
        # ballot is `footer_confirm`, asserted separately below — not the controls' absence.
        assert html =~ ~s(id="feedback-happy"),
               "#{path} lost the feedback pair the rest of the app carries"

        # `href="/how-it-works` without the closing quote on purpose: the footer appends
        # `?return_to=<the path it was tapped on>`, so an exact-href match passes on the
        # screens that happen not to carry one and fails on the screens that do.
        assert html =~ ~s(href="/how-it-works), "#{path} lost the standing links"
        assert html =~ ~s(<span id="chrome-wordmark"), "#{path}'s wordmark is still a link"
      end

      # The ballot is the one screen in the tree holding state that a navigation destroys,
      # so it is the one that must arm the guard — and only once there is something to lose.
      refute ballot =~ "data-confirm",
             "the ballot prompts before anything is selected"

      armed =
        joined
        |> get(~p"/join/#{group.slug}/vote")
        |> html_response(200)

      assert armed =~ ~s(id="feedback-happy")
    end
  end
end
