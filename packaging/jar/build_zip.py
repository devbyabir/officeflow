"""Builds OfficeFlow-<version>.zip for GitHub Releases: the runnable JAR, its web files, a
Quick Start and the licence files. It runs with an installed Java 17 or newer:
    java -jar officeflow.jar

Run from the repository root after `mvn -f server/pom.xml package`:
    python3 packaging/jar/build_zip.py dist
"""
from pathlib import Path
import hashlib
import re
import shutil
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = re.compile(r"\.(exe|dll|cmd|bat|ps1|psm1|vbs|vbe|wsf|wsh|lnk|hta|msi|com|scr)$", re.IGNORECASE)


def crlf(source, target):
    text = source.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\n", "\r\n")
    target.write_bytes(text.encode("utf-8"))


def main():
    version = re.search(r"<artifactId>officeflow</artifactId>\s*<version>([^<]+)</version>",
                        (ROOT / "server/pom.xml").read_text(encoding="utf-8")).group(1)
    name = f"OfficeFlow-{version}"
    jar = ROOT / f"server/target/officeflow-{version}.jar"
    if not jar.is_file():
        sys.exit(f"Build first: mvn -f server/pom.xml package ({jar} is missing)")
    with zipfile.ZipFile(jar) as archive:
        manifest = archive.read("META-INF/MANIFEST.MF").decode("utf-8")
    if "Main-Class: com.officeflow.App" not in manifest:
        sys.exit("officeflow.jar has no Main-Class: java -jar would not start it")

    output = Path(sys.argv[1]).resolve()
    stage = output / name
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    shutil.copy2(jar, stage / "officeflow.jar")
    shutil.copytree(ROOT / "docs/site", stage / "site")
    shutil.copytree(ROOT / "packaging/windows/licenses", stage / "licenses")
    crlf(ROOT / "packaging/jar/Quick Start.txt", stage / "Quick Start.txt")
    crlf(ROOT / "packaging/jar/THIRD-PARTY-NOTICES.txt", stage / "THIRD-PARTY-NOTICES.txt")
    crlf(ROOT / "LICENSE", stage / "LICENSE.txt")
    crlf(ROOT / "TERMS.md", stage / "TERMS.txt")

    files = sorted(p for p in stage.rglob("*") if p.is_file())
    forbidden = [p.relative_to(stage).as_posix() for p in files if FORBIDDEN.search(p.name)]
    if forbidden:
        sys.exit(f"The ZIP must not contain executables or scripts: {forbidden}")
    loose_js = [p.relative_to(stage).as_posix() for p in files
                if p.suffix == ".js" and not p.relative_to(stage).as_posix().startswith("site/")]
    if loose_js:
        sys.exit(f".js files outside site/: {loose_js}")

    archive_path = output / f"{name}.zip"
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            bundle.write(path, f"{name}/{path.relative_to(stage).as_posix()}")
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (output / f"{name}.zip.sha256").write_text(f"{digest}  {name}.zip\n", encoding="ascii")
    shutil.rmtree(stage)
    top = sorted({p.relative_to(stage).parts[0] for p in files})
    print(f"::notice title=Release ZIP::{name}.zip ({archive_path.stat().st_size / 1e6:.1f} MB) "
          f"SHA-256 {digest}; contents: {', '.join(top)}; no executables or scripts")


if __name__ == "__main__":
    main()
