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
        --repo jspanji/Swivel [--min-system 13.0] [--print-only] \
        [--notes-file CHANGELOG-section.md | --notes "text"]

Release notes matter: without a <description>, Sparkle's update dialog shows a
version number and an empty notes pane, which gives users no reason to click
Install.
"""
import argparse
import datetime
import sys

MARKER = "<!-- SPARKLE:NEW-ITEMS-BELOW -->"


def md_to_html(md: str) -> str:
    """Minimal Markdown → HTML for release notes.

    Sparkle renders <description> in a web view, so Markdown passed through
    verbatim would display literal '-' bullets and '###' headings. This covers
    what a Keep-a-Changelog section actually uses: headings, bullet lists,
    bold, and inline code. Deliberately dependency-free — CI shouldn't need a
    pip install to cut a release.

    Wrapped lines matter: CHANGELOG bullets routinely continue onto indented
    following lines, and treating those as new blocks shreds every entry into
    a fragment plus an orphan paragraph.
    """
    import html as _html
    import re as _re

    def inline(text: str) -> str:
        text = _html.escape(text)
        text = _re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = _re.sub(r"`([^`]+?)`", r"<code>\1</code>", text)
        return text

    blocks = []          # ("h", level, text) | ("ul", [items]) | ("p", text)
    for raw in md.strip().splitlines():
        line = raw.rstrip()
        if not line.strip():
            blocks.append(("gap", None))
            continue

        stripped = line.lstrip()
        is_indented = line[:1].isspace()
        is_bullet = stripped.startswith("- ") or stripped.startswith("* ")

        if stripped.startswith("#"):
            level = min(len(stripped) - len(stripped.lstrip("#")), 6)
            blocks.append(("h", level, stripped.lstrip("#").strip()))
        elif is_bullet:
            if blocks and blocks[-1][0] == "ul":
                blocks[-1][1].append(stripped[2:])
            else:
                blocks.append(("ul", [stripped[2:]]))
        elif is_indented and blocks and blocks[-1][0] == "ul":
            # Continuation of the previous bullet. A trailing hyphen means the
            # author split a compound word across lines ("auto-\nupdate"), so
            # rejoin without a space; otherwise a space is the word boundary.
            prev = blocks[-1][1][-1]
            sep = "" if prev.endswith("-") and stripped[:1].islower() else " "
            blocks[-1][1][-1] = prev + sep + stripped
        elif blocks and blocks[-1][0] == "p":
            blocks[-1] = ("p", blocks[-1][1] + " " + stripped)
        else:
            blocks.append(("p", stripped))

    out = []
    for b in blocks:
        if b[0] == "h":
            out.append(f"<h{b[1]}>{inline(b[2])}</h{b[1]}>")
        elif b[0] == "ul":
            out.append("<ul>")
            out.extend(f"<li>{inline(i)}</li>" for i in b[1])
            out.append("</ul>")
        elif b[0] == "p":
            out.append(f"<p>{inline(b[1])}</p>")
    return "\n".join(out)


def build_item(args, pubdate: str) -> str:
    url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"{args.tag}/Swivel-{args.version}.zip"
    )
    notes = args.notes or ""
    if args.notes_file:
        try:
            with open(args.notes_file, encoding="utf-8") as nf:
                notes = nf.read()
        except OSError as exc:
            sys.stderr.write(f"warning: couldn't read {args.notes_file}: {exc}\n")
    description = ""
    if notes.strip():
        # ']]>' would terminate the CDATA section early; split it so the
        # payload survives intact.
        body = md_to_html(notes).replace("]]>", "]]]]><![CDATA[>")
        description = (
            "            <description><![CDATA[\n"
            f"{body}\n"
            "            ]]></description>\n"
        )
    return (
        "        <item>\n"
        f"            <title>{args.version}</title>\n"
        f"            <pubDate>{pubdate}</pubDate>\n"
        f"            <sparkle:version>{args.build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>\n"
        f"            <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>\n"
        f"{description}"
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
    p.add_argument("--notes", default=None, help="release notes (Markdown)")
    p.add_argument("--notes-file", default=None,
                   help="file containing release notes (Markdown); wins over --notes")
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
