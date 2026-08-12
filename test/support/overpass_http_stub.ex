defmodule Consensus.OverpassHTTPStub do
  @moduledoc """
  The test implementation of `Consensus.Discovery.Provider.Overpass.HTTP`,
  wired in by `config/test.exs`.

  Same `$callers`-walking idiom as `Consensus.LinkPreviewStub` (read its
  moduledoc for the full why): a test installs a response function with
  `stub/1`, and `post/3` finds it from any process the test spawned through
  `Task`/`start_async` — the adapter will run inside one once the assisted-add
  UI lands.
  """

  @behaviour Consensus.Discovery.Provider.Overpass.HTTP

  @impl true
  def post(url, ql, opts) do
    case lookup() do
      nil -> {:error, :not_configured}
      fun -> fun.(url, ql, opts)
    end
  end

  @doc """
  Installs the response function for this process and anything it spawns. It
  receives `(url, ql, opts)` and returns what
  `Consensus.Discovery.Provider.Overpass.HTTP` is specified to return —
  `{:ok, %{status:, body:}}` or `{:error, term}`.
  """
  def stub(fun) when is_function(fun, 3), do: Process.put(__MODULE__, fun)

  @doc """
  Convenience: always answer 200 with `elements` (a list of Overpass-shaped
  element maps) wrapped in the interpreter's JSON envelope.
  """
  def stub_elements(elements) when is_list(elements) do
    body = Jason.encode!(%{"elements" => elements})
    stub(fn _url, _ql, _opts -> {:ok, %{status: 200, body: body}} end)
  end

  defp lookup do
    Enum.find_value([self() | callers()], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, __MODULE__)
        nil -> nil
      end
    end)
  end

  defp callers, do: Process.get(:"$callers", [])
end
