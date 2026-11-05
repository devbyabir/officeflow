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
then replace relational rows and credentials in one JDBC transaction. This is
intended for a small single-process workspace. High-volume or multi-process use
would need row-oriented SQL updates and database-level concurrency control.

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
`POST /api/command`, `POST /api/import`. Protected routes require Bearer sessions.
The frontend selects Java mode only when health identifies `officeflow`.

## Scope

GitHub Pages is a browser-only demonstration, not secure shared storage. Java
binds to loopback. Public demo credentials and teacher-ID initial passwords are
educational defaults. This is a local portfolio application, not an institutional
identity system. H2 is supported and tested; original MySQL integration is not claimed.
