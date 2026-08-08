defmodule Consensus.Deadlines do
  @moduledoc """
  Computes the three quick deadline choices shown on the `01 setup` screen
  (`ConsensusWeb.GroupLive.New`) — see `docs/design/DESIGN-SPEC.md` and
  `docs/plans/creation-flow.md`.

  Pure functions, no database. Every function takes the caller's own idea of "now" (a
  UTC `DateTime`) and, where relevant, the browser's UTC offset in minutes (positive
  east of UTC, e.g. `-300` for US Eastern in summer, `330` for India, `540` for Japan)
  so results are deterministic and testable.

  ## Why offset arithmetic instead of a time zone

  We carry no time zone database (`tzdata` is not a dependency — see
  `docs/plans/creation-flow.md`). The browser sends its UTC offset in the LiveView
  connect params instead of a zone name, and every "local" computation here is done by
  shifting a UTC `DateTime` by that many minutes, snapping the shifted (still
  UTC-tagged, but now numerically representing local wall-clock) value to the target
  hour/minute, and shifting back. The shifted intermediate value is never returned to a
  caller — only genuinely-UTC `DateTime`s leave this module.

  **Known limitation:** an offset is a fixed number, not a rule, so a DST transition
  that falls inside the window between `now` and the computed deadline shifts the
  result by an hour versus what a real zone-aware library would produce. Acceptable for
  a same-day-to-one-week deadline picker; not acceptable for anything computed further
  out.

  ## The collision rule

  `:this_evening` is "5pm local today", unless local time is already at or past 5pm, in
  which case it rolls forward to the next day at 5pm — the exact instant `:tomorrow`
  already represents. Rather than show two chips with the same timestamp, `options/2`
  detects that collision and substitutes 5pm local **the day after tomorrow** for the
  `:this_evening` slot, labelled with that day's short weekday name (e.g. `"Sat 5pm"`).
  `resolve/3` mirrors this exactly, so a click on that chip resolves to the same instant
  `options/2` displayed for it.

  Being "at or past 5pm" (not only strictly past) triggers the roll, because otherwise
  a call made at exactly 5pm would return an `:at` equal to `now` — not strictly in the
  future, which every chip is guaranteed to be.

  ## Ordering

  `options/2` always returns its three entries sorted by `:at` ascending. This is not
  always the same as the `:this_evening`, `:tomorrow`, `:next_thursday` conceptual
  order: whenever "today" is a Wednesday (or, after the roll, whenever the collision
  substitute lands mid-week), `:next_thursday` at local noon falls *before*
  `:tomorrow`/`:this_evening` at local 5pm on that same Thursday. Sorting by instant is
  what keeps the "strictly increasing" guarantee true in every case.
  """

  @typedoc "One chip: a stable key, a short human label, and the UTC instant it means."
  @type option :: %{key: atom(), label: String.t(), at: DateTime.t()}

  @evening_hour 17
  @thursday 4
  @weekday_abbrevs {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

  @doc """
  The three deadline chips for `01 setup`, computed from `now_utc` and the browser's
  `tz_offset_minutes`, sorted by `:at` ascending (see moduledoc).

  Always returns exactly three entries, each strictly in the future.
  """
  @spec options(DateTime.t(), integer()) :: [option()]
  def options(now_utc, tz_offset_minutes) when is_integer(tz_offset_minutes) do
    local_now = shift(now_utc, tz_offset_minutes)

    {this_evening_local, this_evening_label} = compute_this_evening(local_now)
    tomorrow_local = compute_tomorrow(local_now)
    next_thursday_local = compute_next_thursday(local_now)

    [
      %{
        key: :this_evening,
        label: this_evening_label,
        at: unshift(this_evening_local, tz_offset_minutes)
      },
      %{key: :tomorrow, label: "Tomorrow 5pm", at: unshift(tomorrow_local, tz_offset_minutes)},
      %{
        key: :next_thursday,
        label: "Thu noon",
        at: unshift(next_thursday_local, tz_offset_minutes)
      }
    ]
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  Resolves a single chip key to the UTC instant it means right now.

  Mirrors `options/2`'s computation for `:this_evening`, `:tomorrow` and
  `:next_thursday` exactly — including the collision substitution — so a chip clicked a
  few minutes after the page rendered resolves to a fresh, still-correct instant rather
  than whatever was true at mount. Returns `nil` for any other atom.
  """
  @spec resolve(atom(), DateTime.t(), integer()) :: DateTime.t() | nil
  def resolve(key, now_utc, tz_offset_minutes) when is_integer(tz_offset_minutes) do
    local_now = shift(now_utc, tz_offset_minutes)

    case key do
      :this_evening ->
        {local, _label} = compute_this_evening(local_now)
        unshift(local, tz_offset_minutes)

      :tomorrow ->
        local_now |> compute_tomorrow() |> unshift(tz_offset_minutes)

      :next_thursday ->
        local_now |> compute_next_thursday() |> unshift(tz_offset_minutes)

      _other ->
        nil
    end
  end

  @doc """
  A human label for an arbitrary deadline, e.g. `"Closes Thu 6:00 PM"`.

  Used for the wizard's fourth, non-canonical chip: when an already-stored
  `deadline_at` no longer matches any of today's three computed options (because time
  has moved on since it was set), the group's actual deadline still needs a label.
  `now_utc` says "today" for the purpose of preferring `"Today"`/`"Tomorrow"` over a
  weekday name when the deadline falls on one of those two local calendar days;
  otherwise the local weekday's short name is used.
  """
  @spec label_for(DateTime.t(), DateTime.t(), integer()) :: String.t()
  def label_for(at, now_utc, tz_offset_minutes) when is_integer(tz_offset_minutes) do
    local_at = shift(at, tz_offset_minutes)
    local_now = shift(now_utc, tz_offset_minutes)

    "Closes #{day_part(local_at, local_now)} #{format_time_12h(local_at)}"
  end

  @doc """
  A short countdown string for a deadline, e.g. `"1d 04h left"`, `"12m left"`,
  `"Closing now"`.

  Purely a duration between the two instants — no time zone involved. Shows the two
  largest non-zero units (days+hours, or hours+minutes, or minutes alone); anything
  under a minute, or already past, is `"Closing now"`.
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

  defp shift(dt, offset_minutes), do: DateTime.add(dt, offset_minutes * 60, :second)
  defp unshift(dt, offset_minutes), do: DateTime.add(dt, -offset_minutes * 60, :second)

  defp snap(dt, hour, minute),
    do: %{dt | hour: hour, minute: minute, second: 0, microsecond: {0, 0}}

  # Returns `{local_datetime, label}` for the `:this_evening` slot — either today at
  # 5pm ("Tonight 5pm") or, once at-or-past 5pm local, the day-after-tomorrow collision
  # substitute ("<Weekday> 5pm") described in the moduledoc.
  defp compute_this_evening(local_now) do
    today_5pm = snap(local_now, @evening_hour, 0)

    if DateTime.compare(local_now, today_5pm) == :lt do
      {today_5pm, "Tonight 5pm"}
    else
      tomorrow_5pm = DateTime.add(today_5pm, 86_400, :second)
      day_after_5pm = DateTime.add(tomorrow_5pm, 86_400, :second)
      {day_after_5pm, "#{weekday_abbrev(day_after_5pm)} 5pm"}
    end
  end

  defp compute_tomorrow(local_now) do
    local_now |> snap(@evening_hour, 0) |> DateTime.add(86_400, :second)
  end

  # Noon local on the next Thursday strictly after today's local date — if today
  # itself is a Thursday, that means a week out, never today (see moduledoc / PRD).
  defp compute_next_thursday(local_now) do
    today = DateTime.to_date(local_now)
    days_ahead = rem(@thursday - Date.day_of_week(today) + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    target = Date.add(today, days_ahead)

    %{local_now | year: target.year, month: target.month, day: target.day}
    |> snap(12, 0)
  end

  defp day_part(local_at, local_now) do
    at_date = DateTime.to_date(local_at)
    now_date = DateTime.to_date(local_now)

    cond do
      Date.compare(at_date, now_date) == :eq -> "Today"
      Date.compare(at_date, Date.add(now_date, 1)) == :eq -> "Tomorrow"
      true -> weekday_abbrev(local_at)
    end
  end

  defp weekday_abbrev(%DateTime{} = dt), do: dt |> DateTime.to_date() |> weekday_abbrev()
  defp weekday_abbrev(%Date{} = date), do: elem(@weekday_abbrevs, Date.day_of_week(date) - 1)

  defp format_time_12h(%DateTime{hour: hour, minute: minute}) do
    {display_hour, period} =
      cond do
        hour == 0 -> {12, "AM"}
        hour == 12 -> {12, "PM"}
        hour > 12 -> {hour - 12, "PM"}
        true -> {hour, "AM"}
      end

    "#{display_hour}:#{pad2(minute)} #{period}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
