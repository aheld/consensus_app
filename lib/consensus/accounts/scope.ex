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

  ## Two kinds of caller (D-058)

  A scope carries a signed-in `:user`, **or** an `:anonymous_organizer` — an organizer
  with no account, resolved from a token in their own browser cookie. Never both: a
  `defstruct` cannot make the two fields exclusive, so `Consensus.Activities` enforces
  it in its function heads instead (every user head pins `anonymous_organizer: nil`,
  every anonymous head pins `user: nil`), and a scope with both set matches neither
  and raises. Build scopes with `for_user/1` and `for_anonymous_organizer/1`, never by
  hand.

  Outside the organizer wizard's `live_session`, `@current_scope` is still only ever
  `nil` or a user scope — two dozen templates read its truthiness as "signed in". Code
  that genuinely needs that question answered asks `authenticated?/1`.
  """

  alias Consensus.Accounts.User
  alias Consensus.Activities.AnonymousOrganizer

  defstruct user: nil, anonymous_organizer: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Creates a scope for an organizer with no account (D-058).

  The organizer must be a persisted row — an integer `id` — because ownership is
  matched on that id, and an unsaved `id: nil` would otherwise equal the `nil`
  `anonymous_organizer_id` of every user-owned group. Returns nil if no organizer is
  given, mirroring `for_user/1`.
  """
  def for_anonymous_organizer(%AnonymousOrganizer{id: id} = organizer) when is_integer(id) do
    %__MODULE__{anonymous_organizer: organizer}
  end

  def for_anonymous_organizer(nil), do: nil

  @doc """
  Returns true only when the scope belongs to a signed-in user.

  An anonymous organizer's scope is **not** authenticated: it has no account, no
  settings page and nothing to log out of. Safe to call with `nil`.
  """
  def authenticated?(%__MODULE__{user: %User{}}), do: true
  def authenticated?(_scope), do: false

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
