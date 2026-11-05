<div align="center">

# OfficeFlow

**Office supplies, in order.**

A responsive inventory and requisition workspace, rebuilt from my third-semester
Java final project at Zhengzhou University.

[![Open Live Demo](https://img.shields.io/badge/OPEN_LIVE_DEMO-OfficeFlow-147d70?style=for-the-badge&logo=githubpages&logoColor=white)](https://devbyabir.github.io/officeflow/)
[![Application checks](https://github.com/devbyabir/officeflow/actions/workflows/checks.yml/badge.svg)](https://github.com/devbyabir/officeflow/actions/workflows/checks.yml)

Java 17+ · JDBC · H2 · JavaScript · GitHub Pages

</div>

![OfficeFlow dashboard](docs/images/dashboard.png)

## A smoother day for your team

- Supply and teacher management with duplicate and input validation.
- Search, category filters, quantity sorting and low-stock indicators.
- Teacher requisitions, personal history and owner-only pending cancellation.
- Administrator issue/reject actions and historical name snapshots.
- CSV batch imports with rollback when any row is invalid.
- CSV reports with spreadsheet-formula protection.
- Responsive layouts, keyboard-accessible dialogs and reduced-motion support.

Pending requests reserve stock. Issuing deducts it once; cancelling or rejecting
releases the reservation. Available quantities always exclude pending requests.

## Two ways to explore

| | Live browser demo | Local Java application |
| --- | --- | --- |
| Open | Live Demo button above | Start the Java server below |
| Storage | This browser's localStorage | JDBC / H2 file database |
| Identity | Switch fictional demo roles | Password login and server sessions |
| Validation | Browser domain model | Server permissions and stock rules |
| Sharing | Each browser has its own records | One local workspace |

**GitHub Pages hosts the interactive demo; it does not run Java.** The Java API
is a separate, working implementation serving the same frontend. Demo records
are fictional. The live link becomes available after Pages deployment succeeds.

## Run the Java application

Requires JDK 17+ and Maven 3.9+. From the repository root:

```sh
mvn -f server/pom.xml package
java -Dofficeflow.seed=true -jar server/target/officeflow-1.0.0.jar
```

Open **http://127.0.0.1:8080**. Omit `officeflow.seed` for an empty workspace.
Seeding is optional and only happens when the inventory is empty.

Local demo administrator: `001` / `001`. Sample teachers: `T001`, `T002`, `T003`;
each initial password is its teacher ID, as specified by the assignment. New
teachers also start with their ID as password. These are public sample credentials.
Set `OFFICEFLOW_ADMIN_PASSWORD` before the first launch to choose the initial
admin password. This does not reset credentials in an existing database.

The server binds to loopback for local use. Real internet hosting would require
HTTPS, operational controls and a first-login password-change flow. Passwords
are salted PBKDF2-HMAC-SHA256 hashes (210,000 iterations). Sessions expire after
eight hours or a server restart. Database files under `data/` are excluded from Git.

JVM properties go **before** `-jar`:

| Property | Default |
| --- | --- |
| `officeflow.port` | `8080` |
| `officeflow.db` | `jdbc:h2:./data/officeflow` |
| `officeflow.site` | `docs/site` |
| `officeflow.seed` | `false` |

## Run only the browser demo

```sh
python -m http.server 4173 --directory docs/site
```

Open http://127.0.0.1:4173. No frontend build or npm dependencies are required.
Use **Switch role** for teacher workflows and **Reset demo** to restore samples.
Google Fonts fall back to system fonts when unavailable.

## CSV files

Administrator imports accept UTF-8 CSV files with 1–500 data rows, up to 200 KB.
Use these exact headers:

```csv
name,category,quantity,threshold,unit
```

```csv
id,name,department,email
```

[Supply example](docs/examples/supplies.csv) · [Teacher example](docs/examples/teachers.csv)

Imports create records; they do not silently overwrite existing IDs or names.
Stock quantities are whole numbers from 0 to 1,000,000. Requests must be positive
and cannot exceed available stock. Email is optional. Resolve pending references
before deleting a teacher or supply; terminal history remains intact.

## Tests

Node.js 22 and Python 3 are used for testing:

```sh
npm test
mvn -f server/pom.xml package dependency:copy-dependencies
python tests/test_server.py
```

The browser suite checks reservations, owner restrictions, terminal transitions,
CSV quoting/rollback and export safety. HTTP tests start a real Java/JDBC server.
The additional Java integration test checks restart persistence:

```sh
javac --release 17 -encoding UTF-8 -cp "server/target/classes:server/target/dependency/*" -d server/target/test-classes server/src/test/java/com/officeflow/ServiceTest.java
java -cp "server/target/classes:server/target/test-classes:server/target/dependency/*" com.officeflow.ServiceTest
```

On Windows replace the classpath separator `:` with `;`. CI runs all three checks.

## Publish the live demo

1. Push to `devbyabir/officeflow` on `main`.
2. In **Settings → Pages**, choose **GitHub Actions** as the source.
3. Run **Publish live demo**. It tests the browser model and Java API, then
   publishes only `docs/site`.
4. Open https://devbyabir.github.io/officeflow/.

## From coursework to this version

The console submission is dated **21 January 2025**, following the 2024
third-semester Java course. This **2026 modernization** adds the web UI,
transactional persistence and tested stock rules. These features are not claimed
to have existed in the original submission. The report describes MySQL; this
version supports H2 through JDBC for a reproducible local setup.

[Implementation plan](docs/PLAN.md) · [Architecture](docs/ARCHITECTURE.md)

## Ownership

© 2026 **devbyabir**. All rights reserved. See [LICENSE](LICENSE).
Third-party libraries and fonts retain their own licences; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
