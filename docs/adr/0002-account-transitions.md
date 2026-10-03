# ADR 0002: One owner for account transitions

- Status: accepted
- Date: 2026-10-02

## Context

Account switching cleared the shared Notes store before retiring the old controller.
Closing that controller then saved its unsynced Notes into the new account's store.
A delayed credential read could also restart sync after sign-out.

## Decision

The Account session owns credential restoration, sign-in, sign-out, and account switching.
The window presents choices and status. The Account session owns the order of operations.
It also publishes account status. The Notes controller forwards status changes from its
active Sync engine; stale engines cannot publish. Only a credential rejection on the
active engine marks an expiry transition and opens the account window automatically.
Launch and ordinary sign-out leave the window closed. An empty local-only notes list
offers an explicit sign-in action.

When another account has unsynced changes, offer **Sync and Switch**, **Discard and Switch**, and **Cancel**.
A failed sync keeps the old account active. Discard requires an explicit choice.
When edits arrive during the sync attempt, keep the old account active for retry or discard.

Retire and flush the old controller before clearing its Notes store.
Ignore callbacks from retired Sync engines and obsolete credential requests.
Retiring a controller more than once has no further effect.

Sign-out retains local Notes and their account association. It removes the credential and stops sync.
Signing back into the same account keeps those Notes.
First sign-in uploads Notes created in local-only mode.

The Notes store, Sync engine, and Simplenote port remain separate modules under ADR 0001.
Debounce timing remains in NotationController.

## Consequences

Switching needs no separate archive of each account's unsynced Notes.
Users must sync or explicitly discard those changes before leaving the old account.
After sign-out, syncing before a switch requires signing back into the old account.

A verified new-account token is retained in memory for retry after a failed switch.
The user does not need another email code for each retry.
