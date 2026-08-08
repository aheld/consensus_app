defmodule ConsensusWeb.AdminLive.HomePageTest do
  use ConsensusWeb.ConnCase

  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures

  alias Consensus.Content
  alias Consensus.Content.HomePage

  describe "authorization" do
    test "redirects an anonymous visitor to the log-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, ~p"/admin/home-page")

      assert to == ~p"/users/log-in"
      assert flash["error"] =~ "must log in"
    end

    test "redirects a signed-in member home", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:redirect, %{to: to, flash: flash}}} = live(conn, ~p"/admin/home-page")
      assert to == ~p"/"
      assert flash["error"] =~ "do not have access"
    end

    test "lets an admin in", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin/home-page")
      assert html =~ "Home page message"
    end
  end

  describe "editing" do
    setup %{conn: conn} do
      admin = admin_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "saves a new message and shows it on the public page", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/home-page")

      assert lv
             |> form("#home-page-form", home_page: %{message: "Tacos on Thursday"})
             |> render_submit() =~ "Home page updated"

      home_page = Content.get_home_page()
      assert home_page.message == "Tacos on Thursday"
      assert home_page.updated_by_id == admin.id

      {:ok, _home, html} = live(build_conn(), ~p"/")
      assert html =~ "Tacos on Thursday"
    end

    test "shows a validation error for a blank message", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/home-page")

      html =
        lv
        |> form("#home-page-form", home_page: %{message: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Content.get_home_page().message == Content.default_message()
    end

    test "validates as you type", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/home-page")

      html =
        lv
        |> form("#home-page-form", home_page: %{message: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "the length limit" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_fixture())}
    end

    defp counter(html) do
      case Regex.run(~r|id="message-counter".*?>\s*(.*?)\s*</p>|s, html) do
        [_, body] -> body |> String.replace(~r/\s+/, " ") |> String.trim()
        nil -> flunk(~s|no <p id="message-counter"> element in the rendered page|)
      end
    end

    test "the counter starts at the stored message's length", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/home-page")

      length = String.length(Content.get_home_page().message)
      assert counter(html) == "#{length} / #{HomePage.max_message_length()} characters"
    end

    test "the counter counts graphemes, the way the server does", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/home-page")

      # Three graphemes and six UTF-16 code units. A browser `maxlength` would count six;
      # `validate_length/3` counts three. The counter has to agree with the validator,
      # otherwise it is a second wrong number rather than a fix for the first.
      html = lv |> form("#home-page-form", home_page: %{message: "🙂🙂🙂"}) |> render_change()

      assert counter(html) == "3 / #{HomePage.max_message_length()} characters"
    end

    test "the textarea does not silently truncate a long paste", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/home-page")

      # `maxlength` is enforced by the browser in UTF-16 code units while the server
      # validates graphemes, and its failure mode is to drop the tail of a paste without
      # saying anything. The counter plus the changeset error replace it.
      refute html =~ "maxlength"
    end

    test "an over-long message is refused with an error the admin can read", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/home-page")
      too_long = String.duplicate("a", HomePage.max_message_length() + 1)

      html = lv |> form("#home-page-form", home_page: %{message: too_long}) |> render_submit()

      assert html =~ "should be at most #{HomePage.max_message_length()} character(s)"
      assert counter(html) == "2001 / #{HomePage.max_message_length()} characters"
      assert Content.get_home_page().message == Content.default_message()
    end
  end
end
