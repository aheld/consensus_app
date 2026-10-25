defmodule ConsensusWeb.ResultsComponentsTest do
  @moduledoc """
  `ConsensusWeb.ResultsComponents.results_panel/1` rendered directly, for the parts both
  results screens share and neither screen's own test owns.

  Today that is how a broken tie names who broke it when the organizer has no account
  (D-058, plan §5.2): the winner card's tie note and the paste-to-chat summary both
  open with the organizer, so a nameless one must read "The organizer picked…", never
  "the organizer picked…" and never an empty subject. Both sites are asserted named and
  unnamed — plan §5.2's table is the test matrix.
  """

  use Consensus.DataCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import Consensus.ActivitiesFixtures
  import Consensus.VotingFixtures

  alias Consensus.Activities
  alias Consensus.Voting
  alias ConsensusWeb.ResultsComponents

  # A completed two-way dead heat on an anonymous-owned group, broken by the organizer —
  # read back the way `JoinLive.Results` reads it (`get_group_by_slug/1`, which preloads
  # the owner narrowly), so the name comes from the real accessor and not the test.
  defp organizer_broken_tie(organizer_attrs) do
    scope = anonymous_scope_fixture(organizer_attrs)
    group = group_fixture(scope, %{deadline_at: future_deadline()})

    [alpha, beta, _gamma] =
      for name <- ~w(Alpha Beta Gamma), do: activity_fixture(group, %{name: name})

    {:ok, group} = Activities.publish_group(scope, group)

    {:ok, _} = Voting.cast_ballot(participant_fixture(group), [alpha.id, beta.id])
    {:ok, group} = Activities.complete_group(scope, group)

    {:ok, _} =
      Activities.resolve_group(
        scope,
        Activities.get_group!(scope, group.id),
        alpha.id,
        "organizer_pick"
      )

    Activities.get_group_by_slug(group.slug)
  end

  defp render_panel(group) do
    tally = Voting.tally(group)

    assigns = %{
      group: group,
      tally: tally,
      outcome: Voting.outcome(group, tally),
      participants: Voting.participants(group),
      organizer_username: Activities.organizer_custom_name(group)
    }

    rendered_to_string(~H"""
    <ResultsComponents.results_panel
      group={@group}
      tally={@tally}
      outcome={@outcome}
      participants={@participants}
      organizer_username={@organizer_username}
    >
      <:footer></:footer>
    </ResultsComponents.results_panel>
    """)
  end

  defp tie_note(html), do: html |> text_of("#winner-tie-note") |> String.trim()

  defp summary(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#copy-summary")
    |> LazyHTML.attribute("data-copy")
    |> List.first()
  end

  defp text_of(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  describe "an anonymous-owned tie the organizer broke" do
    test "tie_note names a named organizer" do
      html = render_panel(organizer_broken_tie(display_name: "Priya"))

      assert tie_note(html) =~ "Priya picked Alpha to break the tie."
    end

    test "tie_note opens with \"The organizer\" when there is no name" do
      html = render_panel(organizer_broken_tie(%{}))

      assert tie_note(html) =~ ~r/\. The organizer picked Alpha to break the tie\.$/
      refute tie_note(html) =~ "the organizer picked"
    end

    test "the paste-to-chat summary names a named organizer" do
      html = render_panel(organizer_broken_tie(display_name: "Priya"))

      assert summary(html) =~ "Priya picked Alpha to break the tie."
    end

    test "the paste-to-chat summary opens its tail with \"The organizer\" when there is no name" do
      html = render_panel(organizer_broken_tie(%{}))

      assert summary(html) =~ "Alpha, Beta. The organizer picked Alpha to break the tie."
      refute summary(html) =~ "the organizer picked"
    end
  end
end
