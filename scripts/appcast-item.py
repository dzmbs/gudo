"""Adds one release to the Mac app's Sparkle feed (site/appcast.xml), newest first.

    appcast-item.py <appcast> --title T --version BUILD --short-version V --minimum-system M
                    --release-notes URL --url URL --length BYTES --signature EDDSA

Earlier releases stay; an item with the same build number is replaced. Run by
scripts/release-mac.sh after the DMG is notarized, stapled and signed.
"""

from __future__ import annotations

import argparse
import email.utils
import re
import sys
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ITEM = re.compile(r"^[ \t]*<item>.*?</item>[ \t]*\n", re.DOTALL | re.MULTILINE)


def item_xml(args: argparse.Namespace) -> str:
    published = email.utils.format_datetime(email.utils.localtime(), usegmt=False)
    return (
        "    <item>\n"
        f"      <title>{escape(args.title)}</title>\n"
        f"      <pubDate>{published}</pubDate>\n"
        f"      <sparkle:version>{escape(args.version)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{escape(args.short_version)}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{escape(args.minimum_system)}</sparkle:minimumSystemVersion>\n"
        f"      <sparkle:releaseNotesLink>{escape(args.release_notes)}</sparkle:releaseNotesLink>\n"
        + (f"      <description>{escape(args.description)}</description>\n" if args.description else "")
        + f"      <enclosure url={quoteattr(args.url)} length={quoteattr(str(args.length))}"
        ' type="application/octet-stream"\n'
        f"                 sparkle:edSignature={quoteattr(args.signature)} />\n"
        "    </item>\n"
    )


def build_number(item: str) -> str | None:
    match = re.search(r"<sparkle:version>(.*?)</sparkle:version>", item)
    return match.group(1).strip() if match else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    for option in ("title", "version", "short-version", "minimum-system", "release-notes", "url", "signature"):
        parser.add_argument(f"--{option}", required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--description", help="short plain-text notes, one change per line")
    args = parser.parse_args()

    with open(args.appcast, encoding="utf-8") as file:
        feed = file.read()
    kept = [item for item in ITEM.findall(feed) if build_number(item) != args.version]
    feed = ITEM.sub("", feed)
    closing = feed.index("  </channel>")
    feed = feed[:closing] + item_xml(args) + "".join(kept) + feed[closing:]

    root = ElementTree.fromstring(feed.encode("utf-8"))
    versions = [element.text for element in root.iter(f"{{{SPARKLE}}}version")]
    if versions[0] != args.version or len(versions) != len(set(versions)):
        sys.exit("error: the feed did not come out as expected")
    with open(args.appcast, "w", encoding="utf-8") as file:
        file.write(feed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
