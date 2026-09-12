"""Package a built Docusaurus site into a ZIM.

Replaces a zimwriterfs invocation. Unlike zimwriterfs, which
indexes each page's whole rendered body, this attaches per-item index data: only
the text inside --index-selector is indexed, and PDFs get their text extracted.

Configuration comes from the consuming site's docusaurus2zim.json (its "defaults"
block); every flag there can be overridden on the command line.
"""

from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import io
import json
import pathlib
import struct
import sys
import urllib.parse
import zlib

from bs4 import BeautifulSoup
from zimscraperlib.filesystem import get_file_mimetype
from zimscraperlib.image.conversion import convert_image, convert_svg2png
from zimscraperlib.image.probing import format_for
from zimscraperlib.image.transformation import resize_image
from zimscraperlib.types import get_mime_for_name
from zimscraperlib.zim.creator import Creator
from zimscraperlib.zim.indexing import IndexData, get_pdf_index_data
from zimscraperlib.zim.items import StaticItem
from zimscraperlib.zim.metadata import (
    CreatorMetadata,
    DateMetadata,
    DefaultIllustrationMetadata,
    DescriptionMetadata,
    LanguageMetadata,
    LongDescriptionMetadata,
    NameMetadata,
    PublisherMetadata,
    StandardMetadataList,
    TagsMetadata,
    TitleMetadata,
)

DEFAULT_CONFIG = pathlib.Path("docusaurus2zim.json")
TEXT_SCAN_SUFFIXES = (".html", ".js", ".css", ".json", ".xml", ".webmanifest")
RENDERED_SUFFIXES = (".html", ".css")


def load_defaults(config: pathlib.Path) -> dict:
    """Site settings come from the consuming repo's config, not from this tool."""
    if not config.exists():
        return {}
    return json.loads(config.read_text(encoding="utf-8")).get("defaults", {})


class PageItem(StaticItem):
    """A built file, indexed by its main content rather than its whole body.

    Index data is computed up front and handed to StaticItem rather than supplied by
    overriding get_indexdata(): the base constructor calls that method while building
    the item, before a subclass __init__ has had a chance to set anything up.
    """

    def __init__(self, root: pathlib.Path, filepath: pathlib.Path, selector: str, path: str):
        mimetype = get_file_mimetype(filepath)
        # Most web files are plain text to libmagic; trust the extension for those.
        if mimetype.startswith("text/"):
            mimetype = get_mime_for_name(filepath)
        title, index_data = index_for(filepath, mimetype, selector)
        super().__init__(
            filepath=filepath,
            path=path,
            title=title,
            mimetype=mimetype,
            index_data=index_data,
        )


def index_for(
    filepath: pathlib.Path, mimetype: str, selector: str
) -> tuple[str, IndexData | None]:
    """Title and index data for one built file; (title, None) leaves libzim's default."""
    if mimetype == "application/pdf":
        return filepath.stem, get_pdf_index_data(filepath=filepath)
    if not mimetype.startswith("text/html"):
        return filepath.name, None
    soup = BeautifulSoup(
        filepath.read_text(encoding="utf-8", errors="replace"), "lxml"
    )
    title = soup.title.get_text(strip=True) if soup.title else filepath.name
    node = soup.select_one(selector) if selector else soup.body
    # A page whose selector matches nothing still deserves its title indexed.
    content = node.get_text(" ", strip=True) if node else ""
    return title, IndexData(title=title, content=content)


def referenced_paths(root: pathlib.Path, prefixes: list[str]) -> set[str]:
    """Relative paths under `prefixes` that something outside them mentions."""
    if not prefixes:
        return set()
    rendered: list[str] = []
    scripted: list[str] = []
    twins: set[str] = set()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if any(rel.startswith(p) for p in prefixes):
            continue
        # Docusaurus copies every imported image to assets/ under a hashed name, so
        # a static original may survive only as a mention in a page's raw source.
        twins.add(hashlib.sha1(path.read_bytes()).hexdigest())
        if path.suffix.lower() in RENDERED_SUFFIXES:
            rendered.append(path.read_text(encoding="utf-8", errors="replace"))
        elif path.suffix.lower() in TEXT_SCAN_SUFFIXES:
            scripted.append(path.read_text(encoding="utf-8", errors="replace"))
    rendered_blob = "\n".join(rendered)
    scripted_blob = "\n".join(scripted)

    keep: set[str] = set()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if not any(rel.startswith(p) for p in prefixes):
            continue
        forms = (rel, urllib.parse.quote(rel))
        if any(f in rendered_blob for f in forms):
            keep.add(rel)
        elif any(f in scripted_blob for f in forms):
            # A hashed twin already serves this file; the mention is markdown source.
            if hashlib.sha1(path.read_bytes()).hexdigest() not in twins:
                keep.add(rel)
    return keep


ILLUSTRATION_SIZE = 48


def favicon_path(root: pathlib.Path, main_path: str) -> pathlib.Path | None:
    """The built file behind the main page's <link rel=icon>, if it is in the tree."""
    page = root / main_path
    if not page.is_file():
        return None
    soup = BeautifulSoup(page.read_text(encoding="utf-8", errors="replace"), "html.parser")
    link = soup.find("link", rel=lambda r: r and "icon" in r)
    href = link.get("href") if link else None
    if not href or "://" in href:
        return None
    parts = urllib.parse.unquote(href.split("?")[0]).strip("/").split("/")
    # The href carries the site's baseUrl; peel leading segments until it resolves.
    for i in range(len(parts)):
        candidate = root.joinpath(*parts[i:])
        if candidate.is_file():
            return candidate
    return None


def png_48(src: pathlib.Path) -> bytes:
    """`src` (SVG, PNG, ICO, ...) rendered as a 48x48 PNG."""
    out = io.BytesIO()
    if src.suffix.lower() == ".svg":
        convert_svg2png(src, out, ILLUSTRATION_SIZE, ILLUSTRATION_SIZE)
        return out.getvalue()
    if format_for(src, from_suffix=False) == "PNG":
        from PIL import Image

        with Image.open(src) as img:
            if img.size == (ILLUSTRATION_SIZE, ILLUSTRATION_SIZE):
                return src.read_bytes()
    png = io.BytesIO()
    convert_image(src, png, fmt="PNG")
    resize_image(png, ILLUSTRATION_SIZE, ILLUSTRATION_SIZE, dst=out, method="cover")
    return out.getvalue()


def flat_png_48(rgb: tuple[int, int, int] = (0x67, 0xEA, 0x94)) -> bytes:
    """Last resort: a solid 48x48 square, so the ZIM still has a valid illustration."""
    w = h = ILLUSTRATION_SIZE
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def illustration_bytes(root: pathlib.Path, explicit: pathlib.Path, main_path: str) -> bytes:
    """A site-supplied PNG wins; else the site's favicon, rendered to 48x48; else flat."""
    if explicit.is_file():
        print(f"==> illustration: {explicit.relative_to(root).as_posix()}")
        return explicit.read_bytes()
    icon = favicon_path(root, main_path)
    if icon:
        try:
            data = png_48(icon)
            print(f"==> illustration: favicon {icon.relative_to(root).as_posix()}")
            return data
        except Exception as exc:  # noqa: BLE001 - any rasteriser failure means fall back
            print(f"==> illustration: favicon {icon.name} unusable ({exc}); using placeholder")
    else:
        print("==> illustration: no favicon found; using placeholder")
    return flat_png_48()


def main() -> int:
    # The site config is read first: it decides which other flags exist at all.
    pre = argparse.ArgumentParser(add_help=False)
    pre.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    defaults = load_defaults(pre.parse_known_args()[0].config)

    parser = argparse.ArgumentParser(parents=[pre], description=__doc__)
    parser.add_argument("--build-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--redirects", type=pathlib.Path)
    parser.add_argument("--illustration", default="zim-illustration.png")
    parser.add_argument("--main-path", default="index.html")
    for flag, default in defaults.items():
        parser.add_argument(f"--{flag.replace('_', '-')}", default=default)
    args = parser.parse_args()

    root: pathlib.Path = args.build_dir
    if not root.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    excludes = [p for p in str(args.exclude).split(",") if p]
    prefixes = [p for p in str(args.prune_prefixes).split(",") if p]
    keep = referenced_paths(root, prefixes)
    if prefixes:
        print(f"==> prune: {len(keep)} referenced files under {','.join(prefixes)}")

    illustration = illustration_bytes(root, root / args.illustration, args.main_path)
    metadata = StandardMetadataList(
        Name=NameMetadata(args.name),
        Language=LanguageMetadata(args.language),
        Title=TitleMetadata(args.title),
        Creator=CreatorMetadata(args.creator),
        Publisher=PublisherMetadata(args.publisher),
        Date=DateMetadata(datetime.date.today()),
        Illustration_48x48_at_1=DefaultIllustrationMetadata(illustration),
        Description=DescriptionMetadata(args.description),
        LongDescription=(
            LongDescriptionMetadata(args.long_description)
            if getattr(args, "long_description", "")
            else None
        ),
        Tags=TagsMetadata(args.tags) if args.tags else None,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    creator = Creator(filename=args.output, main_path=args.main_path)
    creator.config_metadata(metadata)
    creator.config_indexing(True, args.language)

    added = skipped_excluded = skipped_pruned = 0
    skipped_bytes = 0
    added_paths: set[str] = set()
    asset_slashed: list[str] = []
    with creator:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if rel.startswith(".zim-") or rel == args.illustration:
                continue
            if any(fnmatch.fnmatch(rel, pat.replace("**", "*")) for pat in excludes):
                skipped_excluded += 1
                skipped_bytes += path.stat().st_size
                continue
            if any(rel.startswith(p) for p in prefixes) and rel not in keep:
                skipped_pruned += 1
                skipped_bytes += path.stat().st_size
                continue
            # A page lives at its route ("docs/intro/"), never at ".../index.html":
            # the client router only knows the route, and a 302 away from it would
            # hydrate into the site's own not-found page.
            zim_path = rel[: -len("index.html")] if rel.endswith("/index.html") else rel
            creator.add_item(PageItem(root, path, args.index_selector, zim_path))
            added_paths.add(zim_path)
            added += 1
            # trailingSlash decorates asset links too, so a page can point at
            # "file.pdf/". Nothing resolves that in a ZIM, so redirect it to the file.
            if not rel.endswith("index.html"):
                asset_slashed.append(rel)

        redirects = orphaned = 0
        for rel in asset_slashed:
            creator.add_redirect(f"{rel}/", rel, "")
            redirects += 1

        # A redirect to something we did not add would dangle, so drop it with its target.
        if args.redirects and args.redirects.exists():
            for line in args.redirects.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                source, title, target = line.split("\t")
                if target not in added_paths:
                    orphaned += 1
                    continue
                creator.add_redirect(source, target, title)
                redirects += 1

    print(
        f"==> packaged {added} items, {redirects} redirects "
        f"(excluded {skipped_excluded}, pruned {skipped_pruned}, "
        f"{skipped_bytes / 1048576:.1f} MB dropped, {orphaned} redirects orphaned)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
