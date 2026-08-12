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

  describe "fetch/1 — JSON-LD precedence (F3)" do
    defp ld_script(json),
      do: ~s(<script type="application/ld+json">#{json}</script>)

    test "OpenGraph still wins over JSON-LD on every field" do
      html = """
      <html><head>
        <meta property="og:title" content="OG Title">
        <meta property="og:description" content="OG description.">
        <meta property="og:image" content="https://example.test/og.jpg">
        <meta property="og:site_name" content="OG Site">
        #{ld_script(~s({"@type":"Recipe","name":"LD Title","description":"LD description.","image":"https://example.test/ld.jpg","publisher":{"name":"LD Site"}}))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/og-wins")
      assert preview.title == "OG Title"
      assert preview.description == "OG description."
      assert preview.image_url == "https://example.test/og.jpg"
      assert preview.site_name == "OG Site"
    end

    test "JSON-LD fills every field OpenGraph left empty" do
      html = """
      <html><head>
        #{ld_script(~s({"@type":"Recipe","name":"Focaccia","description":"Slow rise, dimpled, olive oil.","image":"https://example.test/f.jpg","publisher":{"@type":"Organization","name":"A Food Blog"}}))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/ld-fills")
      assert preview.title == "Focaccia"
      assert preview.description == "Slow rise, dimpled, olive oil."
      assert preview.image_url == "https://example.test/f.jpg"
      assert preview.site_name == "A Food Blog"
    end

    test "JSON-LD outranks the plain <title>, which is the whole point" do
      html = """
      <html><head>
        <title>Focaccia Recipe | A Food Blog | Best Breads 2026</title>
        #{ld_script(~s({"@type":"Recipe","name":"Focaccia"}))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/ld-beats-title")
      assert preview.title == "Focaccia"
    end

    test "a blank og:title falls through to JSON-LD instead of blanking the card" do
      html = """
      <html><head>
        <meta property="og:title" content="">
        #{ld_script(~s({"@type":"Movie","name":"The Third Man"}))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/blank-og")
      assert preview.title == "The Third Man"
    end

    test "a relative JSON-LD image resolves against the page URL" do
      html = ld_script(~s({"@type":"Recipe","name":"X","image":"/media/dish.jpg"}))
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/recipes/dish")
      assert preview.image_url == "http://192.0.2.10/media/dish.jpg"
    end

    test "a JSON-LD description is truncated by the same 140-character cap" do
      long = String.duplicate("tomato ", 40)
      html = ld_script(~s({"@type":"Recipe","name":"X","description":"#{long}"}))
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/long-ld")
      assert String.length(preview.description) <= 140
    end

    test "malformed JSON-LD never costs a page its OpenGraph tags" do
      html = """
      <html><head>
        <meta property="og:title" content="Still Here">
        <meta property="og:image" content="https://example.test/og.jpg">
        #{ld_script(~s({"@type": "Recipe", "name": "Unterminated))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/broken-ld")
      assert preview.title == "Still Here"
      assert preview.image_url == "https://example.test/og.jpg"
    end
  end

  describe "fetch/1 — image URLs are http(s) only" do
    test "a javascript: og:image is dropped rather than passed to the card" do
      html = "<meta property=\"og:image\" content=\"javascript:alert(1)\">"
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/js-image")
      assert preview.image_url == nil
    end

    test "an unusable og:image falls through to the JSON-LD image" do
      html = """
      <html><head>
        <meta property="og:image" content="javascript:alert(1)">
        #{ld_script(~s({"@type":"Recipe","name":"X","image":"https://example.test/good.jpg"}))}
      </head></html>
      """

      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/js-then-ld")
      assert preview.image_url == "https://example.test/good.jpg"
    end

    test "a protocol-relative image still resolves normally" do
      html = ~s(<meta property="og:image" content="//cdn.example.test/x.jpg">)
      StubFetcher.stub(fn url, _opts -> html_response(url, html) end)

      assert {:ok, preview} = LinkPreview.fetch("http://192.0.2.10/proto-rel")
      assert preview.image_url == "http://cdn.example.test/x.jpg"
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

    test "blocks IPv4-mapped IPv6 literals — [::ffff:...] must answer as the embedded IPv4 would" do
      # The historical blind spot: the 8-tuple clause checked only fc00::/7, so a
      # mapped-IPv6 spelling of a blocked IPv4 target sailed through. Reachable
      # from a paste and from every Discovery adapter (research trap J).
      assert LinkPreview.fetch("http://[::ffff:127.0.0.1]/") == {:error, :blocked_host}
      assert LinkPreview.fetch("http://[::ffff:10.0.0.1]/") == {:error, :blocked_host}
      assert LinkPreview.fetch("http://[::ffff:169.254.169.254]/") == {:error, :blocked_host}
    end

    test "check_host/1 rejects every IPv6 shape that reaches a private target" do
      for host <- [
            # Mapped, in dotted and pure-hex spellings — same tuple either way.
            "::ffff:192.168.1.1",
            "::ffff:a9fe:a9fe",
            # Deprecated IPv4-compatible (::/96), loopback and unspecified.
            "::127.0.0.1",
            "::1",
            "::",
            # Unique local, link-local and deprecated site-local.
            "fc00::1",
            "fe80::1",
            "fec0::1",
            # 6to4 with an embedded 10.0.0.1, Teredo with a private server IPv4.
            "2002:a00:1::",
            "2001:0:c0a8:101::",
            # NAT64 well-known prefix (64:ff9b::/96) embedding 10.0.0.1.
            "64:ff9b::a00:1",
            # NAT64 local-use prefix (64:ff9b:1::/48, RFC 8215) embedding
            # 10.0.0.1 and 127.0.0.1 — the deployments most likely to
            # translate toward internal space, checked like the well-known
            # prefix.
            "64:ff9b:1::a00:1",
            "64:ff9b:1:ffff::7f00:1",
            # Teredo whose (bit-inverted) client words decode to 127.0.0.1.
            "2001:0:808:808:0:5000:80ff:fffe"
          ] do
        assert LinkPreview.check_host(host) == {:error, :blocked_host},
               "expected #{host} to be blocked"
      end

      # And the guard stays an allowlist of *dangerous* ranges, not a ban on
      # IPv6: a public address in any of those families still passes.
      for host <- ["2606:4700::1111", "::ffff:808:808", "2002:808:808::", "64:ff9b:1::808:808"] do
        assert LinkPreview.check_host(host) == :ok, "expected #{host} to pass"
      end
    end

    test "blocks 0.0.0.0/8 — connecting to 0.0.0.0 reaches loopback" do
      assert LinkPreview.fetch("http://0.0.0.0/") == {:error, :blocked_host}
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
