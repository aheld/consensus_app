defmodule ConsensusWeb.OrganizerLabelTest do
  use ExUnit.Case, async: true

  alias ConsensusWeb.OrganizerLabel

  doctest OrganizerLabel

  describe "label/2" do
    test "an unnamed organizer is 'The organizer' at a sentence start" do
      assert OrganizerLabel.label(nil, :start) == "The organizer"
    end

    test "and 'the organizer' mid-sentence" do
      assert OrganizerLabel.label(nil, :mid) == "the organizer"
    end

    test "a blank or whitespace-only name counts as no name" do
      for blank <- ["", "   ", "\t\n"] do
        assert OrganizerLabel.label(blank, :start) == "The organizer"
        assert OrganizerLabel.label(blank, :mid) == "the organizer"
      end
    end

    test "a name is returned as given, in either position" do
      for name <- ["aheld", "Sam", "the boss"] do
        assert OrganizerLabel.label(name, :start) == name
        assert OrganizerLabel.label(name, :mid) == name
      end
    end
  end
end
