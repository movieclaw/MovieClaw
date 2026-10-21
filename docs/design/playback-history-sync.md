# Plugin-facing watch history exchange

An administrator-authorized plugin needs to export local watched movies/episodes, and import dated watches for a selected member. Existing playback marks target the caller and do not accept historical dates; offline playback ingestion also creates playback sessions/events. These two operations provide a bounded catalog and an idempotent history import without pretending imported facts were played on this server.

No Trakt code, new port, daemon or automatic synchronization is added to MovieClaw. The caller owns scans, previews, user confirmation, pagination, checkpoints and retry pacing. A companion example is [movieclaw-trakt](https://github.com/o1xhack/movieclaw-trakt).

## Authorization

Both operations require `require_admin`. Member 0 denotes the administrator. Other IDs must be active members. Results and writes are limited to the intersection of the actor's and target member's browsable libraries, with both content-rating constraints applied. Inventory must be `in_place`. This does not enable member self-service or change an administrator's login identity.

Plugins declare and request installation approval for each operation separately:

```toml
[permissions]
operations = ["playback.sync.catalog", "playback.sync.import"]
```

Use `HOST_OPS` with the same `permissions=(...)` on the plugin entry point. Declaring a read operation does not grant import. The import operation is marked `x-cli-dangerous: confirm`.

## `playback.sync.catalog` — `GET /api/v1/playback/sync/catalog`

Parameters: `member_id=0`, optional opaque `cursor`, `limit=50` (1–100). Returns `{items, next_cursor}`. Continue until `next_cursor` is null, including a page with no visible items but a non-null cursor. Keyset order is media ID, season, episode; duplicate files/versions do not duplicate units. Catalog inventory is not a transactionally frozen snapshot; callers should recheck state before writing and restart a preview if needed.

Each item contains media identity/title, season/episode (movies use 0/0), played, position_ms, updated_at, last_played_at and `watches`. Watches have a stable source `id`, `watched_at` and `basis`:

- `playback`: completed viewings using the existing playback-statistics completion and resume-segment grouping rules. Rewatches remain separate; raw `PlaybackLog.completed` is not treated as a rewatch count.
- `import`: dated external facts from this API, deduplicated against native facts at the same time.
- `state`: a played state with no completed viewing fact. Uses stored last_played_at, or updated_at for a legacy state without it. This is a state-derived timestamp, not evidence of every past manual click or rewatch.

The API does not invent missing historical watches. Existing manual marks may retain an earlier timestamp; this patch does not rewrite that legacy behavior. No season-completed watch is invented. Season grouping belongs to the caller's preview UI.

## `playback.sync.import` — `POST /api/v1/playback/sync/import`

Body: `{member_id, records}` with 1–100 records. Each record supplies media_item_id, kind, a matching tmdb_id or imdb_id, season/episode, stable source_id, timezone-aware watched_at and required expected_updated_at. Use null only when catalog had no PlaybackState row. Reject naive/future dates and unexpected fields.

The source namespace comes from the authenticated plugin's entry ID (`plugin:<entry_id>`), never from request data. Non-plugin administrators use `api`. Uniqueness is `(member_id, source, source_id)`. The source ID must identify one immutable watch, e.g. remote account plus remote history record ID. Repeating the same fact returns `already`; changing the unit/time under that key returns `mismatch`.

Outcomes correspond to input order: `applied`, `already`, `conflict`, `not_found`, `mismatch`, with `state_version` for successful outcomes. New facts and state updates are committed together. Compare-and-set protects the preview version. Multiple records for the same unit in one request share its original expected version. For later requests, use the last successful outcome's state_version. On retry, `already` returns the original receipt's version, rather than the latest user version; a lost response cannot grant permission to overwrite subsequent user activity.

Successful new records set played=true, retain the original watch date, and keep the latest last_played_at. They preserve position, favorites, tracks and an existing play_count (at least 1 for a played state). Actual playback counts/durations are not fabricated from imported watches. The separate WatchRecord table preserves imported rewatches; they are exported through catalog, not inserted into PlaybackLog or playback-duration statistics. No playback or mark event is emitted, avoiding sync loops.

Imports do not create media, files, seasons or episodes, and do not unwatch or delete remote/local history. A rejected row does not stop valid siblings; clients must report every non-success outcome and must not claim the full batch succeeded. There is no cross-system transaction with a third-party API.

## Verification

`tests/api/test_playback_sync.py` exercises real HTTP + SQLite migrations, permission separation through actual HostOps, member and library isolation, episode keyset paging, dated rewatches, exact replay receipts and stale previews. `movieclaw-trakt/tests/test_history_integration.py` mounts the real plugin with the host gateway and real administrator cookie; only Trakt HTTP is mocked.
