defmodule Consensus.Discovery.Nominatim.GateTest do
  # async: true is safe: every case starts its own, unnamed gate with an explicit
  # interval, never the app-wide one (which config/test.exs runs at interval 0).
  use ExUnit.Case, async: true

  alias Consensus.Discovery.Nominatim.Gate

  defp start_gate(interval_ms) do
    start_supervised!({Gate, name: nil, interval_ms: interval_ms})
  end

  test "the first reservation needs no wait" do
    gate = start_gate(1_000)

    assert {:ok, 0} = Gate.reserve(gate, 3_000)
  end

  test "back-to-back reservations are one interval apart" do
    gate = start_gate(1_000)

    assert {:ok, 0} = Gate.reserve(gate, 3_000)
    assert {:ok, second} = Gate.reserve(gate, 3_000)
    assert {:ok, third} = Gate.reserve(gate, 3_000)

    # Measured in real milliseconds, so allow for the time the calls themselves
    # took — but never less than one slot apart, and never more.
    assert second in 990..1_000
    assert third in 1_990..2_000
  end

  test "a reservation past max_wait_ms is :busy, and the refusal does not move the slot" do
    gate = start_gate(1_000)

    assert {:ok, _} = Gate.reserve(gate, 3_000)
    assert {:ok, _} = Gate.reserve(gate, 3_000)
    assert {:ok, _} = Gate.reserve(gate, 3_000)
    assert {:ok, _} = Gate.reserve(gate, 3_000)

    # Four slots taken: the fifth is ~4s out, past the 3s budget.
    assert Gate.reserve(gate, 3_000) == {:error, :busy}
    assert Gate.granted(gate) == 4

    # A caller willing to wait longer still gets the slot right after the
    # fourth — the refusal above reserved nothing.
    assert {:ok, wait} = Gate.reserve(gate, 10_000)
    assert wait in 3_990..4_000
  end

  test "an interval of 0 (the suite's setting) never makes anyone wait" do
    gate = start_gate(0)

    for _ <- 1..5, do: assert({:ok, 0} = Gate.reserve(gate, 0))
  end

  test "a slot in the past is not banked: an idle gate does not hand out a burst" do
    gate = start_gate(50)

    assert {:ok, 0} = Gate.reserve(gate, 3_000)
    Process.sleep(200)

    assert {:ok, 0} = Gate.reserve(gate, 3_000)
    assert {:ok, wait} = Gate.reserve(gate, 3_000)
    assert wait > 0
  end
end
