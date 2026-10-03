# ADR 0009: Read-only here.now Sites in the Notes list

- Status: accepted for issue #30 implementation
- Date: 2026-10-03
- Issue: #30

## Verified API contract

The current [here.now list documentation](https://here.now/docs#list) and [OpenAPI description](https://here.now/openapi.json) describe `GET /api/v1/publishes?scope=all`: Bearer authentication, cursor pagination, at most 100 rows per page, and personal, accepted shared, and joined workspace Sites in one response. Rows include `slug`, `siteUrl`, `displayName`, `ownership`, `workspace`, `primaryUrl`, `status`, `currentVersionId`, and `contentUpdatedAt`. The default list omits shared and workspace Sites. `GET /api/v1/accounts` supplies stable account IDs and workspace selectors. `GET /api/v1/publishes/search?q=...&includeShared=1` searches active Sites and returns `nextCursor`, but content indexing excludes PDF text, Office documents, images, audio, and other formats. It includes a shared Site only after the recipient has opened and verified it. The list, therefore, is the inventory source; search results cannot determine which Sites exist.

These statements were checked against the public docs on 2026-10-03. No authenticated live account response was available; a real account smoke test remains before release.

## Behavior

1. Offer an independent here.now connection. Store its API key in a distinct Keychain service, never the Simplenote service. A Simplenote sign-out or account switch does not reassign Sites to another identity. Clearing the here.now connection removes its key and cached metadata.
2. List personal, accepted shared, and joined workspace Sites using `scope=all`. Show each as a read-only row alongside Notes, with a Site icon and ownership or workspace label. Prefer `displayName`, then `slug`, for the title. Use `primaryUrl` for opening and retain `siteUrl` as the canonical address. The cache key is `(here.now account identity, ownership/workspace identity, slug)`, never a Note ID. Site rows never enter `NVNotesStore`, `NoteObject`, or Simplenote sync.
3. An explicit Open command or Return on a selected Site opens its URL in a browser. Suppress editing, trash, tagging, export-as-Note, and all Note-only commands while it is selected. Do not fetch or cache Site contents. A browser URL may still require a visitor password or member sign-in; an API key does not grant browser access.
4. Refresh on connection and explicit Refresh, and on app activation after a reasonable age threshold. Follow every cursor before replacing the visible snapshot. Preserve the last complete snapshot on transport failure, 401, 403, 429, or partial pagination; mark it stale and show an actionable status. A successful empty inventory replaces the snapshot. Do not treat a failed refresh as evidence that Sites were deleted. Cache metadata per here.now identity for offline list visibility; opening a Site still needs network access.
5. Search Notes locally as today. Filter cached Site title, slug, workspace name, and URL locally so results remain predictable offline. A separate opt-in content search could call the here.now search endpoint, with debounce, cancellation, cursor handling, and an explicit partial-index label. Do not silently mix incomplete remote full-text results into the local Notes search.

## Chosen defaults

- Include personal, accepted shared, and joined workspace Sites with `scope=all`.
- Open the system browser only from an explicit Open command or Return on a Site row.
- Search cached Site metadata locally; do not imply complete content search.
- Keep the last complete snapshot marked stale on refresh failure until disconnect, reconnect, or a complete successful refresh.

`NVHereNowSites` owns read-only requests and a separate JSON metadata cache. Its API key lives in a dedicated Keychain service. `NVHereNowMixedList` combines Site rows with visible Notes without inserting a Site into `NVNotesStore` or Simplenote sync. The Notes menu supplies connection, disconnection, refresh, and explicit Open commands. The isolated earlier prototype (`tools/here-now-read-prototype.swift`) remains as design history.

## Validation limits

Fake-adapter tests cover cursor pagination, atomic replacement, authentication failure, URL preference, identity, metadata filtering, and Note command gating. An authenticated account smoke test and manual UI checks for both list layouts, keyboard and context-menu commands, offline display, and browser access to restricted Sites remain before release.
