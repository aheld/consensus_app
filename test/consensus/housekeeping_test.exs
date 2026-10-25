defmodule Consensus.HousekeepingTest do
  # `async: true` is load-bearing here, not hygiene: it gives this case a private
  # (non-shared) sandbox connection, which is what lets the failure test below provoke a
  # real `DBConnection.OwnershipError` from a process the sandbox has never heard of.
  # Under a shared owner that process would be allowed in and the sweep would succeed.
  use Consensus.DataCase, async: true

  import Consensus.ActivitiesFixtures
  import ExUnit.CaptureLog

  alias Consensus.Activities.AnonymousOrganizer
  alias Consensus.Housekeeping

  defp ago(days), do: DateTime.add(DateTime.utc_now(:second), -days, :day)

  defp abandoned_organizer do
    {_raw_token, organizer} = anonymous_organizer_fixture(last_seen_at: ago(31))
    organizer
  end

  describe "start_link/1" do
    test "does nothing with skip: true" do
      organizer = abandoned_organizer()

      assert Housekeeping.start_link(skip: true) == :ignore
      assert Repo.get(AnonymousOrganizer, organizer.id)
    end

    test "sweeps an abandoned organizer that owns nothing and keeps one that owns a group" do
      abandoned = abandoned_organizer()

      {owner_scope, _group} = anonymous_group_fixture()

      owner =
        owner_scope.anonymous_organizer
        |> Ecto.Changeset.change(last_seen_at: ago(31))
        |> Repo.update!()

      assert Housekeeping.start_link(skip: false) == :ignore

      refute Repo.get(AnonymousOrganizer, abandoned.id)
      assert Repo.get(AnonymousOrganizer, owner.id)
    end

    test "rescues a failure, logs it, and still returns :ignore" do
      organizer = abandoned_organizer()
      test = self()

      # A bare `spawn/1` carries no `$callers`, so the sandbox refuses its checkout with
      # a DBConnection.OwnershipError — an exception the sweep's own busy-database rescue
      # does not cover, so only Housekeeping stands between it and a failed boot.
      log =
        capture_log(fn ->
          spawn(fn -> send(test, {:result, Housekeeping.start_link(skip: false)}) end)
          assert_receive {:result, :ignore}, 5_000
        end)

      assert log =~ "[housekeeping] sweep failed, boot continues"
      assert Repo.get(AnonymousOrganizer, organizer.id)
    end
  end
end
