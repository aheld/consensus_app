defmodule ConsensusWeb.OrganizerLabel do
  @moduledoc """
  How a guest-facing screen names the organizer (D-058, plan §5.2).

  The domain answers *what* the organizer is called —
  `Consensus.Activities.organizer_custom_name/1` returns the account's username, an
  accountless organizer's chosen display name, or `nil`. *How* to say it when there is
  no name is presentation, and it depends on where in the sentence the name falls:
  "The organizer can also close it early." but "not even the organizer". So the
  fallback is applied here, at the call site, and never earlier.

  **Pass the raw name-or-`nil` down to the place that renders it.** A component or an
  endgame card that receives an already-defaulted `"The organizer"` cannot re-case it,
  which is exactly how "Only The organizer can break it." gets printed.

  Note the three strings an unnamed organizer sends *themselves* — the `/join` og:
  description, the invite-card preview and the share text — are written without a
  subject instead ("A vote is open…"), so they do not go through this module at all.
  """

  @doc """
  Returns `name`, or "The organizer" (`:start`) / "the organizer" (`:mid`) when there
  is no name to give.

  A blank or whitespace-only name counts as no name.

      iex> ConsensusWeb.OrganizerLabel.label(nil, :start)
      "The organizer"
      iex> ConsensusWeb.OrganizerLabel.label("", :mid)
      "the organizer"
      iex> ConsensusWeb.OrganizerLabel.label("aheld", :start)
      "aheld"
  """
  @spec label(String.t() | nil, :start | :mid) :: String.t()
  def label(name, position) when position in [:start, :mid] do
    if blank?(name), do: fallback(position), else: name
  end

  defp blank?(nil), do: true
  defp blank?(name) when is_binary(name), do: String.trim(name) == ""

  defp fallback(:start), do: "The organizer"
  defp fallback(:mid), do: "the organizer"
end
