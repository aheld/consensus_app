defmodule ConsensusWeb.StickerVotingTest do
  @moduledoc """
  Rendering coverage for the four voting-loop primitives added to
  `ConsensusWeb.Sticker` (`participant_avatar/1`, `participant_avatar_row/1`,
  `tally_bar/1`, `countdown_header/1`) — see docs/plans/voting-loop.md. Not one of the
  three screens; this exercises the shared components in isolation so their contract is
  pinned before `JoinLive.*` / `GroupLive.Results` exist to call them.
  """
  use ConsensusWeb.ConnCase, async: true
  use Phoenix.Component
  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.VotingFixtures

  alias Consensus.Voting
  alias ConsensusWeb.Sticker

  describe "participant_avatar/1" do
    test "a voted participant renders filled, ink-bordered, with the mint ring and label" do
      html =
        render_component(&Sticker.participant_avatar/1, %{
          participant_id: 1,
          initial: "A",
          state: :voted
        })

      assert html =~ ">A<"
      assert html =~ "border-ink"
      assert html =~ "shadow-[0_0_0_3px_var(--color-mint)]"
      assert html =~ "voted"
      refute html =~ "border-dashed"
    end

    test "a waiting participant renders dashed and faint, with no ring" do
      html =
        render_component(&Sticker.participant_avatar/1, %{
          participant_id: 1,
          initial: "B",
          state: :waiting
        })

      assert html =~ ">B<"
      assert html =~ "border-dashed border-ink/45"
      assert html =~ "text-faint"
      assert html =~ "waiting"
      refute html =~ "shadow-[0_0_0_3px_var(--color-mint)]"
    end

    test "label overrides the default caption (05b's own avatar reads \"you\")" do
      html =
        render_component(&Sticker.participant_avatar/1, %{
          participant_id: 1,
          initial: "J",
          state: :voted,
          label: "you"
        })

      assert html =~ "you"
      refute html =~ ">voted<"
    end

    test "show_label={false} omits the caption entirely" do
      html =
        render_component(&Sticker.participant_avatar/1, %{
          participant_id: 1,
          initial: "J",
          state: :voted,
          show_label: false
        })

      refute html =~ "voted"
    end

    test "the fill cycles deterministically from the participant id, not list position" do
      fills =
        for id <- [1, 2, 3, 4, 5] do
          html =
            render_component(&Sticker.participant_avatar/1, %{
              participant_id: id,
              initial: "X",
              state: :voted
            })

          Regex.run(~r/bg-(yellow|mint|peach|violet-soft)\b/, html) |> hd()
        end

      # rem(id, 4): 1,2,3,4,5 -> 1,2,3,0,1 — the same id always lands on the same fill,
      # and the cycle repeats every four ids (ids 1 and 5 match).
      assert Enum.at(fills, 0) == Enum.at(fills, 4)
      assert length(Enum.uniq(fills)) == 4
    end
  end

  describe "participant_avatar_row/1" do
    test "counts voted/total, marks the current participant \"you\", and renders the caption" do
      {group, activities} = voting_group_fixture(user_scope_fixture())
      voter = participant_fixture(group, %{display_name: "Ada"})
      _waiter = participant_fixture(group, %{display_name: "Bo"})
      {:ok, voter} = Voting.cast_ballot(voter, [hd(activities).id])

      html =
        render_component(&Sticker.participant_avatar_row/1, %{
          participants: Voting.participants(group),
          current_participant_id: voter.id,
          caption: "TAP TO NUDGE"
        })

      assert html =~ "1/2 voted"
      assert html =~ "TAP TO NUDGE"
      assert html =~ "you"
      assert html =~ "waiting"
    end

    # **`/join/:slug` asks a guest for their name under a stated purpose** — "Just so
    # <organizer> can see who has voted" — and this row rendered `aria-hidden="true"`
    # around a single letter with no `title` and no visually-hidden label, so the string
    # the guest typed appeared **nowhere in the organizer's document**. Two guests called
    # Sam and Sarah were the same avatar, and a screen-reader organizer got
    # "1/1 voted, WHO'S VOTED, voted" and no identity at all. The frame draws initials and
    # that is unchanged; the name reaches the accessibility tree and a hover tooltip.
    test "a named participant's name is in the document, not only their initial" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      _voter = participant_fixture(group, %{display_name: "Sam"})

      html =
        render_component(&Sticker.participant_avatar_row/1, %{
          participants: Voting.participants(group)
        })

      assert html =~ "Sam"
      assert html =~ ~s(title="Sam")
    end

    # An anonymous participant has no name, and `?` in an `aria-hidden` circle is exactly
    # as much as the app knows. Inventing "Anonymous" as an accessible name would read as
    # somebody's chosen handle.
    test "an anonymous participant keeps the aria-hidden circle and gains no title" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())
      _voter = participant_fixture(group, %{display_name: nil})

      html =
        render_component(&Sticker.participant_avatar_row/1, %{
          participants: Voting.participants(group)
        })

      assert html =~ ~s(aria-hidden="true")
      refute html =~ "title="
    end

    test "caption is omitted entirely when nil" do
      {group, _activities} = voting_group_fixture(user_scope_fixture())

      html =
        render_component(&Sticker.participant_avatar_row/1, %{
          participants: Voting.participants(group),
          caption: nil
        })

      refute html =~ "NUDGE"
    end
  end

  describe "tally_bar/1" do
    setup do
      {group, activities} = voting_group_fixture(user_scope_fixture())
      participant = participant_fixture(group)

      [leader, runner_up, vetoed] = activities

      {:ok, _} =
        Voting.cast_ballot(participant, [leader.id, runner_up.id], vetoed.id)

      %{tally: Voting.tally(group), leader: leader, runner_up: runner_up, vetoed: vetoed}
    end

    test "a leading survivor gets the star and a proportional violet bar", %{
      tally: tally,
      leader: leader
    } do
      row = Enum.find(tally, &(&1.activity.id == leader.id))
      html = render_component(&Sticker.tally_bar/1, %{row: row})

      assert html =~ leader.name
      assert html =~ "★"
      assert html =~ "bg-violet"
      assert html =~ "width:100%"
      refute html =~ "line-through"
    end

    test "a vetoed row strikes the name, shows the VETOED pill, and stripes the bar", %{
      tally: tally,
      vetoed: vetoed
    } do
      row = Enum.find(tally, &(&1.activity.id == vetoed.id))
      html = render_component(&Sticker.tally_bar/1, %{row: row})

      assert html =~ vetoed.name
      assert html =~ "line-through"
      assert html =~ "Vetoed"
      assert html =~ "uppercase"
      assert html =~ "stripes-vetoed"
      refute html =~ "bg-violet"
    end
  end

  describe "countdown_header/1" do
    test "renders the title, LIVE label, and the given countdown text" do
      html =
        render_component(&Sticker.countdown_header/1, %{
          title: "Dinner Friday?",
          countdown_text: "1h 02m left"
        })

      assert html =~ "Dinner Friday?"
      assert html =~ "LIVE"
      assert html =~ "1h 02m left"
      assert html =~ "until votes close"
      assert html =~ "aria-live=\"polite\""
    end
  end

  # **The one class assertion in this file that stands in for a browser measurement, and
  # it says so.** `.deck-card`'s `max-h-full` is a percentage `max-height`; against a
  # content-height parent CSS resolves that to `none`, so the cap never bound and the card
  # simply overflowed its slot. Measured before the fix at 390×664 (iPhone 14 in Safari):
  # slot 231.5px, card 341.4px, 109.9px of card painted over the PASS / VETO / PICK row,
  # `document.elementFromPoint` returning the card's description at all three button
  # centres — 0 of 78.5 hittable pixel rows each — and `documentElement.scrollHeight ===
  # innerHeight`, so there was nothing to scroll to. Same at 375×667 and 360×640; fine at
  # 420×900, which is the only viewport it had been checked at. Since `SwipeCard` pushes
  # only `approve`/`pass`, veto had **no** gesture at all on the most common iPhone size.
  #
  # After: 79/79/79 hittable rows at 360×640, 375×667, 390×664, 360×700 and 420×900, card
  # 231.5 at 390×664 with zero overflow, and 420×900 unchanged (card 363.9, photo 1.333).
  # An ExUnit test cannot measure any of that; what it can do is fail if either half of
  # the two-part fix is deleted, which is what the sizes above depend on.
  describe "deck_stack/1 — the sizer that bounds the card" do
    test "the sizer is a flex column and the card can shrink inside it" do
      html =
        render_component(&Sticker.deck_stack/1, %{
          id: "deck-card-1",
          name: "Night + Market",
          image_url: nil,
          detail: "Thai, loud and fun",
          behind: 2
        })

      # The sizer: `max-h-full` only resolves for the card if this box is a flex container
      # with a definite height of its own.
      assert html =~ ~r/class="relative flex max-h-full w-full flex-col"/

      # The card: `min-h-0` clears a column flex item's default `min-height: auto`
      # (its content minimum), which would otherwise block the shrink.
      assert html =~ ~r/class="deck-card [^"]*max-h-full min-h-0[^"]*"/
    end
  end
end
