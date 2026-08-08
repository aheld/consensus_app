defmodule Consensus.LinkPreviewTest do
  # async: false: the cache is a single named ETS table shared by the whole app (it is
  # a real child of Consensus.Application, not started per test), and some cases below
  # override the :cache_error_ttl_ms application env to make an expiry observable in
  # milliseconds rather than minutes — both are process-global state.
  use ExUnit.Case, async: false

  alias Consensus.LinkPreview
  alias Consensus.LinkPreviewStub, as: StubFetcher

  setup do
    LinkPreview.Cache.flush()
    StubFetcher.stub(fn _url, _opts -> {:error, :not_configured} end)
    :ok
  end

  defp html_response(url, body, extra_headers \\ []) do
    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "text/html; charset=utf-8"} | extra_headers],
       body: body,
       url: url
     }}
  end

  describe "fetch/1 — OpenGraph extraction" do
    test "prefers OpenGraph tags, in either attribute order" do
      html = """
      <html><head>
        <meta content="A Great Article" property="og:title">
        <meta property="og:description" content="Read all about it.">
        <meta property='og:image' content='/media/cover.jpg'>
        <meta property="og:site_name" content="Example News">
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/article")
      assert preview.title == "A Great Article"
      assert preview.description == "Read all about it."
      assert preview.image_url == "http://192.0.2.10/media/cover.jpg"
      assert preview.site_name == "Example News"
      assert preview.url == "http://192.0.2.10/article"
      assert %DateTime{} = preview.fetched_at
    end
  end

  describe "fetch/1 — fallbacks" do
    test "falls back to <title> when og:title is absent" do
      html = "<html><head><title>Plain Title</title></head></html>"
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/plain")
      assert preview.title == "Plain Title"
    end

    test "falls back to <meta name=description> when og:description is absent" do
      html = ~s(<html><head><meta name="description" content="Fallback text."></head></html>)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/plain2")
      assert preview.description == "Fallback text."
    end

    test "falls back to <link rel=image_src> when og:image is absent" do
      html = ~s(<html><head><link rel="image_src" href="/img/pic.png"></head></html>)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/plain3")
      assert preview.image_url == "http://192.0.2.10/img/pic.png"
    end
  end

  describe "fetch/1 — relative og:image resolution" do
    test "resolves a relative og:image against the final URL" do
      html = ~s(<meta property="og:image" content="../assets/cover.png">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/blog/post-1")
      assert preview.image_url == "http://192.0.2.10/assets/cover.png"
    end
  end

  describe "fetch/1 — entity decoding" do
    test "decodes named and numeric HTML entities in text fields" do
      html = ~s(<meta property="og:title" content="Fish &amp; Chips &#8212; Rob&#39;s Diner">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/entities")
      assert preview.title == "Fish & Chips — Rob's Diner"
    end

    test "decodes HTML entities in og:image before resolving it, not after" do
      # Shaped after the real markup on https://en.wikipedia.org/wiki/Pizza, whose
      # og:image query string joins params with `&amp;`. Decoding after resolution
      # (or not at all) leaves a literal "&amp;" in the stored/rendered URL, which
      # only works by accident on hosts tolerant of a mangled query string.
      html =
        ~s(<meta property="og:image" content="https://upload.example.org/pizza.jpg?utm_source=en.wikipedia.org&amp;utm_campaign=index&amp;utm_content=thumbnail">)

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/wiki-like")

      assert preview.image_url ==
               "https://upload.example.org/pizza.jpg?utm_source=en.wikipedia.org&utm_campaign=index&utm_content=thumbnail"
    end

    test "decodes a relative og:image's entities before resolving against the final URL" do
      html = ~s(<meta property="og:image" content="/img?a=1&amp;b=2">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/post")
      assert preview.image_url == "http://192.0.2.10/img?a=1&b=2"
    end
  end

  describe "fetch/1 — description truncation" do
    test "truncates description to 140 characters on a word boundary" do
      long_description =
        Enum.map_join(1..30, " ", fn n -> "word#{n}" end)

      assert String.length(long_description) > 140

      html = ~s(<meta property="og:description" content="#{long_description}">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/long")
      assert String.length(preview.description) <= 140
      refute String.ends_with?(preview.description, " ")
      # Truncated on a word boundary: what remains is a strict prefix made only of
      # whole words from the original text, never a word sliced mid-way.
      assert String.starts_with?(long_description, preview.description)
      next_char = String.at(long_description, String.length(preview.description))
      assert next_char in [" ", nil]
    end

    test "leaves a short description untouched" do
      html = ~s(<meta property="og:description" content="Short and sweet.">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/short")
      assert preview.description == "Short and sweet."
    end
  end

  describe "fetch/1 — invalid URLs" do
    test "rejects a non-URL string" do
      assert LinkPreview.fetch("not a url") == {:error, :invalid_url}
    end

    test "rejects a non-http(s) scheme" do
      assert LinkPreview.fetch("ftp://192.0.2.10/file.txt") == {:error, :invalid_url}
    end

    test "rejects a URL with no host" do
      assert LinkPreview.fetch("http:///no-host") == {:error, :invalid_url}
    end
  end

  describe "fetch/1 — SSRF guard" do
    test "blocks 127.0.0.1" do
      assert LinkPreview.fetch("http://127.0.0.1/") == {:error, :blocked_host}
    end

    test "blocks localhost" do
      assert LinkPreview.fetch("http://localhost/") == {:error, :blocked_host}
    end

    test "blocks a 10/8 address" do
      assert LinkPreview.fetch("http://10.0.0.1/") == {:error, :blocked_host}
    end

    test "blocks the cloud metadata link-local address" do
      assert LinkPreview.fetch("http://169.254.169.254/") == {:error, :blocked_host}
    end

    test "never calls the fetcher for a blocked host" do
      test_pid = self()
      StubFetcher.stub(fn url, _opts -> send(test_pid, {:fetched, url}) end)

      LinkPreview.fetch("http://127.0.0.1/")

      refute_receive {:fetched, _url}
    end
  end

  describe "fetch/1 — redirects" do
    test "follows redirects up to the limit and blocks the one past it" do
      chain = %{
        "http://192.0.2.10/start" => "http://192.0.2.10/hop1",
        "http://192.0.2.10/hop1" => "http://192.0.2.10/hop2",
        "http://192.0.2.10/hop2" => "http://192.0.2.10/hop3",
        "http://192.0.2.10/hop3" => "http://192.0.2.10/hop4"
      }

      StubFetcher.stub(fn url, _opts ->
        case Map.fetch(chain, url) do
          {:ok, next} -> {:ok, %{status: 301, headers: [{"location", next}], body: "", url: url}}
          :error -> html_response(url, "<title>Destination</title>")
        end
      end)

      assert LinkPreview.fetch("http://192.0.2.10/start") == {:error, :too_many_redirects}
    end

    test "follows a redirect within the limit through to success" do
      StubFetcher.stub(fn
        "http://192.0.2.10/redir", _opts ->
          {:ok,
           %{
             status: 302,
             headers: [{"location", "http://192.0.2.10/final"}],
             body: "",
             url: "http://192.0.2.10/redir"
           }}

        url, _opts ->
          html_response(url, "<title>Landed</title>")
      end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/redir")
      assert preview.title == "Landed"
      assert preview.url == "http://192.0.2.10/final"
    end

    test "re-checks the SSRF guard on a redirect hop" do
      StubFetcher.stub(fn
        "http://192.0.2.10/evil-redirect", _opts ->
          {:ok,
           %{
             status: 302,
             headers: [{"location", "http://127.0.0.1/secret"}],
             body: "",
             url: "http://192.0.2.10/evil-redirect"
           }}

        url, _opts ->
          html_response(url, "<title>Should not be reached</title>")
      end)

      assert LinkPreview.fetch("http://192.0.2.10/evil-redirect") == {:error, :blocked_host}
    end
  end

  describe "fetch/1 — non-HTML and HTTP errors" do
    test "rejects a non-HTML content type" do
      StubFetcher.stub(fn url, _opts ->
        {:ok,
         %{status: 200, headers: [{"content-type", "application/json"}], body: "{}", url: url}}
      end)

      assert LinkPreview.fetch("http://192.0.2.10/api") == {:error, :not_html}
    end

    test "surfaces a 500 as {:error, {:http, 500}}" do
      StubFetcher.stub(fn url, _opts ->
        {:ok, %{status: 500, headers: [], body: "boom", url: url}}
      end)

      assert LinkPreview.fetch("http://192.0.2.10/broken") == {:error, {:http, 500}}
    end
  end

  describe "fetch/1 — fetcher failures never raise" do
    test "a fetcher that raises is caught and logged as :fetch_failed" do
      StubFetcher.stub(fn _url, _opts -> raise "kaboom" end)

      assert LinkPreview.fetch("http://192.0.2.10/raises") == {:error, :fetch_failed}
    end

    test "a fetcher transport error becomes :fetch_failed" do
      StubFetcher.stub(fn _url, _opts -> {:error, :timeout} end)

      assert LinkPreview.fetch("http://192.0.2.10/timeout") == {:error, :fetch_failed}
    end
  end

  describe "fetch/1 — caching" do
    test "a second fetch of the same URL does not call the fetcher again" do
      test_pid = self()

      StubFetcher.stub(fn url, _opts ->
        send(test_pid, {:fetched, url})
        html_response(url, "<title>Cached Page</title>")
      end)

      assert {:ok, _} = LinkPreview.fetch("http://192.0.2.10/cache-me")
      assert_receive {:fetched, "http://192.0.2.10/cache-me"}

      assert {:ok, _} = LinkPreview.fetch("http://192.0.2.10/cache-me")
      refute_receive {:fetched, _url}
    end

    test "a cached error expires on the shorter error TTL" do
      original = Application.get_env(:consensus, Consensus.LinkPreview)

      Application.put_env(
        :consensus,
        Consensus.LinkPreview,
        Keyword.put(original, :cache_error_ttl_ms, 100)
      )

      on_exit(fn -> Application.put_env(:consensus, Consensus.LinkPreview, original) end)

      test_pid = self()

      StubFetcher.stub(fn url, _opts ->
        send(test_pid, {:fetched, url})
        {:error, :timeout}
      end)

      assert LinkPreview.fetch("http://192.0.2.10/flaky") == {:error, :fetch_failed}
      assert_receive {:fetched, _url}

      # Still within the (tiny) TTL: cached, no second call.
      assert LinkPreview.fetch("http://192.0.2.10/flaky") == {:error, :fetch_failed}
      refute_receive {:fetched, _url}

      Process.sleep(150)

      assert LinkPreview.fetch("http://192.0.2.10/flaky") == {:error, :fetch_failed}
      assert_receive {:fetched, _url}
    end
  end
end
