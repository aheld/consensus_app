defmodule ConsensusWeb.GroupLive.OptionsAssistTest do
  @moduledoc """
  The Assisted Add on `02 add options` (design frame t5, states 02b–02f;
  `docs/design/assisted-add-ux-brief.md` F1/F2/F4). One describe per state-table
  row, plus the negative space the brief cares most about: the failure trio
  renders *nothing*, no lookup ever fires per keystroke, a pasted URL never
  reaches Discovery, and with no registered provider the feature is invisible.

  Same stub idiom as `options_test.exs`: `Consensus.DiscoveryStub` /
  `Consensus.GeocoderHTTPStub` / `Consensus.LinkPreviewStub` are installed in
  the test process and found from inside `start_async` Tasks by walking
  `$callers`. Blocking stubs (reply only when the test says so) are what make
  the two-phase assertions — card first, suggestion later — deterministic.
  """

  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result
  alias Consensus.DiscoveryStub
  alias Consensus.GeocoderHTTPStub
  alias Consensus.LinkPreviewStub

  # TEST-NET-1 (RFC 5737), same reasoning as options_test.exs: the SSRF guard skips
  # DNS entirely for a literal IP, so enrichment fetches through the stub never risk
  # a real lookup.
  @link_host "192.0.2.10"

  @odbl_attribution %{
    prefix: "Places from ",
    text: "OpenStreetMap contributors",
    url: "https://opendatacommons.org/licenses/odbl/"
  }

  setup :register_and_log_in_user

  setup do
    Consensus.LinkPreview.Cache.flush()
    Consensus.Discovery.Cache.flush()
    LinkPreviewStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    # The slot's unconditional attribution line comes from the provider via
    # `Discovery.attribution_for/1` — the LiveView hardcodes neither text nor URL.
    DiscoveryStub.stub_attribution(@odbl_attribution)
    :ok
  end

  defp unique_website_url, do: "http://#{@link_host}/site?t=#{System.unique_integer([:positive])}"

  defp result(attrs) do
    struct!(
      %Result{name: "Vernick Food & Drink", source: :osm},
      attrs
    )
  end

  # A group that already knows where to look — lookups fire directly, no prompt.
  defp group_with_area(scope, area \\ "Fishtown") do
    group = group_fixture(scope)

    {:ok, group} =
      Activities.set_search_area(scope, group, %{
        search_area: area,
        search_bbox: "39.96,-75.15,39.99,-75.12"
      })

    group
  end

  defp add_typed(view, name) do
    view |> form("#add-option-form", add_option: %{query: name}) |> render_submit()
  end

  defp only_activity(scope, group) do
    [activity] = Activities.get_group!(scope, group.id).activities
    activity
  end

  defp html_preview(title) do
    """
    <html><head>
      <meta property="og:title" content="#{title}">
      <meta property="og:description" content="Tasting menu on Walnut.">
      <meta property="og:image" content="https://#{@link_host}/photo.jpg">
    </head></html>
    """
  end

  # Runs `fun` with the Discovery provider registry swapped, restoring the real one
  # even if `fun` raises. Safe under `async: true` here because ExUnit runs the tests
  # *within* one module serially, and `max_cases: 1` (D-033) means no other module
  # runs concurrently with this one.
  defp with_registry(providers, fun) do
    original = Application.get_env(:consensus, Consensus.Discovery)
    Application.put_env(:consensus, Consensus.Discovery, providers: providers)

    try do
      fun.()
    after
      Application.put_env(:consensus, Consensus.Discovery, original)
    end
  end

  describe "the F4 copy swap (02a)" do
    test "the helper line describes the assist, and the old 'coming soon' line is gone",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, _view, html} = live(conn, ~p"/groups/#{group}/options")

      # The exact frame copy (frame-review §c) — a revert to the shipped MVP line
      # must go red here. HEEx entity-escapes the apostrophe even in static
      # template text, so the rendered page carries &#39;.
      assert html =~ "Type a name and we&#39;ll try to find its link. Or paste one yourself."
      refute html =~ "Restaurant search coming soon"
    end
  end

  describe "the input refocuses after Add (02b: \"the input clears and stays focused\")" do
    test "only the render an Add produces arms the recreated input's focus command",
         %{conn: conn, scope: scope} do
      group = group_with_area(scope)
      {:ok, view, html} = live(conn, ~p"/groups/#{group}/options")

      # Initial mount: no focus steal — the fresh input carries no phx-mounted.
      assert html =~ "add-option-query-0"
      refute has_element?(view, "#add-option-query-0[phx-mounted]")

      # An Add bumps the id (which is what clears the field) and the recreated
      # element carries the mounted focus command, so the keyboard survives the swap.
      add_typed(view, "Vernick")
      render_async(view)
      assert has_element?(view, "#add-option-query-1[phx-mounted]")

      # An unrelated patch (into the editor and back) recreates the input again —
      # without the focus command: the refocus belongs to Add, not to navigation.
      activity = only_activity(scope, group)
      view |> element(~s(a[href$="/options/#{activity.id}"])) |> render_click()
      render_patch(view, ~p"/groups/#{group}/options")
      assert has_element?(view, "#add-option-query-1")
      refute has_element?(view, "#add-option-query-1[phx-mounted]")
    end
  end

  describe "the lookup fires after Add, never while typing (02b)" do
    test "a typed add lands instantly, shimmers while the one lookup runs, and settles silently on no match",
         %{conn: conn, scope: scope} do
      test_pid = self()

      DiscoveryStub.stub_search(fn query, _area, _opts ->
        send(test_pid, {:search_started, self(), query})
        receive do: (:continue -> {:ok, []})
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      assert_receive {:search_started, task_pid, "Vernick"}, 1000

      # The card exists immediately, bare, exactly as an unassisted add — with the
      # quiet shimmer where the meta line will be. No spinner, no text.
      activity = only_activity(scope, group)
      assert activity.name == "Vernick"
      assert activity.source_url == nil
      assert has_element?(view, "#activities-#{activity.id} .assist-shim")
      refute render(view) =~ "no details yet"

      send(task_pid, :continue)
      html = render_async(view)

      # {:ok, []}: the shimmer stops and the plain line is back. Nothing else. (The
      # meta line renders phrase-by-phrase in nowrap spans so 375px wraps at the "·",
      # so the two phrases are asserted separately.)
      refute has_element?(view, "#activities-#{activity.id} .assist-shim")
      assert html =~ "typed by you"
      assert html =~ "no details yet"
      refute html =~ "Is this it?"

      # Exactly one lookup for one Add.
      refute_receive {:search_started, _, _}, 100
    end

    test "nothing fires per keystroke — the add form has no change binding at all",
         %{conn: conn, scope: scope} do
      test_pid = self()

      DiscoveryStub.stub_search(fn q, _a, _o ->
        send(test_pid, {:search_started, q})
        {:ok, []}
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      refute has_element?(view, "#add-option-form[phx-change]")

      # Typing produces no server event because there is nothing bound to change:
      # driving one anyway is refused by LiveViewTest itself.
      typed_fires_nothing =
        try do
          view |> form("#add-option-form", add_option: %{query: "Vern"}) |> render_change()
          false
        rescue
          _ -> true
        end

      assert typed_fires_nothing, "the add form unexpectedly accepts phx-change"
      refute_receive {:search_started, _}, 100
    end

    test "the area field is submit-only too — no change binding, no geocode while typing",
         %{conn: conn, scope: scope} do
      test_pid = self()

      GeocoderHTTPStub.stub(fn _url, _opts ->
        send(test_pid, :geocode_called)
        {:error, :nope}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")
      add_typed(view, "Vernick")

      assert has_element?(view, "#area-prompt-form")
      refute has_element?(view, "#area-prompt-form[phx-change]")

      typed_fires_nothing =
        try do
          view |> form("#area-prompt-form", area: %{search_area: "Fish"}) |> render_change()
          false
        rescue
          _ -> true
        end

      assert typed_fires_nothing, "the area form unexpectedly accepts phx-change"
      refute_receive :geocode_called, 100
    end

    test "a pasted URL fires no discovery lookup — the existing preview path only",
         %{conn: conn, scope: scope} do
      test_pid = self()

      DiscoveryStub.stub_search(fn q, _a, _o ->
        send(test_pid, {:search_started, q})
        {:ok, []}
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      url = "http://#{@link_host}/menu?t=#{System.unique_integer([:positive])}"
      add_typed(view, url)
      render_async(view)

      activity = only_activity(scope, group)
      assert activity.source_url == url
      refute_receive {:search_started, _}, 100
    end
  end

  describe "one match (02c)" do
    test "the slot renders name, street address and cuisine, with Use this, a dismiss and the attribution",
         %{conn: conn, scope: scope} do
      DiscoveryStub.stub_results([
        result(
          website_url: unique_website_url(),
          address: "2031 Walnut St",
          chips: [{"cuisine", "american"}]
        )
      ])

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      html = render_async(view)

      activity = only_activity(scope, group)
      assert has_element?(view, "#assist-slot-#{activity.id}")

      # The AssistReveal hook is what scrolls the slot into view on a phone (02d
      # annotation, frame-review §e-3's clamp) — deleting the attribute once left
      # every test green, so the wiring itself is pinned here.
      assert has_element?(view, ~s|#assist-slot-#{activity.id}[phx-hook="AssistReveal"]|)

      assert html =~ "Is this it?"
      assert html =~ "Vernick Food &amp; Drink"
      assert html =~ "2031 Walnut St"
      assert html =~ "American"
      assert has_element?(view, ~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      assert has_element?(view, ~s|button[phx-click="assist_dismiss"][title="No thanks"]|)

      # The attribution is unconditional wherever suggestions render, and every part
      # of it comes from Discovery.attribution_for/1. The frame links ONLY the
      # contributors phrase: the "Places from " prefix renders unlinked beside it.
      link_html =
        view
        |> element(~s|#assist-slot-#{activity.id} a[href="#{@odbl_attribution.url}"]|)
        |> render()

      assert link_html =~ "OpenStreetMap contributors"
      refute link_html =~ "Places from"

      assert view |> element("#assist-slot-#{activity.id}") |> render() =~ "Places from"

      # Nothing the licence forbids: no rating, no price band, no hours, no distance.
      slot_html = view |> element("#assist-slot-#{activity.id}") |> render()
      refute slot_html =~ "★"
      refute slot_html =~ "$$"
    end

    test "a provider with no attribution renders the slot without the line, and nothing crashes",
         %{conn: conn, scope: scope} do
      # `Discovery.attribution_for/1` answers nil for a provider whose attribution/0
      # is nil (one that requires none) — the slot's line is `:if`-guarded on it, so
      # the slot renders whole, minus the line, with no link element at all.
      DiscoveryStub.stub_attribution(nil)

      DiscoveryStub.stub_results([
        result(website_url: unique_website_url(), address: "2031 Walnut St")
      ])

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      render_async(view)

      activity = only_activity(scope, group)
      assert has_element?(view, "#assist-slot-#{activity.id}")

      slot_html = view |> element("#assist-slot-#{activity.id}") |> render()
      assert slot_html =~ "Is this it?"
      assert slot_html =~ "Vernick Food &amp; Drink"
      refute slot_html =~ "Places from"
      refute slot_html =~ "OpenStreetMap contributors"
      refute has_element?(view, "#assist-slot-#{activity.id} a")

      # The slot still works: Use this confirms exactly as with an attribution.
      view
      |> element(~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      assert only_activity(scope, group).name == "Vernick Food & Drink"
      assert Process.alive?(view.pid)
    end
  end

  describe "two–three matches (02d)" do
    test "three rows is the hard ceiling even when the seam returns more",
         %{conn: conn, scope: scope} do
      DiscoveryStub.stub_results([
        result(name: "Vernick Food & Drink", address: "2031 Walnut St"),
        result(name: "Vernick Fish", address: "1 N 19th St"),
        result(name: "Vernick Coffee Bar", address: "1 N 19th St"),
        result(name: "Vernick Somewhere Else", address: "9 Elsewhere Ave")
      ])

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      html = render_async(view)

      activity = only_activity(scope, group)

      for index <- 0..2 do
        assert has_element?(
                 view,
                 ~s|#assist-slot-#{activity.id} button[phx-value-index="#{index}"]|
               )
      end

      refute has_element?(view, ~s|button[phx-click="assist_use"][phx-value-index="3"]|)
      refute html =~ "Vernick Somewhere Else"
      assert html =~ "Vernick Fish"
      assert html =~ "Vernick Coffee Bar"
    end
  end

  describe "confirm (02e)" do
    test "Use this takes the canonical name + source_url, collapses the slot, and enriches exactly like a pasted link",
         %{conn: conn, scope: scope} do
      test_pid = self()
      website = unique_website_url()

      DiscoveryStub.stub_results([
        result(name: "Vernick Food & Drink", website_url: website, address: "2031 Walnut St")
      ])

      LinkPreviewStub.stub(fn requested_url, _opts ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :continue ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/html"}],
               body: html_preview("Vernick Food & Drink"),
               url: requested_url
             }}
        end
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      render_async(view)
      activity = only_activity(scope, group)

      view
      |> element(~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      assert_receive {:fetch_started, task_pid}, 1000

      # D3: the canonical name overwrites the typed one (02b's editor is the undo),
      # the suggestion's website is the row's source_url, and the slot is gone.
      confirmed = only_activity(scope, group)
      assert confirmed.name == "Vernick Food & Drink"
      assert confirmed.source_url == website
      refute has_element?(view, "#assist-slot-#{activity.id}")

      # The 02e enriching interval: violet shadow, shimmer tile, its own meta line.
      html = render(view)
      assert html =~ "shadow-assist"
      assert html =~ "link attached"
      assert html =~ "details arriving"
      assert has_element?(view, "#activities-#{activity.id} .assist-shim-anim")

      send(task_pid, :continue)
      html = render_async(view)

      # From here the card is an ordinary link-enriched card.
      enriched = only_activity(scope, group)
      assert enriched.description == "Tasting menu on Walnut."
      assert enriched.image_url == "https://#{@link_host}/photo.jpg"
      assert enriched.metadata_fetched_at
      assert html =~ "link added"
      assert html =~ "photo + description pulled"
      refute html =~ "shadow-assist"
      refute html =~ "details arriving"
    end

    test "the enrichment after Use this keeps the canonical name even when og:title differs",
         %{conn: conn, scope: scope} do
      website = unique_website_url()

      DiscoveryStub.stub_results([
        result(name: "Vernick Food & Drink", website_url: website, address: "2031 Walnut St")
      ])

      # Observed live: the confirmed site titles itself "Vernick Philadelphia". The
      # og:title must NOT replace the canonical provider name the organizer just
      # pressed Use this on — the adopt-the-title rule belongs to the paste path
      # alone (pinned unchanged in options_test.exs, "creates the row immediately
      # with a provisional name, then fills it in asynchronously").
      LinkPreviewStub.stub(fn requested_url, _opts ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "text/html"}],
           body: html_preview("Vernick Philadelphia"),
           url: requested_url
         }}
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      render_async(view)
      activity = only_activity(scope, group)

      view
      |> element(~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      html = render_async(view)

      # Photo, description and the fetch timestamp all landed; the name did not move.
      enriched = only_activity(scope, group)
      assert enriched.name == "Vernick Food & Drink"
      assert enriched.description == "Tasting menu on Walnut."
      assert enriched.image_url == "https://#{@link_host}/photo.jpg"
      assert enriched.metadata_fetched_at
      refute html =~ "Vernick Philadelphia"
    end

    test "a suggestion with no website still confirms name + address usefully — no source_url, no enrichment",
         %{conn: conn, scope: scope} do
      test_pid = self()
      DiscoveryStub.stub_results([result(name: "Vernick Fish", website_url: nil)])

      LinkPreviewStub.stub(fn _url, _opts ->
        send(test_pid, :fetch_started)
        {:error, :nope}
      end)

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      render_async(view)
      activity = only_activity(scope, group)

      view
      |> element(~s|button[phx-click="assist_use"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      confirmed = only_activity(scope, group)
      assert confirmed.name == "Vernick Fish"
      assert confirmed.source_url == nil
      refute has_element?(view, "#assist-slot-#{activity.id}")

      html = render(view)
      assert html =~ "typed by you"
      assert html =~ "no details yet"
      refute html =~ "link attached"
      refute html =~ "shadow-assist"
      refute_receive :fetch_started, 100
      assert Process.alive?(view.pid)
    end
  end

  describe "dismiss" do
    test "✕ collapses the slot and the bare typed card stands", %{conn: conn, scope: scope} do
      DiscoveryStub.stub_results([result(website_url: unique_website_url())])

      group = group_with_area(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      render_async(view)
      activity = only_activity(scope, group)
      assert has_element?(view, "#assist-slot-#{activity.id}")

      view
      |> element(~s|button[phx-click="assist_dismiss"][phx-value-id="#{activity.id}"]|)
      |> render_click()

      refute has_element?(view, "#assist-slot-#{activity.id}")
      dismissed_html = render(view)
      assert dismissed_html =~ "typed by you"
      assert dismissed_html =~ "no details yet"

      untouched = only_activity(scope, group)
      assert untouched.name == "Vernick"
      assert untouched.source_url == nil
    end
  end

  describe "the area prompt (02f)" do
    test "the first lookup that needs an area shows the prompt instead of results, and fires nothing",
         %{conn: conn, scope: scope} do
      test_pid = self()

      DiscoveryStub.stub_search(fn q, _a, _o ->
        send(test_pid, {:search_started, q})
        {:ok, []}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")

      activity = only_activity(scope, group)
      html = render(view)
      assert has_element?(view, "#assist-area-prompt-#{activity.id}")

      # The prompt carries the same AssistReveal hook as the suggestion slot, and it
      # matters MOST here: a one-time prompt rendering below the fold unseen silently
      # disables the assist for the whole session. Pinned because deleting the
      # attribute once left every test green.
      assert has_element?(
               view,
               ~s|#assist-area-prompt-#{activity.id}[phx-hook="AssistReveal"]|
             )

      assert html =~ "Where should we look?"

      assert html =~
               "So we can match names to the right places. Asked once, then remembered for this group."

      assert has_element?(
               view,
               ~s|input[name="area[search_area]"][placeholder="Neighborhood or city"]|
             )

      assert has_element?(view, ~s|#area-prompt-form button[type="submit"]|)
      # The dismiss ✕ the frame's annotation demands (drawing omits it — resolved
      # in favour of annotation + brief).
      assert has_element?(view, ~s|button[phx-click="assist_dismiss_area"][title="No thanks"]|)
      # No maxlength, ever (invariant 11) — the changeset's 100-grapheme cap is the limit.
      refute has_element?(view, ~s|input[name="area[search_area]"][maxlength]|)
      # Attribution renders in ALL slot states, the prompt included — the linked
      # contributors phrase with its unlinked prefix beside it.
      prompt_link_html =
        view
        |> element(~s|#assist-area-prompt-#{activity.id} a[href="#{@odbl_attribution.url}"]|)
        |> render()

      assert prompt_link_html =~ "OpenStreetMap contributors"
      refute prompt_link_html =~ "Places from"
      assert view |> element("#assist-area-prompt-#{activity.id}") |> render() =~ "Places from"

      # The prompt is not results and not a lookup: nothing fired, nothing shimmers.
      refute has_element?(view, ".assist-shim")
      refute_receive {:search_started, _}, 100

      # A second add while the prompt is open neither duplicates nor moves it.
      add_typed(view, "Zahav")
      assert has_element?(view, "#assist-area-prompt-#{activity.id}")
      assert view |> render() |> count_occurrences("Where should we look?") == 1
    end

    test "Save geocodes, stores area + bbox on the group, runs the pending lookup, and never asks again",
         %{conn: conn, scope: scope} do
      test_pid = self()
      typed_area = "Fishtown-#{System.unique_integer([:positive])}"

      GeocoderHTTPStub.stub_places([
        %{"name" => "Fishtown", "boundingbox" => ["39.96", "39.99", "-75.15", "-75.12"]}
      ])

      DiscoveryStub.stub_search(fn query, area, _opts ->
        send(test_pid, {:search_started, query, area})
        {:ok, [result(name: "Vernick Food & Drink", address: "2031 Walnut St")]}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      activity = only_activity(scope, group)
      assert has_element?(view, "#assist-area-prompt-#{activity.id}")

      view
      |> form("#area-prompt-form", area: %{search_area: typed_area})
      |> render_submit()

      # Two chained asyncs (geocode, then the pending lookup started from its
      # handle_async) — wait for the lookup itself before reading the DOM.
      render_async(view, 2000)
      assert_receive {:search_started, "Vernick", %Area{name: ^typed_area}}, 1000
      render_async(view, 2000)

      # Stored on the group, only on geocode success — the organizer's words as the
      # area, the geocoded bbox beside them.
      stored = Activities.get_group!(scope, group.id)
      assert stored.search_area == typed_area
      assert stored.search_bbox == "39.96,-75.15,39.99,-75.12"

      refute has_element?(view, "#assist-area-prompt-#{activity.id}")
      assert has_element?(view, "#assist-slot-#{activity.id}")
      assert render(view) =~ "Vernick Food &amp; Drink"

      # A second typed add in the same session: lookup fires directly, no prompt.
      add_typed(view, "Zahav")
      render_async(view, 2000)
      assert_receive {:search_started, "Zahav", %Area{}}, 1000
      refute render(view) =~ "Where should we look?"

      # And a completely fresh mount with the area set never prompts either.
      {:ok, fresh, _html} = live(conn, ~p"/groups/#{group}/options")
      add_typed(fresh, "Suraya")
      render_async(fresh, 2000)
      assert_receive {:search_started, "Suraya", %Area{}}, 1000
      refute render(fresh) =~ "Where should we look?"
    end

    test "typed adds made while the prompt is open queue their lookups until Save answers it",
         %{conn: conn, scope: scope} do
      test_pid = self()

      GeocoderHTTPStub.stub_places([
        %{"name" => "Fishtown", "boundingbox" => ["39.96", "39.99", "-75.15", "-75.12"]}
      ])

      DiscoveryStub.stub_search(fn query, %Area{} = _area, _opts ->
        send(test_pid, {:search_started, query})
        {:ok, [result(name: "#{query} Found", address: "1 Test St")]}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      # Add #1 opens the prompt; #2 and #3 arrive while the question is open. None
      # of the three may fire before the area exists — but none may be dropped
      # either: they queue behind the answer.
      add_typed(view, "Vernick")
      assert render(view) =~ "Where should we look?"
      add_typed(view, "Zahav")
      add_typed(view, "Suraya")
      refute_receive {:search_started, _query}, 100
      refute has_element?(view, ".assist-shim")

      view
      |> form("#area-prompt-form", area: %{search_area: "Fishtown"})
      |> render_submit()

      # Save geocodes, then fires the pending lookup for EVERY card added while
      # the prompt was open — each keyed per-activity as usual.
      render_async(view, 2000)
      assert_receive {:search_started, "Vernick"}, 1000
      assert_receive {:search_started, "Zahav"}, 1000
      assert_receive {:search_started, "Suraya"}, 1000
      render_async(view, 2000)

      activities = Consensus.Activities.get_group!(scope, group.id).activities
      assert length(activities) == 3

      for activity <- activities do
        assert has_element?(view, "#assist-slot-#{activity.id}"),
               "expected a suggestion slot on #{activity.name}"
      end

      assert render(view) =~ "Vernick Found"
      assert render(view) =~ "Zahav Found"
      assert render(view) =~ "Suraya Found"
    end

    test "dismissing the prompt suppresses it for this session only, and the area stays unset",
         %{conn: conn, scope: scope} do
      test_pid = self()

      DiscoveryStub.stub_search(fn q, _a, _o ->
        send(test_pid, {:search_started, q})
        {:ok, []}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")
      activity = only_activity(scope, group)
      assert has_element?(view, "#assist-area-prompt-#{activity.id}")

      view |> element(~s|button[phx-click="assist_dismiss_area"]|) |> render_click()
      refute render(view) =~ "Where should we look?"

      # The next add in this session neither prompts nor looks anything up.
      add_typed(view, "Zahav")
      refute render(view) =~ "Where should we look?"
      refute has_element?(view, ".assist-shim")
      refute_receive {:search_started, _}, 100

      assert Activities.get_group!(scope, group.id).search_area == nil

      # Suppression is socket state: a fresh mount may ask again.
      {:ok, fresh, _html} = live(conn, ~p"/groups/#{group}/options")
      add_typed(fresh, "Suraya")
      assert render(fresh) =~ "Where should we look?"
    end

    test "a failed geocode collapses the prompt silently, stores nothing, and may ask again later",
         %{conn: conn, scope: scope} do
      GeocoderHTTPStub.stub(fn _url, _opts -> {:ok, %{status: 500, body: ""}} end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")

      view
      |> form("#area-prompt-form",
        area: %{search_area: "Nowhere-#{System.unique_integer([:positive])}"}
      )
      |> render_submit()

      html = render_async(view, 2000)

      # Silence: no prompt, no flash, no error, no shimmer — the card as typed.
      refute html =~ "Where should we look?"
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
      refute has_element?(view, ".assist-shim")
      assert html =~ "typed by you"
      assert html =~ "no details yet"
      assert Activities.get_group!(scope, group.id).search_area == nil

      # The area is still unset and nobody dismissed anything, so a later add asks again.
      add_typed(view, "Zahav")
      assert render(view) =~ "Where should we look?"
    end

    test "an over-long area is an inline changeset error, never a geocode",
         %{conn: conn, scope: scope} do
      test_pid = self()

      GeocoderHTTPStub.stub(fn _url, _opts ->
        send(test_pid, :geocode_called)
        {:error, :nope}
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_typed(view, "Vernick")

      html =
        view
        |> form("#area-prompt-form", area: %{search_area: String.duplicate("a", 101)})
        |> render_submit()

      # Organizer form input, not a lookup — the silence rules don't bind it.
      assert html =~ "should be at most 100"
      assert html =~ "Where should we look?"
      refute_receive :geocode_called, 100
      assert Activities.get_group!(scope, group.id).search_area == nil
    end
  end

  describe "the failure trio renders nothing (no match / provider error / timeout)" do
    for {label, outcome} <- [
          no_match: {:ok, []},
          provider_error: {:error, :rate_limited},
          timeout: {:error, :timeout}
        ] do
      test "#{label}: the settled card is element-for-element a plain typed add with the feature idle",
           %{conn: conn, scope: scope} do
        outcome = unquote(Macro.escape(outcome))

        # Baseline: the same typed add on a screen where the feature does not exist
        # at all (empty registry), normalised over the ids that necessarily differ.
        baseline =
          with_registry(%{}, fn ->
            group = group_with_area(scope)
            {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")
            add_typed(view, "Vernick")
            activity = only_activity(scope, group)
            normalize_card(view |> element("#activities-#{activity.id}") |> render())
          end)

        DiscoveryStub.stub_search(fn _q, _a, _o -> outcome end)
        group = group_with_area(scope)
        {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")
        add_typed(view, "Vernick")
        render_async(view)
        activity = only_activity(scope, group)

        settled = normalize_card(view |> element("#activities-#{activity.id}") |> render())

        assert settled == baseline,
               "after #{inspect(outcome)} the card differs from a plain typed add:\n" <>
                 "expected: #{baseline}\ngot:      #{settled}"

        # And nothing anywhere else either: no flash, no slot, no shimmer.
        refute has_element?(view, "#flash-error")
        refute has_element?(view, "#flash-info")
        refute has_element?(view, ".assist-shim")
        refute render(view) =~ "Is this it?"
      end
    end
  end

  describe "no registered provider — the feature is invisible" do
    test "a typed add renders no assist markup at all and 02 works end to end",
         %{conn: conn, scope: scope} do
      with_registry(%{}, fn ->
        group = group_with_area(scope)
        {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

        add_typed(view, "Osteria Mozza")
        html = render(view)

        assert html =~ "Osteria Mozza"
        assert html =~ "typed by you"
        assert html =~ "no details yet"
        refute html =~ "assist-shim"
        refute html =~ "assist-slot"
        refute html =~ "Is this it?"
        refute html =~ "Where should we look?"

        # The screen still works end to end: edit, come back, review unlocks.
        activity = only_activity(scope, group)
        view |> element(~s(a[href$="/options/#{activity.id}"])) |> render_click()

        view
        |> form("#edit-option-form", activity: %{name: "Osteria", description: ""})
        |> render_submit()

        assert render(view) =~ "Osteria"
        assert has_element?(view, ~s|a#review-cta[href="/groups/#{group.id}/review"]|)
      end)
    end
  end

  defp count_occurrences(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end

  # The two cards being compared belong to different groups/activities, so their DOM
  # ids and hrefs differ by exactly those integers; everything else must be identical.
  # Both cards are position 1 with the same name, so digit-normalisation is symmetric.
  defp normalize_card(html), do: String.replace(html, ~r/\d+/, "N")
end
