# Simplenote sync for nvALT: state of the API (researched 2026-09-30)

Scope: Can this nvALT fork sync with Simplenote in 2026, and how should it? Every claim is cited to a primary source (official docs, first-party source code pinned to a commit, or official forum staff replies). Real API keys are never reproduced here. Where a public repo embeds one, this doc names the file only.

## Bottom line

- **Simperium is still the backend.** It is live and the protocol is the documented one. Official clients in 2026 still talk to `api.simperium.com` and `wss://api.simperium.com/sock/1/...` with app ID `chalk-bump-f49` [1][2][19][25]. Unauthenticated probes on 2026-09-30 got live responses: 401 on the index, and `missing api key` on `/authorize/` [39].
- **You cannot get an API key.** Simperium signups are closed ("Registration is Closed") [3]. Simplenote staff explicitly refused a key to a user asking for one for an **nvALT fork** (May 2023): "we do not provide a Simplenote API key to our users … There isn't an API key that will work only with your account" [6]. Simplenote says it is "not supporting additional third-party Simplenote applications" [4].
- **You don't need one for data access.** The API key only gates `auth.simperium.com` (password login) [1]. Data endpoints only need `X-Simperium-Token` [1]. Official clients now get that token from a **key-less email-code ("magic link") flow** on `app.simplenote.com`: `POST /account/request-login`, then `POST /account/complete-login`, which returns `sync_token` [9][15]. Automattic's own `simplenote-mcp` (2026) uses exactly this to read and write notes via the Simperium HTTP API with no API key [18][19].
- **The realistic path:** replace password login with the email-code flow. Store the token in Keychain. Keep using Simperium HTTP or move to the WebSocket protocol. Build a proper ghost/outbox replica (see design below).
- **Biggest risk: policy.** Simplenote Help says "Third-party Simplenote clients can be blocked from signing in for security reasons" [5]. Staff say third-party sync is not officially supported [7]. `simplenote-mcp` notes that tokens "appear to be scoped by `request_source`" and that a custom value yields a rejected token. So a third-party client would have to send an official client's `request_source` (`macOS`/`electron`) [18][9]. That is UNVERIFIED server behaviour, and it is a ToS grey zone.
- **Technical risk: merge correctness.** Simperium resolves concurrent string edits with diff-match-patch on the server (HTTP) or the client (WebSocket) [1][22]. nvALT's current code tracks only a version number and does no three-way merge [38]. A maintained ObjC diff-match-patch exists inside `Simperium/simperium-ios` (release 1.9.2, 2026-09-24). Google's upstream repo is archived [27][34].
- **The password path still works for apps that have a key.** nvpy, sncli and simplenote.vim still use `auth.simperium.com/…/authorize/` with keys embedded in their own sources [29][31][33]. Staff say password login remains available [7]. Reusing those keys is not authorized for nvALT (see Q2).

## Q1. Current Simplenote sync API

**Backend and app ID.** `chalk-bump-f49` is the Simperium app ID of production Simplenote. It is hard-coded as `DEFAULT_APP_ID` in Automattic's `simplenote-mcp`, with `history-analyst-dad` as the testing app [19]. It also appears in the Electron web deploy script [11]. The dev app `history-analyst-dad` and its key are committed in `simplenote-electron/config.json` and `simplenote-macos/Simplenote/SPCredentials.template.swift` [10][16]. Production credentials are encrypted (`resources/secrets/config.json.enc`; `.configure-files/SPCredentials.swift.enc`, decrypted to `~/.configure/simplenote-macos/secrets`) [10][16]. The Electron README says local development "is currently not supported if you don't have an existing account on the test server or access to the production credentials" [10]. Electron's web deploy writes `"app_key": "12345"` for `chalk-bump-f49` [11]. This suggests the web app never needs a real Simperium key, because it logs in via `app.simplenote.com` (an inference).

**Auth (two paths).**
1. *Password (needs API key):* `POST https://auth.simperium.com/1/{app_id}/authorize/` with header `X-Simperium-API-Key` and body `{"username","password"}`. It returns `{username, access_token, userid}` [1]. node-simperium's `Auth.authorize` and simperium-ios `authenticateWithAppID:APIKey:` implement this [21][25]. Electron still offers it [9]. The probe without a key returns 400 `missing api key`. With a bogus key it returns 401 `invalid app credentials` [39].
2. *Email code (no API key):* `POST https://app.simplenote.com/account/request-login` with `{"username", "request_source"}`, then `POST /account/complete-login` with `{"username","auth_code"}`. The response has `sync_token`, which is used as the Simperium token [9][15][18]. Electron sends `request_source: 'electron'` [9]. `simplenote-mcp` sends `'macOS'` and reports 429 rate limiting and ~10-minute IP lockouts after repeated failures. It also reports no observed token expiry; treat 401 as "re-login" [18][20].

**HTTP REST** (`https://api.simperium.com/1/{app_id}/{bucket}/…`, header `X-Simperium-Token`) [1]:
- `GET index?limit=&mark=&since=&data=1` returns `{index:[{id,v,d?}], current, mark?}`. `mark` is the next-page cursor. `current` is the bucket cv [1].
- `GET i/{id}[/v/{n}]` returns the object, with the version in the `X-Simperium-Version` header [1].
- `POST i/{id}[/v/{n}]?clientid=&ccid=&response=1&replace=` creates or modifies an object. Posting against an older `/v/{n}` makes the server **transform** concurrent string edits (doc example: `"bc"` and `"bd"` from v1 merge to `"bcd"`, v3) [1]. Codes: 200; 400; 401; 404 (version doesn't exist); 412 (empty change) [1]. The doc says omitted fields are kept unless `replace=1` [1]. `simplenote-mcp`'s comment says a partial POST wipes fields, so it always posts the full object [19]. That contradiction is UNVERIFIED; post full objects.
- `DELETE i/{id}[/v/{n}]` removes the object permanently [1].
- `GET /all?cv=` is admin-only [1]. The **per-user changes feed** `GET {bucket}/changes?clientid=&cv=` (long-poll) and bulk `POST {bucket}/changes` (array of `c`-style change objects) are not on the HTTP doc page. They are implemented in Simperium's own `simperium-python` [28], and nvALT already calls `GET /Note/changes?cv=&wait=0` [38].

**WebSocket** (`wss://api.simperium.com/sock/1/{app_id}/websocket`; messages are prefixed with a channel number) [2]:
- `init:{clientid, api:"1.1", token, app_id, name:<bucket>, library, version}` → `auth:<email>` or `auth:{"msg","code":401}` [2].
- `i:<data>:<offset>:<mark>:<limit>` → `i:{current,index,mark?}` [2].
- `e:<id>.<v>` → entity, or `?` if not found [2].
- `cv:<cv>` → `c:[…]`, or `cv:?` meaning the client must re-index because "the server starts aggregating older change versions" [2].
- `c:[…]` sends or receives changes [2].
- `h:<n>` heartbeats after 20 s idle [2].
- The server may send `index` (asking for client state) and `log` [2].

The production web/Electron and Apple clients use this protocol via node-simperium [12] and simperium-ios [25].

**Buckets.** Electron syncs `note`, `tag`, `preferences`, `account` [12]. Tag objects are keyed by a normalized, URL-encoded, lowercased tag hash [14]. nvALT uses `Note` (capitalized) [38]; the official clients use `note` [12][19]. Whether bucket names are case-insensitive is UNVERIFIED.

**Rate limits / ToS.** No numeric API rate limits are published. The Simperium ToS bans "excessive calls" and "shar[ing] or misus[ing] your access credentials", and allows termination [8]. Login endpoints are rate-limited (observed) [18]. I did not find a Simplenote ToS clause specifically about third-party clients. The relevant official statements are [4], [5], [6], [7].

## Q2. Third-party clients

| Client | Auth | Key source | Transport | Status |
|---|---|---|---|---|
| simplenote.py (`simplenote-vim/simplenote.py`, formerly mrtazz) | password → `auth.simperium.com` | base64-obfuscated key in `simplenote/simplenote.py` L40–44, comment "please be kind and don't (ab)use it. Simplenote/Simperium didn't have to provide us with this." [29] | HTTP: `note/index?limit=1000[&since][&mark]`, `i/{id}/v/{v}?response=1`, DELETE [29] | last commit 2019-06 [29]. Key was obtained by emailing Simperium in 2014 [30] |
| nvpy | via `simplenote>=2.1.4` (shares simplenote.py's key) [32] | same | same | active (2026-08 commits). #243 (2025-09/10): auth timeouts and 502 on `auth.simperium.com` [32] |
| sncli | password via `simperium.core.Auth` | its **own** key, "Application token provided for sncli", in `simplenote_cli/simplenote.py` (different from simplenote.py's) [31] | HTTP via simperium-python; index with `data=True, mark, limit=100` [31] | last release 2025-06 [31] |
| simplenote.vim | via git submodule simplenote.py @74da92f [33] | same as simplenote.py | same | active (2026-04) [33] |
| snote (2026, TS) | email code, or `--password` | — | node-simperium WebSocket [36] | new |
| NoteIt (2026, Swift) | password | embeds a hex key in `SimperiumClient.swift` [37] | HTTP | new |

None documents its key as usable by other projects. Staff told an nvALT-fork user no per-user key exists [6]. **Do not borrow these keys.** No 2025–26 reports show the shared keys being revoked. The nvpy failures in #243 look like service outages, not key rejection [32].

## Q3. Data model and change format

**Note object** (`note` bucket): `content` string; `tags` string[]; `deleted` bool or 0/1 (trash); `systemTags` ⊂ {`markdown`,`pinned`,`published`,`shared`}; `creationDate`/`modificationDate` as Unix seconds (float); optional `shareURL`, `publishURL` [13][19]. Writers should preserve fields they don't model [19].

**Versions.** Each object has an integer `v` (the `X-Simperium-Version` header or `ev` in changes) [1][2]. The bucket has an opaque string `cv` (index `current`) [2]. `ccid` is a client-generated UUID per change, used for idempotent resubmits and acknowledgement matching (`ccids` array in server echoes) [1][2][22].

**Change message**: `{clientid, id, o, v, ev, sv?, cv, ccids, d?}`. `o` is `"M"` (modify) or `"-"` (remove) [2]. For `M`, `v` is a jsondiff object diff `{field: {o, v}}`. The ops [24]:
- `+` add
- `-` remove
- `r` replace (numbers, booleans, type changes, and arrays when list-diff is off)
- `I` integer add
- `L` list diff
- `O` nested object diff
- `d` string delta, i.e. diff-match-patch `diff_toDelta`, applied by `diff_fromDelta` + `patch_make` + `patch_apply` (fuzzy)

node-simperium configures `list_diff: false`, so arrays like `tags` are sent as whole-value `r` [24].

**Errors and conflicts** [2]:
- **405** bad `sv`: reload, or resend with full `d`.
- **409** duplicate ccid: treat as acknowledged and fetch changes.
- **412** empty change: ignore.
- **413** too large.
- **440** invalid diff, e.g. "client is sending string diffs and using a different encoding than server": resend with full `d`.
- **404**: object missing; resend as a full create.

node-simperium's handling: 405/440 queue a `full` change, 409/412 acknowledge, anything else is emitted as an error [22]. On HTTP, a stale `/v/{n}` is merged server-side, and a missing version is 404 [1]. Index page size is client-chosen. Observed values are 10 with data (node-simperium) [22], 100 (sncli, nvALT) [31][38], and 1000 (simplenote.py) [29]. The server maximum is UNVERIFIED (the docs themselves ask "is there a default on the server side?") [2].

## Q4. How the official sync engines work

**node-simperium (Electron/web)** [22][23]:
- *Ghost store per bucket:* `{key, version, data}` per object, plus the bucket `cv`. Electron persists it in Redux (`ReduxGhost`) [12].
- *Start-up:* on `auth`, if a stored cv exists it starts the local queue and sends `cv:`. Otherwise it pauses the queue and re-indexes (`i:1:<mark>::10`), saving the final `current` as cv when the last page lands. `cv:?` clears cv and re-indexes [22].
- *Outbound:* each local edit is diffed against the ghost: `buildChange` → `{o:'M', ccid, v: object_diff(ghost.data, new), sv: ghost.version}`. Empty diffs are dropped. Each object has its own queue with **at most one in-flight change** (`sent[id]`). Later edits coalesce until the ack arrives. Unacked changes are resent after reconnect [22][23].
- *Inbound:* a per-object serial queue does the following [22]:
  1. If the ghost version ≠ `sv`, fetch `e:id.sv` first.
  2. Apply the patch to the ghost.
  3. If the `ccid` matches the in-flight change, it is an ack: save the ghost.
  4. Otherwise rebase: compute `diff(ghost_old, local)` and `transform(local_mods, remote_patch, ghost_old)`, save the new ghost, apply the transformed local mods on top, and re-queue them as a new change.
  
  `-` removes the ghost and emits `remove`. Electron maps that to `REMOTE_NOTE_DELETE_FOREVER` [12].
- *Trash vs delete:* Trash is `deleted: true` via a normal modify (`TRASH_NOTE`). "Delete forever" is `bucket.remove` → `o:'-'` [12].

**simperium-ios (macOS/iOS)** follows the same model [26]. Each Core Data object carries `ghost`/`ghostData` and a version. An incoming change whose `ev` equals the ghost version is a dupe and is skipped. If `sv` matches, the diff is applied to the ghost. If the local object changed meanwhile, the diff is transformed (`[bucket.differ transform:…]`) before it is applied to the object. A mismatch triggers re-fetch or `ClientOutOfSync` [26]. It is ObjC, MIT-licensed, actively maintained, and ships `Simperium-OSX.podspec` (macOS 10.13+) and an SPM binary xcframework [27]. It is tightly coupled to Core Data (`initWithModel:context:coordinator:`; `SPCoreDataStorage`) [25][27]. It also has `authenticateWithAppID:token:`, "with no UI interaction required" [25].

**Diff-match-patch for ObjC.** `google/diff-match-patch` (with an `objectivec/` port) is **archived**; its last commit was 2019 [34]. `JanX2/google-diff-match-patch-Objective-C` was last pushed 2023-12 [35]. The most-maintained copy is `simperium-ios/External/diffmatchpatch` (Apache-2.0, non-ARC, built with `-fno-objc-arc`), plus `DiffMatchPatch+Simperium` [27]. Both NSString and JS use UTF-16 code units for `diff_toDelta` lengths. That matches the server; the Python port's code-point counting is the known 440 trigger [2].

## Recommended sync design for nvALT

1. **Auth.** Replace `SimperiumConfig.h` and password login with the email-code flow: an email field, then "enter code", then `sync_token` in Keychain [9][18]. On 401, clear the token and prompt again. Do not ship or borrow an API key [6]. Rate-limit login attempts [18]. Decide deliberately which `request_source` to send; see risks [18].
2. **Per-note sync record** (extend `syncServicesMD`):
   - `key`
   - `version` (ghost v)
   - **`ghost`**: the full last-server JSON, including unknown fields
   - `dirty`
   - `pendingCCID`
   - `pendingSentAt`

   Also persist a per-account **`cv`** [2][22].
3. **First sync / re-index.** Page `note/index?data=1&limit=100&mark=` [1]. Store each `{id, v, d}` as ghost and as note. Save `current` as cv only after the last page; restart if `current` moves mid-scan (nvALT already does this) [38]. Match pre-existing local notes by title/content before creating duplicates.
4. **Incremental pull.** Poll `note/changes?cv=` (HTTP) [28][38], or use WebSocket `cv:` [2]. For each change, in cv order:
   - If `ccid` is ours, it is an ack: set ghost = applied data and v = `ev`.
   - If ghost.v ≠ `sv`, `GET i/{id}` and treat that as the new remote.
   - Otherwise, a three-way merge: `content` gets diff-match-patch of `diff(ghost→local)` rebased onto remote (patch_apply). `tags` get a set merge (ghost/local/remote). Scalars: remote wins unless locally changed.
   - Save cv. A cv error, or `cv:?` on WebSocket, triggers a full re-index [2][22].
5. **Outbox push** (one in flight per note) [22]:
   - Over HTTP: `POST note/i/{id}/v/{ghost.v}?ccid=…&response=1` with the **full** merged object [1][19]. The server merges strings against that base and returns the result plus `X-Simperium-Version`. Adopt the result as both note and ghost.
   - Reuse the same ccid on retry [1].
   - 412 means clean. 404 on `/v/` means re-GET and re-merge. 413 means mark an error and keep the note dirty (nvALT already does this) [1][38].
   - Over WebSocket: send `c:` with a jsondiff against the ghost and handle 405/409/412/440 per [2].
6. **Deletions.** An nvALT delete becomes `deleted: true` (Simplenote trash), which nvALT already does [38]. Remote `deleted: true` should move the note to a local trash state, not delete the file. Only remote `o:"-"` / 404 on an index-listed key should remove locally [2][12]. Never send `DELETE` unless the user explicitly empties the trash.
7. **Fields.** Map nvALT labels ↔ `tags`. Preserve `systemTags` (`markdown`, `pinned`, `published`, `shared`), `shareURL`, `publishURL` from the ghost [13][19]. Optionally upsert `tag` bucket entries keyed by tag hash for new tags [14].
8. **Pieces to build in ObjC:**
   - diff-match-patch: vendor simperium-ios's copy [27].
   - A small jsondiff port (object diff/apply/transform). Only needed for WebSocket; HTTP full-object POST can lean on the server merge [1].
   - A persistent ghost store and outbox.
   - WebSocket client: optional (`NSURLSessionWebSocketTask`).

   Alternative: embed Simperium-OSX directly. It is less code but forces Core Data as the note store, which conflicts with nvALT's own database [25][27].

## Open questions / unverified

- Whether `request_source` scopes tokens, and whether non-official values are rejected. This comes only from a code comment in `simplenote-mcp` [18]. It decides whether nvALT must claim to be `macOS`.
- Whether Simplenote actively blocks third-party sign-ins, and on what signals [5].
- Bucket-name case sensitivity (`Note` vs `note`) [12][38].
- HTTP POST without `replace=1`: does it merge or replace fields? The docs and `simplenote-mcp` disagree [1][19].
- How long HTTP `/v/{n}` stays available for server-side merges, and when `/changes?cv=` stops accepting an old cv. The WebSocket doc only says older cvs are aggregated [2]. node-simperium's comment cites 60 revisions plus a 100-snapshot archive by default [22].
- Maximum index `limit` [2].
- Token lifetime: "no expiry observed" [20].
- Whether the shared simplenote.py and sncli keys still authenticate in 2026. Not tested; deliberately not used.

## Sources

1. Simperium HTTP API reference — https://simperium.com/docs/reference/http/
2. Simperium WebSocket API — https://simperium.com/docs/websocket/
3. Simperium sign-up ("Registration is Closed") — https://simperium.com/signup/
4. Simplenote Developers page — https://simplenote.com/developers/
5. Simplenote Help (sign-in troubleshooting) — https://simplenote.com/help/
6. Simplenote forum, "API Key request" (staff replies, May 2023) — https://forums.simplenote.com/forums/topic/api-key-request/
7. Simplenote forum, "Sync to 3rd party app is broken" (staff replies 2024-09 to 2025-01) — https://forums.simplenote.com/forums/topic/sync-to-3rd-party-app-is-broken-why-did-you-do-this/
8. Simperium Terms of Service — https://simperium.com/tos/
9. simplenote-electron `boot-without-auth.tsx` L40, L80–120, L122–190 — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/lib/boot-without-auth.tsx#L122-L190
10. simplenote-electron `README.md` L9–14 and `config.json` (dev app key lives here) — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/README.md#L9-L14
11. simplenote-electron `bin/deploy.sh` L46 — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/bin/deploy.sh#L46
12. simplenote-electron `lib/state/simperium/middleware.ts` L40–107, L370–386; `functions/redux-ghost.ts` — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/lib/state/simperium/middleware.ts#L78-L107
13. simplenote-electron `lib/types.ts` L16–27 — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/lib/types.ts#L16-L27
14. simplenote-electron `lib/utils/tag-hash.ts` — https://github.com/Automattic/simplenote-electron/blob/43b6e01028b02e47a786108a2d36d2323b6340b6/lib/utils/tag-hash.ts
15. simplenote-macos `SimplenoteConstants.swift` L25–39 — https://github.com/Automattic/simplenote-macos/blob/4e9b1aef2f618c67726a8b80a10a0ee25e958834/Simplenote/SimplenoteConstants.swift#L25-L39
16. simplenote-macos `SPCredentials.template.swift` L20–23 (dev key lives here), `Scripts/Build-Phases/copy-secret.sh` L1–23 — https://github.com/Automattic/simplenote-macos/blob/4e9b1aef2f618c67726a8b80a10a0ee25e958834/Simplenote/SPCredentials.template.swift#L20-L23
17. simplenote-macos `SimplenoteAppDelegate.m` L104 — https://github.com/Automattic/simplenote-macos/blob/4e9b1aef2f618c67726a8b80a10a0ee25e958834/Simplenote/SimplenoteAppDelegate.m#L104
18. Automattic/simplenote-mcp `src/providers/auth.ts` L15–141 — https://github.com/Automattic/simplenote-mcp/blob/29b3285ef071dbc63e532ed275bfdfbf94c2c33f/src/providers/auth.ts#L15-L141
19. Automattic/simplenote-mcp `src/providers/simperium-api.ts` L19–23, L183–201, L309–344, L530–575, L654–755; `AGENTS.md` L68–70 — https://github.com/Automattic/simplenote-mcp/blob/29b3285ef071dbc63e532ed275bfdfbf94c2c33f/src/providers/simperium-api.ts#L19-L23
20. Automattic/simplenote-mcp `README.md` ("Token lifetime") — https://github.com/Automattic/simplenote-mcp/blob/29b3285ef071dbc63e532ed275bfdfbf94c2c33f/README.md
21. node-simperium `src/simperium/auth.js` — https://github.com/Simperium/node-simperium/blob/bd7ba0667acc4a324f2374e5fe79f85821ee76d9/src/simperium/auth.js
22. node-simperium `src/simperium/channel.js` L8–12, L79–218, L538–645, L714–850 — https://github.com/Simperium/node-simperium/blob/bd7ba0667acc4a324f2374e5fe79f85821ee76d9/src/simperium/channel.js
23. node-simperium `src/simperium/util/change.js` L97–171, `util/operation.js` — https://github.com/Simperium/node-simperium/blob/bd7ba0667acc4a324f2374e5fe79f85821ee76d9/src/simperium/util/change.js#L97-L114
24. node-simperium `jsondiff/jsondiff.js` L195–330, `jsondiff/index.js` L7 — https://github.com/Simperium/node-simperium/blob/bd7ba0667acc4a324f2374e5fe79f85821ee76d9/src/simperium/jsondiff/jsondiff.js#L195-L330
25. simperium-ios `Simperium/Simperium.h` L88–95, `SPEnvironment.m` L19–21 — https://github.com/Simperium/simperium-ios/blob/50a3a39811f3cbcbece755eee259fa72bc424e95/Simperium/Simperium.h#L88-L95
26. simperium-ios `Simperium/SPChangeProcessor.m` L255–360 — https://github.com/Simperium/simperium-ios/blob/50a3a39811f3cbcbece755eee259fa72bc424e95/Simperium/SPChangeProcessor.m#L255-L360
27. simperium-ios `Simperium-OSX.podspec`, `Package.swift`, `External/diffmatchpatch/` (release 1.9.2, 2026-09-24) — https://github.com/Simperium/simperium-ios/tree/50a3a39811f3cbcbece755eee259fa72bc424e95/External/diffmatchpatch
28. simperium-python `simperium/core.py` L123–160, L209–290 — https://github.com/Simperium/simperium-python/blob/4a64465d8c92915371b7e6dca3bd20000da10ab6/simperium/core.py#L265-L290
29. simplenote.py `simplenote/simplenote.py` L40–47 (embedded key), L228–323 — https://github.com/simplenote-vim/simplenote.py/blob/74da92f778522fafc667a09cd4dfa5bf7f57a815/simplenote/simplenote.py#L40-L47
30. simplenote.py issue #11 "Update to the new Simperium API" — https://github.com/simplenote-vim/simplenote.py/issues/11
31. sncli `simplenote_cli/simplenote.py` L28–47, L234–248 (embedded key) — https://github.com/insanum/sncli/blob/befe46abf978e315472ade27e841c0a21fe6b467/simplenote_cli/simplenote.py#L28-L47
32. nvpy `setup.py` L35; issue #243 — https://github.com/cpbotha/nvpy/blob/bb4b66e32777c08986b3f461f47f5228adb3460e/setup.py#L35 , https://github.com/cpbotha/nvpy/issues/243
33. simplenote.vim `.gitmodules` (submodule pinned to simplenote.py 74da92f) — https://github.com/simplenote-vim/simplenote.vim/blob/3e9219992d40550c56010618478b267589219799/.gitmodules
34. google/diff-match-patch (archived; `objectivec/`) — https://github.com/google/diff-match-patch ; archive flag: https://api.github.com/repos/google/diff-match-patch
35. JanX2/google-diff-match-patch-Objective-C — https://github.com/JanX2/google-diff-match-patch-Objective-C
36. Donnishcomau/snote `docs/ARCHITECTURE.md` (Auth, Sync) — https://github.com/Donnishcomau/snote/blob/8912143c22aae40f1b35b798c6d498c1a85c68ba/docs/ARCHITECTURE.md
37. gummipunkt/NoteIt `SimperiumClient.swift` (embedded key) — https://github.com/gummipunkt/NoteIt/blob/254b972145b46b9a5a9088dc6193c934374bb6a4/Sources/NoteItCore/Simplenote/SimperiumClient.swift
38. This repo: `SimplenoteSession.m` (L41, L66–77, L298–345, L1092–1240), `SimplenoteEntryCollector.m` (L270–350, L400–480), `SimperiumConfig.h`
39. Unauthenticated probes run 2026-09-30: `GET api.simperium.com/1/chalk-bump-f49/note/index` → 401; `POST auth.simperium.com/1/chalk-bump-f49/authorize/` without key → 400 "missing api key", with dummy key → 401 "invalid app credentials"; `app.simplenote.com/login-with-password/` → 200.

## Spike results (2026-09-30)

Tested against the maintainer's real Simplenote account, read-only, from a scratch script (not committed). Only status codes, field names and counts were recorded; no note contents and no token.

| Step | Result |
|---|---|
| `POST app.simplenote.com/account/request-login` with `request_source: "nvalt"` (honest third-party identity, no API key) | **HTTP 200**, login code emailed |
| `POST /account/complete-login` with the emailed code | **HTTP 200**, response keys `sync_token`, `username`; token is 32 chars |
| `GET api.simperium.com/1/chalk-bump-f49/note/index?limit=5` with `X-Simperium-Token` | **HTTP 200**, keys `current`, `index`, `mark` |
| Full index, paged with `mark` (limit 500) | 2,324 note IDs in 5 pages (local database has 2,094 notes; difference not yet analysed — likely trashed notes and notes added elsewhere) |
| `GET /note/i/<id>` | **HTTP 200**, `X-Simperium-Version` header present; fields `content`, `creationDate`, `deleted`, `modificationDate`, `publishURL`, `shareURL`, `systemTags`, `tags` |
| `note` vs `Note` bucket | Identical ID sets and identical `current` cv: **bucket names are case-insensitive** |

Conclusions:
- The UNVERIFIED `request_source` scoping concern does not block an honestly identified client: a token obtained with `request_source: "nvalt"` was accepted by the data API.
- No API key is needed anywhere in the path. `SimperiumConfig.h` and password login can be removed.
- Not yet tested: writes (`POST /note/i/<id>/v/<n>`), `/changes?cv=`, token lifetime, and whether Simplenote later blocks or rate-limits this identity.

## Write spike and end-to-end results (2026-10-01, #14)

Against the maintainer's account, writing only to one throwaway note (`nvalt-spike-…`, left in the trash).

| Check | Result |
|---|---|
| `POST note/i/<id>` (create) | 200, `X-Simperium-Version: 1`, full object echoed with `response=1` |
| Edit at current version | 200, v2 |
| Conflicting edit posted against stale v1 | 200, v3; **server kept both** appended lines, the stale post's first: `…base line\nedit from machine B\nedit from machine A`. All other fields preserved. |
| Same `ccid` posted twice | 200, then **409** (duplicate change) |
| Identical object re-posted | **412** (empty change), version unchanged |
| `GET i/<id>/v/1` / `/v/9999` | 200 / 404 |
| Trash (`deleted: true`) | 200, new version |
| Bad token | 401 |
| `GET note/changes?cv=<cv>` | **Works**: JSON array of `{ccids, clientid, cv, ev, id, o, sv, v}` (no object data). With `wait=0` returns `[]` immediately when up to date; without it, long-polls. `clientid` optional. |
| `changes` with a change version from before a long quiet period, or a bogus one | **404** — the server forgets old change versions; clients must re-index (the adapter maps 404 → unknown change version). |
| `index?since=<cv>` | 200, `{current, index}` with only notes changed since `cv` (a lighter alternative to re-indexing; not used yet). |

End-to-end (`Tests/RealSimplenoteSyncTests.m`, opt-in): the Sync engine + HTTP adapter did a first sync of **2,325 notes in 4.3 s** (matching the server index exactly), pushed a local edit, and merged a concurrent "phone" edit server-side with both lines kept. The real app, signed in inside a throwaway home folder, synced the same 2,325 notes (229 in trash, 2,096 visible — the same count as the old database) and caught up on relaunch without re-indexing.

Changes made from these results: `NVTextMerge` now keeps both sides' insertions at the same point (ours first), matching the server, and the fake server inherits that.
