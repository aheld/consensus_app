defmodule Consensus.DeadlinesTest do
  use ExUnit.Case, async: true

  alias Consensus.Deadlines
  alias Consensus.Deadlines.Clock

  # An offset-only clock — no zone name, which is exactly what D-031 shipped and what a
  # browser that sends `tz_offset` without a resolvable `tz` still produces. Every case
  # below that predates D-055 uses it, so the whole original suite goes on asserting that
  # the fallback path is byte-for-byte unchanged. The zone path has its own describes.
  defp clock(offset_minutes), do: %Clock{offset_minutes: offset_minutes}

  # A zone clock. The offset is deliberately left at its 0 default: nothing may read it
  # when a zone is present, so a wrong one here would be caught by any test that did.
  defp zone(name), do: %Clock{zone: name}

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
      options = Deadlines.options(now, clock(0))

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
      options = Deadlines.options(now, clock(0))

      this_evening = find(options, :this_evening)
      assert this_evening.label == "Fri 5pm"
      assert to_local(this_evening.at, 0) == utc(@friday, ~T[17:00:00])
      assert DateTime.compare(this_evening.at, now) == :gt
    end

    test "after 5pm local rolls and collides with tomorrow: dedupes to day-after-tomorrow" do
      now = utc(@wednesday, ~T[20:00:00])
      options = Deadlines.options(now, clock(0))

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
        options = Deadlines.options(now, clock(0))
        next_thursday = find(options, :next_thursday)

        local = to_local(next_thursday.at, 0)
        assert DateTime.to_date(local) == @expected
        assert {local.hour, local.minute} == {12, 0}
      end
    end

    test "today being Thursday means a week out, never today" do
      now = utc(@thursday, ~T[09:00:00])
      options = Deadlines.options(now, clock(0))
      next_thursday = find(options, :next_thursday)

      assert DateTime.to_date(to_local(next_thursday.at, 0)) == @next_thursday
    end
  end

  describe "options/2 — offsets" do
    test "negative offset (US, e.g. Eastern DST-off -300)" do
      offset = -300
      # now_utc chosen so local wall time is 10:00 on @wednesday.
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, clock(offset))
      this_evening = find(options, :this_evening)

      local = to_local(this_evening.at, offset)
      assert DateTime.to_date(local) == @wednesday
      assert {local.hour, local.minute} == {17, 0}
    end

    test "positive offset (Japan, +540)" do
      offset = 540
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, clock(offset))
      tomorrow = find(options, :tomorrow)

      local = to_local(tomorrow.at, offset)
      assert DateTime.to_date(local) == @thursday
      assert {local.hour, local.minute} == {17, 0}
    end

    test "half-hour offset (India, +330)" do
      offset = 330
      now = DateTime.add(utc(@wednesday, ~T[10:00:00]), -offset * 60, :second)

      options = Deadlines.options(now, clock(offset))
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
      options = Deadlines.options(now, clock(-120))

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
      options = Deadlines.options(now, clock(120))

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
        options = Deadlines.options(@now, clock(@offset))

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
      options = Deadlines.options(now, clock(0))

      for key <- [:this_evening, :tomorrow, :next_thursday] do
        assert Deadlines.resolve(key, now, clock(0)) == find(options, key).at
      end
    end

    test "matches options/2's collision substitute for :this_evening, after the roll" do
      now = utc(@wednesday, ~T[20:00:00])
      options = Deadlines.options(now, clock(0))

      assert Deadlines.resolve(:this_evening, now, clock(0)) == find(options, :this_evening).at
    end

    test "unknown keys resolve to nil" do
      now = utc(@wednesday, ~T[10:00:00])
      assert Deadlines.resolve(:custom, now, clock(0)) == nil
      assert Deadlines.resolve(:stored, now, clock(0)) == nil
    end
  end

  describe "label_for/3" do
    test "a distant weekday, matching the moduledoc example exactly" do
      now = utc(@monday, ~T[09:00:00])
      at = utc(@thursday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, clock(0)) == "Closes Thu 6:00 PM"
    end

    test "today, locally" do
      now = utc(@wednesday, ~T[10:00:00])
      at = utc(@wednesday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, clock(0)) == "Closes Today 6:00 PM"
    end

    test "tomorrow, locally" do
      now = utc(@wednesday, ~T[10:00:00])
      at = utc(@thursday, ~T[18:00:00])

      assert Deadlines.label_for(at, now, clock(0)) == "Closes Tomorrow 6:00 PM"
    end

    test "noon and midnight format as 12-hour, not 0-hour or 24-hour" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.label_for(utc(@thursday, ~T[12:00:00]), now, clock(0)) ==
               "Closes Thu 12:00 PM"

      assert Deadlines.label_for(utc(@thursday, ~T[00:00:00]), now, clock(0)) ==
               "Closes Thu 12:00 AM"
    end

    test "applies the offset before deciding the weekday and time" do
      now = utc(@monday, ~T[09:00:00])
      # 01:00 UTC Thursday, offset -300 -> local is 20:00 Wednesday.
      at = utc(@thursday, ~T[01:00:00])

      assert Deadlines.label_for(at, now, clock(-300)) == "Closes Wed 8:00 PM"
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

  # ---------------------------------------------------------------------------------
  # D-055: zone rules. Everything above this line exercises the offset fallback and is
  # unchanged from what D-031 shipped.
  # ---------------------------------------------------------------------------------

  describe "clock_from_params/1 — the zone → offset → UTC ladder" do
    test "a zone the database knows wins, and the offset rides along unused" do
      clock = Deadlines.clock_from_params(%{"tz" => "America/New_York", "tz_offset" => -240})

      assert clock.zone == "America/New_York"
      assert clock.offset_minutes == -240
    end

    test "a zone the database does not know is dropped, and the offset is used instead" do
      clock = Deadlines.clock_from_params(%{"tz" => "Mars/Olympus_Mons", "tz_offset" => -240})

      assert clock.zone == nil
      assert clock.offset_minutes == -240
    end

    test "a non-string zone is ignored rather than crashing — it is untrusted client input" do
      assert Deadlines.clock_from_params(%{"tz" => 42, "tz_offset" => 60}).zone == nil
      assert Deadlines.clock_from_params(%{"tz" => nil}).zone == nil
      assert Deadlines.clock_from_params(%{"tz" => ["America/New_York"]}).zone == nil
    end

    test "no params at all — the dead render — is UTC, not a guessed region" do
      assert Deadlines.clock_from_params(nil) == %Clock{zone: nil, offset_minutes: 0}
      assert Deadlines.clock_from_params(%{}) == %Clock{zone: nil, offset_minutes: 0}
    end

    test "a float offset is rounded, as the browser can send one" do
      assert Deadlines.clock_from_params(%{"tz_offset" => -239.7}).offset_minutes == -240
    end
  end

  describe "from_wall_clock/2 — the custom picker's conversion" do
    test "an ordinary time converts through the zone's rules" do
      # 7pm on 11 Aug 2026 in New York is EDT, UTC-4 -> 23:00 UTC.
      assert {:ok, at} =
               Deadlines.from_wall_clock(~N[2026-08-11 19:00:00], zone("America/New_York"))

      assert at == ~U[2026-08-11 23:00:00Z]
    end

    test "the same wall clock after DST ends converts an hour differently" do
      # 7pm on 8 Nov 2026 is EST, UTC-5 -> midnight UTC on the 9th.
      assert {:ok, at} =
               Deadlines.from_wall_clock(~N[2026-11-08 19:00:00], zone("America/New_York"))

      assert at == ~U[2026-11-09 00:00:00Z]
    end

    test "a half-hour zone" do
      assert {:ok, at} =
               Deadlines.from_wall_clock(~N[2026-11-08 19:00:00], zone("Asia/Kolkata"))

      assert at == ~U[2026-11-08 13:30:00Z]
    end

    test "a southern-hemisphere zone, where December is the summer offset" do
      assert {:ok, dec} =
               Deadlines.from_wall_clock(~N[2026-12-20 19:00:00], zone("Australia/Sydney"))

      assert {:ok, jun} =
               Deadlines.from_wall_clock(~N[2026-06-20 19:00:00], zone("Australia/Sydney"))

      # AEDT (+11) in December, AEST (+10) in June — the opposite way round from the
      # northern zones above, which is the point of testing one.
      assert dec == ~U[2026-12-20 08:00:00Z]
      assert jun == ~U[2026-06-20 09:00:00Z]
    end

    test "with no zone it is exactly the D-031 offset arithmetic" do
      assert {:ok, at} = Deadlines.from_wall_clock(~N[2026-08-11 19:00:00], clock(-240))
      assert at == ~U[2026-08-11 23:00:00Z]
    end

    test "a malformed clock carrying an unresolvable zone returns an error, never raises" do
      assert {:error, :time_zone_not_found} =
               Deadlines.from_wall_clock(~N[2026-08-11 19:00:00], %Clock{zone: "Mars/Olympus"})
    end
  end

  # D3 in docs/plans/custom-deadline.md: one rule for both, and it is asserted as the
  # rule rather than as whatever the implementation happens to return.
  describe "from_wall_clock/2 — wall-clock times that do not exist, or happen twice" do
    test "an ambiguous time takes the LATER of the two instants" do
      # 01:30 on 1 Nov 2026 in New York happens twice: once at UTC-4, then at UTC-5.
      assert {:ok, at} =
               Deadlines.from_wall_clock(~N[2026-11-01 01:30:00], zone("America/New_York"))

      assert at == ~U[2026-11-01 06:30:00Z]
      refute at == ~U[2026-11-01 05:30:00Z]
    end

    test "a nonexistent time takes the first instant AFTER the gap" do
      # 02:30 on 8 Mar 2026 in New York does not exist; the clock jumps 02:00 -> 03:00.
      assert {:ok, at} =
               Deadlines.from_wall_clock(~N[2026-03-08 02:30:00], zone("America/New_York"))

      # 03:00 EDT (UTC-4), i.e. the moment the gap ends — not the 01:59:59.999999 EST
      # instant just before it.
      assert at == ~U[2026-03-08 07:00:00Z]
    end

    test "the rule holds in the southern hemisphere, where the transitions are reversed" do
      assert {:ok, ambiguous} =
               Deadlines.from_wall_clock(~N[2026-04-05 02:30:00], zone("Australia/Sydney"))

      assert {:ok, gap} =
               Deadlines.from_wall_clock(~N[2026-10-04 02:30:00], zone("Australia/Sydney"))

      # Later instant of the repeated hour: AEST (+10), not AEDT (+11).
      assert ambiguous == ~U[2026-04-04 16:30:00Z]
      # First instant after the gap: 03:00 AEDT.
      assert gap == ~U[2026-10-03 16:00:00Z]
    end

    test "and in Europe, whose transitions fall on different dates again" do
      assert {:ok, ambiguous} =
               Deadlines.from_wall_clock(~N[2026-10-25 01:30:00], zone("Europe/London"))

      assert {:ok, gap} =
               Deadlines.from_wall_clock(~N[2026-03-29 01:30:00], zone("Europe/London"))

      assert ambiguous == ~U[2026-10-25 01:30:00Z]
      assert gap == ~U[2026-03-29 01:00:00Z]
    end

    test "a deadline is never moved EARLIER than the words that set it" do
      # The rule as one property over every odd case in all three zones, stated as "the
      # later of the two candidates" rather than as two pattern-match clauses — so a
      # swap in either clause of the implementation fails here.
      for {zone_name, naive} <- [
            {"America/New_York", ~N[2026-11-01 01:30:00]},
            {"America/New_York", ~N[2026-03-08 02:30:00]},
            {"Australia/Sydney", ~N[2026-04-05 02:30:00]},
            {"Australia/Sydney", ~N[2026-10-04 02:30:00]},
            {"Europe/London", ~N[2026-10-25 01:30:00]},
            {"Europe/London", ~N[2026-03-29 01:30:00]}
          ] do
        date = NaiveDateTime.to_date(naive)
        time = NaiveDateTime.to_time(naive)

        {earlier, later} =
          case DateTime.new(date, time, zone_name) do
            {:ambiguous, first, second} -> {first, second}
            {:gap, just_before, just_after} -> {just_before, just_after}
          end

        earlier = DateTime.shift_zone!(earlier, "Etc/UTC")
        later = DateTime.shift_zone!(later, "Etc/UTC")

        assert {:ok, resolved} = Deadlines.from_wall_clock(naive, zone(zone_name))

        assert resolved == later,
               "#{zone_name} #{naive}: took #{resolved}, wanted the later candidate #{later}"

        assert DateTime.compare(resolved, earlier) == :gt,
               "#{zone_name} #{naive}: #{resolved} is not strictly after #{earlier}"
      end
    end
  end

  # The bug the whole feature exists to prevent, named so it cannot be quietly lost.
  describe "the pick-7-see-8 regression (D-055)" do
    test "a deadline set across a DST boundary reads back as the hour that was picked" do
      # The organizer is in New York on 25 Oct 2026 — still EDT — and picks 7:00 PM on
      # 8 Nov, by which time the zone is on EST. Under offset arithmetic the stored
      # instant was an hour early AND the label read back "8:00 PM".
      clock = zone("America/New_York")
      now = ~U[2026-10-25 18:00:00Z]

      assert {:ok, at} = Deadlines.from_wall_clock(~N[2026-11-08 19:00:00], clock)
      assert Deadlines.label_for(at, now, clock) == "Closes Sun 7:00 PM"
      assert Deadlines.compact_reading_for(at, now, clock) == "Sun 7pm"
    end

    test "the offset path still gets it wrong, which is why the zone path exists" do
      # Not an aspiration — a pin on the fallback's known limitation, so that if someone
      # later "fixes" the offset path by guessing, this fails and sends them here.
      offset_clock = clock(-240)
      now = ~U[2026-10-25 18:00:00Z]

      assert {:ok, at} = Deadlines.from_wall_clock(~N[2026-11-08 19:00:00], offset_clock)
      assert Deadlines.label_for(at, now, offset_clock) == "Closes Sun 7:00 PM"

      # ...but the instant it stored is an hour off what a New Yorker meant, and that is
      # exactly the defect the zone path removes.
      assert at == ~U[2026-11-08 23:00:00Z]

      assert {:ok, correct} =
               Deadlines.from_wall_clock(~N[2026-11-08 19:00:00], zone("America/New_York"))

      assert DateTime.diff(correct, at, :second) == 3600
    end
  end

  describe "options/2 and label_for/3 under zone rules" do
    test "the chips are computed in the zone's wall clock" do
      # 14:00 UTC on 11 Aug 2026 is 10:00 EDT — before 5pm, so tonight is today.
      now = ~U[2026-08-11 14:00:00Z]
      options = Deadlines.options(now, zone("America/New_York"))

      assert find(options, :this_evening).label == "Tonight 5pm"
      assert find(options, :this_evening).at == ~U[2026-08-11 21:00:00Z]
    end

    test "the 5pm roll uses the zone's local time, not UTC's" do
      # 22:00 UTC is 18:00 EDT — past 5pm locally, so `:this_evening` rolls forward even
      # though UTC has not reached 5pm on any reading.
      now = ~U[2026-08-11 22:00:00Z]
      options = Deadlines.options(now, zone("America/New_York"))

      assert find(options, :this_evening).label == "Thu 5pm"
    end

    test "'tomorrow 5pm' stays 5pm across a DST transition rather than drifting an hour" do
      # 31 Oct 2026 in New York is EDT; 1 Nov is EST. "Tomorrow 5pm" must be 5pm on the
      # 1st, not 4pm — which is what adding 86,400 seconds to an instant would give.
      now = ~U[2026-10-31 15:00:00Z]
      options = Deadlines.options(now, zone("America/New_York"))
      tomorrow = find(options, :tomorrow).at

      assert Deadlines.label_for(tomorrow, now, zone("America/New_York")) ==
               "Closes Tomorrow 5:00 PM"

      assert tomorrow == ~U[2026-11-01 22:00:00Z]
    end

    test "every chip is still strictly in the future, in a zone" do
      now = ~U[2026-11-01 05:30:00Z]

      for zone_name <- ["America/New_York", "Europe/London", "Australia/Sydney", "Asia/Kolkata"],
          option <- Deadlines.options(now, zone(zone_name)) do
        assert DateTime.compare(option.at, now) == :gt,
               "#{zone_name} #{option.key} was not in the future"
      end
    end
  end

  describe "compact_reading_for/3 — the share card's format" do
    test "on-the-hour drops the colon and the leading zero" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.compact_reading_for(utc(@thursday, ~T[18:00:00]), now, clock(0)) ==
               "Thu 6pm"
    end

    test "off-the-hour keeps the minutes" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.compact_reading_for(utc(@thursday, ~T[18:30:00]), now, clock(0)) ==
               "Thu 6:30pm"
    end

    test "relative days are lower-case, and the weekday abbreviation is not" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.compact_reading_for(utc(@monday, ~T[18:00:00]), now, clock(0)) ==
               "today 6pm"

      assert Deadlines.compact_reading_for(utc(@tuesday, ~T[18:00:00]), now, clock(0)) ==
               "tomorrow 6pm"
    end

    test "midnight and noon" do
      now = utc(@monday, ~T[09:00:00])

      assert Deadlines.compact_reading_for(utc(@thursday, ~T[00:00:00]), now, clock(0)) ==
               "Thu 12am"

      assert Deadlines.compact_reading_for(utc(@thursday, ~T[12:00:00]), now, clock(0)) ==
               "Thu 12pm"
    end
  end
end
