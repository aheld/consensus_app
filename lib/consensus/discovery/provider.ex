defmodule Consensus.Discovery.Provider do
  @moduledoc """
  The behaviour every Discovery adapter implements
  (docs/research/activity-discovery.md §4.3).

  Adapters are registered as data in the config registry —
  `config :consensus, Consensus.Discovery, providers: %{type => {module, opts}}` —
  and `Consensus.Discovery` resolves the activity type with `Map.get/3`. The type
  never reaches an adapter and no adapter ever branches on it: per-type knowledge
  (Overpass tags, an API key) travels in the registered `opts`, which
  `Consensus.Discovery.search/3` passes through to `c:search/3` unchanged. That is
  how four types can share one module with different data, and it is what keeps
  CLAUDE.md product invariant 2 checkable.

  Adapters return `Consensus.Discovery.Result` structs or they are wrong — mapping
  provider-specific fields anywhere above the adapter is the invariant-12 branch
  reappearing one layer up (research §4.4).
  """

  alias Consensus.Discovery.Area
  alias Consensus.Discovery.Result

  @doc """
  Runs one search. `area` is the group's geocoded search area, or `nil` when the
  group has none (a `c:location_mode/0` of `:unused` never receives one). `opts`
  are the adapter's registered per-type options, verbatim from the registry.

  Every failure is a tagged tuple; implementations should not raise, but
  `Consensus.Discovery.search/3` catches them if they do.
  """
  @callback search(query :: String.t(), area :: Area.t() | nil, opts :: keyword()) ::
              {:ok, [Result.t()]} | {:error, atom()}

  @doc """
  The adapter's caching contract, honoured by `Consensus.Discovery`:

    * `:ttl_ms` — how long a successful result list may be cached, or `:none` to
      bypass the cache entirely (research §4.5: for some providers TTL is a
      compliance constant, not a tuning knob).
    * `:error_ttl_ms` — the (shorter) TTL for a cached failure, so a transient
      outage heals itself.
    * `:may_store_results?` — `false` marks a provider whose terms forbid
      server-side result storage outright. Such an adapter is **un-registerable**:
      `Consensus.Discovery.Cache` validates the registry when it starts and
      refuses to boot, turning "this provider is not allowed" from a memo into a
      fact the supervision tree enforces.

  Every key is required, and the engine is deliberately conservative about a
  policy that omits one: with a real `:ttl_ms` but **no `:may_store_results?`**,
  `Consensus.Discovery.search/3` refuses the whole search as
  `{:error, :search_failed}` rather than guessing whether storage is allowed —
  a policy silent on its own compliance flag never reaches the provider, and
  never reaches the cache either. (Same conservative degrade as any other
  malformed policy shape; `test/consensus/discovery_test.exs` pins it.)
  """
  @callback cache_policy() :: %{
              ttl_ms: pos_integer() | :none,
              error_ttl_ms: pos_integer(),
              may_store_results?: boolean()
            }

  @doc """
  The attribution line that must render wherever this adapter's results render
  (the assisted-add brief makes it unconditional), or `nil` for a source that
  requires none.

  The map carries the line already split the way the design frame renders it:
  `:prefix` is plain, unlinked text (`"Places from "` — trailing space included,
  or `""` when the line needs none), and only `:text` becomes the link to
  `:url`. The UI renders the three fields verbatim and adds nothing.
  """
  @callback attribution() ::
              %{prefix: String.t(), text: String.t(), url: String.t()} | nil

  @doc """
  Whether this adapter needs a search area: `:required` (a places index),
  `:optional`, or `:unused` (movies, recipes). A callback rather than knowledge
  in the UI, so no screen ever branches on which provider is registered —
  see the reviewer's note in research §4.3.
  """
  @callback location_mode() :: :required | :optional | :unused
end
