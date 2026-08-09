defmodule ConsensusWeb.CurrentPathTest do
  @moduledoc """
  `safe_return_to/1` is the only thing standing between `?return_to=` — a query parameter,
  and therefore attacker-controlled — and a `<.link navigate={...}>` on four pages that
  wear this app's chrome. An open redirect out of a page a visitor believes is ours is
  exactly the shape a credential-phishing link wants, so the rejections are pinned here
  rather than left to the `back={@return_to}` call sites.
  """
  use ExUnit.Case, async: true

  alias ConsensusWeb.CurrentPath

  describe "safe_return_to/1" do
    test "accepts a local absolute path, query and all" do
      assert CurrentPath.safe_return_to("/groups/12/options") == "/groups/12/options"
      assert CurrentPath.safe_return_to("/feedback?mood=sad") == "/feedback?mood=sad"
      assert CurrentPath.safe_return_to("/") == "/"
    end

    test "rejects anything that could leave this site" do
      # `//host/x` and `/\host/x` are both protocol-relative to a browser.
      for hostile <- [
            "https://elsewhere.example/x",
            "//elsewhere.example/x",
            "/\\elsewhere.example/x",
            "javascript:alert(1)",
            "groups/12",
            "",
            nil,
            123
          ] do
        assert CurrentPath.safe_return_to(hostile) == nil,
               "#{inspect(hostile)} was accepted as a return path"
      end
    end
  end

  describe "return_to/1" do
    test "falls back to / rather than nil, so `back` is never an empty href" do
      assert CurrentPath.return_to(%{}) == "/"
      assert CurrentPath.return_to(%{"mood" => "sad"}) == "/"
      assert CurrentPath.return_to(%{"return_to" => "https://elsewhere.example"}) == "/"
    end

    test "hands back a local path unchanged" do
      assert CurrentPath.return_to(%{"return_to" => "/groups/3/review"}) == "/groups/3/review"
    end
  end
end
