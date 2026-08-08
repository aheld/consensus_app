defmodule Consensus.SeedsTest do
  use Consensus.DataCase, async: false

  # `Consensus.Seeds` logs a loud warning whenever the default password is still in
  # place, which is most of this file.
  @moduletag :capture_log

  alias Consensus.Accounts
  alias Consensus.Accounts.User
  alias Consensus.Repo
  alias Consensus.Seeds

  setup do
    on_exit(fn ->
      System.delete_env("ADMIN_USERNAME")
      System.delete_env("ADMIN_EMAIL")
      System.delete_env("ADMIN_PASSWORD")
    end)

    :ok
  end

  describe "run!/0" do
    test "creates a confirmed admin that can log in with the documented password" do
      assert {:ok, %{admin: admin}} = Seeds.run!()

      assert admin.username == "aheld"
      assert admin.is_admin
      assert admin.confirmed_at
      assert Accounts.get_user_by_login_and_password("aheld", "adminpass")
      assert Accounts.get_user_by_login_and_password(admin.email, "adminpass")
    end

    test "is idempotent" do
      {:ok, %{admin: first}} = Seeds.run!()
      assert {:ok, %{admin: nil}} = Seeds.run!()

      assert Repo.aggregate(User, :count) == 1
      assert Accounts.get_user!(first.id).is_admin
    end

    test "does not recreate the bootstrap account after the admin renames themselves" do
      # The regression this guards: keying idempotency off the username meant that
      # renaming the seeded admin made the next boot look like a first boot, silently
      # recreating an `aheld` / `adminpass` administrator.
      {:ok, %{admin: admin}} = Seeds.run!()
      {:ok, _} = Accounts.update_user_username(admin, %{username: "aaron"})

      assert {:ok, %{admin: nil}} = Seeds.run!()

      assert Repo.aggregate(User, :count) == 1
      refute Accounts.get_user_by_username("aheld")
    end

    test "does not recreate the bootstrap account after the admin changes their email" do
      {:ok, %{admin: admin}} = Seeds.run!()

      {:ok, _} =
        admin
        |> Ecto.Changeset.change(email: "aaron@example.com")
        |> Repo.update()

      assert {:ok, %{admin: nil}} = Seeds.run!()
      assert Repo.aggregate(User, :count) == 1
    end

    test "leaves an existing non-seeded admin alone" do
      admin = Consensus.AccountsFixtures.admin_fixture(%{username: "someoneelse"})

      assert {:ok, %{admin: nil}} = Seeds.run!()

      assert Repo.aggregate(User, :count) == 1
      assert Accounts.get_user!(admin.id).is_admin
      refute Accounts.get_user_by_username("aheld")
    end

    test "raises on a genuine first boot with an unusable admin configuration" do
      System.put_env("ADMIN_EMAIL", "not-an-email")

      error = assert_raise RuntimeError, fn -> Seeds.run!() end

      assert error.message =~ "could not seed the bootstrap admin"

      # This branch is guarded by `count_users() == 0`, so a name collision is not
      # merely unlikely, it is impossible — the message must not send the operator
      # hunting for one.
      refute error.message =~ "already taken"
      assert error.message =~ "no accounts at all, so no name or address can be in use"
    end

    test "holds an operator-supplied ADMIN_PASSWORD to the full length minimum" do
      # The whole point of the conditional waiver: the built-in `adminpass` is nine
      # characters and is accepted, anything an operator sets is not.
      System.put_env("ADMIN_PASSWORD", "hunter2")

      error = assert_raise RuntimeError, fn -> Seeds.run!() end

      assert error.message =~ "should be at least"
      assert error.message =~ "count: #{User.min_password_length()}"

      # And it names the cause an operator can act on, rather than a collision.
      assert error.message =~
               "ADMIN_PASSWORD shorter than #{User.min_password_length()} characters"

      assert Accounts.count_users() == 0
    end

    test "logs instead of raising when accounts exist but none is an admin" do
      user = Consensus.AccountsFixtures.user_fixture()
      System.put_env("ADMIN_EMAIL", user.email)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{admin: nil}} = Seeds.run!() end)

      assert log =~ "could not seed the bootstrap admin"
      # Here a collision genuinely is the likeliest cause, and it is what happened.
      assert log =~ "already taken"
      assert Accounts.count_admins() == 0
    end

    test "never resurrects a changed password" do
      {:ok, %{admin: admin}} = Seeds.run!()
      {:ok, {admin, _}} = Accounts.update_user_password(admin, %{password: "a much longer one"})

      Seeds.run!()

      refute Accounts.get_user_by_login_and_password("aheld", "adminpass")
      assert Accounts.get_user_by_login_and_password("aheld", "a much longer one")
      assert Accounts.get_user!(admin.id).is_admin
      assert Accounts.count_users() == 1
    end

    test "honours ADMIN_USERNAME, ADMIN_EMAIL and ADMIN_PASSWORD" do
      System.put_env("ADMIN_USERNAME", "boss")
      System.put_env("ADMIN_EMAIL", "boss@example.com")
      System.put_env("ADMIN_PASSWORD", "a properly long password")

      assert {:ok, %{admin: admin}} = Seeds.run!()

      assert admin.username == "boss"
      assert admin.email == "boss@example.com"
      assert admin.is_admin
      assert Accounts.get_user_by_login_and_password("boss", "a properly long password")
      refute Accounts.get_user_by_username("aheld")
    end
  end

  describe "default_password_in_use?/0" do
    test "is false before seeding" do
      refute Seeds.default_password_in_use?()
    end

    test "is true straight after seeding, and false once the password changes" do
      {:ok, %{admin: admin}} = Seeds.run!()
      assert Seeds.default_password_in_use?()

      {:ok, {_admin, _}} = Accounts.update_user_password(admin, %{password: "a much longer one"})
      refute Seeds.default_password_in_use?()
    end

    test "is false when ADMIN_PASSWORD was supplied" do
      System.put_env("ADMIN_PASSWORD", "a properly long password")
      Seeds.run!()
      refute Seeds.default_password_in_use?()
    end
  end

  describe "start_link/1" do
    test "skips the work when told to" do
      assert :ignore = Seeds.start_link(skip: true)
      assert Repo.aggregate(User, :count) == 0
    end

    test "seeds and stays out of the supervision tree" do
      assert :ignore = Seeds.start_link([])
      assert Accounts.get_user_by_username("aheld")
    end
  end

  describe "admins_with_default_password/0" do
    test "names every admin still on the default, not just the seeded one" do
      {:ok, %{admin: seeded}} = Seeds.run!()
      other = Consensus.AccountsFixtures.admin_fixture(%{username: "other"})

      assert Enum.map(Seeds.admins_with_default_password(), & &1.username) == [seeded.username]

      {:ok, {_other, _}} = Accounts.update_user_password(other, %{password: "adminpass    "})
      refute "other" in Enum.map(Seeds.admins_with_default_password(), & &1.username)
    end
  end
end
