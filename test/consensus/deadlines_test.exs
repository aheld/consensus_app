defmodule Consensus.DeadlinesTest do
  use ExUnit.Case, async: true

  alias Consensus.Deadlines

  # A known week: 2026-08-10 is a Monday, ..., 2026-08-16 is a Sunday, 2026-08-13 and
  # 2026-08-20 are Thursdays a week apart. Verified with `date -j -f "%Y-%m-%d" ... "+%A"`.
  @monday ~D[2026-08-10]
  @tuesday ~D[2026-08-11]
  @wednesday ~D[2026-08-12]
  @thursday ~D[2026-08-13]
  @friday ~D[2026-08-14]
  @saturday ~D[2026-08-15]
  @sunday ~D[2026-08-16]
  @next_thursday ~D[2026-08-20]

  defp utc(date, time), do: DateTime.new!(date, time, "Etc/UTC")

  # Mirrors the module's own offset arithmetic, so tests can assert on local wall-clock
  # fields without hardcoding pre-computed UTC instants for every offset.
  defp to_local(dt, offset_minutes), do: DateTime.add(dt, offset_minutes * 60, :second)

  defp find(options, key), do: Enum.find(options, &(&1.key == key))

  # A module attribute value cannot call this module's own local functions (they
  # aren't defined yet as far as attribute evaluation is concerned), so this builds
  # each `DateTime` inline via `DateTime.new!/3` rather than through the `utc/2` test
  # helper above (a remote call, unlike a local one, is fine at this point).
  @cases [
    {DateTime.new!(@monday, ~T[08:00:00], "Etc/UTC"), 0},
    {DateTime.new!(@wednesday, ~T[16:59:59], "Etc/UTC"), 0},
    {DateTime.new!(@thursday, ~T[12:00:00], "Etc/UTC"), 0},
    {DateTime.new!(@friday, ~T[23:59:00], "Etc/UTC"), -420},
    {DateTime.new!(@saturday, ~T[00:00:01], "Etc/UTC"), 600},
    {DateTime.new!(@sunday, ~T[13:37:00], "Etc/UTC"), 330},
    {DateTime.new!(@tuesday, ~T[17:00:00], "Etc/UTC"), -60}
  ]

  describe "options/2 — before/exactly/after the 5pm boundary" do
    test "before 5pm local: this_evening is today, labelled Tonight 5pm" do
      now = utc(@wednesday, ~T[10:00:00])
      options = Deadlines.options(now, 0)

      this_evening = find(options, :this_evening)
      assert this_evening.label == "Tonight 5pm"
      assert to_local(this_evening.at, 0) == utc(@wednesday, ~T[17:00:00])

      tomorrow = find(options, :tomorrow)
      assert tomorrow.label == "Tomorrow 5pm"
      assert to_local(tomorrow.at, 0) == utc(@thursday, ~T[17:00:00])

      # today is Wednesday, so "next Thursday" is tomorrow, at noon — chronologically
      # *before* the 5pm "tomorrow" chip. options/2 must still sort ascending.
      next_thursday = find(options, :next_thursday)
      assert next_thursday.label == "Thu noon"
      assert to_local(next_thursday.at, 0) == utc(@thursday, ~T[12:00:00])

      assert Enum.map(options, & &1.key) == [:this_evening, :next_thursday, :tomorrow]
    end

    test "exactly 5pm local rolls, same as past 5pm — an at equal to now would not be strictly future" do
      now = utc(@wednesday, ~T[17:00:00])
      options = Deadlines.options(now, 0)

      this_evening = find(options, :this_evening)
      assert this_evening.label == "Fri 5pm"
      assert to_local(this_evening.at, 0) == utc(@friday, ~T[17:00:00])
      assert DateTime.compare(this_evening.at, now) == :gt
    end

    test "after 5pm local rolls and collides with tomorrow: dedupes to day-after-tomorrow" do
      now = utc(@wednesday, ~T[20:00:00])
      options = Deadlines.options(now, 0)

      assert length(options) == 3
      ats = Enum.map(options, & &1.at)
      assert ats == Enum.uniq(ats)

      tomorrow = find(options, :tomorrow)
      assert to_local(tomorrow.at, 0) == utc(@thursday, ~T[17:00:00])

      this_evening = find(options, :this_evening)
      assert this_evening.label == "Fri 5pm"
      assert to_local(this_evening.at, 0) == utc(@friday, ~T[17:00:00])

      next_thursday = find(options, :next_thursday)
      assert to_local(next_thursday.at, 0) == utc(@thursday, ~T[12:00:00])

      # ascending: next_thursday (Thu noon) < tomorrow (Thu 5pm) < this_evening (Fri 5pm)
      assert Enum.map(options, & &1.key) == [:next_thursday, :tomorrow, :this_evening]
    end
  end

  describe "options/2 — the next-Thursday rule, every weekday" do
    for {date, expected} <- [
          {~D[2026-08-10], ~D[2026-08-13]},
          {~D[2026-08-11], ~D[2026-08-13]},
          {~D[2026-08-12], ~D[2026-08-13]},
          {~D[2026-08-13], ~D[2026-08-20]},
          {~D[2026-08-14], ~D[2026-08-20]},
          {~D[2026-08-15], ~D[2026-08-20]},
          {~D[2026-08-16], ~D[2026-08-20]}
        ] do
      @date date
      @expected expected

      test "#{Date.day_of_week(date)}: #{date} -> #{expected}" do
        now = utc(@date, ~T[09:00:00])
        options = Deadlines.options(now, 0)
        next_thursday = find(options, :next_thursday)

        local = to_local(next_thursday.at, 0)
        assert DateTime.to_date(local) == @expected
        assert {local.hour, local.minute} == {12, 0}
      end
    end

    test "today being Thursday means a week out, never today" do
      now = utc(@thursday, ~T[09:00:00])
      options = Deadlines.options(now, 0)
      next_thursday = find(options, :next_thursday)

      assert DateTime.to_date(to_local(next_thursday.at, 0)) == @next_thursday
    end
  end

  describe "options/2 — offsets" do
    test "negative offset (US, e.g. Eastern DST-off -300)" do
      offset = -300
      # now_utc chosen so local wall time is 10:00 on @wednesday.
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, offset)
      this_evening = find(options, :this_evening)

      local = to_local(this_evening.at, offset)
      assert DateTime.to_date(local) == @wednesday
      assert {local.hour, local.minute} == {17, 0}
    end

    test "positive offset (Japan, +540)" do
      offset = 540
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, offset)
      tomorrow = find(options, :tomorrow)

      local = to_local(tomorrow.at, offset)
      assert DateTime.to_date(local) == @thursday
      assert {local.hour, local.minute} == {17, 0}
    end

    test "half-hour offset (India, +330)" do
      offset = 330
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, offset)
      next_thursday = find(options, :next_thursday)

      local = to_local(next_thursday.at, offset)
      assert DateTime.to_date(local) == @thursday
      assert {local.hour, local.minute} == {12, 0}
    end
  end

  describe "options/2 — midnight boundaries" do
    test "local date behind the UTC date (negative offset crossing midnight)" do
      # 00:10 UTC on Thursday, offset -120 -> local is 22:10 Wednesday.
      now = utc(@thursday, ~T[00:10:00])
      options = Deadlines.options(now, -120)

      this_evening = find(options, :this_evening)
      # local is already past 5pm on Wednesday, so it rolls; tomorrow local is Thursday.
      local_tomorrow = find(options, :tomorrow).at |> to_local(-120)
      assert DateTime.to_date(local_tomorrow) == @thursday

      # collision substitute lands the day after that.
      local_this_evening = this_evening.at |> to_local(-120)
      assert DateTime.to_date(local_this_evening) == @friday

      # "today" for the Thursday rule is still Wednesday, not Thursday: tomorrow (Thu).
      local_next_thursday = find(options, :next_thursday).at |> to_local(-120)
      assert DateTime.to_date(local_next_thursday) == @thursday
    end

    test "local date ahead of the UTC date (positive offset crossing midnight)" do
      # 23:50 UTC on Wednesday, offset +120 -> local is 01:50 Thursday.
      now = utc(@wednesday, ~T[23:50:00])
      options = Deadlines.options(now, 120)

      this_evening = find(options, :this_evening)
      local_this_evening = to_local(this_evening.at, 120)
      # local "today" is already Thursday, well before 5pm -> not rolled.
      assert this_evening.label == "Tonight 5pm"
      assert DateTime.to_date(local_this_evening) == @thursday

      # "today" being Thursday means next_thursday skips a week.
      local_next_thursday = find(options, :next_thursday).at |> to_local(120)
      assert DateTime.to_date(local_next_thursday) == @next_thursday
    end
  end

  describe "options/2 — sanity properties" do
    for {{now, offset}, index} <- Enum.with_index(@cases) do
      @now now
      @offset offset

      test "case #{index}: three strictly-increasing, strictly-future options" do
        options = Deadlines.options(@now, @offset)

        assert length(options) == 3
        assert Enum.all?(options, &(DateTime.compare(&1.at, @now) == :gt))
        assert Enum.all?(options, &(&1.label != ""))

        ats = Enum.map(options, & &1.at)

        assert ats
               |> Enum.chunk_every(2, 1, :discard)
               |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) == :lt end)
      end
    end
  end

  describe "resolve/3" do
    test "matches options/2's at for each canonical key, before the roll" do
      now = utc(@wednesday, ~T[10:00:00])
      options = Deadlines.options(now, 0)

      for key <- [:this_evening, :tomorrow, :next_thursday] do
        assert Deadlines.resolve(key, now, 0) == find(options, key).at
      end
    end

    test "matches options/2's collision substitute for :this_evening, after the roll" do
      now = utc(@wednesday, ~T[20:00:00])
      options = Deadlines.options(now, 0)

      assert Deadlines.resolve(:this_evening, now, 0) == find(options, :this_evening).at
    end

    test "unknown keys resolve to nil" do
      now = utc(@wednesday, ~T[10:00:00])
      assert Deadlines.resolve(:custom, now, 0) == nil
      assert Deadlines.resolve(:stored, now, 0) == nil
    end
  end

  describe "label_for/3" do
    test "a distant weekday, matching the moduledoc example exactly" do
      now = utc(@monday, ~T[09:00:00])
      at = utc(@thursday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, 0) == "Closes Thu 6:00 PM"
    end

    test "today, locally" do
      now = utc(@wednesday, ~T[10:00:00])
      at = utc(@wednesday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, 0) == "Closes Today 6:00 PM"
    end

    test "tomorrow, locally" do
      now = utc(@wednesday, ~T[10:00:00])
      at = utc(@thursday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, 0) == "Closes Tomorrow 6:00 PM"
    end

    test "noon and midnight format as 12-hour, not 0-hour or 24-hour" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.label_for(utc(@thursday, ~T[12:00:00]), now, 0) == "Closes Thu 12:00 PM"
      assert Deadlines.label_for(utc(@thursday, ~T[00:00:00]), now, 0) == "Closes Thu 12:00 AM"
    end

    test "applies the offset before deciding the weekday and time" do
      now = utc(@monday, ~T[09:00:00])
      # 01:00 UTC Thursday, offset -300 -> local is 20:00 Wednesday.
      at = utc(@thursday, ~T[01:00:00])

      assert Deadlines.label_for(at, now, -300) == "Closes Wed 8:00 PM"
    end
  end

  describe "countdown/2" do
    test "days and (zero-padded) hours" do
      now = utc(@monday, ~T[09:00:00])
      deadline = now |> DateTime.add(1, :day) |> DateTime.add(4 * 3600 + 30 * 60, :second)

      assert Deadlines.countdown(deadline, now) == "1d 04h left"
    end

    test "hours and (zero-padded) minutes, under a day" do
      now = utc(@monday, ~T[09:00:00])
      deadline = DateTime.add(now, 2 * 3600 + 5 * 60, :second)

      assert Deadlines.countdown(deadline, now) == "2h 05m left"
    end

    test "minutes only, under an hour" do
      now = utc(@monday, ~T[09:00:00])
      deadline = DateTime.add(now, 12 * 60, :second)

      assert Deadlines.countdown(deadline, now) == "12m left"
    end

    test "closing now: already past" do
      now = utc(@monday, ~T[09:00:00])
      deadline = DateTime.add(now, -5, :second)

      assert Deadlines.countdown(deadline, now) == "Closing now"
    end

    test "closing now: under a minute away" do
      now = utc(@monday, ~T[09:00:00])
      deadline = DateTime.add(now, 30, :second)

      assert Deadlines.countdown(deadline, now) == "Closing now"
    end

    test "closing now: exactly now" do
      now = utc(@monday, ~T[09:00:00])
      assert Deadlines.countdown(now, now) == "Closing now"
    end
  end
end
