# Architecture

## Source review

Reviewed the course assignment PDF, January 21 2025 report PDF/Word text, all six
submitted Java files, JDBC example and ZIP inventory. The ZIP and loose files
have the same console-project structure. Course PDFs, reports and identifiers
are not redistributed.

The prototype used separate Main/Administrator lists, an uninitialized supply
list, printed credentials and unchecked numeric input. Its JDBC example did not
back the operational menus. This version replaces those inconsistent workflows.

## Components

- `docs/site/model.js`: pure browser-demo transitions and CSV routines.
- `docs/site/app.js`: views, dialogs, file import/export and API adapter.
- `Accounts`: account inheritance/polymorphism and password hashing.
- `Service`: permissions, validation, ownership, stock rules and atomic imports.
- `Store`: JDBC tables for teachers, supplies, requisitions and credentials.
- `App`: HTTP endpoints, bounded bodies, sessions and local static serving.
- `SetupToken`: short-lived, one-use first-run authorization.
- `Startup`: checks the web files, database location and first-run admin password
  before H2 is opened, and refuses the removed `officeflow.seed` option.
- `packaging/windows/launcher`: the windowless Go launcher starts Java and opens
  the local page in the browser; Inno Setup installs it and keeps the workspace
  outside the program folder. The portable ZIP uses the same launcher and runtime.

Java serializes operations through the service. Mutations validate a snapshot,
then compare the validated before/after snapshots and batch only changed rows
with keyed JDBC statements in one transaction. Unchanged rows and password hashes
are preserved; deletes target specific IDs. Teacher availability aggregates other
teachers' reservations in one pass over the same snapshot, without per-item database
reads. Writes return a filtered view of the committed snapshot without rereading it.
This remains a small single-process workspace: snapshots are still read into memory,
and multi-process use would need database-level concurrency control.

Requisitions keep historical name/ID snapshots. Those historical references are
not cascading foreign keys; pending references are protected by the service.

## Course requirements

| Requirement | Implementation |
| --- | --- |
| Classes, inheritance, polymorphism | Administrator and Teacher account types |
| Exceptions | Validation errors, HTTP feedback and JDBC rollback |
| Collections | Arrays, maps and session/request collections |
| File input/output | Static files, H2 database file, CSV upload/download |
| JDBC | Prepared statements, relational tables and transactions |
| Teacher CRUD and import | Directory forms and CSV imports |
| Supply management/import/sort | Inventory forms, search and quantity sorting |
| Requisition, cancellation, history | Teacher-owned workflow |
| Admin issue | Confirmed one-time stock deduction |

## Stock rules

Lifecycle status belongs to each requisition, because different teachers can
request the same supply concurrently. Available = on hand - pending quantities.
Issue deducts on hand and ends the reservation; rejection/cancellation releases
only the reservation. This refines the assignment's single supply status field.

Teacher snapshots exclude other teachers' profiles and histories. An aggregate
`reservedByOthers` count preserves correct availability without disclosing them.

## API

`GET /api/health`, `GET/POST /api/setup`, `POST /api/login`,
`POST /api/recovery/hint`, `POST /api/recovery/reset`, `GET /api/session`,
`GET /api/state`, `POST /api/command`, `POST /api/import`,
`POST /api/logout`, `POST /api/username`, `POST /api/password/change`,
`POST /api/recovery/update`, `POST /api/password/reset` and `POST /api/quit`.
Protected routes require Bearer sessions. Password change verifies the current
password; admin reset is restricted to active teacher accounts. Both revoke all
sessions for the affected account after a successful credential update. Logout
revokes the current token; teacher deletion revokes that teacher's sessions so
reusing an ID cannot reactivate old tokens.

First-run setup and recovery endpoints require a loopback request with an
OfficeFlow `Host` header. The setup token expires after 15 minutes, works once
and locks after repeated wrong guesses. JSON POST bodies are bounded; the
server does not grant cross-origin access. Login and recovery attempts are
rate-limited. Sessions are random bearer tokens kept in browser session storage
and expire after eight hours. Passwords and recovery codes are stored as salted
hashes, not plaintext.

New teachers (form or CSV import) receive a random temporary password, returned
once in that response as `temporaryPasswords`. Administrator resets are temporary
too. A session opened with a temporary password may only call `/api/session`,
`/api/password/change` and `/api/logout`; anything else returns 403 with code
`PASSWORD_CHANGE_REQUIRED`. Accounts from older workspaces keep working unchanged.

## Java mode and sample mode

`docs/site/index.html` carries `<meta name="officeflow-mode" content="sample">`.
The Java server serves it as `content="java"`, so the page knows its mode before
any request. Java mode shows "Connecting…" until `/api/health` answers, then
sign-in or the workspace; on failure it shows an error with Retry. It never reads
or writes the browser sample workspace. Every other copy (GitHub Pages, a local
static server) is the sample workspace and makes no API calls.

## Scope

GitHub Pages is a browser-only demonstration, not secure shared storage. Java
binds to loopback and is meant for one shared office PC. This is a small local
application, not an institutional identity system. H2 is supported and tested;
original MySQL integration is not claimed.

The H2 database is not encrypted at rest. Anyone with access to the Windows
account and its files can copy it; the app's password screen controls actions
through the API, not direct filesystem access. Backups need the same care.
The server is not designed for exposure to other computers or the internet.
Snapshot-based writes are serialized inside one Java process; multiple
concurrent processes would need database-level coordination.

The Windows installer and launcher in release 1.0.2 are unsigned. A matching
SHA-256 verifies an asset's bytes but does not establish a trusted publisher;
Smart App Control can block installer, launcher or uninstaller. Trusted code
signing and a clean protected-Windows test remain outside the current release.
CI tests functionality on disposable Windows runners, not Smart App Control
reputation on every user's device.
