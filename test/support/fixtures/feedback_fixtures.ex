defmodule Consensus.FeedbackFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Consensus.Feedback` context.

  Everything goes through the real public write path, `Consensus.Feedback.submit/2` —
  there is no chicken-and-egg problem here, because that path takes no actor and no
  parent row. A fixture that inserted straight through `Repo` would be free to build a
  shape the changeset refuses (a `nil` mood, a `page_path` on an entry whose sender
  unticked the box) and every test built on it would then be testing nothing.
  """

  alias Consensus.Feedback

  @doc """
  One piece of feedback. `attrs` are the *form's* params (string or atom keys);
  `opts` are `submit/2`'s programmatic ones (`:user_id`, `:page_path`).
  """
  def feedback_fixture(attrs \\ %{}, opts \\ []) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Enum.into(%{
        "mood" => "sad",
        "message" => "I got stuck after adding my options."
      })

    {:ok, entry} = Feedback.submit(attrs, opts)
    entry
  end

  @doc "An entry an administrator has already marked read."
  def read_feedback_fixture(scope, attrs \\ %{}, opts \\ []) do
    {:ok, entry} = Feedback.set_read(scope, feedback_fixture(attrs, opts), true)
    entry
  end
end
