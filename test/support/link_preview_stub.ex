defmodule Consensus.LinkPreviewStub do
  @moduledoc """
  The test implementation of `Consensus.LinkPreview.Fetcher`.

  There is no Mox in this project, so the stub is a plain module wired in by
  `config/test.exs`. A test installs a response function with `stub/1`; every call to
  `get/2` runs it.

  ## Why it walks `$callers`

  The obvious implementation stores the function in the calling process's dictionary and
  reads it back in `get/2`. That works only while `Consensus.LinkPreview.fetch/1` runs in
  the same process as the test — which it does in the context tests, and does **not** in
  any LiveView test, because the screens call `fetch/1` from a `start_async` and that runs
  in a `Task`. The stub would come back `:not_configured` and the assertion would fail
  for a reason that has nothing to do with the code under test.

  `Task` copies the spawning process's `:"$callers"` chain into the new process's
  dictionary, so walking it finds the test process that installed the stub. This is the
  same mechanism Mox's `allow/3` automates, done by hand because we carry no Mox.

  A stub is therefore visible to the test that set it and to any process that test spawned
  through `Task`/`start_async`, and to nobody else — so the suite stays `async: true`
  everywhere except where genuinely global state (the cache table, application env)
  forces otherwise.
  """

  @behaviour Consensus.LinkPreview.Fetcher

  @impl true
  def get(url, opts) do
    case lookup() do
      nil -> {:error, :not_configured}
      fun -> fun.(url, opts)
    end
  end

  @doc """
  Installs the response function for this process and anything it spawns.

  The function receives `(url, opts)` and returns what `Consensus.LinkPreview.Fetcher`
  is specified to return — `{:ok, %{status:, headers:, body:, url:}}` or `{:error, term}`.
  """
  def stub(fun) when is_function(fun, 2), do: Process.put(__MODULE__, fun)

  @doc "Convenience: always answer with this HTML body at status 200."
  def stub_html(body, url \\ nil) do
    stub(fn requested, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "text/html; charset=utf-8"}],
         body: body,
         url: url || requested
       }}
    end)
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
