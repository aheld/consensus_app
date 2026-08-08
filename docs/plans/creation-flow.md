# Plan — the organizer's creation flow (design 1a + 1b)

Status: **in progress.** Owner: this build. Scope: everything an organizer does before anyone
votes. Voting, ranking, results and the recipient's view are explicitly **not** in this plan.

Relevant decisions: D-003 (stack), D-004/D-005/D-015/D-017 (auth and magic-link recovery),
D-011 (admin authorization), D-021 (sudo mode on admin writes). Nothing here contradicts them.
The product invariants in `CLAUDE.md` — especially **2, the engine is activity-agnostic** and
**4, results are real-time** — bind this work.

## What we are building

| Design frame | Route | Module |
|---|---|---|
| `00a` splash (signed out) | `/` | `ConsensusWeb.HomeLive` |
| `00` home (signed in) | `/` | `ConsensusWeb.HomeLive` |
| `01` setup | `/groups/new`, `/groups/:id/edit` | `ConsensusWeb.GroupLive.New` |
| `02` add options | `/groups/:id/options` | `ConsensusWeb.GroupLive.Options` |
| `02b` edit an option | `/groups/:id/options/:activity_id` | `ConsensusWeb.GroupLive.Options` (`:edit_activity`) |
| `03` review pool | `/groups/:id/review` | `ConsensusWeb.GroupLive.Review` |
| `04` share | `/groups/:id/share` | `ConsensusWeb.GroupLive.Share` |
| desktop console | `/` at a wide viewport | `ConsensusWeb.HomeLive` |

Visual truth is `docs/design/DESIGN-SPEC.md` plus the per-screen reference files it lists.

## Contracts

### `Consensus.Activities` — shipped

Scope-first, exactly like `Consensus.Accounts`. Authorization is a precondition in the
function head; `update_activity/3` and `delete_activity/2` instead re-read the owning group
from the database, because an `%Activity{}` carries only `group_id` and a preloaded `:group`
could be stale.

```elixir
subscribe_group(group_id)

list_groups(%Scope{})            # newest first, activities preloaded
list_active_groups(%Scope{})     # status in [:draft, :voting]
list_past_groups(%Scope{})       # status in [:completed, :cancelled]

get_group!(%Scope{}, id)         # raises unless the scope's user organizes it
get_group_by_slug(slug)          # unscoped, for the public /join link; nil when missing

change_group(%Scope{}, %Group{}, attrs \\ %{})
create_group(%Scope{}, attrs)
update_group(%Scope{}, %Group{}, attrs)

publish_group(%Scope{}, %Group{})   # :draft -> :voting
#   {:error, :no_activities} | {:error, :no_deadline} | {:error, :not_draft}
cancel_group(%Scope{}, %Group{})    # {:error, :already_finished}
complete_group(%Scope{}, %Group{})  # {:error, :already_finished}
maybe_complete_group(%Group{})      # returns a %Group{}; completes it if past deadline

add_activity(%Scope{}, %Group{}, attrs)
update_activity(%Scope{}, %Activity{}, attrs)
delete_activity(%Scope{}, %Activity{})     # renumbers the remaining positions
reorder_activities(%Scope{}, %Group{}, ordered_ids)
count_activities(%Group{} | group_id)
```

`%Group{}`: `title`, `slug`, `status` (`:draft | :voting | :completed | :cancelled`),
`activity_type`, `deadline_at`, `anonymous`, `veto_allowed`, `expected_voter_count`,
`completed_at`, `cancelled_at`, `organizer_id`, `activities`.

`%Activity{}`: `group_id`, `position`, `name`, `description` (≤140), `image_url`,
`source_url`, `metadata_fetched_at`, `added_by_id`.

`Group.status_changeset/2` is the only way to move `status` — the organizer-facing
`changeset/2` cannot smuggle a lifecycle transition, the same shape as `User.admin_changeset/2`.

### `Consensus.LinkPreview`

```elixir
fetch(url) :: {:ok, %Consensus.LinkPreview{
                 url:, title:, description:, image_url:, site_name:, fetched_at:}}
            | {:error, :invalid_url | :blocked_host | :not_html | :fetch_failed | {:http, status}}
```

Cached, SSRF-guarded, never raises. **Call it from a `start_async`, never inline in a
`handle_event`** — it makes a network request and a LiveView must stay responsive. The
paste field shows a pending state while it runs.

### `ConsensusWeb.Sticker`

The design primitives: `sticker_card/1`, `chip/1`, `pill/1`, `eyebrow/1`, `step_progress/1`,
`position_badge/1`, `photo_frame/1`. **Read `lib/consensus_web/components/sticker.ex` before
writing HEEx** — that file is the contract, this list is only an index.

### `Consensus.Deadlines`

The three chips on `01` are computed, not stored strings:
`5pm this evening` · `5pm tomorrow` · `next Thursday at noon`. "This evening" means the next
occurrence — after 5pm it rolls to tomorrow. A custom picker is deliberately deferred; the
design's dashed `Custom…` chip renders disabled.

Named time zones need a tz database we do not carry, so the browser sends its UTC offset in
the LiveView connect params (`tz_offset`, minutes east of UTC) and the chips are computed by
offset arithmetic on UTC. An unconnected mount falls back to UTC — a first paint may be an
hour off in a `phx-no-connect` render, which is acceptable and self-corrects on connect.

## Decisions this plan makes

1. **`/` is one route with two faces.** Signed out renders `00a`; signed in renders `00`.
   A bookmark must not 404 after logging out, and the design treats them as one place.
2. **No global navigation bar.** Each screen draws its own header, because the design's
   headers differ per screen. `Layouts.app/1` is canvas, column and flash only.
3. **A group is created as a `:draft` on step 1** and edited in place through steps 2 and 3.
   That is what makes "never re-enter anything" true: leaving the browser mid-wizard and
   coming back lands on the same draft with its options intact. The home screen lists drafts
   under `ACTIVE`, tagged `DRAFT`.
4. **Images are URL-referenced only.** No upload, no storage, no image proxy. A dead URL
   degrades to the striped placeholder.
5. **Publishing happens on `03`,** at "Get the share link" — that is the moment the group
   stops being a draft and the share link starts working.
6. **Cancel and complete are organizer actions on an active group,** reachable from the group's
   own screens. Automatic completion is lazy: `maybe_complete_group/1` runs on read paths.
   No scheduler, no GenServer — a deadline that passes while nobody is looking is completed
   the next time anyone looks, which is indistinguishable to a user and cannot drift.

## Out of scope, on purpose

Ranked-choice tallying, the swipe deck and sticker-grid voting alternatives, place discovery
and any Places/Yelp call, saved friend groups, venue blacklists, movie and travel modules,
the QR code image, and the recipient's join screen. `CLAUDE.md`'s scope discipline section is
the authority; none of these may grow a code path this pass.
