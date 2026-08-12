defmodule Consensus.LinkPreview.JsonLdTest do
  @moduledoc """
  Unit tests for the `schema.org` JSON-LD parser (F3).

  These exercise `extract/1` directly, so the values asserted here are **raw** — not
  entity-decoded, not resolved against a base URL, not truncated. The precedence
  chain that places these values relative to OpenGraph, and the normalisation applied
  afterwards, are covered by the "JSON-LD" describes in
  `test/consensus/link_preview_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Consensus.LinkPreview.JsonLd

  defp script(json),
    do: ~s(<html><head><script type="application/ld+json">#{json}</script></head></html>)

  describe "extract/1 — the shapes a page actually ships" do
    test "reads name, description and image off a Recipe" do
      html =
        script("""
        {
          "@context": "https://schema.org",
          "@type": "Recipe",
          "name": "Salted Chocolate Chip Cookies",
          "description": "Brown butter, flaky salt, twelve hours in the fridge.",
          "image": "https://example.test/cookies.jpg"
        }
        """)

      assert %{
               title: "Salted Chocolate Chip Cookies",
               description: "Brown butter, flaky salt, twelve hours in the fridge.",
               image_url: "https://example.test/cookies.jpg"
             } = JsonLd.extract(html)
    end

    test "unwraps an @graph" do
      html =
        script("""
        {
          "@context": "https://schema.org",
          "@graph": [
            {"@type": "WebSite", "name": "Some Food Blog"},
            {"@type": "Recipe", "name": "Roast Chicken", "image": "https://example.test/c.jpg"}
          ]
        }
        """)

      assert %{title: "Roast Chicken", image_url: "https://example.test/c.jpg"} =
               JsonLd.extract(html)
    end

    test "handles a top-level array" do
      html =
        script("""
        [
          {"@type": "BreadcrumbList", "name": "Breadcrumbs"},
          {"@type": "Movie", "name": "The Third Man"}
        ]
        """)

      assert %{title: "The Third Man"} = JsonLd.extract(html)
    end

    test "reads the most specific member when @type is a list" do
      html =
        script("""
        {"@type": ["LocalBusiness", "Restaurant"], "name": "Vernick Food & Drink"}
        """)

      assert %{title: "Vernick Food & Drink"} = JsonLd.extract(html)
    end

    test "tolerates fully-qualified and prefixed type spellings" do
      for type <- ["http://schema.org/Recipe", "https://schema.org/Recipe", "schema:Recipe"] do
        html = script(~s({"@type": "#{type}", "name": "Tagine"}))
        assert %{title: "Tagine"} = JsonLd.extract(html), "failed for #{type}"
      end
    end

    test "reads across multiple ld+json blocks" do
      html = """
      <html><head>
        <script type="application/ld+json">{"@type": "Organization", "name": "A Site"}</script>
        <script type="application/ld+json">{"@type": "Book", "name": "The Dispossessed"}</script>
      </head></html>
      """

      assert %{title: "The Dispossessed"} = JsonLd.extract(html)
    end

    test "accepts a type attribute carrying parameters" do
      html =
        ~s(<html><script type="application/ld+json; charset=utf-8">{"@type":"Event","name":"Night Market"}</script></html>)

      assert %{title: "Night Market"} = JsonLd.extract(html)
    end
  end

  describe "extract/1 — choosing between eligible nodes" do
    test "a Recipe outranks an Article on the same page" do
      html = """
      <html><head>
        <script type="application/ld+json">{"@type": "Article", "name": "How I Developed This Recipe"}</script>
        <script type="application/ld+json">{"@type": "Recipe", "name": "Focaccia"}</script>
      </head></html>
      """

      assert %{title: "Focaccia"} = JsonLd.extract(html)
    end

    test "a Restaurant outranks the generic LocalBusiness parent" do
      html = """
      <html><head>
        <script type="application/ld+json">{"@type": "LocalBusiness", "name": "Generic Listing Entry"}</script>
        <script type="application/ld+json">{"@type": "Restaurant", "name": "Zahav"}</script>
      </head></html>
      """

      assert %{title: "Zahav"} = JsonLd.extract(html)
    end

    test "site-chrome types are ineligible — a page of only those yields nothing" do
      html = """
      <html><head>
        <script type="application/ld+json">{"@type": "Organization", "name": "Allrecipes"}</script>
        <script type="application/ld+json">{"@type": "WebSite", "name": "Allrecipes"}</script>
        <script type="application/ld+json">{"@type": "BreadcrumbList", "name": "Recipes > Desserts"}</script>
      </head></html>
      """

      assert %{title: nil, description: nil, image_url: nil, site_name: nil} =
               JsonLd.extract(html)
    end

    test "does not descend into nested properties like itemListElement" do
      html =
        script("""
        {
          "@type": "BreadcrumbList",
          "itemListElement": [{"@type": "Recipe", "name": "A Related Recipe Stub"}]
        }
        """)

      assert %{title: nil} = JsonLd.extract(html)
    end
  end

  describe "extract/1 — image shapes" do
    test "takes the first entry of an image array" do
      html =
        script(
          ~s({"@type":"Recipe","name":"X","image":["https://e.test/1.jpg","https://e.test/2.jpg"]})
        )

      assert %{image_url: "https://e.test/1.jpg"} = JsonLd.extract(html)
    end

    test "reads an ImageObject's url" do
      html =
        script(
          ~s({"@type":"Recipe","name":"X","image":{"@type":"ImageObject","url":"https://e.test/i.jpg"}})
        )

      assert %{image_url: "https://e.test/i.jpg"} = JsonLd.extract(html)
    end

    test "reads an ImageObject's contentUrl when it has no url" do
      html =
        script(
          ~s({"@type":"Recipe","name":"X","image":{"@type":"ImageObject","contentUrl":"https://e.test/c.jpg"}})
        )

      assert %{image_url: "https://e.test/c.jpg"} = JsonLd.extract(html)
    end

    test "reads an array of ImageObjects" do
      html = script(~s({"@type":"Movie","name":"X","image":[{"url":"https://e.test/a.jpg"}]}))
      assert %{image_url: "https://e.test/a.jpg"} = JsonLd.extract(html)
    end

    test "falls back to thumbnailUrl" do
      html = script(~s({"@type":"VideoObject","name":"X","thumbnailUrl":"https://e.test/t.jpg"}))
      assert %{image_url: "https://e.test/t.jpg"} = JsonLd.extract(html)
    end
  end

  describe "extract/1 — site_name from publisher" do
    test "reads an Organization publisher's name" do
      html =
        script(
          ~s({"@type":"Recipe","name":"X","publisher":{"@type":"Organization","name":"Serious Eats"}})
        )

      assert %{site_name: "Serious Eats"} = JsonLd.extract(html)
    end

    test "reads a bare string publisher" do
      html = script(~s({"@type":"Recipe","name":"X","publisher":"Serious Eats"}))
      assert %{site_name: "Serious Eats"} = JsonLd.extract(html)
    end
  end

  describe "extract/1 — failure is silence" do
    test "malformed JSON yields empty metadata rather than raising" do
      html = script(~s({"@type": "Recipe", "name": "Unterminated))

      assert %{title: nil, description: nil, image_url: nil, site_name: nil} =
               JsonLd.extract(html)
    end

    test "a page with no JSON-LD at all yields empty metadata" do
      assert %{title: nil, description: nil, image_url: nil, site_name: nil} =
               JsonLd.extract("<html><head><title>Nothing here</title></head></html>")
    end

    test "a script of another type is ignored" do
      html =
        ~s(<html><script type="text/javascript">{"@type":"Recipe","name":"Not Data"}</script></html>)

      assert %{title: nil} = JsonLd.extract(html)
    end

    test "a script with no type attribute is ignored" do
      html = ~s(<html><script>{"@type":"Recipe","name":"Not Data"}</script></html>)
      assert %{title: nil} = JsonLd.extract(html)
    end

    test "non-string name and description read as absent" do
      html = script(~s({"@type":"Recipe","name":{"@value":"Nested"},"description":42}))
      assert %{title: nil, description: nil} = JsonLd.extract(html)
    end

    test "blank strings read as absent" do
      html = script(~s({"@type":"Recipe","name":"   ","description":""}))
      assert %{title: nil, description: nil} = JsonLd.extract(html)
    end

    test "a JSON scalar rather than an object yields empty metadata" do
      assert %{title: nil} = JsonLd.extract(script("\"just a string\""))
      assert %{title: nil} = JsonLd.extract(script("42"))
      assert %{title: nil} = JsonLd.extract(script("null"))
    end

    test "deep nesting is bounded rather than exhausting the stack" do
      deep =
        Enum.reduce(1..200, ~s({"@type":"Recipe","name":"Deep"}), fn _, acc -> "[#{acc}]" end)

      assert %{title: nil} = JsonLd.extract(script(deep))
    end
  end
end
