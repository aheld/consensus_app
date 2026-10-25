# Plan — the accountless organizer (create, publish and share with no account)

Status: **Implemented — Stages 1–7 all landed in the working tree, uncommitted (2026-10-24;
`mix test` 1555 tests, 0 failures, up from 1256).** Where the build departed from the text
below, [§0 "As built"](#0-as-built-2026-10-24) is the shipped truth and the affected
sections were corrected in place. The 2026-10-23 revision folded in a read-only review of
the first draft against the source: five independent lenses, adversarial refutation of
every finding, and a completeness critic. Where this plan and [D-058](../decisions.md)
disagree, D-058 wins — and the two were edited together so they should not.
**What this builds.** A visitor who has never signed up can open `/groups/new`, name a
session, set a deadline, add options, publish, and walk away with a working
`/join/:slug` link — the whole organizer wizard, end to end, with no account. An
account stops being the price of organizing and becomes what it was always specified
to be: the thing that *saves* a session so it outlives one browser.

**Why.** `docs/PRD.md` § "Organizer access", requirement 1: *an organizer can create and
run a session with no more setup than a participant needs*; requirement 2: an account is
optional and *must never become a precondition for running a session*. The build
reversed that. D-058 reverses the reversal.

Read first: [CLAUDE.md](../../CLAUDE.md) product invariants 1 and 3, engineering
invariants 1 (ownership is a precondition in the function head), 2 (Seeds directly after
the migrator), 3/10 (boot-time migration, the CI boot-twice rehearsal), 5 (the
`delete_user/2` cascade), 11, 15, 16, 17 (busy writes return tuples), 18;
[docs/decisions.md](../decisions.md) **D-029**, **D-033**, **D-035**, **D-036**,
**D-041** (the chrome and its `⋯` menu), **D-045** (a dead end is a defect; why
`renew_session/2` preserves participant tokens), **D-047 §4**/**D-048** ("Start
something"), **D-050** (the social card), **D-051** (the endgame takeovers);
[docs/open-questions.md](../open-questions.md) **F-1** and **Q-4**.

**Ship as one deploy.** Every push to `main` deploys (D-057 exempts only docs). The
stages below are a build order, not a release order: between "routes open" and "claim +
04 warning exist" an organizer could create sessions with no disclosure and orphan them on
sign-up. Nothing in this plan is committed until all of Stages 1–7 pass together.

---

## 0. As built (2026-10-24)

The implementation follows the plan below except for these fifteen points. Each is the
shipped behaviour; where a later section said otherwise it has been corrected to match.

1. **A magic-link log-in claims only with consent.** `UserLive.Confirmation` renders an
   **unticked** box — "Also save the N sessions started in this browser to <email>" —
   only when the browser's identity owns at least one session, and
   `UserSessionController` passes `claim: false` to `UserAuth.log_in_user/4` (it now
   takes `opts`) unless it comes back ticked. Password log-in and the post-registration
   log-in claim automatically. *Why:* the account behind a magic link is whoever
   requested it and the URL can be forwarded, so an automatic claim would let an attacker
   mail a link for their own account and collect the victim's sessions (found by the
   adversarial review). The box is consent, not the capability — the token still comes
   from the cookie.
2. **Every settled claim outcome clears the cookie and disconnects.** `{:ok, n}` (0
   included), `{:error, :already_claimed}` and `{:error, :not_found}` all delete the
   organizer cookie and broadcast `disconnect` on the identity's topic; the
   "N session(s) saved to your account." flash appears only when `n > 0`.
   `{:error, {:database_busy, _}}` keeps the cookie and broadcasts nothing. The anonymous
   `create_group/2` and `create_group_with_organizer_name/3` heads re-read the identity
   inside their transaction and return `{:error, :claimed}` for a claimed one, and a
   re-claim by the *same* user re-runs the group move, so a group that landed on the
   identity after the first claim is moved rather than answered with a bare `{:ok, 0}`.
   *Why:* a token that will never resolve again is settled whatever the reason, and a tab
   left holding its scope would strand a new group where no resolver or claim reaches it.
3. **Stale anonymous tabs are disconnected by the process, not only the transport.**
   `OrganizerAuth`'s `:require_organizer` subscribes every connected anonymous LiveView to
   `OrganizerAuth.live_socket_id/1` (derived from the token) and attaches a `handle_info`
   hook that redirects the tab to its own route on the claim's broadcast; the session's
   `live_socket_id` is also written on the dead render of every wizard route (by
   `:fetch_organizer_token`, on every `:browser` request). *Why:* the transport's
   `live_socket_id` is read from the session cookie as it stood at connect, and another
   tab can rewrite that cookie in between.
4. **The organizer cookie slides.** `fetch_organizer_token/2` re-issues it with a fresh
   `max_age` on every `:browser` request, so 90 days means 90 days *idle*. A session copy
   of the token is trusted only when the same request carried the verified cookie; an
   absent or tampered cookie removes the session copy and its `organizer_sessions:` topic.
   *Why:* written once at mint it would expire 90 days after the first visit, stranding a
   live row's sessions; and the session cookie has no `__Host-` prefix, so a planted
   session must not outlive its cookie.
5. **A busy database while minting** on `GET /groups/new` redirects to `/` with
   "Consensus is busy — try again in a moment." instead of a 500. *Why:* invariant 17's
   shape — it is the front door of the product.
6. **Group and display name save in one transaction** via
   `Activities.create_group_with_organizer_name/3` and
   `update_group_with_organizer_name/4`, broadcasting after commit. Also added:
   `change_organizer_display_name/2` (the `as: "organizer"` form) and `count_groups/1`
   (how many sessions the confirmation box names, and whether the log-in and registration
   "check your email" states show point 12's line). *Why:* a name saved without its group,
   or a broadcast of a rolled-back write, is a half-state.
7. **`get_group!/2` with an unsaved-id scope raises `FunctionClauseError`** (the
   `is_integer` guards), not `Ecto.NoResultsError`; a foreign group still raises
   `NoResultsError`. `set_search_area/3`, `add_activity/3` and `reorder_activities/3` each
   have **one** public user/anonymous head pair, with the `:draft` check in the shared
   private body rather than in a second public pair. *Why:* fewer heads, same
   precondition-in-the-head guarantee.
8. **The migration carries `activity_groups`' `AUTOINCREMENT` sequence across the
   rebuild, up and down** (§2.2 steps 3 and 6). *Why:* surviving `feedback.page_path` rows
   name `/groups/:id/…` and `/admin/feedback` links them; a reset sequence would point
   them at an unrelated new group.
9. **`AnonymousOrganizer.display_name_changeset/2` caps more than graphemes**: 160
   codepoints, 8 codepoints per text grapheme and 12 per emoji grapheme, and it refuses
   the combining grapheme joiner and every variation selector — letting only the two
   presentation selectors (VS15/VS16) back in, inside an emoji or keycap — and tag
   characters outside the flag form (plus the invisible fillers D-058 lists).
   *Why:* one grapheme can carry unboundedly many marks, so a 40-grapheme cap alone
   bounds nothing.
10. **`:require_organizer` tells `/groups/new` from `/groups/:id/*` by `socket.view` and
    `live_action`**, because `on_mount` is handed no URI. On `/groups/new` with no
    resolvable identity it shows the cookies-needed flash only when the session never
    carried an identity; a token that went stale under an open tab redirects to
    `/groups/new` itself, whose plugs find the account or mint afresh.
11. **The attribute name `organizer_username` was kept** (it now holds nil-or-name). The
    unnamed-organizer share text, `04`'s invite-card preview, `Entry`'s pill and its
    og:description are subjectless ("A vote is open…", "You're invited") and do **not**
    go through `ConsensusWeb.OrganizerLabel`; every other §5.2 site does.
12. **The magic-link "same browser" line** shipped as: *"Open the link in this same browser
    to bring your sessions with you — you'll be asked before they're saved. If it opens
    somewhere else, nothing is lost: log in here later and they can follow."*
    (`UserLive.Login.bring_sessions_line/0`), reflecting point 1.
13. **`Consensus.Housekeeping` is the boot sweep child**, directly after `Consensus.Seeds`,
    with `skip: skip_seeds?()`; every failure is rescued and logged.
14. **The `05` "Only in this browser — save these" line sits outside the results panel**,
    so it still shows during the tie and all-vetoed takeovers, which replace the panel.
15. **Element ids added for tests**: `#home-hero`, `#home-sessions`, `#chrome-menu-start`,
    `#chrome-menu-sign-up`, `#chrome-menu-save-sessions`, `#share-save-warning`,
    `#claim-consent` and others.

---

## 1. The identity model

The app already has the pattern one layer down. A guest voter has no account;
`Consensus.Voting.Participant` carries a server-minted token written by a **controller**
(`ConsensusWeb.JoinController` exists because a LiveView cannot write a cookie) and
resolved by an `on_mount` hook (`ConsensusWeb.JoinAuth`). This is that pattern on the other
side of the link — with two deliberate differences.

**One identity per browser, not one capability per group.** A participant token is keyed
per group because one browser may join many votes as different people. An organizer is one
person with many sessions, so the browser holds a **single** organizer token resolving to
one `anonymous_organizers` row that owns zero or more groups. That is what makes "the
account is only for saving" literally true: an anonymous organizer already has a `/` list;
registering makes it durable, it does not create it.

**Stored hashed, unlike `participants.token`.** D-045 calls participant tokens "ballot
receipts, not credentials". An organizer token is a **write capability** (cancel, close
early, resolve a tie, reopen, edit a draft). The precedent is `users_tokens`:
`:crypto.strong_rand_bytes(32)` to the browser, `:crypto.hash(:sha256, token)` to the
column, lookup by digest. D-058 records the inconsistency so nobody "fixes" it.

**Carried in its own long-lived cookie, not in the Phoenix session.** The session cookie
`_consensus_key` (`lib/consensus_web/endpoint.ex:7-12`) has no `max_age`: it is a
*browser-session* cookie, dropped when the browser quits. An organizer's most important
return trip is after the deadline (a D-051 tie or all-vetoed takeover), so a token stored
there would routinely die before it mattered, and a server-side TTL would be decorative.
Setting `max_age` on the shared session cookie is wrong too — it would silently turn every
non-remember-me login into a long one.

So the token lives in a dedicated **signed** cookie, `max_age` 90 days, `http_only`,
`same_site: "Lax"`, written with `put_resp_cookie(..., sign: true)`. Its name comes from
config: **`__Host-consensus_organizer` in prod** (the `__Host-` prefix forces `Secure`,
`Path=/` and no `Domain`, so a sibling subdomain of `isourthing.com` cannot plant one) and
`_consensus_organizer` in dev/test, where there is no TLS. A plug with no database access
(`OrganizerAuth.fetch_organizer_token/2`) mirrors it into
the session key `"organizer_token"` on every `:browser` request — and re-issues it so the
90 days are an idle window (§0 point 4) — exactly as
`UserAuth.ensure_user_token/1` mirrors the remember-me cookie (`user_auth.ex:111-124`) —
LiveView reads only the session at connect. Because the cookie is outside the session,
`clear_session/1` in `renew_session/2` never touches it, and **`renew_session/2` needs no
new clause at all** (see §6.2).

**Not on `@current_scope` outside the wizard.** Today `@current_scope` is `nil` or
`%Scope{user: %User{}}` and about two dozen templates test it for truthiness as "signed
in" — including `user_live/login.ex:216/277/340`, where a truthy scope swaps the sign-up
link for "You need to reauthenticate" and makes both identity inputs `readonly`. Widening
the app-wide scope would lock an anonymous organizer out of the very log-in that saves
their sessions. So:

- `UserAuth.fetch_current_scope_for_user/2` and `:mount_current_scope` are **unchanged**:
  `@current_scope` stays user-or-nil on every `:browser` page.
- Inside `live_session :organizer` only, `OrganizerAuth` assigns `@current_scope` to the
  anonymous `%Scope{}` when no user is signed in, so the wizard has one code path.
- `HomeLive` gets a separate read-only hook that assigns `@organizer_scope`; nothing else
  in the app sees the anonymous identity.
- `Scope.authenticated?/1` (true only for `%Scope{user: %User{}}`) is still added, and the
  wizard's chrome and the three `login.ex` sites plus `confirmation.ex:103` use it
  defensively, so the predicate is right even if a future change widens the scope.

---

## 2. Data model

### 2.1 New table

```elixir
create table(:anonymous_organizers) do
  add :token_hash, :binary, null: false
  add :display_name, :string               # nullable; what a guest sees instead of a username
  add :claimed_by_user_id, references(:users, on_delete: :nilify_all)
  add :claimed_at, :utc_datetime
  add :last_seen_at, :utc_datetime, null: false

  timestamps(type: :utc_datetime)
end

create unique_index(:anonymous_organizers, [:token_hash])
create index(:anonymous_organizers, [:claimed_by_user_id])
```

*Anonymous* here means **has no account**. It is unrelated to `activity_groups.anonymous`
(voting secrecy, D-035); D-058 carries that glossary line.

- **"Claimed" is keyed on `claimed_at`, never on `claimed_by_user_id`.** The latter is
  `:nilify_all`, so deleting the claiming account would otherwise make a claimed row look
  unclaimed again. After a claim the row owns nothing; it is history.
- `display_name` lives on the person so a third session does not ask again. It is shown as
  typed and is **retroactive** across that organizer's unclaimed sessions; after a claim,
  guests see the account's username instead (§6.3). Both are accepted and recorded in D-058.
- The schema marks `token_hash` `redact: true`, and no guest-facing preload loads the
  `anonymous_organizers` row in full (§5): only `display_name` reaches the `/join` tree.
- `ecto_sqlite3` ignores `size:` on `:binary`; the 32-byte length is enforced in the
  changeset, not the column.

### 2.2 The `activity_groups` rebuild — a transactional wipe

`organizer_id` must become nullable and the ownership `CHECK` must be added. SQLite has
neither `ALTER COLUMN` nor `ADD CONSTRAINT`, and the pinned `ecto_sqlite3` *raises* on both
(it does not emulate them — F-1's copy-and-swap sentence is wrong and is corrected in the
same change). The table is therefore rebuilt.

**Existing groups are not preserved — in production too.** The owner accepted this on
2026-10-23 (D-058): every group, option, participant and vote is destroyed, and every
`/join/:slug` link already pasted into a chat starts to 404. Signed-in users, their
accounts and feedback survive.

The first draft of this plan offered `PRAGMA foreign_keys = OFF` around `DROP`/`CREATE`.
**That is broken and must not be used:** with enforcement off, `DROP TABLE` does no
implicit delete, so `activities` and `participants` rows survive pointing at group ids
that no longer exist, and because `DROP TABLE` also resets the `AUTOINCREMENT` sequence,
the next group #1 adopts them (reproduced in a scratch database during the review). And on
the boot path the migrator runs on the already-started `Consensus.Repo` with `pool_size: 1`,
so a PRAGMA left off would stay off for the life of the process and silently disable every
cascade the app relies on.

The rebuild instead runs **inside the ordinary DDL transaction, with foreign keys on,
and no `@disable_ddl_transaction`**:

1. `CREATE TABLE anonymous_organizers` (§2.1, DSL is fine).
2. `DELETE FROM activity_groups` — FKs on, so `activities` and `participants` cascade,
   `votes` cascade from both, and the circular `resolved_activity_id → activities` is
   `ON DELETE SET NULL` and causes no trouble (verified during the review). `votes` reach
   `activity_groups` only through `participants` and `activities`; they have no FK of their
   own into it.
3. Set aside the `AUTOINCREMENT` high-water mark: copy `activity_groups`' `seq` out of
   `sqlite_sequence` into a temp table (`d058_activity_groups_seq`), because `DROP TABLE`
   deletes that row.
4. `DROP TABLE activity_groups`.
5. `CREATE TABLE activity_groups` as **literal SQL**, below.
6. Put the saved `seq` back into `sqlite_sequence` and drop the temp table, so group ids
   are never reused after the wipe — a `feedback.page_path` row that survives it still
   names `/groups/:id/…`, and `/admin/feedback` renders that as a link.
7. Recreate the three existing indexes **by their existing names**, plus
   `activity_groups_anonymous_organizer_id_index`.

Because everything is one transaction, a machine killed mid-boot rolls back and the next
boot re-runs the whole migration cleanly; there is no half-built state.

The `CREATE TABLE` is the current table, column for column, with exactly three changes —
`organizer_id` loses `NOT NULL`, `anonymous_organizer_id` is added, and the named `CHECK`:

```sql
CREATE TABLE "activity_groups" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "title" TEXT NOT NULL,
  "slug" TEXT NOT NULL,
  "status" TEXT DEFAULT 'draft' NOT NULL,
  "activity_type" TEXT DEFAULT 'restaurant' NOT NULL,
  "deadline_at" TEXT,
  "anonymous" INTEGER DEFAULT true NOT NULL,
  "veto_allowed" INTEGER DEFAULT true NOT NULL,
  "expected_voter_count" INTEGER,
  "completed_at" TEXT,
  "cancelled_at" TEXT,
  "organizer_id" INTEGER CONSTRAINT "activity_groups_organizer_id_fkey"
    REFERENCES "users"("id") ON DELETE CASCADE,
  "anonymous_organizer_id" INTEGER CONSTRAINT "activity_groups_anonymous_organizer_id_fkey"
    REFERENCES "anonymous_organizers"("id") ON DELETE RESTRICT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "resolution" TEXT,
  "resolved_activity_id" INTEGER CONSTRAINT "activity_groups_resolved_activity_id_fkey"
    REFERENCES "activities"("id") ON DELETE SET NULL,
  "resolved_at" TEXT,
  "search_area" TEXT,
  "search_bbox" TEXT,
  CONSTRAINT "organizer_xor_anonymous_organizer"
    CHECK (("organizer_id" IS NULL) <> ("anonymous_organizer_id" IS NULL))
);
```

That column list is taken from `.schema activity_groups` on a freshly migrated database
(2026-10-23), not written from memory — the first draft's list named a nonexistent `name`
column and dropped six real ones. The implementer re-diffs it against `.schema` before
landing, and a release test pins it (§9).

Notes the DDL encodes on purpose:

- **Column-level `REFERENCES`, never table-level `FOREIGN KEY`.** The older downs that
  `release_test.exs` runs when it rolls the chain back
  (`20260811172739`'s `DROP COLUMN search_area/search_bbox`, `20260810164221`'s
  `DROP COLUMN resolved_activity_id`) fail on SQLite when the column sits in a table-level
  `FOREIGN KEY` or in a `CHECK`, and succeed for a column-level `REFERENCES`. The CHECK
  mentions only the two owner columns, which no older down drops.
- **`organizer_id ... ON DELETE CASCADE` is kept.** Invariant 5's
  delete-the-organizer's-groups cascade depends on it; without it the CHECK would make
  `Accounts.delete_user/2` fail instead.
- **`anonymous_organizer_id ... ON DELETE RESTRICT`.** Nothing but the boot sweep ever
  deletes an `anonymous_organizers` row, and the sweep is only allowed to delete rows that
  own nothing. RESTRICT makes a bug in its predicate raise instead of cascading through
  groups, participants and votes.
- The precedent for literal SQL with a CHECK is `create_home_page.exs` and the `down/0` of
  `drop_home_page.exs` — **not** `create_activity_groups.exs`, whose moduledoc says it used
  the DSL precisely because it needed no CHECK.

**`down/0`** must keep working: `release_test.exs` rolls the whole chain back to zero and
CI's *"Boot twice on one volume"* step and `scripts/release-upgrade-test.sh` roll the
newest migration down and up on a populated volume. F-1's "downs are not maintained" is
false in practice for exactly that reason and is amended. In order:

1. `DELETE FROM activity_groups` (FKs on; cascades).
2. Save the `sqlite_sequence` `seq` into the temp table, as in the up.
3. `DROP TABLE activity_groups`.
4. `CREATE TABLE activity_groups` with the **pre-D-058** literal DDL (`organizer_id ...
   NOT NULL`, no `anonymous_organizer_id`, no CHECK), restore the saved `seq`, and the
   three original index names.
5. Only then `DROP TABLE anonymous_organizers`.

Rows do not survive a down either. That is consistent with the up and is stated in the
migration's moduledoc.

### 2.3 The ownership rule

Exactly one of `organizer_id` / `anonymous_organizer_id` is non-null, always — the named
CHECK. A claim *moves* ownership (set `organizer_id`, null `anonymous_organizer_id`); it
never accumulates both (§12 says why).

The CHECK is a backstop for changeset paths: `Group.changeset/2` (and any changeset that
can set an owner) declares `check_constraint(:organizer_id, name:
:organizer_xor_anonymous_organizer)`. The claim's `update_all` bypasses changesets, so a
violation there raises `Exqlite.Error` — which the claim rescues (§6.3).

---

## 3. `Consensus.Activities` — two heads, no runtime branch

The moduledoc's promise — ownership is a **precondition in the function head**, so a call on
someone else's group raises `FunctionClauseError` rather than taking a branch — survives.
Collapsing ownership into a computed `owner_key(scope)` compared in the body is rejected
(§12).

### 3.1 `Scope`

```elixir
defstruct user: nil, anonymous_organizer: nil

def for_anonymous_organizer(%AnonymousOrganizer{id: id} = o) when is_integer(id),
  do: %__MODULE__{anonymous_organizer: o}
def for_anonymous_organizer(nil), do: nil

def authenticated?(%__MODULE__{user: %User{}}), do: true
def authenticated?(_), do: false
```

`for_anonymous_organizer(nil) -> nil` mirrors `for_user(nil)`. **"Mutually exclusive by
construction" is not achievable with a `defstruct`** — any code can write
`%Scope{user: u, anonymous_organizer: a}`. Exclusivity is enforced where it matters, in
the heads, and fails closed:

### 3.2 The paired heads

```elixir
def publish_group(%Scope{user: %User{id: id}, anonymous_organizer: nil},
                  %Group{organizer_id: id} = group) when is_integer(id),
  do: do_publish_group(group)

def publish_group(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{id: id}},
                  %Group{anonymous_organizer_id: id} = group) when is_integer(id),
  do: do_publish_group(group)
```

- **The other identity is pinned to `nil`** in every head, so a both-set scope matches
  *neither* head and raises, instead of the first head silently winning.
- **`when is_integer(id)`** on every head. Today `organizer_id` is `NOT NULL`, so `nil == nil`
  never met a column. After §2.3 every user-owned group has `anonymous_organizer_id: nil`
  and every anonymous-owned group has `organizer_id: nil`, so an unsaved struct
  (`%User{id: nil}`, an `%AnonymousOrganizer{}` from a failed mint) would otherwise match
  every group owned by the other kind — a cross-tenant write no "different owner" test
  catches.

There are **18 owning clauses across 15 functions** (14 public plus the private
`authorize_activity/2`), re-anchored against `lib/consensus/activities.ex` on 2026-10-23:
`list_groups/1` (99), `get_group!/2` (126), `change_group/3` (149), `create_group/2` (163),
`update_group/3` (170), `set_search_area/3` ×2 (188, 198), `publish_group/2` (211),
`cancel_group/2` (226), `complete_group/2` (242), `resolve_group/4` (339),
`rescue_group/2` (388), `reopen_group/2` (443), `add_activity/3` ×2 (531, 550),
`reorder_activities/3` ×2 (636, 666), `authorize_activity/2` (682). Each gains a sibling
(**as built**, §0 point 7: the ×2 functions — `set_search_area/3`, `add_activity/3`,
`reorder_activities/3` — ended up with *one* public user/anonymous pair each, the `:draft`
check moving into the shared private body);
`authorize_activity/2` gains a second clause and `update_activity/3`/`delete_activity/2` are
otherwise unchanged. `list_active_groups/1` and `list_past_groups/1` delegate to
`list_groups/1` and need no head of their own.

What a cross-owner call does is **per function**, because the functions already differ:

| Functions | Cross-owner behaviour (both "another anonymous owner" and "a user owner") |
|---|---|
| `change_group`, `update_group`, `set_search_area`, `publish_group`, `cancel_group`, `complete_group`, `resolve_group`, `rescue_group`, `reopen_group`, `add_activity`, `reorder_activities` (11) | raises `FunctionClauseError` |
| `get_group!/2` | filters in the query, raises `Ecto.NoResultsError` |
| `update_activity/3`, `delete_activity/2` (via `authorize_activity/2`) | `{:error, :unauthorized}` |
| `list_groups/1`, `create_group/2`, `new_group/1` | take no foreign group; each identity sees and creates only its own rows |

and, for **every** function in the table, a both-set scope raises `FunctionClauseError`
and an unsaved-id scope raises `FunctionClauseError` — `get_group!/2` included: its heads
carry the same `is_integer` guards, so an unsaved id never reaches the query (§0 point 7;
this sentence used to say `get_group!` "finds nothing").

### 3.3 Other context details

1. **`add_activity/3` and `added_by_id`.** `activities.added_by_id` is an FK to `users`.
   The user head sets it as today; the anonymous head leaves it `nil`.
   `GroupLive.Options`' `added_by_you_count/2` (`options.ex:1021-1023`, rendered at :1759)
   reads `current_scope.user.id` and crashes on step 02 for an anonymous scope; it becomes
   the count of the group's activities, since only the organizer can add options until
   co-creation exists (its own comment at :1750-1756 says so).
2. **`Activities.new_group(%Scope{})`** — two heads, returning `%Group{organizer_id: id}` or
   `%Group{anonymous_organizer_id: id}`, so `GroupLive.New` never reaches into
   `scope.user.id`.
3. **`Activities.update_organizer_display_name(%Scope{user: nil, anonymous_organizer: %AnonymousOrganizer{}}, attrs)`**
   casts only `:display_name`; trims; collapses internal whitespace; rejects control and
   bidi-format characters (the spirit of `Feedback.Entry.safe_page_path/1`); blank → `nil`;
   `validate_length(max: AnonymousOrganizer.max_display_name_length())` = 40 graphemes, its
   **own** constant (do not borrow `Participant`'s). The name is self-chosen and not unique;
   D-058 says so, and no screen presents it as verified.
4. **Owner preloads.** `get_group!/2` and `get_group_by_slug/1` preload `:organizer` and a
   *narrow* `:anonymous_organizer` (`display_name` only) so any screen holding a `%Group{}`
   has the owner's name without another query. (The first draft named a
   `get_group_with_organizer_by_slug/1` and a context `reload/1`; neither exists.)
5. **`Activities.organizer_custom_name(%Group{}) :: String.t() | nil`** — the username,
   the anonymous `display_name`, or `nil`. That is the domain's only accessor. **Casing is
   presentation**, so it lives in the web layer (§5).
6. **The token resolver, one function for every caller:**
   `Activities.get_anonymous_organizer_by_token(raw_token)` hashes, looks up, and returns
   `nil` for an unknown token, a row with `claimed_at` set, or a row whose `last_seen_at` is
   older than 90 days. On a hit it bumps `last_seen_at` **at most once per 24 hours**
   (a conditional `UPDATE ... WHERE last_seen_at < ^cutoff`, so a fresh row costs no write),
   rescuing busy errors (a failed touch never fails the request). The mint plug,
   `OrganizerAuth`, and `HomeLive`'s hook all call it, so `/`, `/join` return trips and the
   wizard agree on whether an identity is alive.
7. **`Activities.mint_anonymous_organizer/0`** → `{raw_token, %AnonymousOrganizer{}}`.

---

## 4. The web layer

### 4.1 Routes and pipelines

The seven wizard routes — `/groups/new`, `/groups/:id/edit`, `/groups/:id/options`,
`/groups/:id/options/:activity_id`, `/groups/:id/review`, `/groups/:id/share`,
`/groups/:id/results` — move out of `live_session :require_authenticated_user` (they are
*removed* there, not copied; a live_session name is declared once and a route lives in one)
into a new `live_session :organizer`:

```elixir
scope "/", ConsensusWeb do
  pipe_through [:browser]

  live_session :organizer,
    on_mount: [
      {ConsensusWeb.UserAuth, :mount_current_scope},
      {ConsensusWeb.OrganizerAuth, :require_organizer}
    ] do
    scope "/" do
      pipe_through [:ensure_organizer_identity]   # mints — /groups/new only
      live "/groups/new", GroupLive.New, :new
    end

    live "/groups/:id/edit", GroupLive.New, :edit
    # … the other five, resolve-only
  end
end
```

(If nesting a `scope` inside a `live_session` turns out not to compile on this Phoenix
version, the fallback is a plug that mints only when `conn.path_info == ["groups", "new"]`;
either way the rule is "mint on `/groups/new` only".)

`/users/settings`, `/users/settings/confirm-email/:token` and `POST
/users/update-password` stay behind `:require_authenticated_user`.

`:browser` gains one plug, `:fetch_organizer_token` (no DB access, never mints). When a
signed organizer cookie verifies it copies it into session `"organizer_token"`, re-issues
the cookie with a fresh 90-day `max_age` — so the browser-side lifetime slides with use
exactly as `last_seen_at` does, instead of expiring 90 days after the *first* visit — and,
when no user is signed in, puts `OrganizerAuth.live_socket_id(token)` in the session as
`"live_socket_id"`. The topic is `"organizer_sessions:" <> base64url(sha256(token))`,
derived from the digest the row stores rather than the row id, precisely so it can be
written on every request: a returning organizer reaches `/groups/:id/*` from a `/` card
without ever passing `/groups/new`, and that tab must be one the claim's disconnect
reaches (§6.3).

### 4.2 Minting: a plug on `GET /groups/new`, because a LiveView cannot write a cookie

`:ensure_organizer_identity`, on `/groups/new` only:

- a signed-in user (`%Scope{user: %User{}}` — pattern-match, do not call `.user` on what may
  be `nil`): do nothing;
- else a token that `get_anonymous_organizer_by_token/1` resolves: do nothing more (the
  resolver already touched it; `:fetch_organizer_token` already slid the cookie and set the
  topic);
- else mint, `put_resp_cookie` the signed cookie, `put_session("organizer_token", …)`,
  `put_session("live_socket_id", OrganizerAuth.live_socket_id(raw_token))` (§6.3), and
  **`assign(conn, :current_scope, Scope.for_anonymous_organizer(row))`** so the dead render
  sees it. (`mount_current_scope` uses `assign_new`, which copies the conn's `nil` and never
  calls its fallback; without this assign the first-ever visit crashes.)

**Why only `/groups/new`.** Minting on the whole wizard would insert a row for every
crawler or stale bookmark that probes `/groups/:id/*` — integer ids, enumerable — and then
404, on the single SQLite writer that also serves the ballot burst (invariant 17). The cost
that remains is honest: one row per drive-by visit to `/groups/new`, swept at boot (§4.6).

The rejected alternative — a redirect through `/groups/:id/claim?t=<token>` — puts a write
capability in history, `Referer` and proxy logs (§12).

### 4.3 `OrganizerAuth`, the on_mount hook

Sibling of `JoinAuth`, at `lib/consensus_web/organizer_auth.ex`. If `:mount_current_scope`
produced a user scope, it does nothing. Otherwise it resolves session `"organizer_token"`
through the shared resolver and `assign/3`s (**not** `assign_new`) `@current_scope` to the
anonymous scope. (`on_mount` is handed no URI, so the hook tells `/groups/new` from
`/groups/:id/*` by `socket.view` and `live_action` — §0 point 10. A connected anonymous
mount also subscribes to the identity's topic and redirects on the claim's broadcast —
§0 point 3.) When neither identity resolves:

- on `/groups/new` (cookie blocked, or cleared between the GET and the socket connect):
  halt to `/` with "This browser didn't keep the cookie Consensus needs to remember your
  session. Allow cookies for this site and try again." — **only when the session never
  carried an identity**; a token that went stale under an open tab (a log-out or a claim
  elsewhere) redirects to `/groups/new` itself, whose plugs find the account or mint afresh;
- on `/groups/:id/*`: halt to `/users/log-in?return_to=<path>` (validated by
  `UserAuth.store_return_to/2`) with "If this session is yours, log in to reach it." —
  restoring the log-in bounce an account holder (or an organizer who registered and then
  logged out) gets today. **Never** redirect a non-owner to `/join/:slug/results` as a
  consolation: that would turn sequential group ids into a slug-enumeration oracle.

A **signed-in** non-owner keeps today's "isn't yours" flash. That copy currently ends "Here
is everything you organize" (`share.ex:57-65`, `results.ex:113-120`); for an anonymous
scope with no groups that is false, so the anonymous variant drops the clause.

### 4.4 `HomeLive`

`/` stays in `live_session :current_user`, plus one read-only hook that assigns
`@organizer_scope` from the shared resolver (never minting). In `mount/3`, before choosing
anything else:

```elixir
groups = load groups for whichever scope is present (user scope, else organizer scope)
home_mode = if Scope.authenticated?(current_scope) or groups != [], do: :list, else: :splash
```

and **one** `@home_mode` drives page title, width, background, chrome variant, and
splash-vs-list — today those are eight separate `if @current_scope` sites
(`home_live.ex:39, 44, 92, 111, 112, 113, 115, 117`). A drive-by visit to `/groups/new`
followed by `‹` therefore still lands on the `00a` splash with `:marketing` chrome. The
per-group PubSub subscription and the minute `:tick` run for `:list` mode regardless of
identity kind.

### 4.5 Chrome, CTAs and copy that becomes false

- **The `⋯` menu gets a third state** for an anonymous organizer on the wizard (`:app`
  variant): **"Save your sessions"** → `/users/register` and **"Log in"** → `/users/log-in`;
  no "Start something" (it would link to the page you are on at step 1, and start a second
  draft mid-wizard). The signed-out menu elsewhere becomes "Log in", "Sign up"
  (→ `/users/register`, hidden on that path) and "Start something" (→ `/groups/new`, hidden
  under `/groups/*`). `Chrome.signed_in?/1` (`chrome.ex:626`) already treats a user-less
  scope as signed out and is left alone. D-041's menu table and D-047 §4 / D-048 ("Start
  something" = `/users/register` everywhere) are amended in place.
- **"Start something" CTAs go to `~p"/groups/new"` unconditionally:** `home_live.ex:172`,
  `how_it_works_live.ex:283`, `privacy_live.ex:245` (the last two are
  `if @current_scope, do: …, else: ~p"/users/register"` today; the branch is deleted).
  `AboutLive` has no such CTA and is untouched.
- **Delete, do not reword**, the two signed-out sub-lines that say "Starting one asks for an
  email, a username and a password": `how_it_works_live.ex:287-290` and
  `privacy_live.ex:249-252`.
- `/privacy`'s "If you organize" (`privacy_live.ex:136-141`) and its cookie paragraph
  (`:172-175`, "Two cookies") are rewritten: an optional name, a random token stored hashed,
  a third cookie that lasts 90 days, and the shared-browser line from §6.3.
- The five standing-screen variant sites (`about_live.ex:52`, `feedback_live.ex:457`,
  `how_it_works_live.ex:189`, `privacy_live.ex:111`, plus HomeLive) are **unaffected** by
  this design, because `@current_scope` stays user-or-nil there. A test pins that.

### 4.6 The boot sweep

`{Consensus.Housekeeping, skip: skip_seeds?()}`, a synchronous child returning `:ignore`
(like `Consensus.Seeds`), placed **after `Consensus.Seeds`** and before the caches and the
Endpoint — invariant 2 and `application_test.exs` pin Seeds directly after the migrator, so
nothing goes between them. Gated like Seeds so it never runs under `mix test` or
`mix phx.server`. One statement, rescued so a busy writer never aborts boot:

```sql
DELETE FROM anonymous_organizers
WHERE claimed_at IS NULL
  AND last_seen_at < :thirty_days_ago
  AND NOT EXISTS (SELECT 1 FROM activity_groups g
                  WHERE g.anonymous_organizer_id = anonymous_organizers.id)
```

It is housekeeping, not correctness: the machine never auto-stops (invariant 4), so it may
go months between runs, and that is acceptable. Rows that own groups are never swept; past
90 days of inactivity they simply stop resolving.

---

## 5. Call sites

### 5.1 What breaks with an anonymous owner (re-anchored 2026-10-23)

| File:line | Today | With an anonymous owner | Fix |
|---|---|---|---|
| `group_live/new.ex:40` | `%Group{organizer_id: socket.assigns.scope.user.id}` | `nil.id` — **`/groups/new` crashes on mount** | `Activities.new_group(scope)` |
| `group_live/new.ex:27-33` | snapshots `current_scope` into a second `:scope` assign | goes stale when the display name is updated | drop `:scope`; read `@current_scope` everywhere |
| `group_live/new.ex:528` | `<Layouts.avatar user={@current_scope.user}>` | renders `"?"` (catch-all in `layouts.ex:226-229`), ignoring a typed name | feed it the name (§7.3) |
| `group_live/options.ex:1022` (rendered :1759) | `added_by_id == current_scope.user.id` | `nil.id` — **step 02 crashes** (missed by the first draft) | count of the group's activities (§3.3) |
| `group_live/share.ex:49` | `current_scope.user.username` | `nil.username` — **04 crashes after publish** | `organizer_custom_name/1` |
| `group_live/results.ex:420` | `organizer_username={@current_scope.user.username}` | `nil.username` | `organizer_custom_name/1` |
| `join_live/entry.ex:108` | `Accounts.get_user!(group.organizer_id)` | `Repo.get!(User, nil)` → **`ArgumentError`** — the guest's entry screen 500s | owner preload |
| `join_live/results.ex:107` | same | same — guest results 500s | owner preload |

(The first draft's `home_live.ex:256 is_admin` row does not exist; HomeLive's real hazard
is the truthiness rewrite in §4.4 and `list_groups/1`'s single head.)

### 5.2 Every place the organizer is named to a guest

The domain returns a name or `nil`. A web-layer helper, `ConsensusWeb.OrganizerLabel.label(name, :start | :mid)`,
renders `"The organizer"` / `"the organizer"` when it is `nil`. Components and endgame cards
keep an `organizer_name` attr that is **nil-or-name**; each site chooses `:start` or `:mid`,
and nothing ever passes an already-defaulted string (or `tie.ex` prints "Only The organizer
can…"). `results_components.ex`'s existing `picker_name(nil) -> "The organizer"` is the
precedent and moves onto the helper.

| Site | Text | Position |
|---|---|---|
| `join_live/entry.ex:138` | og:description "X set up a vote." | start — **unnamed: subjectless** ("A vote is open…") |
| `join_live/entry.ex:319-321` | pill "X invited you" + initial (`organizer_initial/1` :200-204 already → `?`) | start — **unnamed: "You're invited"** with `?` |
| `join_live/entry.ex:448` | "Nobody sees what you picked — not even X" | mid |
| `join_live/results.ex:120` | og:description "X called this vote on Consensus" | start |
| `join_live/results.ex:186` | flash "X reopened the option pool" | start |
| `join_live/results.ex:431` | "X can also close it early." | start |
| `join_live/results.ex:477, 507, 523` | "not even for X" | mid |
| `join_live/results.ex:502` | "X closed it while you were on this page" | start |
| `join_live/results.ex:534` | "X called it off" | start |
| `group_live/share.ex:162` | invite-card preview "X set up a vote. Tap to pick." | start — **unnamed: subjectless** |
| `group_live/share.ex:198` | `data-share-text`, the string pasted into the chat | start — **unnamed: subjectless** (the organizer sends it from their own phone) |
| `results_components.ex:553-555` (`tie_note`) | "X picked Y to break the tie" | start |
| `results_components.ex:618-619` (`tie_break_tail`, paste-back summary) | same | start |
| `endgame/tie.ex:265` | "Only X can break it." | mid |
| `endgame/tie.ex:452` | "Only X can break this tie … flips on its own" | mid — see §7.5 |
| `endgame/all_vetoed.ex:234` | "Only X can fix this" | mid — see §7.5 |

As built (§0 point 11): the four subjectless rows — `Entry`'s og:description and pill,
`04`'s invite-card preview and `data-share-text` — do not go through `OrganizerLabel`; they
are written without a subject when the name is `nil`. The attribute carrying the name kept
its old spelling, `organizer_username`, and now holds nil-or-name.

No possessive is rendered anywhere (`entry.ex:429`, `results.ex:416/424` are comments).
This table is the test matrix: one assertion per site, named and unnamed.

D-050: the og: block must still render for an anonymous-owned group — the card is the one
artifact the link-share model depends on.

---

## 6. The claim — turning an anonymous organizer into an account

### 6.1 Where it hooks

Every log-in funnels through `UserAuth.log_in_user/4` (it was `/3`; it gained an `opts`
keyword, `claim:` defaulting to `true`) — password, magic link
(`_action=confirmed`) and post-registration (`_action=registered`, which `UserLive.Registration`
reaches by posting to `/users/log-in`). One hook there covers all three. The claim runs
automatically on every password and registration log-in (D-058); a shared-browser
inheritance is never silent because a non-zero outcome is flashed (§6.3).

**A magic-link log-in claims only with explicit consent.** The account behind a magic
link is whoever *requested* it, and the URL can be forwarded: an attacker who mails a
link for their own account to someone organizing without one would otherwise collect the
victim's sessions (login CSRF). So `UserLive.Confirmation` shows an **unticked** "Also
save the N sessions started in this browser to <email>" box whenever the browser's
identity owns a session, and `UserSessionController` passes `claim: false` to
`log_in_user/4` unless it comes back ticked. The box is consent, not the capability —
the token is still read from the cookie. Unticked, the cookie stays and a later log-in
from this browser claims.

### 6.2 `renew_session/2` is not touched

Because the token is its own cookie (§1), `clear_session/1` never sees it. `log_in_user/4`
reads the signed organizer cookie **before** `renew_session/2` (as it already reads
`:user_return_to` at `user_auth.ex:40`), runs the claim after, and on a definitive outcome
calls `delete_resp_cookie`. D-045's participant-key exception stays exactly as narrow as
D-045 wrote it — "for guest ballot receipts specifically, not a general keep-useful-things
rule" — and no organizer write capability is carried through the fixation defence.

Log-out (`renew_session(conn, nil)`) does nothing to the organizer cookie. It can only
still be present if a claim failed transiently (below), and then keeping it is what lets
the next log-in retry.

### 6.3 Semantics

```elixir
Activities.claim_anonymous_groups(%User{} = user, raw_token) ::
  {:ok, non_neg_integer()}            # groups moved (0 for an idempotent re-claim by the same user)
  | {:error, :already_claimed}        # claimed by a different user
  | {:error, :not_found}              # unknown or expired token
  | {:error, {:database_busy, String.t()}}
```

The one write in `Activities` authorized by possession of a secret rather than a
head-matched scope, so its `@doc` says the token comes only from the conn in
`UserAuth.log_in_user/4`, never a client parameter. In one transaction:

1. **Compare-and-swap, the house idiom** (cf. `cast_ballot/3`'s `WHERE voted_at IS NULL`):
   `UPDATE anonymous_organizers SET claimed_by_user_id = ?, claimed_at = ? WHERE id = ? AND claimed_at IS NULL`.
   Exactly one row changed → step 2. Zero → re-read: claimed by this user → `{:ok, 0}`;
   by another → `{:error, :already_claimed}`.
2. `UPDATE activity_groups SET organizer_id = ?, anonymous_organizer_id = NULL WHERE anonymous_organizer_id = ?`.
3. Rescue `Exqlite.Error` and `DBConnection.ConnectionError` into
   `{:error, {:database_busy, msg}}`, logged at `:warning` (invariant 17's shape).

Production's `default_transaction_mode: :immediate` also serializes two concurrent claims;
the CAS makes correctness not depend on it.

In `log_in_user/4`: the user is logged in **regardless** of the result — failing a log-in
over a housekeeping write is the worse outcome (an unexpected raise or exit from the claim
is caught there and treated as busy). With `claim: false` none of the below runs and the
cookie is left untouched.

- `{:ok, n}` with `n > 0`: delete the cookie; flash "N session(s) saved to your account",
  composed with whatever `:info` the controller already sets (e.g. the magic-link
  "password removed" sentence).
- `{:ok, 0}`, `{:error, :already_claimed}`, `{:error, :not_found}`: delete the cookie, no
  flash.
- `{:error, {:database_busy, _}}`: **keep** the cookie, so the next log-in retries.

After every settled claim — `{:ok, n}` **including `{:ok, 0}`** (the normal state of an
identity still on step 1), `:already_claimed` and `:not_found`; never after busy — `ConsensusWeb.Endpoint.broadcast(OrganizerAuth.live_socket_id(raw_token),
"disconnect", %{})` — the claim holds the raw token from the cookie, and
`:fetch_organizer_token` put that same topic in every anonymous session — so a tab still
mounted with the anonymous scope reconnects, re-runs `OrganizerAuth`, finds no identity and
is bounced to log-in. Without it, that tab's head-matched writes would keep working on
groups that now belong to the account (the stale-scope problem invariant 1 documents for
`set_admin/3`) — or, on a zero-group claim, create a group on the claimed identity, where
no resolver and no later claim would ever reach it. The broadcast is the prompt half; the
guarantee is that the anonymous `create_group/2` and `create_group_with_organizer_name/3`
heads re-read the identity inside their transaction and refuse a claimed one with
`{:error, :claimed}` (`GroupLive.New` redirects to `/groups/new`, where the plugs find
the account). A re-claim by the claiming user also re-runs step 2, so anything that did
land on the identity afterwards is moved rather than answered with a bare `{:ok, 0}`.

Edge cases, decided here:

1. **Already claimed by someone else** (shared browser): refuse silently, log in normally.
2. **Logging in on a browser holding someone else's unclaimed token:** the account inherits
   those sessions, and the flash says so. D-058 accepts this explicitly — it is not "not a
   new hole": it turns "write access while sitting at that browser" into the account's
   permanent ownership. The alternative (a confirm step on plain log-in) was considered and
   deferred. `/privacy` gets one line about it.
3. **Partial failure:** one transaction; atomic or nothing.
4. **What guests see changes.** After the claim the group is user-owned, so guest screens
   show the account's username instead of the anonymous `display_name`; text already pasted
   into a chat keeps the old name. Accepted and recorded (D-058).

### 6.4 The log-out consequence

The claim moves ownership, so after logging out those sessions are not reachable from that
browser without signing back in. The log-out control is a stateless `⋯` item
(`chrome.ex:486-493`) that already spends its one `data-confirm` on the draft prompt, so the
line is delivered where the database is: `UserSessionController.delete/2` runs one
`Activities.owns_any_group?(user)` query (only at log-out, never per render) and, when true,
flashes "Logged out. Your sessions stay with your account — log back in to reach them."
That flash plus the log-in bounce in §4.3 is the whole recovery path.

---

## 7. The UX this obliges

### 7.1 `04 share`: the warning and the save prompt

Rendered **only when the group is anonymous-owned**, directly above the Copy link row
(`share.ex` flashes "Link copied" there, so it must sit by the control, not only in the
header). The words — D-058 obliges them — say what is actually lost after publish (the pool
is frozen, invariant 16, so not "edit" or "publish"):

> Without an account, this session can only be managed from this browser. If you clear
> your browser data or switch devices, you won't be able to close it early, call it off or
> break a tie. Everyone can still vote and see results at the link.

Two doors, never a gate: **"Create an account"** → `/users/register`, and **"Already have
one? Log in"** → `/users/log-in?return_to=/groups/:id/share` (`login.ex` already honours it;
`registration.ex` has no `return_to`, so registering lands on `/`, where the session list
now shows the saved session).

A one-line quiet version ("Only in this browser — save these") sits on the `00` list for an
anonymous organizer and on `05` results — on `05` **outside** the results panel, so it
still shows while a tie or all-vetoed takeover replaces the panel (§0 point 14).

### 7.2 `/` lists an anonymous organizer's sessions once they have one

See §4.4.

### 7.3 "Your name" on `01 setup`

For anonymous organizers only (absent for a signed-in organizer):

- In the "Group" row beside the avatar (`new.ex:526-529`), replacing its static avatar
  with one that updates from the typed name and shows `?` when blank.
- Hand-built like `JoinLive.Entry`'s name field (`entry.ex` ~470, counter :497-507), in its
  **own form namespace** (`as: "organizer"`) with its own changeset — `GroupLive.New`'s form
  is a `Group` changeset and its `validate` handler matches `%{"group" => _}`.
- **Optional.** Blank means "The organizer". Requiring it would reintroduce the asymmetry
  D-058 removes (product invariant 1).
- Invariant 11: **no `maxlength`**, a live `String.length` counter against
  `AnonymousOrganizer.max_display_name_length/0`, tangerine when over, the changeset is the
  cap. Invariant 18: ≥16px.
- Helper copy saying where the name goes: "Shown to guests as who invited them, on the
  invite page and in the link preview. Leave it blank to show 'The organizer'."
- Prefilled from the stored name for a returning anonymous organizer. `draft?/1` and
  `discard_prompt/0` (`new.ex` ~380-385) compare and mention the name too, so a typed name
  arms `back_confirm`/`footer_confirm`.
- Saved in the same transaction as the group by
  `Activities.create_group_with_organizer_name/3` / `update_group_with_organizer_name/4`,
  which broadcast after commit (§0 point 6); the form is built by
  `change_organizer_display_name/2`. The changeset also caps codepoints (§0 point 9).

### 7.4 The magic link opened somewhere else

When the browser holds an organizer token with at least one group, the registration and
log-in "check your email" states add (as shipped, `UserLive.Login.bring_sessions_line/0`):
*"Open the link in this same browser to bring your sessions with you — you'll be asked
before they're saved. If it opens somewhere else, nothing is lost: log in here later and
they can follow."* (Opened in this browser, the confirmation screen then asks — §6.1's
consent box — before it claims anything.) It is
conditioned on **browser** state, not on the address, so it does not break the log-in
screen's byte-identical known/unknown-address pin (`login.ex:43-46`); the code comment says
so, so nobody "fixes" it. Nothing is lost in that case — the claim is deferred to the next
log-in from the original browser — and `open-questions.md` records the webview case.

### 7.5 A tie or all-vetoed session whose organizer lost the cookie

It never resolves: only the organizer can exit a D-051 takeover, and nobody can reach it.
Accepted (D-058) rather than auto-resolved. What changes is the copy: for an
anonymous-owned group, the guest waiting lines in `tie.ex:447-453` and `all_vetoed.ex:228-235`
stop promising the page "flips on its own the moment they do" and say plainly that the
organizer has to come back to settle it; §7.1's warning covers the case; and
`open-questions.md` gets an entry. (Branching on whether the owner is anonymous is a column
check, not a branch on `activity_type` — invariant 12 is untouched.)

### 7.6 Nothing changes for the voter

Product invariant 1 is untouched.

---

## 8. Failure modes

| Failure | Behaviour |
|---|---|
| Browser data cleared / different device, before claiming | Sessions unreachable for management, forever. `/join/:slug` works for everyone. The `04` warning discloses it. |
| Browser quit | **Nothing lost** — the organizer cookie has its own 90-day `max_age` (§1). |
| Two tabs, one browser | One identity; both resolve to the same scope. |
| A tab still open when another tab claims | Disconnected by the `organizer_sessions:<token digest>` broadcast; reconnects, finds no identity, is bounced to log-in (§6.3). |
| In-app webview with its own cookie jar | A new identity; a session created there may be unreachable from the real browser. A magic link opened there defers the claim (§7.4). Recorded in `open-questions.md` (Q-4's organizer twin). |
| Shared/kiosk browser | The next visitor inherits the identity, bounded by the 90-day expiry; logging in claims it, with a flash. Accepted in D-058. |
| Planted organizer cookie | `__Host-` in prod stops a sibling subdomain from setting it; physical access remains, bounded as above. |
| Cookies blocked | `/groups/new` halts to `/` with a "cookies needed" flash (§4.3). |
| Cookie cleared between the GET and the socket connect | Same as cookies blocked. |
| Tie / all-vetoed with an unreachable organizer | Never resolves; honest copy (§7.5). |
| Abusive content in an anonymous session | No admin lever exists (§11). Recorded in `open-questions.md`. |
| Busy writer during a claim | Logged in anyway; cookie kept; next log-in retries. |
| Busy writer during the `last_seen_at` touch or the sweep | Rescued; the request or boot proceeds. |
| `%Scope{}` with both fields set, or an unsaved id | Matches no head; `FunctionClauseError` (§3.2). |

---

## 9. Verification

Everything below is `mix test` (partitioned) plus the release scripts and one live browser
pass. Suite before Stage 1: 1256 tests (CLAUDE.md, 2026-08-12); with Stages 1–7 landed:
**1555 tests, 0 failures** (2026-10-24, partitioned).

**The router source pin** (Stage 2, landed red): `test/consensus_web/organizing_needs_no_account_test.exs`
reads `lib/consensus_web/router.ex` and asserts that **none of the seven wizard routes**
sits in a scope piping through `:require_authenticated_user`, in the idiom of
`test/consensus/activity_type_invariant_test.exs`. It must fail first, for that reason.
Mutation check after Stage 4: move one wizard route back and watch it fail.

**Migration (Stage 1):**

- `release_test.exs`: the newest-migration rollback test is rewritten. After `up`,
  `pragma_table_info('activity_groups')` equals the old column set plus
  `anonymous_organizer_id`, `organizer_id` has `notnull = 0`, the CHECK exists by name,
  `pragma_foreign_key_list` matches §2.2's actions, `pragma_index_list` has the four names.
  After rolling the newest back: `anonymous_organizers` absent, `organizer_id` `notnull = 1`,
  **`search_area` and the resolution columns present** (the old assertion at :83 refutes
  `search_area` and fails as soon as a newer migration exists). The chain-to-zero tests stay
  as the proof that the older downs still run.
- A **populated-database** release test: migrate a `TmpRepo` to `20260811172739`, insert raw
  rows on the old schema (user, group, activities, participant, votes, a
  `resolved_activity_id`), run the new migration, assert all four tables are empty,
  `PRAGMA foreign_key_check` is empty and `PRAGMA foreign_keys` is 1; then insert an
  anonymous-owned group and a user-owned group through the context on the migrated repo, and
  assert a both-owners and a no-owner insert are refused by the CHECK.
- `scripts/release-upgrade-test.sh` and the matching CI step: after the rollback and before
  the second boot, insert a group + activity on the old schema; after the boot, assert they
  are gone, `foreign_key_check` is empty and `PRAGMA foreign_keys` is 1 on the live repo.
  This is the only thing that runs the new migration on the pool-1 boot path.

**Context (Stage 3)** — written from §3, not from the implementation:

- per function, §3.2's table: own group succeeds; another anonymous owner and a user owner
  get the listed outcome (`FunctionClauseError` for the 11); a both-set scope and an
  unsaved-id scope raise for all of them. **The raise is the assertion**; a returned error
  tuple from one of the 11 means a head became a branch. Mutation check: collapse one head
  pair into an `if` and watch it fail.
- `Scope`: `for_anonymous_organizer(nil)`, the `is_integer` guard, `authenticated?/1`.
- resolver: unknown, claimed, 90-day-expired → `nil`; touch writes at most once per 24h.
- display name: trim, whitespace collapse, control/bidi rejection, 40-grapheme cap, blank → nil.
- claim: happy path; idempotent re-claim `{:ok, 0}`; `{:error, :already_claimed}`; CAS under
  two concurrent claims; a forced `Exqlite.Error` → `{:error, {:database_busy, _}}`.
- sweep: an old zero-group row is deleted; an old row owning a voted group survives; a
  claimed row survives; RESTRICT makes a direct delete of an owning row raise.

**Web (Stages 4–6):**

- the first-ever cookieless `GET /groups/new` renders step 1 without crashing, sets the
  signed cookie with `max_age`, and the prod name has the `__Host-` prefix;
- a stranger on `/groups/:id/*` gets the log-in bounce and **no row is minted**;
- every §5.1 row and every §5.2 site renders for an anonymous-owned group, named and
  unnamed; `Entry`'s og: block is intact;
- drive-by `/groups/new` → `‹` → `/` shows the `00a` splash and `:marketing` chrome
  (assert the real selectors — verify `#home-hero` exists before relying on it);
- with an organizer token present, `/users/log-in`, `/users/register` and
  `/users/log-in/:token` render editable fields, the sign-up link and the remember-me
  choice, and the standing pages keep `:marketing` chrome;
- chrome: the anonymous `⋯` state, route by route, in `chrome_test.exs`'s component half and
  route-by-route half;
- claim end to end: create anonymously → register → the group is in `list_groups/1`, the
  organizer cookie is deleted, the flash names the count; a forced busy claim logs in and
  keeps the cookie; a still-mounted anonymous LiveView is disconnected;
- log-out flash when the account owns a group;
- `application_test.exs`: the sweep child is after Seeds and before the Endpoint, and its
  `skip:` follows `skip_seeds?/0` in both `RELEASE_NAME` states.

**Existing tests this inverts** (rewrite, do not delete the intent):
`test/consensus_web/live/group_live/new_test.exs:343-348` (signed-out → log-in),
`journey_test.exs:67-69` (journey starts at "Start something" → `/users/register` — keep
it as the signed-up journey and add an **anonymous journey** sibling),
`home_live_test.exs:17`, `how_it_works_live_test.exs:66, 74, 199`,
`components/chrome_test.exs:197, 272` (and the route rows at :929-941, :1000-1018),
`test/consensus/release_test.exs:83`.

**Test support** (Stage 3/4): `anonymous_organizer_fixture/1` → `{raw_token, row}`,
`anonymous_scope_fixture/0`, `ConnCase.put_organizer_token(conn, raw_token)` (writes the
signed cookie), and a `:create_anonymous_organizer` setup mirroring
`register_and_log_in_user/1`.

**Live pass** on `consensus-dev` with cookies cleared, two browser contexts: create,
publish, copy the link, vote from the second context, watch the tally land in the
organizer's open tab over PubSub, quit and reopen the first browser and confirm the session
is still reachable, then register and confirm it is in the account.

---

## 10. Stages (build order; ships as one deploy)

| Stage | Contents | Gate |
|---|---|---|
| **0** | D-058, PRD deviation note, open-questions entries. | — |
| **1** | Migration (§2.2), `AnonymousOrganizer` schema, `Group` fields + `check_constraint`, release tests, upgrade-script and CI step edits. | release tests green incl. the populated-database one. |
| **2** | Router source pin, landed red. | Fails, for the right reason (quoted). |
| **3** | `Scope`, the paired heads, `new_group/1`, display name, `organizer_custom_name/1`, resolver, mint, claim, sweep function, fixtures. | Context tests green; mutation check fails a collapsed head. |
| **4** | `:fetch_organizer_token`, `:ensure_organizer_identity`, `OrganizerAuth`, `live_session :organizer`, HomeLive hook + `@home_mode`, chrome third state, `OrganizerLabel`, §5 call sites, "Your name". | Stage 2's pin green; mutation check fails a moved route. |
| **5** | Claim hook in `log_in_user/4`, disconnect broadcast, flash. | Create anonymously → register → still there. |
| **6** | `04` warning + doors, quiet `00`/`05` lines, log-out flash, sweep child, CTAs, deleted sub-lines, magic-link line, §7.5 copy. | The live pass. |
| **7** | Doc sweep (below). | The working agreement. |

**Stage 7's list** (from the review's doc-consistency pass; grep again before finishing):
README.md (intro, the `/`, `/how-it-works`, `/privacy` route rows, the journey
description, the Activities head-match paragraph, test count); CLAUDE.md (intro, invariant
1's Activities paragraph, invariant 5's cascade paragraph — add `anonymous_organizers` and
RESTRICT, product invariant 1's "accounts are for organizers", repo layout:
`organizer_auth.ex`, `housekeeping.ex`, the migration, the table; test counts; the
`D-001 through D-05x` range); docs/PRD.md (the deviation block — mark it resolved; the
"organizer signs up" line); docs/plans/creation-flow.md (00 "signed in"); docs/design/DESIGN-SPEC.md
("signed out it goes to /users/register"); `.claude/skills/phoenix/SKILL.md` (the wizard
"lives inside `:require_authenticated_user`"), `elixir/SKILL.md`, `sqlite/SKILL.md`;
docs/sqlite-capacity-review.md; code copy and moduledocs in `privacy_live.ex`,
`how_it_works_live.ex`, `home_live.ex`, `chrome.ex`, `router.ex` comments, `activities.ex`,
`group.ex`, `scope.ex`, `user_auth.ex` (the `:mount_current_scope` doc stays true — say
why), `join_auth.ex`, `results.ex:408-412`, `results_components.ex:129-137`.
**decisions.md entries amended in place:** D-027 (the two faces of `/`), D-029 (the boot
sweep is housekeeping, not a scheduler), D-041 (variant/menu table, the `/how-it-works`
CTA bullet), D-045 (note that the organizer token deliberately does **not** use the
participant-key exception), D-047 §4 and D-048 ("Start something"), D-050 (the card's
organizer name). F-1 in open-questions.md is amended in the Stage 0 change.

---

## 11. Out of scope

- **Letting a guest voter become an organizer in one tap from `/join`.** The "Create your
  own →" pill stays; it already reaches `/groups/new` in two taps via `/`.
- **Email notification of results** (Q-7).
- **Admin visibility and takedown of anonymous sessions.** No admin screen lists
  `anonymous_organizers`, and today's only moderation lever, `Accounts.delete_user/2`, has
  nothing to act on for an anonymous session. This is a real gap, accepted for now and
  recorded in `open-questions.md`; a function-head-guarded `admin_cancel_group/2` with an
  `audit/4` line is the shape it should take when it is built.
- **Merging two anonymous identities** into one account.
- **A confirm step before claiming on a plain log-in** (§6.3 edge case 2) — deferred.
- **Auto-resolving an orphaned tie / all-vetoed** (§7.5) — deferred.
- Everything already Post-MVP: saved friend groups, venue blacklists, history.

---

## 12. Alternatives rejected

**Shadow `users` rows.** Every anonymous organizer gets a real `users` row with a synthetic
email/username. Smallest diff — no rebuild, no CHECK, all 18 clauses unchanged — but it pays
in the authentication domain: drive-by visits mint fake addresses into uniquely indexed
`NOT NULL` columns, `/admin/users` fills with non-people, and `count_admins()`,
`delete_user/2` and the magic-link flows all start needing to mean "real account" somewhere
unwritten.

**Keeping both owner columns after a claim.** Avoids the log-out consequence, at the price
of a second live write capability on every claimed session held by a cookie the user cannot
see or revoke.

**A capability URL to hand over the token** (`/groups/:id/claim?t=…`). Rejected on leakage
— history, `Referer`, proxy logs — not effort.

**A computed `owner_key/1` compared in the body.** Half the lines of §3, and one inverted
comparison away from a cross-tenant write the suite cannot see.

**The token in the Phoenix session.** The first draft's design. The session cookie dies when
the browser quits, which made the 90-day TTL decorative, and it forced a `renew_session/2`
special case that widened D-045's deliberately narrow exception to a write capability.

**An app-wide non-nil `@current_scope` for anonymous organizers.** The first draft's design.
It changes the meaning of every `if @current_scope` in the app — most damagingly on
`/users/log-in`, where it made the identity fields read-only for exactly the person trying
to save their sessions.

**Preserving existing groups through a 12-step copy-and-swap.** Needs foreign keys off
outside a transaction on the pool-1 boot connection, idempotent statements to survive a
mid-boot kill, and a manual snapshot the pipeline cannot enforce — for data the owner
decided not to keep (D-058).
