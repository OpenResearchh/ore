# Pluggable external storage

ORE's database stays on This Mac (`~/ore/ore.sqlite`, or `$ORE_HOME`). Worktrees
and project libraries can live on another volume the user registers. Unplugging
that volume must never corrupt git state or silently move work onto the internal
disk.

Cloud sync is out of scope.

## Layout

A **storage root** is an OreHome-shaped directory:

| Path | Role |
|---|---|
| `<root>/repositories/` | New local projects and GitHub clones |
| `<root>/workspaces/<repo>/<slug>/` | Isolated worktrees |

**Internal** (always present, never removable): `~/ore`, or `$ORE_HOME`. Same
paths as today.

**External**: a folder the user picks in Settings. ORE creates `repositories/`
and `workspaces/` there on first use. The picker is the folder itself — if they
want `/Volumes/T7/ore`, they choose that folder.

## Persistence

SQLite (`storageRoot` table, schema v15):

- `id` — stable. Internal is `internal`.
- `kind` — `internal` \| `external`
- `displayName` — "This Mac", or a volume/folder label
- `mountPath` — last-known absolute path of this root
- `volumeUUID` — macOS volume UUID when the OS provides one
- `pathRelativeToVolume` — path of the root under the volume mount point, so a
  remount at `/Volumes/T7 1` can rebuild `mountPath`
- `isPreferred` — default for **new** workspaces and projects
- `createdAt`, `lastSeenAt`

`workspace.storageRootID` and `repository.storageRootID` reference that table.
Existing rows backfill to `internal`. The worktree's absolute `worktreePath`
stays the source of truth for git; the root id is how we know *which volume*
it belongs to after that path goes missing.

The database never lives on an external root. If the internal home were on a
volume that unplugged, ORE could not open.

## Availability

A root is **available** when its `mountPath` exists as a directory and, if a
UUID is stored, that UUID still matches.

On **remount**, ORE scans mounted volumes for a matching UUID, rebuilds
`mountPath` from `pathRelativeToVolume`, and **rewrites** stored
`worktreePath` / `repository.path` prefixes from the old mount to the new one.
That is the same volume, not a migration onto This Mac.

On **unplug**:

- The root and every workspace on it stay in SQLite.
- Summaries carry `storage.isOffline = true`.
- Running engines for those worktrees stop. No git writes against a disappearing
  disk.
- Agents cannot start. Sends fail with a sentence that names the volume.
- Nothing is copied to `~/ore`.

## New work

Creation takes an optional `storageRootID`. Resolution:

1. Requested root, if registered and available.
2. Else the preferred root, if available.
3. Else **internal**.

An unplugged preferred/requested volume does not fail the create and does not
move existing external workspaces. New work goes to This Mac until the volume
returns. The New Workspace sheet says so before the click.

## NSWorkspace

The Mac app observes `didMount`, `didUnmount`, and `didRenameVolume`, and sends
`rescanStorageRoots`. The core re-probes, rewrites remounted prefixes, stops or
starts engines, and emits a snapshot. The sidebar reads `WorkspaceSummary.storage`
and updates on that snapshot — no extra round trip.

Linux/headless: path reachability only; no UUID remount.

## UI

**Settings → Environment.** List roots, availability, Add Volume… (directory
open panel), Remove (refused while workspaces still reference the root).
Internal cannot be removed.

**New Workspace.** A storage picker. Offline roots are visible and disabled.
If the preferred volume is unplugged, the picker sits on This Mac with a
caption.

**Sidebar.** Offline workspaces keep their row, with an Offline badge and a
second line that names the volume.

**Composer.** Sending is disabled. A banner: the workspace is on “Name”, which
isn't connected; plug it in to continue; ORE will not move it onto This Mac.

## Not in this slice

- iCloud / Dropbox / network-share sync of `ore.sqlite`
- Moving an existing workspace between roots
- Registering a root that is currently unplugged (the open panel requires it
  to be mounted)
