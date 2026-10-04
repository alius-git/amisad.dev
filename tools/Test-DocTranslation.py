# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Check source currentness and integrity of the two local pt-BR documents.

The explicit --record-machine mode records machine origin. Currentness and
integrity checks do not certify native or professional translation quality.
"""

import sys

sys.dont_write_bytecode = True

import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

DOCUMENTS = ("poc/test.md", "poc/usernames.md")
REPOSITORY = "amisad.dev"
SCHEMA = "yuruna.doc-translations/v1"
MANIFEST = "globalization/manifests/doc-translations.json"


def document_hash(raw):
    text = raw.decode("utf-8-sig")
    version = r"\d{4}\.\d{2}\.\d{2}(?:\.\d+)?"
    text = re.sub(r"(?m)^(Last review: )" + version + r"$", r"\1<version>", text)
    text = re.sub(r"(alissonsol/yuruna/)refs/tags/" + version,
                  r"\1refs/tags/<version>", text)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def translated_path(source):
    return "docs/pt-BR/" + source


def rooted(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root):
        raise ValueError("Path escapes the repository: " + relative)
    return path


def markdown_shape(text):
    text = text.replace("\r\n", "\n")
    blocks, prose_lines, active = [], [], []
    marker = None
    for line in text.splitlines(keepends=True):
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})([^\n]*)", line)
        if marker is None and fence:
            marker = fence[1]
            active = [line]
        elif marker is not None:
            active.append(line)
            if (fence and fence[1][0] == marker[0] and
                    len(fence[1]) >= len(marker) and not fence[2].strip()):
                blocks.append("".join(active))
                marker, active = None, []
        else:
            prose_lines.append(line)
    if marker is not None:
        raise ValueError("Unclosed Markdown code fence")
    prose = "".join(prose_lines)
    headings = re.findall(r"(?m)^(#{1,6})\s+(.+)$", prose)
    return {
        "fenced code": blocks,
        "inline literals": collections.Counter(re.findall(r"(?<!`)`([^`\n]+)`(?!`)", text)),
        "heading hierarchy": [len(level) for level, title in headings],
        "numeric tokens": collections.Counter(re.findall(r"(?<!\w)\d+(?:[.,]\d+)*(?!\w)", text)),
        "legal notices": re.findall(r"(?m)^(?:LICENSEURI|Copyright).*?$", text),
        "table structure": [line.count("|") for line in prose.splitlines()
                            if line.strip().startswith("|")],
        "headings": headings,
        "anchors": re.findall(r'<a\s+id="([^"]+)"[^>]*>', text),
        "links": re.findall(r"\]\(([^)\s]+)", prose),
    }


def heading_slug(heading):
    heading = re.sub(r"<[^>]+>", "", heading).lower()
    heading = re.sub(r"[^\w\-\s]", "", heading)
    return heading.replace(" ", "-")


def fragment_exists(target, fragment):
    shape = markdown_shape(target.read_bytes().decode("utf-8-sig"))
    return fragment in shape["anchors"] or fragment in {
        heading_slug(title) for level, title in shape["headings"]
    }


def link_identity(root, parent, destination, prefer_translation):
    uri = urlsplit(destination)
    if uri.scheme or uri.netloc:
        return destination
    file = unquote(uri.path)
    target = parent if not file else (parent.parent / file).resolve()
    if not target.is_relative_to(root):
        raise ValueError("Link escapes the repository: " + destination)
    if prefer_translation and target.is_file():
        relative = target.relative_to(root).as_posix()
        if relative in DOCUMENTS:
            target = root / translated_path(relative)
    return (target, unquote(uri.fragment))


def check_document(root, source, row):
    original = rooted(root, source)
    translated = rooted(root, translated_path(source))
    if not original.is_file() or not translated.is_file():
        return [source + ": source or translation is missing"]
    raw = original.read_bytes()
    src = markdown_shape(raw.decode("utf-8-sig"))
    dst = markdown_shape(translated.read_bytes().decode("utf-8-sig"))
    issues = []
    for key in ("fenced code", "inline literals", "heading hierarchy", "numeric tokens", "legal notices", "table structure"):
        if src[key] != dst[key]:
            issues.append(source + ": " + key + " differ")
    if not set(src["anchors"]).issubset(dst["anchors"]):
        issues.append(source + ": an existing source HTML anchor is missing")
    expected = [link_identity(root, original, link, True) for link in src["links"]]
    actual = [link_identity(root, translated, link, False) for link in dst["links"]]
    if collections.Counter(expected) != collections.Counter(actual):
        issues.append(source + ": relative link targets or fragments differ")
    for link in actual:
        if isinstance(link, str):
            continue  # Absolute URLs are compared byte for byte, never fetched.
        target, fragment = link
        if not target.exists():
            issues.append(source + ": local link target is missing: " + str(target))
        elif fragment and target.is_file() and not fragment_exists(target, fragment):
            issues.append(source + ": local link fragment is missing: " + fragment)
    if row is None:
        issues.append(source + ": translation is not recorded")
    elif row["sourceHash"] != document_hash(raw):
        issues.append(source + ": recorded source is stale")
    return issues


def load_manifest(path):
    if not path.exists():
        return {"schema": SCHEMA, "documents": []}
    manifest = json.loads(path.read_bytes())
    if manifest.get("schema") != SCHEMA or not isinstance(manifest.get("documents"), list):
        raise ValueError("Unsupported local translation manifest")
    seen = set()
    for row in manifest["documents"]:
        source = row.get("source")
        if row.get("repo") != REPOSITORY or source not in DOCUMENTS or row.get("locale") != "pt-BR":
            raise ValueError("Unexpected local translation identity")
        if source in seen:
            raise ValueError("Duplicate local translation identity")
        seen.add(source)
        if row.get("translated") != translated_path(source):
            raise ValueError("Unexpected translated path: " + source)
        if not re.fullmatch(r"[0-9a-f]{64}", row.get("sourceHash", "")):
            raise ValueError("Invalid source digest: " + source)
        if row.get("origin") not in (None, "machine"):
            raise ValueError("Unsupported provenance: " + source)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source", action="append", choices=DOCUMENTS)
    parser.add_argument("--record-machine", action="store_true",
                        help="Explicitly record selected complete drafts as machine origin")
    args = parser.parse_args()
    root = args.root.resolve()
    selected = args.source or list(DOCUMENTS)
    if args.record_machine and not args.source:
        parser.error("--record-machine requires explicit --source selections")
    manifest_path = rooted(root, MANIFEST)
    manifest = load_manifest(manifest_path)
    rows = {row["source"]: row for row in manifest["documents"]}
    findings = []
    for source in selected:
        row = rows.get(source)
        if args.record_machine:
            row = {"repo": REPOSITORY, "source": source, "locale": "pt-BR",
                   "translated": translated_path(source),
                   "sourceHash": document_hash(rooted(root, source).read_bytes()),
                   "origin": "machine"}
        issues = check_document(root, source, row)
        findings.extend(issues)
        if not issues and args.record_machine:
            rows[source] = row
        elif not issues and row.get("origin") == "machine":
            print(source + ": current machine draft; professional/native review not certified")
    if findings:
        print("\n".join(findings))
        return 1
    if args.record_machine:
        # This command can only set machine origin; it has no accepted/professional mode.
        manifest["documents"] = sorted(rows.values(), key=lambda row: row["source"])
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"Checked {len(selected)} local document(s); 0 problem(s).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Cannot evaluate local translations: " + str(error), file=sys.stderr)
        sys.exit(2)
