"""Creates or updates the draft GitHub Release for this version and attaches its files.

Run by CI with GITHUB_TOKEN (contents: write):
    python3 packaging/release/update_draft_release.py [--replace-all] <tag> <notes.md> <file>...

It never publishes a release, and it stops without changes if the tag already belongs to a
published release. Existing assets with the same names on the draft are replaced; with
--replace-all, any other assets on the draft are removed.
"""
from pathlib import Path
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://api.github.com"
REPOSITORY = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GITHUB_TOKEN"]


def call(method, url, data=None, content_type="application/json"):
    body = json.dumps(data).encode() if isinstance(data, dict) else data
    request = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "Content-Type": content_type})
    with urllib.request.urlopen(request, timeout=600) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def main():
    arguments = sys.argv[1:]
    replace_all = arguments[:1] == ["--replace-all"]
    if replace_all:
        arguments = arguments[1:]
    tag, notes, files = arguments[0], Path(arguments[1]), [Path(p) for p in arguments[2:]]
    releases, page = [], 1
    while True:
        batch = call("GET", f"{API}/repos/{REPOSITORY}/releases?per_page=100&page={page}")
        releases += batch
        if len(batch) < 100:
            break
        page += 1
    matching = [r for r in releases if r["tag_name"] == tag]
    if any(not r["draft"] for r in matching):
        sys.exit(f"{tag} is already a published release; not changing it.")
    details = {"tag_name": tag, "target_commitish": os.environ["GITHUB_SHA"],
               "name": f"OfficeFlow {tag.lstrip('v')}",
               "body": notes.read_text(encoding="utf-8"), "draft": True, "prerelease": False}
    if matching:
        release = call("PATCH", f"{API}/repos/{REPOSITORY}/releases/{matching[0]['id']}", details)
        print(f"Updated draft release {release['id']} for {tag}")
    else:
        release = call("POST", f"{API}/repos/{REPOSITORY}/releases", details)
        print(f"Created draft release {release['id']} for {tag}")
    assert release["draft"], "The release must stay a draft"

    existing = {asset["name"]: asset["id"] for asset in release.get("assets", [])}
    for path in files:
        if path.name in existing:
            call("DELETE", f"{API}/repos/{REPOSITORY}/releases/assets/{existing[path.name]}")
        upload = (f"https://uploads.github.com/repos/{REPOSITORY}/releases/{release['id']}/assets"
                  f"?name={urllib.parse.quote(path.name)}")
        asset = call("POST", upload, path.read_bytes(), "application/octet-stream")
        print(f"Attached {asset['name']} ({asset['size']:,} bytes)")
    if replace_all:
        # Remove files from earlier drafts that are not part of this release (draft only).
        uploaded = {path.name for path in files}
        for asset in call("GET", f"{API}/repos/{REPOSITORY}/releases/{release['id']}")["assets"]:
            if asset["name"] not in uploaded:
                call("DELETE", f"{API}/repos/{REPOSITORY}/releases/assets/{asset['id']}")
                print(f"Removed {asset['name']} from the draft")
    final = call("GET", f"{API}/repos/{REPOSITORY}/releases/{release['id']}")
    assert final["draft"], "The release must stay a draft"
    names = sorted(asset["name"] for asset in final["assets"])
    print(f"::notice title=Draft release::{final['name']} (draft, unpublished, tag {tag} not yet "
          f"created): {', '.join(names)}")


if __name__ == "__main__":
    main()
