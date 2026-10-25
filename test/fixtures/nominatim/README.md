# Recorded Nominatim responses

Real answers from `https://nominatim.openstreetmap.org/search`, captured 2026-10-25
with the exact parameters `Consensus.Discovery.Provider.Nominatim` sends
(`format=jsonv2&layer=poi&bounded=1&limit=10&addressdetails=1&extratags=1`,
viewbox = the Philadelphia bbox `-75.2803,40.1379,-74.9558,39.867`), for `q=Zahav`,
`q=Vernick` and `q=Federal Donuts`. The only edit is that each element's `licence`
string was removed.

They are recorded rather than hand-written on purpose
(docs/plans/nominatim-lookup.md §5): hand-written fixtures are how a parser
passes its tests and fails its first real page. To refresh one, re-run the same
request (with the app's User-Agent, and no faster than one per second) and keep
the edit to the `licence` field.
