#!/usr/bin/env python3
"""Insert a signed Sparkle <item> into appcast.xml, newest-first.

Used by .github/workflows/release.yml after it builds + signs a release, but
deliberately a standalone, locally-testable script (the CI-only surface should
be as small as possible). It is idempotent: if the appcast already lists the
given short version, the file is left untouched.

The new item is inserted immediately below the marker line:

    <!-- SPARKLE:NEW-ITEMS-BELOW -->

The generated item XML is always printed to stdout so the caller can surface it
(e.g. in a CI run summary) even when the file can't be written/committed.

Usage:
    append_appcast_item.py \
        --appcast appcast.xml --version 1.1.0 --tag v1.1.0 \
        --build 5 --length 1436505 --sig "<edSignature>" \
        --repo jspanji/Swivel [--min-system 13.0] [--print-only]
"""
import argparse
import datetime
import sys

MARKER = "<!-- SPARKLE:NEW-ITEMS-BELOW -->"


def build_item(args, pubdate: str) -> str:
    url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"{args.tag}/Swivel-{args.version}.zip"
    )
    return (
        "        <item>\n"
        f"            <title>{args.version}</title>\n"
        f"            <pubDate>{pubdate}</pubDate>\n"
        f"            <sparkle:version>{args.build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>\n"
        f"            <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>\n"
        f'            <enclosure url="{url}" length="{args.length}"'
        ' type="application/octet-stream"'
        f' sparkle:edSignature="{args.sig}" />\n'
        "        </item>"
    )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", default="appcast.xml")
    p.add_argument("--version", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--sig", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--min-system", default="13.0")
    p.add_argument("--pubdate", default=None, help="RFC-822 date; defaults to now (UTC)")
    p.add_argument("--print-only", action="store_true",
                   help="print the item but don't modify the file")
    args = p.parse_args()

    pubdate = args.pubdate or datetime.datetime.now(
        datetime.timezone.utc
    ).strftime("%a, %d %b %Y %H:%M:%S +0000")

    item = build_item(args, pubdate)
    # Always emit the item so the caller has it regardless of file outcome.
    print(item)

    if args.print_only:
        return 0

    with open(args.appcast, encoding="utf-8") as f:
        src = f.read()

    if MARKER not in src:
        sys.stderr.write(f"error: marker {MARKER!r} not found in {args.appcast}\n")
        return 2

    needle = f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>"
    if needle in src:
        sys.stderr.write(f"note: appcast already lists {args.version}; unchanged\n")
        return 0

    src = src.replace(MARKER, MARKER + "\n" + item, 1)
    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(src)
    sys.stderr.write(f"inserted {args.version} into {args.appcast}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
