defmodule Consensus.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Consensus.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Consensus.Accounts.User

  defstruct user: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Returns true when the scope belongs to a signed-in administrator.

  Safe to call with `nil`, which is what a public page passes before anyone logs in.
  This is a **display** predicate — `ConsensusWeb.Chrome.header/1` reads it to decide
  whether the `⋯` menu offers an Admin link. It is never the authorization: that is the
  router's `:require_admin_user` plug plus the `:require_admin` on_mount hook, and, for
  a write, `Consensus.Accounts`' re-read of the actor's role inside the transaction
  (CLAUDE.md invariant 1).

  It lives here rather than in `ConsensusWeb.Layouts` because it is a predicate about a
  scope and has nothing to do with layouts. `Layouts` imports `ConsensusWeb.Chrome`
  through `ConsensusWeb.html_helpers/0`, so a `Chrome` → `Layouts` call made the two
  modules mutually dependent for this one two-clause function; it compiled only because
  the call was remote, and an `import ConsensusWeb.Layouts` in `chrome.ex` would have
  turned it into a compile deadlock.
  """
  def admin?(%__MODULE__{user: %User{is_admin: true}}), do: true
  def admin?(_scope), do: false
end
