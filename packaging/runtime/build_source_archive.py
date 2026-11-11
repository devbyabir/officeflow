"""Builds OfficeFlow-<version>-java-runtime-source.zip: the complete corresponding source for
the Java runtime bundled in the Windows ZIP, with build scripts, build configuration, notices
and a provenance record.

Run from the repository root (CI does this on Linux):
    python3 packaging/runtime/build_source_archive.py dist

Every download is checked against packaging/runtime/temurin-21.json. The official Temurin source
tarball is compared file by file with the pinned jdk21u commit; if the tarball lacks any file or
differs, the commit's own archive is included as well.
"""
from pathlib import Path
import datetime
import hashlib
import http.client
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PIN = json.loads((ROOT / "packaging/runtime/temurin-21.json").read_text(encoding="utf-8"))


TEMPORARY_HTTP_ERRORS = {408, 429, 500, 502, 503, 504}
DOWNLOAD_ATTEMPTS = 5


def download(url, target):
    """Downloads url to target, retrying temporary server and network errors with backoff.
    Integrity is still checked by the callers (checksums and the source comparison)."""
    name = Path(target).name
    partial = Path(f"{target}.part")
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        print(f"Downloading {name} (attempt {attempt}/{DOWNLOAD_ATTEMPTS})", flush=True)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "officeflow-release-build"})
            with urllib.request.urlopen(request, timeout=300) as response, open(partial, "wb") as out:
                shutil.copyfileobj(response, out)
            partial.replace(target)
            print(f"Downloaded {name} ({Path(target).stat().st_size:,} bytes)", flush=True)
            return target
        except Exception as error:  # noqa: BLE001 - classified by is_temporary
            partial.unlink(missing_ok=True)
            if not is_temporary(error) or attempt == DOWNLOAD_ATTEMPTS:
                print(f"::error title=Download failed::{name} from {url}: {error}", flush=True)
                raise
            wait = 10 * 2 ** (attempt - 1)
            print(f"::warning title=Download retry::{name}: {error}; retrying in {wait} s", flush=True)
            time.sleep(wait)


def is_temporary(error):
    """True for server and network errors worth retrying (408, 429, 5xx, timeouts, resets)."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code in TEMPORARY_HTTP_ERRORS
    return isinstance(error, (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead))


GIT_FETCH_ATTEMPTS = 3
# Ignore the machine's own git settings (core.autocrlf, filters) so `git archive` writes the
# files exactly as committed, like GitHub's archive.
GIT_ENV = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0"}


def commit_archive_of(repository, commit, target):
    """Downloads GitHub's archive of a pinned commit. If GitHub keeps failing with temporary
    errors, fetches exactly that commit with git instead and archives it with the same top
    folder (<repo>-<commit>/), so the checks that follow see the same layout. Returns
    (path, how) where how describes the source used, for the provenance record."""
    name = repository.rstrip("/").rsplit("/", 1)[1]
    try:
        return download(f"{repository}/archive/{commit}.tar.gz", target), "GitHub's archive download"
    except Exception as error:  # noqa: BLE001
        if not is_temporary(error):
            raise
        print(f"::warning title=Archive fallback::{Path(target).name}: GitHub's archive kept failing "
              f"({error}); fetching commit {commit} with git instead", flush=True)
    clone = Path(f"{target}.git")
    for attempt in range(1, GIT_FETCH_ATTEMPTS + 1):
        shutil.rmtree(clone, ignore_errors=True)
        try:
            subprocess.run(["git", "init", "-q", "--bare", str(clone)], check=True, env=GIT_ENV)
            print(f"git fetch {repository} {commit} (attempt {attempt}/{GIT_FETCH_ATTEMPTS})", flush=True)
            subprocess.run(["git", "-C", str(clone), "fetch", "-q", "--depth", "1", "--no-tags",
                            f"{repository}.git", commit], check=True, timeout=1200, env=GIT_ENV)
            break
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            if attempt == GIT_FETCH_ATTEMPTS:
                print(f"::error title=Git fetch failed::{repository} {commit}: {error}", flush=True)
                raise
            wait = 30 * attempt
            print(f"::warning title=Git fetch retry::{repository}: {error}; retrying in {wait} s", flush=True)
            time.sleep(wait)
    fetched = subprocess.run(["git", "-C", str(clone), "rev-parse", "FETCH_HEAD^{commit}"],
                             check=True, capture_output=True, text=True, env=GIT_ENV).stdout.strip()
    if fetched != commit:
        raise SystemExit(f"git fetched {fetched}, not the pinned commit {commit}")
    subprocess.run(["git", "-C", str(clone), "archive", "--format=tar.gz", f"--prefix={name}-{commit}/",
                    "-o", str(Path(target).resolve()), commit], check=True, env=GIT_ENV)
    shutil.rmtree(clone, ignore_errors=True)
    print(f"Archived {Path(target).name} from git commit {fetched} ({Path(target).stat().st_size:,} bytes)",
          flush=True)
    return target, f"`git fetch` of commit `{commit}` (verified) and `git archive`, because GitHub's archive download kept failing"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tree(path):
    """Maps each file path (without the top folder) to a content hash or link target."""
    files = {}
    with tarfile.open(path, "r:*") as archive:
        for member in archive:
            parts = member.name.split("/", 1)
            if len(parts) < 2 or not parts[1] or member.isdir():
                continue
            name = parts[1]
            if member.issym() or member.islnk():
                files[name] = "link:" + member.linkname
            elif member.isfile():
                files[name] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    return files


def main():
    version = re.search(r"<artifactId>officeflow</artifactId>\s*<version>([^<]+)</version>",
                        (ROOT / "server/pom.xml").read_text(encoding="utf-8")).group(1)
    name = f"OfficeFlow-{version}-java-runtime-source"
    output = Path(sys.argv[1]).resolve()
    work = output / "runtime-source-work"
    stage = output / name
    for folder in (work, stage):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    base = PIN["download_base"]
    commit, scripts = PIN["openjdk_source"]["commit"], PIN["build_scripts"]["commit"]
    report = []

    # Official source tarball and the metadata Adoptium publishes beside both downloads.
    openjdk = stage / "openjdk"
    openjdk.mkdir()
    sources = download(f"{base}/{PIN['sources']['file']}", openjdk / PIN["sources"]["file"])
    for item in (PIN["sources"]["file"], PIN["jdk"]["file"]):
        for suffix in (".sha256.txt", ".json", ".sig"):
            download(f"{base}/{item}{suffix}", openjdk / (item + suffix))
    published = (openjdk / (PIN["sources"]["file"] + ".sha256.txt")).read_text().split()[0]
    actual = sha256(sources)
    assert published == PIN["sources"]["sha256"] == actual, (published, actual)
    report.append(f"- `{PIN['sources']['file']}`: SHA-256 `{actual}` matches Adoptium's "
                  "published checksum and the pinned value.")

    for item, kind in ((PIN["jdk"]["file"], "jdk"), (PIN["sources"]["file"], "sources")):
        meta = json.loads((openjdk / (item + ".json")).read_text(encoding="utf-8"))
        assert meta["sha256"] == PIN[kind]["sha256"], (item, meta["sha256"])
        assert meta["openjdk_source"].endswith("/commit/" + commit), meta["openjdk_source"]
        assert meta["buildRef"].endswith("/commit/" + scripts), meta["buildRef"]
        assert meta["scmRef"] == PIN["openjdk_source"]["tag"], meta["scmRef"]
    report.append(f"- Adoptium's metadata for both the Windows JDK and the source tarball names "
                  f"OpenJDK source commit `{commit}` (tag `{PIN['openjdk_source']['tag']}`) and "
                  f"build scripts commit `{scripts}`.")

    # The exact jdk21u commit, compared file by file with the official tarball.
    commit_archive, how = commit_archive_of(PIN["openjdk_source"]["repository"], commit,
                                            work / f"jdk21u-{commit}.tar.gz")
    report.append(f"- The jdk21u commit was obtained by {how}.")
    official, upstream = tree(sources), tree(commit_archive)
    missing = sorted(set(upstream) - set(official))
    extra = sorted(set(official) - set(upstream))
    changed = sorted(p for p in set(upstream) & set(official) if upstream[p] != official[p])
    report.append(f"- File-by-file comparison with commit `{commit}`: {len(upstream)} files in the "
                  f"commit, {len(official)} in the tarball; {len(missing)} missing from the tarball, "
                  f"{len(changed)} with different content, {len(extra)} only in the tarball"
                  + (f" ({', '.join(extra[:10])}{' …' if len(extra) > 10 else ''})" if extra else "")
                  + ".")
    if missing or changed:
        shutil.copy2(commit_archive, openjdk / commit_archive.name)
        report.append(f"- Because the tarball is not identical to the commit, the commit's own "
                      f"archive `{commit_archive.name}` is included as well.")
        for label, paths in (("missing", missing), ("changed", changed)):
            if paths:
                report.append(f"  - {label}: {', '.join(paths[:20])}{' …' if len(paths) > 20 else ''}")

    # Temurin's build scripts at the commit that produced the Windows JDK.
    build = stage / "temurin-build"
    build.mkdir()
    build_archive, how = commit_archive_of(PIN["build_scripts"]["repository"], scripts,
                                           build / f"temurin-build-{scripts}.tar.gz")
    report.append(f"- Temurin build scripts `temurin-build-{scripts}.tar.gz`, from the commit named "
                  f"in Adoptium's metadata, obtained by {how}. The Windows build's configure and make "
                  f"arguments are in `openjdk/{PIN['jdk']['file']}.json`.")

    # How OfficeFlow derived its runtime from the JDK.
    officeflow = stage / "officeflow"
    officeflow.mkdir()
    for relative in ("packaging/windows/build-zip.ps1", "packaging/windows/fetch-jdk.ps1",
                     "packaging/runtime/temurin-21.json", "packaging/runtime/build_source_archive.py"):
        shutil.copy2(ROOT / relative, officeflow / Path(relative).name)

    files = sorted(p for p in stage.rglob("*") if p.is_file())
    checksums = "\n".join(f"| `{p.relative_to(stage).as_posix()}` | {p.stat().st_size:,} | `{sha256(p)}` |"
                          for p in files)
    provenance = f"""# Java runtime provenance for OfficeFlow {version} (Windows x64)

The `runtime` folder installed by `OfficeFlow-Setup-{version}-x64.exe` was created with `jlink` from
the {PIN['vendor']} {PIN['distribution']} JDK **{PIN['version']}** for Windows x64
(`{PIN['jdk']['file']}`, SHA-256 `{PIN['jdk']['sha256']}`), downloaded from
{PIN['release_page']} and verified before use (`officeflow/fetch-jdk.ps1`). The exact `jlink`
command and module list are in `officeflow/build-zip.ps1`; the module list for this build is
also printed in the build log.

The runtime is licensed under the GNU General Public License, version 2, with the Classpath
Exception. The licence, the exception and third-party notices are in the source tree (`LICENSE`,
`ASSEMBLY_EXCEPTION`, `ADDITIONAL_LICENSE_INFO`) and in the runtime's `legal` folder.

## Contents

- `openjdk/` - Adoptium's official source tarball for this build, with its checksum, metadata
  (including the full configure and make arguments) and signature, plus the metadata, checksum
  and signature of the Windows JDK the runtime was made from.
- `temurin-build/` - the Temurin build scripts at the commit Adoptium recorded for this build.
- `officeflow/` - the scripts OfficeFlow uses to fetch the JDK, create the runtime with `jlink`
  and build this archive.

## Verification (generated {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC)

{chr(10).join(report)}

## Checksums

| File | Bytes | SHA-256 |
| --- | ---: | --- |
{checksums}
"""
    (stage / "PROVENANCE.md").write_text(provenance, encoding="utf-8")
    (stage / "README.txt").write_text(
        f"Source code for the Java runtime bundled with OfficeFlow {version} for Windows.\n"
        "See PROVENANCE.md for what is included, where it came from and how it was verified.\n",
        encoding="utf-8")

    archive = output / f"{name}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(p for p in stage.rglob("*") if p.is_file()):
            # Already-compressed archives are stored as they are.
            method = zipfile.ZIP_STORED if path.suffix in (".gz", ".zip") else zipfile.ZIP_DEFLATED
            bundle.write(path, f"{name}/{path.relative_to(stage).as_posix()}", compress_type=method)
    digest = sha256(archive)
    (output / f"{name}.zip.sha256").write_text(f"{digest}  {name}.zip\n", encoding="ascii")
    shutil.copy2(stage / "PROVENANCE.md", output / f"{name}-PROVENANCE.md")
    shutil.rmtree(work)
    shutil.rmtree(stage)
    size = archive.stat().st_size / 1e6
    summary = " ".join(line.lstrip("- ") for line in report if line.startswith("- File-by-file"))
    print(f"::notice title=Runtime source archive::{name}.zip ({size:.1f} MB) SHA-256 {digest}")
    print(f"::notice title=Runtime source verification::{summary}")


if __name__ == "__main__":
    main()
