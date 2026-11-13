# Development and verification

[← Overview](../README.md) · [Architecture](ARCHITECTURE.md) · [Implementation plan](PLAN.md)

OfficeFlow has a Java 17 HTTP API and JDBC/H2 storage. `docs/site` is the shared frontend. GitHub Pages serves it as a browser-only sample workspace; the Java server marks its own copy as Java mode before serving it.

## Build from source

Install JDK 17 or newer and Maven 3.9 or newer. From the repository root:

```sh
mvn -f server/pom.xml package dependency:copy-dependencies
```

This creates `server/target/officeflow-1.0.2.jar`. Keep the JAR in `server/target` so it can find `docs/site` in the checkout. For the first source run, set an administrator password of 6–12 characters, then start the JAR. In PowerShell:

```powershell
$secure = Read-Host "New OfficeFlow admin password" -AsSecureString
$env:OFFICEFLOW_ADMIN_PASSWORD = [Net.NetworkCredential]::new("", $secure).Password
Remove-Variable secure
java -jar server/target/officeflow-1.0.2.jar
```

The prompt masks input and keeps the password out of shell history. The environment variable is used only for a new workspace; it does not change an existing administrator password. Open `http://127.0.0.1:8080` and sign in with ID `001`, then choose a username under **Account**. Later runs need only `java -jar server/target/officeflow-1.0.2.jar`. Keep the terminal open; press Ctrl+C to stop cleanly.

On Windows the default database is `%LOCALAPPDATA%\OfficeFlow\officeflow.mv.db`. Elsewhere it is `./data/officeflow.mv.db` relative to the working directory. Java properties go before `-jar`:

| Property | Purpose |
| --- | --- |
| `officeflow.port` | HTTP port; default `8080` |
| `officeflow.db` | H2 JDBC URL for a separate workspace |
| `officeflow.site` | Explicit path to the frontend files |

## Run the sample site locally

```sh
python -m http.server 4173 --directory docs/site
```

Open `http://127.0.0.1:4173`. It uses fictional records in browser `localStorage` and does not call the Java API. No frontend build or npm runtime dependencies are needed.

## Tests

```sh
npm test
mvn -f server/pom.xml package dependency:copy-dependencies
python tests/test_server.py
```

The Node tests cover stock, requisitions, CSV and view calculations. The HTTP suite runs the real Java server on temporary databases and checks setup, roles, login/recovery, imports, restarts, upgrade paths and backup restoration. The Java service test can also be run directly (replace `:` with `;` in the classpath on Windows):

```sh
javac --release 17 -encoding UTF-8 -cp "server/target/classes:server/target/dependency/*" -d server/target/test-classes server/src/test/java/com/officeflow/ServiceTest.java
java -cp "server/target/classes:server/target/test-classes:server/target/dependency/*" com.officeflow.ServiceTest
```

For real Chromium UI tests:

```sh
python -m pip install -r tests/requirements-ui.txt
python -m playwright install chromium
python tests/test_ui.py
```

Set `OFFICEFLOW_UI_JAVA=1` after the Maven build to include the installed-app mode and first-run browser tests. CI runs these checks on Linux and runs the launcher, portable ZIP, installer, upgrade and uninstall tests on Windows.

## CI and releases

| Workflow | What it checks |
| --- | --- |
| [Application checks](https://github.com/devbyabir/officeflow/actions/workflows/checks.yml) | Node model, Java service/HTTP and Chromium UI |
| [Windows smoke](https://github.com/devbyabir/officeflow/actions/workflows/windows-smoke.yml) | Source startup, local data and backup/restore on Windows |
| [Windows installer](https://github.com/devbyabir/officeflow/actions/workflows/windows-release.yml) | Pinned Temurin download, Go launcher, portable ZIP, installer, upgrade/uninstall and matching runtime source |
| [Release ZIP](https://github.com/devbyabir/officeflow/actions/workflows/release-zip.yml) | Runnable JAR ZIP on Linux and Windows |
| [Publish live demo](https://github.com/devbyabir/officeflow/actions/workflows/pages.yml) | Browser/Java checks before GitHub Pages deployment |

The Windows workflow uploads installer, portable ZIP, checksums, runtime source and provenance artifacts. A manual dispatch can update a **draft** GitHub Release; it never publishes automatically. Published release assets must be verified and explicitly published. Releases are unsigned until a trusted signing identity and a clean Smart App Control On test are available; do not represent an unsigned build as trusted.

The [latest release](https://github.com/devbyabir/officeflow/releases/latest) contains the end-user terms and matching runtime source. The original coursework was a console prototype; this repository documents the 2026 redesign and does not claim the new UI or H2 workspace existed in the 2025 submission.
