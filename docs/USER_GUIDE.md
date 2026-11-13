# OfficeFlow user guide

[← Overview](../README.md) · [Latest Windows release](https://github.com/devbyabir/officeflow/releases/latest) · [Live demo](https://devbyabir.github.io/officeflow/)

OfficeFlow is a **single-computer** office workspace. Administrator and teachers use the same Windows PC and browser, signing in and out in turn. The live demo uses fictional browser data; it is not your installed workspace.

## Install or use the portable ZIP

- **Installer:** download `OfficeFlow-Setup-<version>-x64.exe` from the [latest release](https://github.com/devbyabir/officeflow/releases/latest), run it, then open **OfficeFlow** from the Start menu. The app runs without a console and opens `http://127.0.0.1:8080` in your browser.
- **Portable ZIP:** download `OfficeFlow-<version>-windows-x64.zip` from the same page, extract the entire archive to a folder you keep, and run `OfficeFlow.exe` inside it. Keep its `app` and `runtime` folders beside the launcher.
- Both packages include Java. Windows 10 or 11 x64, a browser and the Microsoft Visual C++ Redistributable (x64, version 14.40 or newer) are needed. The installer offers Microsoft's official download if that runtime is missing.
- Check the downloaded file against its `.sha256` asset. For example, run `Get-FileHash .\OfficeFlow-Setup-<version>-x64.exe -Algorithm SHA256` in PowerShell and compare the output.

**Windows security:** the 1.0.2 binaries are unsigned. Smart App Control can block setup, launch or uninstall; SmartScreen may warn about an unrecognized app. GitHub hosting and matching hashes do not establish publisher trust. Read [Microsoft's Smart App Control guidance](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview) before changing Windows protection. The [release notes](https://github.com/devbyabir/officeflow/releases/latest) repeat this limitation.

## First run and sign-in

On a new Windows workspace, the **Create account** screen asks for an administrator username, password, confirmation and hint. It works only on this PC, for 15 minutes, and only until the first administrator is created. If it expires, quit OfficeFlow and reopen it from the Start menu for a new setup screen.

- Usernames are 3–32 characters, start with a letter, and may contain letters, numbers, dots, dashes and underscores. They are case-insensitive.
- New passwords are 6–12 characters. Use a unique one; existing longer passwords remain valid after an upgrade.
- A hint cannot contain the complete username or password. It helps you remember but **cannot** reset the account.
- Save the recovery code shown once, away from this PC. **Forgot username or password?** can show your hint or accept that code to choose a new password. A successful reset revokes existing sessions and replaces the code.
- Older accounts may still sign in with their account ID; the administrator's ID is `001`. Set a username under **Account**. Replace legacy passwords promptly.

The **Account** button above the workspace contains username, password, hint, recovery and sign-out controls. Always sign out before leaving a shared computer. Closing the browser tab does not stop OfficeFlow; use **Quit OfficeFlow** in the sidebar or Start menu when finished.

## Teachers, inventory and CSV

Administrators add teachers under **Teachers**. Each new teacher receives a random temporary password shown once; share it privately. At first sign-in, that teacher must choose a new password and hint and save a recovery code before using the workspace. An administrator can issue another temporary password from **Account → Reset teacher password**.

Supplies can be searched and sorted. Pending requests reserve available stock. Issuing a request deducts stock once; cancelling or rejecting it releases the reservation. CSV imports are atomic: one invalid row rejects the batch. Imports accept UTF-8 CSV with 1–500 data rows (up to 200 KB) and these exact headers:

```csv
name,category,quantity,threshold,unit
```

```csv
id,name,department,email
```

See the [supply example](examples/supplies.csv) and [teacher example](examples/teachers.csv). Imports create new records and do not silently overwrite existing IDs or names. Exported CSV protects cells that spreadsheet software might interpret as formulas.

## Data, backup and upgrade

Your Windows workspace is the file `%LOCALAPPDATA%\OfficeFlow\officeflow.mv.db`. It is **outside** the program folder, so installing, upgrading and uninstalling keep it. The file is not encrypted; protect your Windows account and backup copies.

1. Stop OfficeFlow with **Quit OfficeFlow**.
2. Copy `officeflow.mv.db` to a safe location, ideally off this PC.
3. To restore, stop OfficeFlow, rename the current file as a backup, then copy the saved file into the same folder under the name `officeflow.mv.db`.

A newer installer stops a running copy before replacing program files. For a portable update, quit OfficeFlow and extract the new ZIP into a new folder; the new launcher opens the same workspace. Do not run the installer and a portable copy against the same database at once.

**Upgrading from 1.0.0:** the old `-Dofficeflow.seed=true` flag is refused. If a workspace is found in the old `data` folder while the new default location is empty, startup stops with options rather than silently making a new workspace. Accounts and longer passwords remain usable; change old default passwords after signing in.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Smart App Control or SmartScreen warning | Read the [Windows security note](https://github.com/devbyabir/officeflow/releases/latest); the unsigned app may be blocked. |
| Visual C++ runtime missing | Install the [official x64 redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist), then reopen OfficeFlow. |
| Setup link expired | Quit OfficeFlow and open it again from the Start menu. |
| Port 8080 in use | Quit the other program or OfficeFlow copy using that port, then reopen. |
| Browser cannot reach server | Reopen OfficeFlow from the Start menu and press **Retry** in the browser. |
| Workspace already open | Quit the other OfficeFlow process before launching another copy. |
| Setup cannot replace files | Use **Quit OfficeFlow**, then run setup again. |

Startup details are in `%LOCALAPPDATA%\OfficeFlow\launcher.log`. Reinstalling can repair missing program files without deleting the workspace. The included `Quick Start.txt` repeats the essentials offline.
