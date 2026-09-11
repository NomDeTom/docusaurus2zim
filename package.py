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
import json
import pathlib
import sys
import urllib.parse

from bs4 import BeautifulSoup
from zimscraperlib.filesystem import get_file_mimetype
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

    def __init__(self, root: pathlib.Path, filepath: pathlib.Path, selector: str):
        mimetype = get_file_mimetype(filepath)
        # Most web files are plain text to libmagic; trust the extension for those.
        if mimetype.startswith("text/"):
            mimetype = get_mime_for_name(filepath)
        title, index_data = index_for(filepath, mimetype, selector)
        super().__init__(
            filepath=filepath,
            path=filepath.relative_to(root).as_posix(),
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
    blob: list[str] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in TEXT_SCAN_SUFFIXES:
            continue
        rel = path.relative_to(root).as_posix()
        if any(rel.startswith(p) for p in prefixes):
            continue
        blob.append(path.read_text(encoding="utf-8", errors="replace"))
    haystack = "\n".join(blob)

    keep: set[str] = set()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if not any(rel.startswith(p) for p in prefixes):
            continue
        if rel in haystack or urllib.parse.quote(rel) in haystack:
            keep.add(rel)
    return keep


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

    illustration = root / args.illustration
    metadata = StandardMetadataList(
        Name=NameMetadata(args.name),
        Language=LanguageMetadata(args.language),
        Title=TitleMetadata(args.title),
        Creator=CreatorMetadata(args.creator),
        Publisher=PublisherMetadata(args.publisher),
        Date=DateMetadata(datetime.date.today()),
        Illustration_48x48_at_1=DefaultIllustrationMetadata(illustration.read_bytes()),
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
            creator.add_item(PageItem(root, path, args.index_selector))
            added_paths.add(rel)
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
