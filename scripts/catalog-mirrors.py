#!/usr/bin/env python3
"""Bake the iOS Firmware Exhibit Collection on archive.org into the firmware catalog as a fallback source.

    scripts/catalog-mirrors.py [--metadata FILE]   # default: fetch https://archive.org/metadata/<collection>

For every entry whose IPSW the collection holds with the same sha1 and size (matched by file name, then by sha1),
source.mirrors gets that copy's archive.org URL, sha1 and bytes; a copy that differs (truncated uploads) is left out.
Other mirrors (BetaArchive RARs, other hosts) stay; mirrors are kept Apple, archive.org IPSW, RAR, other hosts. The app downloads source.url first, then each mirror
(FirmwareDownloads), and checks the sha1 of whatever it got. Rewrites only the "source" lines of
LightTouchMac/Resources/firmware-catalog.json; prints a line per entry.
"""
import argparse, json, re, urllib.request
from pathlib import Path

COLLECTION = "iOS_Firmware_Exhibit_Collection"
DOWNLOAD = f"https://archive.org/download/{COLLECTION}/"
CATALOG = Path(__file__).resolve().parents[1] / "LightTouchMac/Resources/firmware-catalog.json"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", help="a saved copy of the collection's metadata JSON")
    args = parser.parse_args()
    raw = Path(args.metadata).read_bytes() if args.metadata else \
        urllib.request.urlopen(f"https://archive.org/metadata/{COLLECTION}", timeout=120).read()
    files = [f for f in json.loads(raw)["files"] if f["name"].endswith(".ipsw")]
    by_name, by_sha1 = {f["name"]: f for f in files}, {f.get("sha1"): f for f in files}

    entries = json.loads(CATALOG.read_text())["entries"]
    sources = {}
    for e in entries:
        src = dict(e["source"])
        name = src["url"].rsplit("/", 1)[-1]
        found = by_name.get(name) or by_sha1.get(src["sha1"])
        same = bool(found) and found.get("sha1") == src["sha1"] and int(found["size"]) == src["bytes"]
        url = DOWNLOAD + found["name"] if found else None
        mirrors = [m for m in src.get("mirrors", []) if not m["url"].startswith(DOWNLOAD)]
        if same and url != src["url"]:
            mirrors.append({"url": url, "sha1": found["sha1"], "bytes": int(found["size"])})
        # Most reliable first: Apple, archive.org IPSWs, archive.org RARs, other hosts.
        mirrors.sort(key=lambda m: 0 if "apple.com" in m["url"] else 3 if "archive.org" not in m["url"] else 2 if m.get("kind") == "rar" else 1)
        if mirrors:
            src["mirrors"] = mirrors
        else:
            src.pop("mirrors", None)
        sources[e["id"]] = src
        state = "primary" if url == src["url"] else "added" if same else \
            f"differs (sha1 {found.get('sha1')}, {found['size']} bytes)" if found else "not in the collection"
        print(f"{e['id']:16} archive.org: {state}")

    # The file keeps its hand layout: one `"source": {...},` line per entry, in entry order.
    lines, ids = CATALOG.read_text().split("\n"), iter(e["id"] for e in entries)
    for i, line in enumerate(lines):
        if m := re.fullmatch(r'(\s*"source": ).*?(,?)', line):
            lines[i] = m[1] + json.dumps(sources[next(ids)], ensure_ascii=False) + m[2]
    assert next(ids, None) is None, "a catalog entry without a one-line source"
    CATALOG.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
