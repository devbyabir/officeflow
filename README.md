<div align="center">
  <img src="docs/site/officeflow-icon.svg" width="64" height="64" alt="OfficeFlow icon">
  <h1>OfficeFlow</h1>
  <p><strong>Office supplies, in order.</strong></p>
  <p>A local inventory and requisition workspace for one office, rebuilt from a Java coursework project.</p>
  <p>
    <a href="https://devbyabir.github.io/officeflow/"><img src="docs/images/live-demo-button.svg" width="250" alt="Open the interactive OfficeFlow demo with sample data"></a>
    <a href="https://github.com/devbyabir/officeflow/releases/latest"><img src="docs/images/windows-download-button.svg" width="250" alt="Download OfficeFlow for Windows"></a>
  </p>
  <p><sub>The demo uses fictional records in your browser. The Windows app stores your own records on your PC.</sub></p>
  <p>
    <a href="https://github.com/devbyabir/officeflow/actions/workflows/checks.yml"><img src="https://github.com/devbyabir/officeflow/actions/workflows/checks.yml/badge.svg" alt="Application checks"></a>
    <a href="https://github.com/devbyabir/officeflow/releases/latest"><img src="https://img.shields.io/github/v/release/devbyabir/officeflow?label=release" alt="Latest release"></a>
  </p>
</div>

## Explore the workspace

![OfficeFlow overview with fictional sample data](docs/images/dashboard.png)

<details>
<summary>See dark mode and more screens</summary>

![OfficeFlow overview in dark mode](docs/images/dark-mode.png)

| Screen | Light | Dark |
| --- | --- | --- |
| Supply inventory | [View](docs/images/inventory-light.png) | [View](docs/images/inventory-dark.png) |
| Requisitions | [View](docs/images/requests-light.png) | [View](docs/images/requests-dark.png) |

</details>

OfficeFlow tracks supplies, available stock, teachers, and requisitions. Pending requests reserve stock; issue deducts it once, while rejection or cancellation releases the reservation. Administrators manage inventory and approvals. Teachers see their own requests and available stock.

## Choose how to run it

| | [Live demo](https://devbyabir.github.io/officeflow/) | [Windows release](https://github.com/devbyabir/officeflow/releases/latest) |
| --- | --- | --- |
| Data | Fictional sample records in browser `localStorage` | Your office's H2 database on this PC |
| Sign-in | Switch between sample roles | Username, password, hint and one-time recovery code |
| Java installation | None | None; the Windows package includes its own runtime |
| Network | GitHub Pages hosts static files | Java API listens only on `127.0.0.1` |

### Install on Windows

1. Read the [end-user terms](TERMS.md), then download the [latest installer](https://github.com/devbyabir/officeflow/releases/latest) (`OfficeFlow-Setup-<version>-x64.exe`). A [portable Windows ZIP](https://github.com/devbyabir/officeflow/releases/latest) is available on the same page.
2. Compare the downloaded file's SHA-256 with its `.sha256` file. In PowerShell: `Get-FileHash .\OfficeFlow-Setup-<version>-x64.exe -Algorithm SHA256`.
3. Run setup, then open **OfficeFlow** from the Start menu. It starts a hidden Java process and opens `http://127.0.0.1:8080` in your browser. On first run, create an administrator username, a 6–12 character password and a private hint; save the recovery code shown once.

Windows 10 or 11 x64 and a browser are required. If the Microsoft Visual C++ Redistributable is missing, setup offers to download the official Microsoft installer with your permission. Setup, updates and uninstall keep your workspace at `%LOCALAPPDATA%\OfficeFlow\officeflow.mv.db`.

> **Windows trust warning:** OfficeFlow 1.0.2 is unsigned. Windows Smart App Control may block setup, launch or uninstall, and SmartScreen may show an unrecognized-app warning. A SHA-256 match verifies the file you downloaded, but does not make its publisher trusted. See the [release notes](https://github.com/devbyabir/officeflow/releases/latest) and [Microsoft's Smart App Control guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview) before changing Windows security settings.

The [user guide](docs/USER_GUIDE.md) covers the portable ZIP, first sign-in, teacher accounts, recovery, backup, upgrade and troubleshooting.

## What is inside

- **Inventory:** supplies, categories, stock thresholds, search, sorting and CSV import/export.
- **Requisitions:** teacher requests, stock reservations, administrator decisions and history.
- **Accounts:** role checks on the Java server, temporary teacher passwords, recovery hints and rotating recovery codes.
- **Two interfaces, one design:** the same responsive pages serve the local Java app and the clearly labeled sample demo; their storage and sign-in flows stay separate.
- **Windows delivery:** Inno Setup installer and portable ZIP, each with a bundled Temurin runtime. The matching runtime source archive, provenance and SHA-256 files accompany the release.

## Architecture and security boundary

The Windows launcher starts the local Java server, then opens the browser. The Java API applies permissions and stock rules before writing to H2 through JDBC. The GitHub Pages demo runs entirely in the browser; it never connects to the local Java API.

Passwords are stored as salted PBKDF2-HMAC-SHA256 hashes. Sessions expire after eight hours or when revoked. **The H2 database itself is not encrypted:** someone with access to your Windows account and files can copy it. Use Windows account protection and back up the database securely. OfficeFlow is designed for one shared PC, not internet hosting or multiple concurrent PCs. See the [architecture](docs/ARCHITECTURE.md) for the trust boundaries and limitations.

## Build and verify

Java 17+ and Maven 3.9+ are needed to build from source. Node.js 22 and Python 3 are used by the tests.

```sh
mvn -f server/pom.xml package dependency:copy-dependencies
npm test
python tests/test_server.py
```

GitHub Actions also runs browser tests, Windows launcher/installer tests, a ZIP test and release artifact checks. See the [development guide](docs/DEVELOPMENT.md) for setup, commands and CI details. Passing tests and scans are useful checks, not a guarantee that no vulnerability exists; review [code-scanning findings](https://github.com/devbyabir/officeflow/security/code-scanning) in their source context.

## Project background

The original console assignment was submitted in January 2025. This 2026 version adds the web UI, local HTTP API, JDBC/H2 persistence, account recovery, Windows packaging and tested stock rules. It does not claim those features were in the original submission. [Implementation plan](docs/PLAN.md) · [Release notes](https://github.com/devbyabir/officeflow/releases/latest).

Copyright © 2026 devbyabir. The repository source is [all rights reserved](LICENSE); the official Windows installer and portable ZIP have separate [end-user terms](TERMS.md). Third-party components retain their own [licenses and notices](THIRD_PARTY_NOTICES.md).
