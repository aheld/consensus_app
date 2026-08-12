defmodule Consensus.Deadlines.Clock do
  @moduledoc """
  How one viewer's browser told us to read a wall clock.

  Built once per LiveView mount by `Consensus.Deadlines.clock_from_params/1` and passed
  to every `Consensus.Deadlines` function that has to turn a wall-clock reading into an
  instant, or an instant back into a wall-clock reading.

  Two fields, in strict priority order (D-055):

    * `:zone` — an IANA name (`"America/New_York"`) the compiled-in database recognises,
      or `nil`. When present it is authoritative, because a zone carries *rules* and gets
      the right answer for a date months out.
    * `:offset_minutes` — minutes east of UTC, positive east (`-300` for US Eastern in
      winter, `330` for India, `540` for Japan). The fallback, and exactly what D-031
      shipped: right for now, wrong across a DST transition.

  `%Clock{zone: nil, offset_minutes: 0}` is UTC, and is what a dead render gets. It is
  also the struct's default, so a caller that forgets to pass anything degrades to UTC
  rather than to a plausible-looking guess.

  ## Why the zone is validated at construction and never again

  `clock_from_params/1` resolves the zone name against the database once and drops it to
  `nil` if it is unknown — a stale client, a spoofed connect param, or a zone added to
  IANA after the deploy that compiled this database in. Everything downstream may
  therefore use the raising `DateTime.shift_zone!/2` without a rescue: an unknown zone
  cannot reach it. The database is static within a release, so a name that resolved at
  mount cannot stop resolving later in the same session.
  """

  @type t :: %__MODULE__{zone: String.t() | nil, offset_minutes: integer()}

  defstruct zone: nil, offset_minutes: 0
end
