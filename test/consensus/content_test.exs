defmodule Consensus.ContentTest do
  use Consensus.DataCase, async: true

  import Consensus.AccountsFixtures

  alias Consensus.Accounts.Scope
  alias Consensus.Content
  alias Consensus.Content.HomePage
  alias Consensus.Repo

  # The home page renders the message inside a `whitespace-pre-wrap` paragraph, so the
  # string's own line structure IS what the browser lays out — a newline in the source
  # is a forced break on screen. `mix format` cannot see that (it never reflows string
  # contents), so a source wrap added to fit the 98-column margin leaks into the landing
  # page of every fresh install with a clean format check and a green suite. The
  # "default_message/0" tests below are the only thing holding that contract.
  defp default_message_lines, do: String.split(Content.default_message(), "\n")

  describe "default_message/0" do
    test "no line carries leading or trailing whitespace" do
      for line <- default_message_lines() do
        assert line == String.trim(line),
               "the default message renders with surrounding whitespace on #{inspect(line)}; " <>
                 "with whitespace-pre-wrap the browser shows every one of those spaces"
      end
    end

    # A colon used to be accepted here alongside `.`, `!` and `?`, and that was a hole
    # rather than a nicety: the default message contains exactly one colon, mid-line, and
    # it is the single most tempting place to wrap the source line. Splitting there left
    # a fragment ending in ":" and a fragment ending in "." — both accepted, both wrong,
    # and the page grew a line break nobody asked for while the suite stayed green. Only
    # a sentence-ending mark ends a line now.
    test "every non-empty line ends a sentence instead of wrapping mid-thought" do
      for line <- default_message_lines(), line != "" do
        assert String.last(line) in [".", "!", "?"],
               "the default message breaks mid-sentence after #{inspect(line)}; " <>
                 "that is a source wrap leaking into the page — join the line with the " <>
                 "one that follows it, do not reflow prose to fit the source margin"
      end
    end

    # The mirror of the test above. That one catches a line that stops early; this catches
    # two sentences sharing a line, which is what a *re*flow produces — pull one line up to
    # fill the margin and the join lands mid-line as ". ". Together they pin the rendered
    # line structure to "one sentence per line" without pinning the prose itself.
    test "no line carries a second sentence" do
      for line <- default_message_lines(), line != "" do
        refute String.contains?(line, [". ", "! ", "? "]),
               "two sentences share one line in #{inspect(line)}; with whitespace-pre-wrap " <>
                 "that is a rendered line change — give each sentence its own list element"
      end
    end

    test "neither opens nor closes with a blank line" do
      lines = default_message_lines()

      assert List.first(lines) != ""
      assert List.last(lines) != ""
    end
  end

  describe "get_home_page/0" do
    test "falls back to the default message when nothing is stored yet" do
      home_page = Content.get_home_page()

      assert home_page.id == HomePage.singleton_id()
      assert home_page.message == Content.default_message()
      refute home_page.updated_at
    end

    test "returns the stored row once it exists" do
      Content.ensure_home_page!()
      assert %HomePage{} = home_page = Content.get_home_page()
      assert home_page.updated_at
    end
  end

  describe "ensure_home_page!/0" do
    test "is idempotent" do
      first = Content.ensure_home_page!()
      second = Content.ensure_home_page!()

      assert first.id == second.id
      assert Repo.aggregate(HomePage, :count) == 1
    end
  end

  describe "update_home_page/2" do
    setup do
      %{scope: admin_scope_fixture(), home_page: Content.ensure_home_page!()}
    end

    test "stores the message and records who wrote it", %{scope: scope} do
      assert {:ok, home_page} = Content.update_home_page(scope, %{message: "Dinner at 7."})
      assert home_page.message == "Dinner at 7."
      assert home_page.updated_by_id == scope.user.id
      assert Content.get_home_page().message == "Dinner at 7."
    end

    test "trims surrounding whitespace", %{scope: scope} do
      assert {:ok, home_page} = Content.update_home_page(scope, %{message: "  spaced  "})
      assert home_page.message == "spaced"
    end

    test "rejects a blank message", %{scope: scope} do
      assert {:error, changeset} = Content.update_home_page(scope, %{message: "   "})
      assert %{message: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a message longer than the maximum", %{scope: scope} do
      too_long = String.duplicate("a", HomePage.max_message_length() + 1)
      assert {:error, changeset} = Content.update_home_page(scope, %{message: too_long})

      assert "should be at most #{HomePage.max_message_length()} character(s)" in errors_on(
               changeset
             ).message
    end

    test "broadcasts to subscribers", %{scope: scope} do
      :ok = Content.subscribe_home_page()

      {:ok, home_page} = Content.update_home_page(scope, %{message: "Broadcast me"})

      assert_receive {:home_page_updated, ^home_page}
    end

    test "refuses an admin whose role was revoked while they held the editor open" do
      keeper = Consensus.AccountsFixtures.admin_fixture()
      editor = Consensus.AccountsFixtures.admin_fixture()
      stale_scope = user_scope_fixture(editor)

      {:ok, _} = Content.update_home_page(stale_scope, %{message: "while still an admin"})

      {:ok, {_editor, _tokens}} =
        Consensus.Accounts.set_admin(user_scope_fixture(keeper), editor, false)

      assert {:error, :unauthorized} =
               Content.update_home_page(stale_scope, %{message: "after being demoted"})

      assert Content.get_home_page().message == "while still an admin"
    end

    test "refuses an admin whose account was deleted" do
      keeper = Consensus.AccountsFixtures.admin_fixture()
      editor = Consensus.AccountsFixtures.user_fixture()
      {:ok, {editor, _}} = Consensus.Accounts.set_admin(user_scope_fixture(keeper), editor, true)
      stale_scope = user_scope_fixture(editor)

      {:ok, {_editor, _}} =
        Consensus.Accounts.set_admin(user_scope_fixture(keeper), editor, false)

      {:ok, _} = Consensus.Accounts.delete_user(user_scope_fixture(keeper), editor)

      assert {:error, :unauthorized} = Content.update_home_page(stale_scope, %{message: "ghost"})
    end

    test "refuses a non-admin scope" do
      scope = user_scope_fixture()

      assert_raise FunctionClauseError, fn ->
        Content.update_home_page(scope, %{message: "nope"})
      end
    end

    test "refuses an anonymous scope" do
      # `apply/3` keeps the compiler's set-theoretic type checker from flagging the
      # call it is the point of this test to make.
      assert_raise FunctionClauseError, fn ->
        apply(Content, :update_home_page, [Scope.for_user(nil), %{message: "nope"}])
      end
    end
  end

  describe "the singleton invariant" do
    test "the database rejects a second home page row" do
      Content.ensure_home_page!()

      assert_raise Ecto.ConstraintError, ~r/check_constraint/, fn ->
        Repo.insert!(%HomePage{id: 2, message: "second"})
      end
    end

    test "the changeset maps the violation to an error instead of raising" do
      # This is what `check_constraint(:id, name: :home_page_is_a_singleton)` in the
      # schema buys, and it only works because the migration names the CHECK — SQLite
      # otherwise reports it under the column name and the mapping silently misses.
      Content.ensure_home_page!()

      assert {:error, changeset} =
               %HomePage{id: 2}
               |> HomePage.changeset(%{message: "second"})
               |> Repo.insert()

      assert %{id: ["is invalid"]} = errors_on(changeset)
    end
  end
end
