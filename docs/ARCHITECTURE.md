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
| File input/output | Sample JSON input, static files, CSV upload/download |
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

`GET /api/health`, `POST /api/login`, `GET /api/session`, `GET /api/state`,
`POST /api/command`, `POST /api/import`, `POST /api/logout`,
`POST /api/password/change`, `POST /api/password/reset`.
Protected routes require Bearer sessions. Password change verifies the current
password; admin reset is restricted to active teacher accounts. Both revoke all
sessions for the affected account after a successful credential update. Logout
revokes the current token; teacher deletion revokes that teacher's sessions so
reusing an ID cannot reactivate old tokens.
The frontend selects Java mode only when health identifies `officeflow`.

## Scope

GitHub Pages is a browser-only demonstration, not secure shared storage. Java
binds to loopback. Public demo credentials and teacher-ID initial passwords are
educational defaults. This is a local portfolio application, not an institutional
identity system. H2 is supported and tested; original MySQL integration is not claimed.
