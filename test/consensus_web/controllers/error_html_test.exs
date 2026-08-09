defmodule ConsensusWeb.ErrorHTMLTest do
  use ConsensusWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  describe "the two pages a person can land on" do
    test "404 wears the chrome and offers a way into the app" do
      html = render_to_string(ConsensusWeb.ErrorHTML, "404", "html", conn: build_conn())

      # The chrome, because a mistyped `/join/<slug>` is the likeliest 404 in this
      # product and the generator's answer to it was the unstyled words "Not Found".
      assert html =~ ~s(id="chrome-wordmark")
      assert html =~ "Made with"
      assert html =~ ~s(href="/")
      assert html =~ "nothing at this address"

      # `:marketing`, not `:app`: an unmatched path raises before any pipeline runs, so
      # there is no `current_scope` and the page cannot know who is looking at it.
      refute html =~ ~s(id="chrome-menu")
    end

    test "500 says nothing already sent was lost" do
      html = render_to_string(ConsensusWeb.ErrorHTML, "500", "html", conn: build_conn())

      assert html =~ ~s(id="chrome-wordmark")
      assert html =~ "Something broke on our side"
      assert html =~ ~s(href="/")
    end
  end

  test "an unmatched path really does serve that page, head and stylesheet included", %{
    conn: conn
  } do
    # `render_to_string/4` above proves the template; only going through the endpoint
    # proves the `root_layout:` in `config/config.exs`'s `render_errors`. Without it
    # the body comes back as a bare fragment with no `<head>` — so no stylesheet, and
    # the chrome renders as unstyled text.
    conn = get(conn, "/definitely-not-a-route")

    assert conn.status == 404
    assert conn.resp_body =~ "<!DOCTYPE html>"
    assert conn.resp_body =~ ~s(href="/assets/css/app.css")
    assert conn.resp_body =~ "nothing at this address"
  end

  test "every other status keeps the generator's plain-text body" do
    assert render_to_string(ConsensusWeb.ErrorHTML, "429", "html", []) == "Too Many Requests"
  end
end
