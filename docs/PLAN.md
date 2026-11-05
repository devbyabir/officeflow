# OfficeFlow implementation plan

Source: assignment PDF, January 21 2025 report, six Java files and submitted ZIP.
Original application: console prototype; separate ArrayLists cause inconsistent
inventory and requisition views. JDBC demonstration is not integrated.

Build a responsive inventory workspace: teacher and supply CRUD, CSV batch import,
search/sort, requisitions, issue/reject/cancel, own history and CSV export.
Reserve pending quantities; release on cancel/reject; deduct exactly once on issue.
Use immutable IDs and snapshot historical names. Protect active references.

Java 17 HTTP API + JDBC/H2 persistence, password hashing, server sessions and
role/owner checks. H2 replaces the report's MySQL for reproducible local setup.
Static ES-module frontend serves both Java mode and an explicit browser-only
sample-data demo for GitHub Pages. Pages does not execute Java.

Visual direction: ivory canvas, navy sidebar, teal accents, precise tables and
status chips; responsive navigation, accessible dialogs and clear feedback.

Verify domain transitions and CSV rollback with Node, Java persistence/access/API
with integration tests, then browser desktop/mobile workflows. Publish finished
static demo through GitHub Pages and add a README Live Demo badge. Current work
is a 2026 modernization, not the unchanged original 2025 submission.
