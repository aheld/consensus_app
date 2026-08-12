defmodule Consensus.Discovery.CacheTest do
  @moduledoc """
  Pins the parameterisation of `Consensus.LinkPreview.Cache` (research §4.5): the
  table is a `start_link/1` option, two instances keep genuinely separate tables,
  and a put may carry its own TTLs — the pieces `Consensus.Discovery.Cache` (the
  second supervised instance) is built from. The LinkPreview instance's own
  behaviour stays pinned where it always was, in
  `test/consensus/link_preview_test.exs`.
  """

  # async: false: touches the app-wide Consensus.Discovery.Cache and
  # Consensus.LinkPreview.Cache named ETS tables.
  use ExUnit.Case, async: false

  alias Consensus.Discovery
  alias Consensus.LinkPreview

  setup do
    Discovery.Cache.flush()
    :ok
  end

  describe "table parameterisation" do
    test "an instance on its own table stores independently of the default one" do
      table = :discovery_cache_param_test
      start_supervised!({LinkPreview.Cache, table: table})

      LinkPreview.Cache.put(table, "key", {:ok, :parameterised})

      assert LinkPreview.Cache.get(table, "key") == {:hit, {:ok, :parameterised}}
      # Neither app-wide instance saw it.
      assert LinkPreview.Cache.get("key") == :miss
      assert Discovery.Cache.get("key") == :miss
    end

    test "a per-put ttl_ms override expires an {:ok, _} entry" do
      table = :discovery_cache_ttl_test
      start_supervised!({LinkPreview.Cache, table: table})

      LinkPreview.Cache.put(table, "short", {:ok, :val}, ttl_ms: 50)
      assert LinkPreview.Cache.get(table, "short") == {:hit, {:ok, :val}}

      Process.sleep(80)

      assert LinkPreview.Cache.get(table, "short") == :miss
    end

    test "a per-put error_ttl_ms override expires an {:error, _} entry" do
      table = :discovery_cache_error_ttl_test
      start_supervised!({LinkPreview.Cache, table: table})

      LinkPreview.Cache.put(table, "flaky", {:error, :down}, error_ttl_ms: 50)
      assert LinkPreview.Cache.get(table, "flaky") == {:hit, {:error, :down}}

      Process.sleep(80)

      assert LinkPreview.Cache.get(table, "flaky") == :miss
    end

    test "without per-put opts the config-default TTLs apply (hours, so: still live)" do
      table = :discovery_cache_default_ttl_test
      start_supervised!({LinkPreview.Cache, table: table})

      LinkPreview.Cache.put(table, "key", {:ok, :val})

      assert LinkPreview.Cache.get(table, "key") == {:hit, {:ok, :val}}
    end
  end

  describe "the Consensus.Discovery.Cache instance" do
    test "put/get/size/flush work against its own table only" do
      before_default = LinkPreview.Cache.size()

      Discovery.Cache.put({:search, "x"}, {:ok, [:result]}, ttl_ms: :timer.hours(1))

      assert Discovery.Cache.get({:search, "x"}) == {:hit, {:ok, [:result]}}
      assert Discovery.Cache.size() == 1
      # The default (LinkPreview) instance is untouched by a Discovery put...
      assert LinkPreview.Cache.size() == before_default
      assert LinkPreview.Cache.get({:search, "x"}) == :miss

      # ...and by a Discovery flush.
      LinkPreview.Cache.put("stays", {:ok, :kept})
      Discovery.Cache.flush()

      assert Discovery.Cache.size() == 0
      assert LinkPreview.Cache.get("stays") == {:hit, {:ok, :kept}}

      LinkPreview.Cache.flush()
    end
  end
end
