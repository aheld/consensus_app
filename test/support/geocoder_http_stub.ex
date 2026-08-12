defmodule Consensus.GeocoderHTTPStub do
  @moduledoc """
  The test implementation of `Consensus.Discovery.Geocoder.HTTP`, wired in by
  `config/test.exs`.

  Same `$callers`-walking idiom as `Consensus.LinkPreviewStub` (read its
  moduledoc for the full why): a test installs a response function with
  `stub/1`, and `get/2` finds it from any process the test spawned through
  `Task`/`start_async` — the geocoder will run inside one once the area-prompt
  UI lands.
  """

  @behaviour Consensus.Discovery.Geocoder.HTTP

  @impl true
  def get(url, opts) do
    case lookup() do
      nil -> {:error, :not_configured}
      fun -> fun.(url, opts)
    end
  end

  @doc """
  Installs the response function for this process and anything it spawns. It
  receives `(url, opts)` and returns what `Consensus.Discovery.Geocoder.HTTP`
  is specified to return — `{:ok, %{status:, body:}}` or `{:error, term}`.
  """
  def stub(fun) when is_function(fun, 2), do: Process.put(__MODULE__, fun)

  @doc """
  Convenience: always answer 200 with `places` (a list of Nominatim-shaped
  maps) encoded as the JSON body.
  """
  def stub_places(places) when is_list(places) do
    body = Jason.encode!(places)
    stub(fn _url, _opts -> {:ok, %{status: 200, body: body}} end)
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
