defmodule ConsensusWeb.AdminLive.ItemsTest do
  @moduledoc """
  `/admin/items` (D-060; docs/plans/item-details-and-catalog.md §4) and the admin
  writes behind it. Written from the plan: an admin can edit, hide and delete catalog
  rows and fix any option's *details* — never rename, reorder or delete another
  organizer's option — every write is an admin head match, delete re-reads the actor,
  and each one leaves an `[audit]` line.
  """
  use ConsensusWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Consensus.AccountsFixtures
  import Consensus.ActivitiesFixtures

  alias Consensus.Accounts.Scope
  alias Consensus.Activities
  alias Consensus.Activities.Activity
  alias Consensus.Catalog
  alias Consensus.Catalog.CatalogItem
  alias Consensus.Repo

  setup %{conn: conn} do
    admin = admin_fixture()
    organizer = user_scope_fixture()
    group = group_fixture(organizer)
    activity = activity_fixture(group, %{name: "Zahav"})

    {:ok, activity} =
      Activities.update_activity_details(organizer, activity, %{address: "237 St James Pl"})

    {:ok, activity} = Catalog.share_activity(organizer, activity)

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      admin_scope: Scope.for_user(admin),
      organizer: organizer,
      group: group,
      activity: activity,
      row: Repo.get!(CatalogItem, activity.catalog_item_id)
    }
  end

  describe "the guards" do
    test "a signed-in non-admin is bounced" do
      conn = build_conn() |> log_in_user(user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/items")
    end

    test "/admin/users links here", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      assert has_element?(lv, ~s|#admin-items-link[href="/admin/items"]|)
    end
  end

  describe "the catalog tab" do
    test "lists the row with its sharer, source and uses", %{
      conn: conn,
      row: row,
      organizer: organizer
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/items")

      assert has_element?(lv, "#catalog-#{row.id}", "Zahav")
      assert has_element?(lv, "#catalog-#{row.id}", "shared by #{organizer.user.username}")
      assert has_element?(lv, "#catalog-#{row.id}", "Organizer")
    end

    test "edit stamps admin_edited_at, so the organizer's next edit no longer syncs", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/items")

      lv |> element(~s|#catalog-#{ctx.row.id} button[phx-click="edit"]|) |> render_click()
      lv |> form("#item-edit-form", item: %{phone: "2156258800"}) |> render_submit()

      edited = Repo.get!(CatalogItem, ctx.row.id)
      assert {edited.phone, is_struct(edited.admin_edited_at, DateTime)} == {"2156258800", true}

      {:ok, _} =
        Activities.update_activity_details(ctx.organizer, ctx.activity, %{phone: "2155550000"})

      assert Repo.get!(CatalogItem, ctx.row.id).phone == "2156258800"
    end

    test "hide takes it out of the lookup; unhide puts it back", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/items")

      lv |> element(~s|#catalog-#{ctx.row.id} button[phx-click="set_status"]|) |> render_click()
      assert Catalog.search(ctx.group.activity_type, "zahav", nil) == []

      lv
      |> element(~s|#catalog-#{ctx.row.id} button[phx-click="set_status"]|, "Unhide")
      |> render_click()

      assert [_] = Catalog.search(ctx.group.activity_type, "zahav", nil)
    end

    test "delete removes the row and no group's option changes", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/items")

      lv |> element(~s|#catalog-#{ctx.row.id} button[phx-click="delete"]|) |> render_click()

      refute Repo.get(CatalogItem, ctx.row.id)
      option = Repo.get!(Activity, ctx.activity.id)

      assert {option.name, option.address, option.catalog_item_id} ==
               {"Zahav", "237 St James Pl", nil}
    end
  end

  describe "the all-items tab" do
    test "fixes another organizer's details, after publish too; the name is not a field", ctx do
      Consensus.VotingFixtures.force_group!(ctx.group, status: :voting)

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/items?tab=items")
      assert has_element?(lv, "#item-#{ctx.activity.id}", "Zahav")

      lv |> element(~s|#item-#{ctx.activity.id} button[phx-click="edit"]|) |> render_click()
      refute has_element?(lv, ~s|#item-edit-form input[name="item[name]"]|)

      lv
      |> form("#item-edit-form", item: %{phone: "2156258800"})
      |> render_submit(%{item: %{name: "Hijacked"}})

      option = Repo.get!(Activity, ctx.activity.id)
      assert {option.phone, option.name} == {"2156258800", "Zahav"}
    end

    test "share to catalog makes an admin-owned snapshot and leaves the organizer's toggle alone",
         ctx do
      other = activity_fixture(ctx.group, %{name: "Kismet"})

      {:ok, other} =
        Activities.update_activity_details(ctx.organizer, other, %{address: "4648 Hollywood Blvd"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/admin/items?tab=items")
      lv |> element(~s|#item-#{other.id} button[phx-click="share"]|) |> render_click()

      row = Repo.get_by!(CatalogItem, name: "Kismet")

      assert {row.shared_by_user_id, is_struct(row.admin_edited_at, DateTime)} ==
               {ctx.admin.id, true}

      assert Repo.get!(Activity, other.id).shared_to_catalog_at == nil
    end
  end

  describe "the admin writes, as functions" do
    test "a non-admin scope cannot reach them — the head match is the refusal", ctx do
      member = ctx.organizer

      assert_raise FunctionClauseError, fn ->
        Catalog.admin_update(member, ctx.row, %{name: "x"})
      end

      assert_raise FunctionClauseError, fn ->
        Catalog.admin_set_status(member, ctx.row, "hidden")
      end

      assert_raise FunctionClauseError, fn -> Catalog.admin_delete(member, ctx.row) end
      assert_raise FunctionClauseError, fn -> Catalog.list_items_for_admin(member) end

      assert_raise FunctionClauseError, fn ->
        Activities.admin_update_activity_details(member, ctx.activity, %{phone: "2156258800"})
      end

      assert_raise FunctionClauseError, fn -> Activities.list_all_activities_for_admin(member) end
    end

    test "delete re-reads the actor: a demoted admin's stale scope is refused", ctx do
      ctx.admin |> Consensus.Accounts.User.admin_changeset(%{is_admin: false}) |> Repo.update!()

      log =
        capture_log(fn ->
          assert Catalog.admin_delete(ctx.admin_scope, ctx.row) == {:error, :unauthorized}
        end)

      assert Repo.get(CatalogItem, ctx.row.id)
      assert log =~ "[audit] catalog_delete REFUSED :unauthorized actor_id=#{ctx.admin.id}"
    end

    test "every admin write re-reads the actor, not only delete", ctx do
      ctx.admin |> Consensus.Accounts.User.admin_changeset(%{is_admin: false}) |> Repo.update!()

      capture_log(fn ->
        assert Catalog.admin_update(ctx.admin_scope, ctx.row, %{phone: "2156258800"}) ==
                 {:error, :unauthorized}

        assert Catalog.admin_set_status(ctx.admin_scope, ctx.row, "hidden") ==
                 {:error, :unauthorized}

        assert Catalog.admin_share(ctx.admin_scope, ctx.activity) == {:error, :unauthorized}

        assert Activities.admin_update_activity_details(ctx.admin_scope, ctx.activity, %{
                 phone: "2156258800"
               }) == {:error, :unauthorized}
      end)

      assert Repo.get!(CatalogItem, ctx.row.id).status == "visible"
      assert Repo.get!(Activity, ctx.activity.id).phone == nil
    end

    test "sharing an option whose twin an admin hid says so instead of claiming success", ctx do
      {:ok, _} = Catalog.admin_set_status(ctx.admin_scope, ctx.row, "hidden")
      twin = activity_fixture(ctx.group, %{name: "Zahav"})

      {:ok, twin} =
        Activities.update_activity_details(ctx.organizer, twin, %{address: "237 St James Pl"})

      twin |> Ecto.Changeset.change(osm_ref: "node/1") |> Repo.update!()
      ctx.row |> Ecto.Changeset.change(osm_ref: "node/1") |> Repo.update!()

      assert Catalog.admin_share(ctx.admin_scope, Repo.get!(Activity, twin.id)) ==
               {:error, :hidden}
    end

    test "an admin cannot rename or delete another organizer's option", ctx do
      assert Activities.update_activity(ctx.admin_scope, ctx.activity, %{name: "Hijacked"}) ==
               {:error, :unauthorized}

      assert Activities.delete_activity(ctx.admin_scope, ctx.activity) == {:error, :unauthorized}
    end

    test "every write leaves an [audit] line, ids first", ctx do
      # The suite runs at :warning; success lines are :info. ConnCase is synchronous, so
      # raising the level for this one test cannot leak into another (users_test's idiom).
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log(fn ->
          {:ok, _} = Catalog.admin_update(ctx.admin_scope, ctx.row, %{phone: "2156258800"})
          {:ok, _} = Catalog.admin_set_status(ctx.admin_scope, ctx.row, "hidden")
          {:ok, _} = Catalog.admin_set_status(ctx.admin_scope, ctx.row, "visible")

          {:ok, _} =
            Activities.admin_update_activity_details(ctx.admin_scope, ctx.activity, %{
              phone: "2156258800"
            })

          {:ok, _} = Catalog.admin_delete(ctx.admin_scope, Repo.get!(CatalogItem, ctx.row.id))
        end)

      for action <-
            ~w(catalog_edit catalog_hide catalog_unhide activity_details_edit catalog_delete) do
        assert log =~
                 "[audit] #{action} actor_id=#{ctx.admin.id} actor=#{inspect(ctx.admin.username)}"
      end
    end
  end
end
