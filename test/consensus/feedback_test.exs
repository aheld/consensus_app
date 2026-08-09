defmodule Consensus.FeedbackTest do
  # Sync (the default) like every other DataCase in this suite that writes rows; see
  # AGENTS.md's split. Nothing here issues DDL.
  use Consensus.DataCase

  import Consensus.AccountsFixtures
  import Consensus.FeedbackFixtures

  alias Consensus.Accounts
  alias Consensus.Feedback
  alias Consensus.Feedback.Entry

  describe "submit/2" do
    test "stores a mood and a message with no actor at all" do
      assert {:ok, %Entry{} = entry} =
               Feedback.submit(%{"mood" => "happy", "message" => "the share sheet is great"})

      assert entry.mood == :happy
      assert entry.message == "the share sheet is great"
      assert entry.user_id == nil
      assert entry.read_at == nil
    end

    test "requires a mood, so a direct visit with no ?mood= cannot store a blank one" do
      assert {:error, changeset} = Feedback.submit(%{"message" => "hello"})
      assert "tap a face so we know which way this went" in errors_on(changeset).mood
    end

    test "requires a message" do
      assert {:error, changeset} = Feedback.submit(%{"mood" => "sad"})
      assert "tell us what happened" in errors_on(changeset).message
    end

    test "an over-long name or email says what to do about it" do
      # Neither field has a `maxlength` (invariant 11) and neither has a counter, so this
      # refusal is the first warning a sender ever gets. The framework default — "should
      # be at most 60 character(s)", passive, with a `(s)` plural artefact — is not it.
      long_name = String.duplicate("x", Entry.max_name_length() + 1)
      long_email = String.duplicate("x", Entry.max_email_length()) <> "@e.com"

      assert {:error, changeset} =
               Feedback.submit(%{"mood" => "sad", "message" => "hi", "name" => long_name})

      assert ["that's a bit long — trim it to 60 characters"] = errors_on(changeset).name

      assert {:error, changeset} =
               Feedback.submit(%{"mood" => "sad", "message" => "hi", "email" => long_email})

      assert "that's a bit long — trim it to 160 characters" in errors_on(changeset).email
    end

    test "refuses a message past the cap the counter shows" do
      over = String.duplicate("a", Entry.max_message_length() + 1)

      assert {:error, changeset} = Feedback.submit(%{"mood" => "sad", "message" => over})
      assert changeset.errors[:message]

      assert {:ok, _} =
               Feedback.submit(%{
                 "mood" => "sad",
                 "message" => String.duplicate("a", Entry.max_message_length())
               })
    end

    test "counts the cap in graphemes, not bytes or UTF-16 units" do
      # A family emoji is one grapheme and several code points; `maxlength` in a browser
      # would count it as several. Invariant 11 exists because those two disagree.
      message = String.duplicate("👨‍👩‍👧‍👦", Entry.max_message_length())
      assert String.length(message) == Entry.max_message_length()
      assert {:ok, _} = Feedback.submit(%{"mood" => "sad", "message" => message})
    end

    test "normalises a blank name and email to nil rather than storing empty strings" do
      entry =
        feedback_fixture(%{"name" => "   ", "email" => ""})

      assert entry.name == nil
      assert entry.email == nil
    end

    test "keeps a name and email when they are given" do
      entry = feedback_fixture(%{"name" => " Jordan ", "email" => "jordan@example.com"})
      assert entry.name == "Jordan"
      assert entry.email == "jordan@example.com"
    end

    test "rejects an email with no @" do
      assert {:error, changeset} =
               Feedback.submit(%{"mood" => "sad", "message" => "x", "email" => "nope"})

      assert "needs an @ in it" in errors_on(changeset).email
    end

    test "associates a signed-in sender without letting the form claim one" do
      user = user_fixture()

      entry = feedback_fixture(%{"mood" => "happy", "message" => "hi"}, user_id: user.id)
      assert entry.user_id == user.id

      # `user_id` is not castable: a hand-crafted form param must not be able to file
      # feedback as somebody else.
      forged = feedback_fixture(%{"mood" => "happy", "message" => "hi", "user_id" => user.id})
      assert forged.user_id == nil
    end

    test "keeps the feedback when the account that sent it is deleted" do
      admin_scope = admin_scope_fixture()
      user = user_fixture()

      entry = feedback_fixture(%{}, user_id: user.id)

      assert {:ok, {_deleted, _tokens}} = Accounts.delete_user(admin_scope, user)

      reloaded = Feedback.get_entry(entry.id)
      assert reloaded.message == entry.message
      assert reloaded.user_id == nil
    end
  end

  describe "submit/2 and the \"include the screen I was on\" box" do
    test "captures the path when the box is ticked" do
      entry =
        feedback_fixture(%{"include_page" => "true"}, page_path: "/groups/12/options")

      assert entry.page_path == "/groups/12/options"
    end

    test "captures nothing when the box is unticked, even though a path was passed" do
      entry =
        feedback_fixture(%{"include_page" => "false"}, page_path: "/groups/12/options")

      assert entry.page_path == nil
    end

    test "defaults to ticked, which is what the checkbox renders" do
      entry = feedback_fixture(%{}, page_path: "/groups/12/review")
      assert entry.page_path == "/groups/12/review"
    end

    test "captures nothing when there was no origin to capture" do
      entry = feedback_fixture(%{"include_page" => "true"})
      assert entry.page_path == nil
    end

    test "refuses a path that is not a plain local path, whatever the caller passed" do
      # `page_path` is the one column here written from a query parameter and the one
      # later rendered as an `href` on /admin/feedback, so the guard is in the changeset
      # rather than only in the LiveView that happens to call it today.
      for hostile <- [
            "//evil.example/x",
            "/\\evil.example/x",
            # Browsers strip ASCII tab/LF/CR before resolving a URL, so each of these
            # resolves as `//evil.example/x` — protocol-relative, off-site.
            "/\t/evil.example/x",
            "/\n/evil.example/x",
            "/\r/evil.example/x",
            "https://evil.example/x",
            "javascript:alert(1)"
          ] do
        entry = feedback_fixture(%{"include_page" => "true"}, page_path: hostile)
        assert entry.page_path == nil, "stored a hostile page_path: #{inspect(hostile)}"
      end
    end

    test "the bare home path is still captured, because it is the commonest one" do
      # A `\A/[^/\\]` shape check would drop it — and the footer's faces are tapped from
      # the home page more than anywhere else.
      entry = feedback_fixture(%{"include_page" => "true"}, page_path: "/")
      assert entry.page_path == "/"
    end
  end

  describe "list_entries/0 and count_unread/0" do
    test "lists newest first" do
      first = feedback_fixture(%{"message" => "first"})
      second = feedback_fixture(%{"message" => "second"})

      assert [%{id: a}, %{id: b}] = Feedback.list_entries()
      assert a == second.id
      assert b == first.id
    end

    test "counts only what nobody has marked read" do
      scope = admin_scope_fixture()
      feedback_fixture()
      read_feedback_fixture(scope)

      assert Feedback.count_unread() == 1
    end

    test "preloads the sender's account so the queue can name them" do
      user = user_fixture()
      feedback_fixture(%{}, user_id: user.id)

      assert [entry] = Feedback.list_entries()
      assert entry.user.username == user.username
      assert Entry.sender_label(entry) == user.username
    end
  end

  describe "set_read/3" do
    test "marks read and unread again — both directions" do
      scope = admin_scope_fixture()
      entry = feedback_fixture()

      assert {:ok, read} = Feedback.set_read(scope, entry, true)
      assert read.read_at
      assert Entry.read?(read)

      assert {:ok, unread} = Feedback.set_read(scope, read, false)
      assert unread.read_at == nil
      refute Entry.read?(unread)
    end

    test "a non-admin scope matches no clause" do
      scope = user_scope_fixture()
      entry = feedback_fixture()

      assert_raise FunctionClauseError, fn -> Feedback.set_read(scope, entry, true) end
    end
  end

  describe "annotate/3" do
    test "writes and clears the private note" do
      scope = admin_scope_fixture()
      entry = feedback_fixture()

      assert {:ok, noted} = Feedback.annotate(scope, entry, "emailed them back by hand")
      assert noted.admin_note == "emailed them back by hand"

      assert {:ok, cleared} = Feedback.annotate(scope, noted, "   ")
      assert cleared.admin_note == nil
    end

    test "cannot edit what the sender wrote" do
      scope = admin_scope_fixture()
      entry = feedback_fixture(%{"message" => "the original words"})

      {:ok, noted} = Feedback.annotate(scope, entry, "note")
      assert noted.message == "the original words"

      # `admin_changeset/2` casts exactly [:read_at, :admin_note]; the sender's own
      # fields are not reachable from the admin path at all.
      changeset = Entry.admin_changeset(entry, %{message: "tampered", mood: :happy})
      refute Map.has_key?(changeset.changes, :message)
      refute Map.has_key?(changeset.changes, :mood)
    end

    test "a non-admin scope matches no clause" do
      scope = user_scope_fixture()
      entry = feedback_fixture()

      assert_raise FunctionClauseError, fn -> Feedback.annotate(scope, entry, "nope") end
    end
  end

  describe "get_entry/1" do
    test "returns nil rather than raising for a missing or non-integer id" do
      assert Feedback.get_entry(-1) == nil
      assert Feedback.get_entry("12") == nil
      assert Feedback.get_entry(nil) == nil
    end
  end
end
