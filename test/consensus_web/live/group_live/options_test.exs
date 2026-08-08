defmodule ConsensusWeb.GroupLive.OptionsTest do
  use ConsensusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Activities
  alias Consensus.LinkPreviewStub

  # A TEST-NET-1 literal IP (RFC 5737) — never routable, and `Consensus.LinkPreview`'s
  # SSRF guard skips DNS resolution entirely for a literal IP, so fetches through the
  # stub never risk a real (and, in a sandboxed test run, possibly slow or hanging) DNS
  # lookup the way a named host like "sushienya.example" would.
  @link_host "192.0.2.10"

  setup :register_and_log_in_user

  setup do
    Consensus.LinkPreview.Cache.flush()
    LinkPreviewStub.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  # `ExUnit`'s async runner schedules individual tests concurrently (not just distinct
  # modules), and `Consensus.LinkPreview.Cache` is one real, process-global ETS table —
  # `flush/0` in `setup` only protects a test from an *earlier* one's leftovers, not
  # from a *concurrently running* one reusing the same URL. Each test that pastes or
  # refetches a link therefore gets its own cache key via a unique query string, while
  # the host (and so the provisional name) stays the constant `@link_host` above.
  defp unique_link_url, do: "http://#{@link_host}/menu?t=#{System.unique_integer([:positive])}"

  # `Consensus.Activities` has no single-activity getter (by design — see
  # `lib/consensus/activities.ex`), only a scoped group with its activities preloaded.
  defp fetch_activity(scope, group, activity_id) do
    Activities.get_group!(scope, group.id).activities |> Enum.find(&(&1.id == activity_id))
  end

  defp html_preview(opts \\ []) do
    title = Keyword.get(opts, :title, "Sushi Enya")
    description = Keyword.get(opts, :description, "Great sushi on Sunset.")
    image = Keyword.get(opts, :image, "https://#{@link_host}/photo.jpg")

    """
    <html><head>
      <meta property="og:title" content="#{title}">
      <meta property="og:description" content="#{description}">
      <meta property="og:image" content="#{image}">
    </head></html>
    """
  end

  describe "adding a plain name" do
    test "creates an activity with just a name and no link", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: "Osteria Mozza"})
      |> render_submit()

      html = render(view)
      assert html =~ "Osteria Mozza"
      assert html =~ "typed by you"

      assert [activity] = Activities.get_group!(scope, group.id).activities
      assert activity.name == "Osteria Mozza"
      assert activity.source_url == nil
      assert activity.added_by_id == scope.user.id
    end

    test "blank input is a no-op", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: "   "})
      |> render_submit()

      assert Activities.get_group!(scope, group.id).activities == []
    end
  end

  describe "adding a link" do
    test "creates the row immediately with a provisional name, then fills it in asynchronously",
         %{conn: conn, scope: scope} do
      test_pid = self()
      url = unique_link_url()

      # A stub that resolves instantly would race the assertions below — the async
      # task can complete before the "immediately" checks even run. Blocking until the
      # test explicitly releases it makes both halves (immediate row, async fill-in)
      # deterministic instead of depending on scheduler luck.
      LinkPreviewStub.stub(fn requested_url, _opts ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :continue ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/html"}],
               body: html_preview(),
               url: requested_url
             }}
        end
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: url})
      |> render_submit()

      assert_receive {:fetch_started, task_pid}, 1000

      # The row exists — with a provisional name and a pending provenance line —
      # before the fetch has resolved.
      assert [created] = Activities.get_group!(scope, group.id).activities
      assert created.name == @link_host
      assert created.source_url == url
      refute created.metadata_fetched_at
      assert render(view) =~ "fetching details"

      send(task_pid, :continue)
      html = render_async(view)

      assert html =~ "Sushi Enya"
      assert html =~ "photo + description pulled"
      refute html =~ @link_host

      assert [updated] = Activities.get_group!(scope, group.id).activities
      assert updated.name == "Sushi Enya"
      assert updated.description == "Great sushi on Sunset."
      assert updated.image_url == "https://#{@link_host}/photo.jpg"
      assert updated.metadata_fetched_at
    end

    test "does not overwrite a name the organizer already edited before the fetch resolved",
         %{conn: conn, scope: scope} do
      test_pid = self()
      url = unique_link_url()

      LinkPreviewStub.stub(fn requested_url, _opts ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :continue ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/html"}],
               body: html_preview(),
               url: requested_url
             }}
        end
      end)

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: url})
      |> render_submit()

      assert_receive {:fetch_started, task_pid}, 1000

      [created] = Activities.get_group!(scope, group.id).activities

      # Same LiveView process/socket as the one holding the pending task — the design
      # reaches 02b via `push_patch`, not a fresh mount, and the "unless already
      # edited" guard only makes sense within one session.
      view
      |> element(~s|a[href="/groups/#{group.id}/options/#{created.id}"]|)
      |> render_click()

      view
      |> form("#edit-option-form", activity: %{name: "My Own Name", description: ""})
      |> render_submit()

      send(task_pid, :continue)
      render_async(view)

      assert fetch_activity(scope, group, created.id).name == "My Own Name"
    end

    test "a failing fetch leaves a usable row with the error provenance line", %{
      conn: conn,
      scope: scope
    } do
      LinkPreviewStub.stub(fn _url, _opts -> {:error, :timeout} end)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: url})
      |> render_submit()

      html = render_async(view)
      assert html =~ "couldn&#39;t read that page"
      assert html =~ @link_host

      assert [activity] = Activities.get_group!(scope, group.id).activities
      assert activity.name == @link_host
      assert activity.source_url == url
      refute activity.metadata_fetched_at
    end

    test "a crashing fetch is handled the same as a returned error", %{conn: conn, scope: scope} do
      LinkPreviewStub.stub(fn _url, _opts -> raise "boom" end)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> form("#add-option-form", add_option: %{query: url})
      |> render_submit()

      html = render_async(view)
      assert html =~ "couldn&#39;t read that page"
      assert Process.alive?(view.pid)
    end
  end

  describe "the provenance line" do
    # Regression coverage for the bug the critic found: the line used to be driven by
    # "did a fetch happen" rather than by what the fetch actually returned, so a page
    # with no og:description still read "photo + description pulled". Each fixture
    # below *omits* the meta tag for the field under test rather than giving it an
    # empty `content=""` — `Consensus.LinkPreview` resolves a blank relative image URL
    # against the page's own URL and gets the page URL back, not nil, so an empty
    # attribute would not actually exercise the "no image" case.
    defp add_link(view, url) do
      view |> form("#add-option-form", add_option: %{query: url}) |> render_submit()
    end

    test "reports photo-only when the fetch found an image but no description",
         %{conn: conn, scope: scope} do
      html = """
      <html><head>
        <meta property="og:title" content="Sushi Enya">
        <meta property="og:image" content="https://#{@link_host}/photo.jpg">
      </head></html>
      """

      LinkPreviewStub.stub_html(html)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_link(view, url)
      rendered = render_async(view)

      assert rendered =~ "photo pulled"
      refute rendered =~ "description pulled"
      refute rendered =~ "photo + description"

      activity = List.first(Activities.get_group!(scope, group.id).activities)
      assert activity.image_url
      refute activity.description
    end

    test "reports description-only when the fetch found a description but no image",
         %{conn: conn, scope: scope} do
      html = """
      <html><head>
        <meta property="og:title" content="Sushi Enya">
        <meta property="og:description" content="Great sushi on Sunset.">
      </head></html>
      """

      LinkPreviewStub.stub_html(html)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_link(view, url)
      rendered = render_async(view)

      assert rendered =~ "description pulled"
      refute rendered =~ "photo pulled"
      refute rendered =~ "photo + description"

      activity = List.first(Activities.get_group!(scope, group.id).activities)
      refute activity.image_url
      assert activity.description
    end

    test "reports nothing found when the fetch succeeded but the page had neither",
         %{conn: conn, scope: scope} do
      html = "<html><head><title>Untitled</title></head></html>"

      LinkPreviewStub.stub_html(html)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_link(view, url)
      rendered = render_async(view)

      assert rendered =~ "nothing useful found"
      refute rendered =~ "pulled"

      activity = List.first(Activities.get_group!(scope, group.id).activities)
      assert activity.metadata_fetched_at, "a successful-but-empty fetch must still be recorded"
    end

    test "reports both when the fetch found a photo and a description", %{
      conn: conn,
      scope: scope
    } do
      LinkPreviewStub.stub_html(html_preview())
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      add_link(view, url)
      rendered = render_async(view)

      assert rendered =~ "photo + description pulled"
    end

    test "a failed fetch still reads as failed after a full remount, not as untried",
         %{conn: conn, scope: scope} do
      LinkPreviewStub.stub(fn _url, _opts -> {:error, :timeout} end)
      url = unique_link_url()

      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")
      add_link(view, url)
      render_async(view)

      # A brand-new mount — new LiveView process, no `@fetching` socket state carried
      # over from the one above. The failure has to be read back off the row itself
      # (`source_url` set, `metadata_fetched_at` nil) or it silently reverts to
      # looking untried ("no details yet").
      {:ok, fresh_view, html} = live(conn, ~p"/groups/#{group}/options")
      assert html =~ "couldn&#39;t read that page"
      refute html =~ "no details yet"
      assert Process.alive?(fresh_view.pid)
    end
  end

  describe "editing an option" do
    test "renders the option's stored values without re-asking (never re-enter anything)",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)

      activity =
        activity_fixture(group, %{
          name: "Guisados",
          description: "Handmade tacos on Sunset.",
          image_url: "https://#{@link_host}/g.jpg",
          source_url: "https://#{@link_host}/guisados",
          metadata_fetched_at: DateTime.utc_now(:second)
        })

      {:ok, view, html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      assert html =~ "Edit option"
      assert has_element?(view, ~s(input[name="activity[name]"][value="Guisados"]))
      assert render(view) =~ "Handmade tacos on Sunset."
      assert render(view) =~ "https://#{@link_host}/guisados"
      assert render(view) =~ "PULLED FROM LINK"
    end

    test "the description counter moves live as you type", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{description: "short"})

      {:ok, view, html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")
      assert html =~ "5/140"

      view
      |> form("#edit-option-form",
        activity: %{name: activity.name, description: String.duplicate("a", 62)}
      )
      |> render_change()

      assert render(view) =~ "62/140"
    end

    test "the 140-character cap rejects a longer description on save, changeset not maxlength alone",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{description: "short"})

      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      too_long = String.duplicate("a", 141)

      html =
        view
        |> form("#edit-option-form", activity: %{name: activity.name, description: too_long})
        |> render_submit()

      assert html =~ "at most 140"

      assert Activities.get_group!(scope, group.id).activities |> hd() |> Map.get(:description) ==
               "short"
    end

    test "saving valid changes patches back to the pool", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Old Name"})

      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      view
      |> form("#edit-option-form", activity: %{name: "New Name", description: "A place."})
      |> render_submit()

      assert_patched(view, ~p"/groups/#{group}/options")
      assert render(view) =~ "New Name"
      assert fetch_activity(scope, group, activity.id).name == "New Name"
    end

    test "Refetch overwrites description, image and timestamp via a start_async", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope)

      activity =
        activity_fixture(group, %{
          name: "Kept Name",
          source_url: unique_link_url(),
          description: "stale"
        })

      LinkPreviewStub.stub_html(html_preview(description: "Fresh description."))

      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      view |> element(~s|button[phx-click="refetch"]|) |> render_click()

      html = render_async(view)
      assert html =~ "Fresh description."
      # Name is deliberately untouched by a manual refetch on the edit screen.
      assert html =~ "Kept Name"

      updated = fetch_activity(scope, group, activity.id)
      assert updated.name == "Kept Name"
      assert updated.description == "Fresh description."
    end

    test "Remove deletes the option and returns to the pool", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      activity = activity_fixture(group, %{name: "Doomed"})

      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options/#{activity.id}")

      view |> element(~s|button[phx-click="remove_option"]|) |> render_click()

      assert_patched(view, ~p"/groups/#{group}/options")
      # Scoped to the pool list, not the whole page — the flash ("Doomed removed.")
      # legitimately names the deleted option once.
      refute view |> element("#pool-list") |> render() =~ "Doomed"
      assert Activities.get_group!(scope, group.id).activities == []
    end
  end

  describe "deleting from the pool" do
    test "renumbers the remaining positions", %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      a1 = activity_fixture(group, %{name: "First"})
      a2 = activity_fixture(group, %{name: "Second"})
      a3 = activity_fixture(group, %{name: "Third"})

      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      view
      |> element(~s|button[phx-click="delete_activity"][phx-value-id="#{a2.id}"]|)
      |> render_click()

      remaining = Activities.get_group!(scope, group.id).activities |> Enum.sort_by(& &1.position)
      assert Enum.map(remaining, & &1.name) == ["First", "Third"]
      assert Enum.map(remaining, & &1.position) == [1, 2]
      assert Enum.map(remaining, & &1.id) == [a1.id, a3.id]

      html = render(view)
      assert html =~ "First"
      assert html =~ "Third"
      refute html =~ "Second"
    end
  end

  describe "Review →" do
    test "is disabled while the pool is empty and enables once it has an option", %{
      conn: conn,
      scope: scope
    } do
      group = group_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/groups/#{group}/options")

      # The Tailwind class list itself contains the literal substring "disabled"
      # (`disabled:cursor-not-allowed`, ...) whether or not the control actually is,
      # so these assert on the HTML attribute and the tag, not a text search.
      assert has_element?(view, "button#review-cta[disabled]")
      refute has_element?(view, "a#review-cta")

      view
      |> form("#add-option-form", add_option: %{query: "Osteria Mozza"})
      |> render_submit()

      refute has_element?(view, "button#review-cta[disabled]")
      assert has_element?(view, ~s|a#review-cta[href="/groups/#{group.id}/review"]|)
    end
  end

  describe "authorization" do
    test "another organizer's group is refused, not merely hidden", %{conn: conn} do
      stranger_scope = user_scope_fixture(user_fixture())
      group = group_fixture(stranger_scope)

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/groups/#{group}/options") end
    end

    test "another organizer's activity_id under your own group is treated as not found",
         %{conn: conn, scope: scope} do
      group = group_fixture(scope)
      stranger_scope = user_scope_fixture(user_fixture())
      other_group = group_fixture(stranger_scope)
      foreign_activity = activity_fixture(other_group)

      # The redirect happens during the very first `handle_params`, before `live/2`
      # ever hands back a `%View{}` — so it surfaces as a live-redirect error tuple,
      # not as something to `assert_patch/2` against on a mounted view.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/groups/#{group}/options/#{foreign_activity.id}")

      assert to == ~p"/groups/#{group}/options"
      assert flash["error"] =~ "Could not find that option"
    end
  end
end
