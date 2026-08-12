defmodule Consensus.Deadlines do
  @moduledoc """
  Every wall-clock computation in the app: the three quick deadline chips on `01 setup`,
  the custom picker's conversion, and the labels both of them render back
  (`ConsensusWeb.GroupLive.New`, `.Review`, `.Share` and `ConsensusWeb.JoinLive.Results`).

  Pure functions, no database. Every function takes the caller's own idea of "now" (a UTC
  `DateTime`) and a `Consensus.Deadlines.Clock` describing the viewer's wall clock, so
  results are deterministic and testable.

  ## Zone rules, with the offset as a fallback (D-055, superseding half of D-031)

  D-031 shipped offset arithmetic and recorded its own cost: *"an offset is a fixed
  number, not a rule, so a DST transition that falls inside the window between `now` and
  the computed deadline shifts the result by an hour … Acceptable for a
  same-day-to-one-week deadline picker; **not acceptable for anything computed further
  out**."* The custom picker is "further out" — its window is whatever the organizer
  types — so the offset stopped being sufficient and the zone database D-031 declined is
  now a dependency (`:tz`, compiled in, no updater; see `config/config.exs`).

  The browser was already sending the zone name and nothing read it. It does now, and the
  ladder is **zone → offset → UTC** (`Clock`). The offset path is byte-for-byte the
  arithmetic D-031 shipped, so a client that sends no zone behaves exactly as before.

  ### What that fixes, concretely

  On 25 Oct in New York an organizer picks Nov 8, 7:00 PM. Today's offset is `-240`
  (EDT); on Nov 8 the zone is on EST (`-300`). Under offset arithmetic the stored instant
  was an hour early **and** `label_for/3` rendered it back as 8:00 PM — the organizer
  picked 7 and the confirmation said 8. Under zone rules both are 7:00 PM.

  ## Wall-clock times that do not exist, or happen twice

  A picker can select `02:30` on spring-forward day (no such instant) or `01:30` on
  fall-back day (two such instants). `from_wall_clock/2` resolves both with one rule:
  **take the later instant.** A deadline may never arrive *earlier* than the organizer's
  own words imply, so on `{:ambiguous, first, second}` it takes `second` and on
  `{:gap, just_before, just_after}` it takes `just_after`. Both give voters at least as
  much time as they expect; the alternatives close voting early on a date nobody was
  thinking about.

  Offset arithmetic cannot even detect these cases — it silently invents an answer — so
  this rule only binds on the zone path.

  ## The collision rule

  `:this_evening` is "5pm local today", unless local time is already at or past 5pm, in
  which case it rolls forward to the next day at 5pm — the exact instant `:tomorrow`
  already represents. Rather than show two chips with the same timestamp, `options/2`
  detects that collision and substitutes 5pm local **the day after tomorrow** for the
  `:this_evening` slot, labelled with that day's short weekday name (e.g. `"Sat 5pm"`).
  `resolve/3` mirrors this exactly, so a click on that chip resolves to the same instant
  `options/2` displayed for it.

  Being "at or past 5pm" (not only strictly past) triggers the roll, because otherwise a
  call made at exactly 5pm would return an `:at` equal to `now` — not strictly in the
  future, which every chip is guaranteed to be.

  ## Ordering

  `options/2` always returns its three entries sorted by `:at` ascending. This is not
  always the same as the `:this_evening`, `:tomorrow`, `:next_thursday` conceptual order:
  whenever "today" is a Wednesday (or, after the roll, whenever the collision substitute
  lands mid-week), `:next_thursday` at local noon falls *before* `:tomorrow`/
  `:this_evening` at local 5pm on that same Thursday. Sorting by instant is what keeps the
  "strictly increasing" guarantee true in every case.

  ## Local time is a `NaiveDateTime` here, deliberately

  Internally, "local wall clock" is a `NaiveDateTime` — a reading with no zone, which is
  exactly what it is. The previous implementation carried it as a UTC-tagged `DateTime`
  shifted by the offset, which worked but meant every intermediate value was a `DateTime`
  claiming a zone it did not have. Nothing but a genuinely-UTC `DateTime` leaves this
  module, in either version.
  """

  alias Consensus.Deadlines.Clock

  @typedoc "One chip: a stable key, a short human label, and the UTC instant it means."
  @type option :: %{key: atom(), label: String.t(), at: DateTime.t()}

  @evening_hour 17
  @thursday 4
  @weekday_abbrevs {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

  @doc """
  Builds a `Consensus.Deadlines.Clock` from a LiveView's `get_connect_params/1`.

  **The one place connect params are read.** Four LiveViews used to carry a private
  near-copy of this (`read_tz_offset`/`assign_tz_offset` in `GroupLive.New`, `.Review`,
  `.Share` and `JoinLive.Results`); adding a fifth near-copy for the zone name is how
  this seam would rot, so they all call here now.

  `nil` — which is what `get_connect_params/1` returns on the dead render, before the
  socket connects — is a valid argument and yields the UTC clock.

  The zone name is resolved against the database here and dropped to `nil` if unknown, so
  everything downstream can assume a `:zone` that resolves. See `Clock`'s moduledoc.
  """
  @spec clock_from_params(map() | nil) :: Clock.t()
  def clock_from_params(params) do
    %Clock{zone: known_zone(params), offset_minutes: offset_from_params(params)}
  end

  defp known_zone(%{"tz" => zone}) when is_binary(zone) do
    # A connect param is untrusted client input. `DateTime.shift_zone/2` is the cheapest
    # honest membership test: it consults the same database every later call will use, so
    # a name that passes here cannot fail there.
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _shifted} -> zone
      {:error, _reason} -> nil
    end
  end

  defp known_zone(_params), do: nil

  defp offset_from_params(%{"tz_offset" => offset}) when is_integer(offset), do: offset
  defp offset_from_params(%{"tz_offset" => offset}) when is_float(offset), do: round(offset)
  defp offset_from_params(_params), do: 0

  @doc """
  The three deadline chips for `01 setup`, computed from `now_utc` and the viewer's
  `Clock`, sorted by `:at` ascending (see moduledoc).

  Always returns exactly three entries, each strictly in the future.
  """
  @spec options(DateTime.t(), Clock.t()) :: [option()]
  def options(now_utc, %Clock{} = clock) do
    local_now = to_local(now_utc, clock)

    {this_evening_local, this_evening_label} = compute_this_evening(local_now)

    [
      %{
        key: :this_evening,
        label: this_evening_label,
        at: to_utc!(this_evening_local, clock)
      },
      %{
        key: :tomorrow,
        label: "Tomorrow 5pm",
        at: local_now |> compute_tomorrow() |> to_utc!(clock)
      },
      %{
        key: :next_thursday,
        label: "Thu noon",
        at: local_now |> compute_next_thursday() |> to_utc!(clock)
      }
    ]
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  Resolves a single chip key to the UTC instant it means right now.

  Mirrors `options/2`'s computation for `:this_evening`, `:tomorrow` and `:next_thursday`
  exactly — including the collision substitution — so a chip clicked a few minutes after
  the page rendered resolves to a fresh, still-correct instant rather than whatever was
  true at mount. Returns `nil` for any other atom.
  """
  @spec resolve(atom(), DateTime.t(), Clock.t()) :: DateTime.t() | nil
  def resolve(key, now_utc, %Clock{} = clock) do
    local_now = to_local(now_utc, clock)

    case key do
      :this_evening ->
        {local, _label} = compute_this_evening(local_now)
        to_utc!(local, clock)

      :tomorrow ->
        local_now |> compute_tomorrow() |> to_utc!(clock)

      :next_thursday ->
        local_now |> compute_next_thursday() |> to_utc!(clock)

      _other ->
        nil
    end
  end

  @doc """
  Turns a wall-clock reading the organizer typed into the UTC instant it means.

  This is the custom picker's conversion (`ConsensusWeb.GroupLive.New`). The input is a
  `NaiveDateTime` because that is honestly what an organizer types: a reading with no
  zone attached. The `Clock` supplies the zone.

  Ambiguous and nonexistent wall-clock times both resolve to the **later** instant — see
  the moduledoc. Returns `{:error, :time_zone_not_found}` only if a `Clock` were somehow
  built with an unvalidated zone; `clock_from_params/1` makes that unreachable, and the
  clause exists so this function has no way to raise at an organizer.
  """
  @spec from_wall_clock(NaiveDateTime.t(), Clock.t()) ::
          {:ok, DateTime.t()} | {:error, atom()}
  def from_wall_clock(%NaiveDateTime{} = naive, %Clock{zone: nil} = clock) do
    {:ok, offset_to_utc(naive, clock)}
  end

  def from_wall_clock(%NaiveDateTime{} = naive, %Clock{zone: zone}) do
    date = NaiveDateTime.to_date(naive)
    time = NaiveDateTime.to_time(naive)

    case DateTime.new(date, time, zone) do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      # Later instant on both, per the moduledoc: a deadline may never arrive earlier
      # than the words that set it.
      {:ambiguous, _first, second} -> {:ok, DateTime.shift_zone!(second, "Etc/UTC")}
      {:gap, _just_before, just_after} -> {:ok, DateTime.shift_zone!(just_after, "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The wall clock this viewer would read off a UTC instant — the inverse of
  `from_wall_clock/2`.

  A `NaiveDateTime`, because a wall-clock reading genuinely carries no zone. The custom
  picker uses it for both of its `datetime-local` values: the `min` attribute (local
  "now") and the field's own value when an existing deadline is being edited, so opening
  the picker on a saved session shows the deadline that is already set rather than an
  empty field.
  """
  @spec wall_clock(DateTime.t(), Clock.t()) :: NaiveDateTime.t()
  def wall_clock(at, %Clock{} = clock), do: to_local(at, clock)

  @doc """
  A human label for an arbitrary deadline, e.g. `"Closes Thu 6:00 PM"`.

  Used for the wizard's fourth, non-canonical chip: when an already-stored `deadline_at`
  no longer matches any of today's three computed options (because time has moved on
  since it was set, or because it came from the custom picker), the group's actual
  deadline still needs a label. `now_utc` says "today" for the purpose of preferring
  `"Today"`/`"Tomorrow"` over a weekday name when the deadline falls on one of those two
  local calendar days; otherwise the local weekday's short name is used.
  """
  @spec label_for(DateTime.t(), DateTime.t(), Clock.t()) :: String.t()
  def label_for(at, now_utc, %Clock{} = clock) do
    local_at = to_local(at, clock)
    local_now = to_local(now_utc, clock)

    "Closes #{day_part(local_at, local_now)} #{format_time_12h(local_at)}"
  end

  @doc """
  The compact reading the share card wants: `"today 6pm"`, `"tomorrow 6:30pm"`,
  `"Thu 6pm"` — lower-case relative days, no colon or leading zero on the hour.

  Deliberately *not* `label_for/3`'s `"Thu 6:00 PM"`; `ConsensusWeb.GroupLive.Share`
  composes this into `"5 spots · closes thu 6pm"` and the compact form is what the
  reference card draws.

  It lives here rather than in the LiveView because it did live in the LiveView, as a
  private copy of `shift/2` plus two private formatters — which meant the share sheet,
  the one screen whose entire job is producing the artifact the group reads, would have
  gone on doing offset arithmetic while every other screen moved to zone rules (D-055).
  The formatting differs; the wall-clock conversion must not.
  """
  @spec compact_reading_for(DateTime.t(), DateTime.t(), Clock.t()) :: String.t()
  def compact_reading_for(at, now_utc, %Clock{} = clock) do
    local_at = to_local(at, clock)
    local_now = to_local(now_utc, clock)

    "#{compact_day_part(local_at, local_now)} #{compact_time_12h(local_at)}"
  end

  @doc """
  A short countdown string for a deadline, e.g. `"1d 04h left"`, `"12m left"`,
  `"Closing now"`.

  Purely a duration between the two instants — no zone and no clock involved, which is
  why this one function did not change when the rest of the module moved to zone rules.
  Shows the two largest non-zero units (days+hours, or hours+minutes, or minutes alone);
  anything under a minute, or already past, is `"Closing now"`.
  """
  @spec countdown(DateTime.t(), DateTime.t()) :: String.t()
  def countdown(deadline_at, now_utc) do
    diff = DateTime.diff(deadline_at, now_utc, :second)

    if diff <= 0 do
      "Closing now"
    else
      days = div(diff, 86_400)
      hours = diff |> rem(86_400) |> div(3600)
      minutes = diff |> rem(3600) |> div(60)

      cond do
        days > 0 -> "#{days}d #{pad2(hours)}h left"
        hours > 0 -> "#{hours}h #{pad2(minutes)}m left"
        minutes > 0 -> "#{minutes}m left"
        true -> "Closing now"
      end
    end
  end

  ## -- local wall-clock math (see moduledoc) --------------------------------------

  # UTC instant -> the wall clock this viewer would read off it.
  defp to_local(dt, %Clock{zone: nil, offset_minutes: offset}) do
    dt |> DateTime.add(offset * 60, :second) |> DateTime.to_naive()
  end

  defp to_local(dt, %Clock{zone: zone}) do
    dt |> DateTime.shift_zone!(zone) |> DateTime.to_naive()
  end

  # Wall clock -> UTC instant, for values this module computed itself (a snapped hour on
  # a date at most a week out). `from_wall_clock/2`'s error clause cannot fire for these:
  # the zone is already validated, and 5pm/noon are never in a DST gap in any zone whose
  # transitions happen at 00:00–03:00. Raising here rather than threading an impossible
  # error tuple through `options/2`'s three call sites keeps the chips total.
  defp to_utc!(naive, clock) do
    case from_wall_clock(naive, clock) do
      {:ok, dt} -> dt
      {:error, reason} -> raise ArgumentError, "unresolvable deadline clock: #{inspect(reason)}"
    end
  end

  # The D-031 arithmetic, unchanged: treat the reading as UTC and subtract the offset.
  defp offset_to_utc(naive, %Clock{offset_minutes: offset}) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-offset * 60, :second)
  end

  defp snap(%NaiveDateTime{} = naive, hour, minute),
    do: %{naive | hour: hour, minute: minute, second: 0, microsecond: {0, 0}}

  # Returns `{local_naive, label}` for the `:this_evening` slot — either today at 5pm
  # ("Tonight 5pm") or, once at-or-past 5pm local, the day-after-tomorrow collision
  # substitute ("<Weekday> 5pm") described in the moduledoc.
  defp compute_this_evening(local_now) do
    today_5pm = snap(local_now, @evening_hour, 0)

    if NaiveDateTime.compare(local_now, today_5pm) == :lt do
      {today_5pm, "Tonight 5pm"}
    else
      day_after_5pm = NaiveDateTime.add(today_5pm, 2 * 86_400, :second)
      {day_after_5pm, "#{weekday_abbrev(day_after_5pm)} 5pm"}
    end
  end

  defp compute_tomorrow(local_now) do
    local_now |> snap(@evening_hour, 0) |> NaiveDateTime.add(86_400, :second)
  end

  # Noon local on the next Thursday strictly after today's local date — if today itself
  # is a Thursday, that means a week out, never today (see moduledoc / PRD).
  defp compute_next_thursday(local_now) do
    today = NaiveDateTime.to_date(local_now)
    days_ahead = rem(@thursday - Date.day_of_week(today) + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    target = Date.add(today, days_ahead)

    %{local_now | year: target.year, month: target.month, day: target.day}
    |> snap(12, 0)
  end

  defp day_part(local_at, local_now) do
    at_date = NaiveDateTime.to_date(local_at)
    now_date = NaiveDateTime.to_date(local_now)

    cond do
      Date.compare(at_date, now_date) == :eq -> "Today"
      Date.compare(at_date, Date.add(now_date, 1)) == :eq -> "Tomorrow"
      true -> weekday_abbrev(local_at)
    end
  end

  # Same relative-day rule as `day_part/2`, lower-cased for the share card's sentence.
  # The weekday abbreviation stays capitalised in both — "closes Thu 6pm".
  defp compact_day_part(local_at, local_now) do
    at_date = NaiveDateTime.to_date(local_at)
    now_date = NaiveDateTime.to_date(local_now)

    cond do
      Date.compare(at_date, now_date) == :eq -> "today"
      Date.compare(at_date, Date.add(now_date, 1)) == :eq -> "tomorrow"
      true -> weekday_abbrev(local_at)
    end
  end

  defp weekday_abbrev(%NaiveDateTime{} = naive),
    do: naive |> NaiveDateTime.to_date() |> weekday_abbrev()

  defp weekday_abbrev(%Date{} = date), do: elem(@weekday_abbrevs, Date.day_of_week(date) - 1)

  defp format_time_12h(%NaiveDateTime{hour: hour, minute: minute}) do
    {display_hour, period} =
      cond do
        hour == 0 -> {12, "AM"}
        hour == 12 -> {12, "PM"}
        hour > 12 -> {hour - 12, "PM"}
        true -> {hour, "AM"}
      end

    "#{display_hour}:#{pad2(minute)} #{period}"
  end

  # "6pm", "12pm", "6:30pm" — no colon or leading zero on the hour, matching the share
  # card's reference drawing. `format_time_12h/1`'s "6:00 PM" is deliberately not reused.
  defp compact_time_12h(%NaiveDateTime{hour: hour, minute: minute}) do
    {display_hour, period} =
      cond do
        hour == 0 -> {12, "am"}
        hour == 12 -> {12, "pm"}
        hour > 12 -> {hour - 12, "pm"}
        true -> {hour, "am"}
      end

    if minute == 0 do
      "#{display_hour}#{period}"
    else
      "#{display_hour}:#{pad2(minute)}#{period}"
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
