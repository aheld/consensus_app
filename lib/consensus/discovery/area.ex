defmodule Consensus.Discovery.Area do
  @moduledoc """
  A geocoded search area: a human-facing `:name` and a `:bbox` of
  `{min_lat, min_lon, max_lat, max_lon}`.

  Produced by `Consensus.Discovery.Geocoder.geocode/1` and stored on the group as
  the two strings `Consensus.Activities.Group` already carries: `search_area`
  (the name) and `search_bbox` (the bbox, encoded by `encode_bbox/1` as
  `"min_lat,min_lon,max_lat,max_lon"` — the format that schema documents).
  `decode/2` is the way back from those columns to a struct.
  """

  @enforce_keys [:name, :bbox]
  defstruct [:name, :bbox]

  @type bbox :: {number(), number(), number(), number()}
  @type t :: %__MODULE__{name: String.t(), bbox: bbox()}

  @doc """
  Encodes the bbox as the `"min_lat,min_lon,max_lat,max_lon"` string
  `Group.search_bbox` stores.
  """
  @spec encode_bbox(t()) :: String.t()
  def encode_bbox(%__MODULE__{bbox: {min_lat, min_lon, max_lat, max_lon}}) do
    Enum.map_join([min_lat, min_lon, max_lat, max_lon], ",", &coord_to_string/1)
  end

  @doc """
  Rebuilds an `%Area{}` from a group's stored `search_area` / `search_bbox` pair.

  Returns `{:error, :invalid_bbox}` for anything that is not four comma-separated
  numbers — including `nil`, so a group that never answered the area prompt can be
  fed straight in.
  """
  @spec decode(String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, :invalid_bbox}
  def decode(name, bbox_string) when is_binary(name) and is_binary(bbox_string) do
    with [_, _, _, _] = parts <- String.split(bbox_string, ","),
         [min_lat, min_lon, max_lat, max_lon] <- parse_coords(parts) do
      {:ok, %__MODULE__{name: name, bbox: {min_lat, min_lon, max_lat, max_lon}}}
    else
      _ -> {:error, :invalid_bbox}
    end
  end

  def decode(_name, _bbox_string), do: {:error, :invalid_bbox}

  defp parse_coords(parts) do
    coords =
      for part <- parts,
          {value, ""} <- [Float.parse(String.trim(part))],
          do: value

    if length(coords) == 4, do: coords, else: :error
  end

  defp coord_to_string(value) when is_float(value), do: Float.to_string(value)
  defp coord_to_string(value) when is_integer(value), do: Integer.to_string(value)
end
