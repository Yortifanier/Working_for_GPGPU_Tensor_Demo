#!/usr/bin/env python3
"""Recheck the uploaded PTX 9.4 PDF, inventory, and SM-document coverage.

Requires PyMuPDF (``import fitz``). Run from any working directory, for example:

  python docs/sm/check_instruction_inventory.py --pdf /path/to/ptx_isa_9.4.pdf
  python docs/sm/check_instruction_inventory.py --pdf /path/to/ptx_isa_9.4.pdf \
      --document docs/sm/SM_ARCHITECTURE.md --require-document

Coverage is explicit: one Markdown table row per instruction-description section,
with the section number in its own cell and at least two nonempty companion cells
(for example instruction name and disposition). A prose reference or a range of
section numbers does not claim coverage. {} and @ each need a control-syntax row.
Chapter 10 coverage can additionally be required with --require-special-registers.
An absent document is reported as pending unless --require-document is supplied.
This script writes its report; it never rewrites either source inventory.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys


HERE = Path(__file__).resolve().parent
EXPECTED = {
    "instruction_description_topics": 217,
    "actual_instruction_topics": 215,
    "control_syntax_topics": 2,
    "syntax_blocks": 217,
    "categories": 21,
    "special_register_sections": 35,
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def numbered_bookmarks(document) -> list[dict]:
    """The PDF bookmarks carry titles; hierarchy reconstructs the printed numbers."""
    bookmarks = document.get_toc()
    counters = [0] * max(level for level, _, _ in bookmarks)
    result = []
    for index, (level, title, page) in enumerate(bookmarks):
        counters[level - 1] += 1
        counters[level:] = [0] * (len(counters) - level)
        section = ".".join(map(str, counters[:level]))
        result.append({
            "section": section,
            "title": title,
            "pdf_page": page,
            "level": level,
            "leaf": not (index + 1 < len(bookmarks) and
                         bookmarks[index + 1][0] > level),
        })
    return result


def extract_chapter(document, bookmarks: list[dict], chapter: int,
                    errors: list[str]) -> list[dict]:
    pages = [page.get_text() for page in document]
    offsets = []
    current = 0
    for page in pages:
        offsets.append(current)
        current += len(page) + 1
    whole = "\n".join(pages)
    next_chapter = next(b for b in bookmarks if b["section"] == str(chapter + 1))
    chapter_end = offsets[next_chapter["pdf_page"] - 1]
    sections = []
    for bookmark in bookmarks:
        if not bookmark["section"].startswith(f"{chapter}."):
            continue
        section = dict(bookmark)
        body_page = pages[section["pdf_page"] - 1]
        match = re.search(r"(?m)^" + re.escape(section["section"]) +
                          r"\.?\s+(?!\d)", body_page)
        if match is None:
            errors.append(f"PDF body heading missing at bookmark: {section['section']}")
            continue
        section["body_start"] = offsets[section["pdf_page"] - 1] + match.start()
        sections.append(section)
    for index, section in enumerate(sections):
        end = sections[index + 1]["body_start"] if index + 1 < len(sections) else chapter_end
        section["body"] = whole[section["body_start"]:end]
        section["syntax_blocks"] = len(re.findall(r"(?m)^Syntax\s*$", section["body"]))
        section["predefined_syntax_blocks"] = len(re.findall(
            r"(?m)^Syntax \(predefined\)\s*$", section["body"]))
    return sections


def instruction_topic(section: dict) -> bool:
    return (section["section"].startswith("9.7.") and section["leaf"] and
            bool(re.search(r"instructions?: ", section["title"], re.IGNORECASE)))


def heading_names(title: str) -> list[str]:
    label = re.sub(r" \(deprecated\)$", "", title.split(": ", 1)[1])
    return re.split(r",\s*| / ", label)


def source_excerpt(body: str, label: str, end_labels: list[str]) -> str | None:
    """Reproduce the inventory's evidence extraction, without parsing legal tuples."""
    match = re.search(r"(?m)^" + re.escape(label) + r"\s*$", body)
    if match is None:
        return None
    rest = body[match.end():]
    stops = [end.start() for end_label in end_labels
             if (end := re.search(r"(?m)^" + re.escape(end_label) + r"\s*$", rest))]
    raw = (rest[:min(stops)] if stops else rest).replace("\uffff", "").replace("\u00ad", "")
    lines = []
    for line in raw.splitlines():
        value = line.strip()
        if (not value or value == "PTX ISA, Release 9.4" or
            "Chapter 9. Instruction Set" in value or value == "9.7. Instructions" or
            re.fullmatch(r"\(continues?d? (?:on next|from previous) page\)", value)):
            continue
        lines.append(line.rstrip())
    return "\n".join(lines).strip()


def table_section_rows(text: str) -> dict[str, list[dict]]:
    """Recognize exact section cells, not ranges, footnotes, or prose citations."""
    result: dict[str, list[dict]] = {}
    pattern = re.compile(r"(?:9\.7(?:\.\d+)+|10\.\d+)")
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith("|"):
            continue
        cells = [cell.strip() for cell in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        for index, cell in enumerate(cells):
            section = cell.strip("` ")
            if not pattern.fullmatch(section):
                continue
            companions = [value for cell_index, value in enumerate(cells)
                          if cell_index != index and value.strip("` ")]
            placeholder = bool(re.search(r"\b(?:TODO|TBD)\b|待补|占位", " ".join(companions), re.I))
            result.setdefault(section, []).append({
                "line": line_number,
                "companion_cells": companions,
                "valid_mapping_row": len(companions) >= 2 and not placeholder,
            })
    return result


def document_coverage(path: Path, topic_sections: set[str],
                      instruction_sections: set[str], controls: set[str],
                      all_isa_sections: set[str], special_sections: set[str],
                      require_document: bool, require_special: bool,
                      errors: list[str]) -> dict:
    if not path.is_file():
        if require_document or require_special:
            errors.append(f"Required SM document does not exist: {path}")
        return {
            "status": "pending_document",
            "path": str(path),
            "expected_instruction_description_sections": len(topic_sections),
            "mapped_sections": [],
            "missing_sections": sorted(topic_sections, key=section_key),
            "special_register_missing_sections": sorted(special_sections, key=section_key),
        }
    text = path.read_text(encoding="utf-8")
    rows = table_section_rows(text)
    mapped = {section for section, records in rows.items()
              if any(record["valid_mapping_row"] for record in records)}
    missing = topic_sections - mapped
    unknown = set(rows) - all_isa_sections
    invalid = {section: records for section, records in rows.items()
               if section in topic_sections and not any(r["valid_mapping_row"] for r in records)}
    special_missing = special_sections - mapped
    if missing:
        errors.append(f"SM document missing {len(missing)} explicit instruction-section mappings")
    if unknown:
        errors.append(f"SM document table contains unknown ISA section IDs: {sorted(unknown)}")
    if require_special and special_missing:
        errors.append(f"SM document missing {len(special_missing)} special-register-section mappings")
    return {
        "status": "pass" if not missing and not unknown and not (require_special and special_missing) else "fail",
        "path": str(path),
        "sha256": sha256(path),
        "mapping_rule": "Exact section cell in a Markdown table row, plus at least two nonempty companion cells and no TODO/TBD placeholder; prose/ranges do not count",
        "expected_instruction_description_sections": len(topic_sections),
        "mapped_instruction_description_sections": len(topic_sections & mapped),
        "mapped_actual_instruction_sections": len(instruction_sections & mapped),
        "mapped_control_syntax_sections": len(controls & mapped),
        "missing_sections": sorted(missing, key=section_key),
        "unknown_table_sections": sorted(unknown, key=section_key),
        "invalid_mapping_rows": invalid,
        "instruction_mapping_rows": {s: rows[s] for s in sorted(topic_sections & set(rows), key=section_key)},
        "duplicate_instruction_section_rows": {s: rows[s] for s in topic_sections & set(rows) if len(rows[s]) > 1},
        "special_register_coverage_required": require_special,
        "special_register_mapped_sections": sorted(special_sections & mapped, key=section_key),
        "special_register_missing_sections": sorted(special_missing, key=section_key),
    }


def section_key(section: str) -> tuple[int, ...]:
    return tuple(map(int, section.split(".")))


def run(args) -> dict:
    errors: list[str] = []
    report = {
        "checker": str(Path(__file__).resolve()),
        "checker_sha256": sha256(Path(__file__).resolve()),
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "expected_counts": EXPECTED,
        "errors": errors,
    }
    try:
        import fitz
        inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
        pdf = args.pdf or Path(inventory["source"]["uploaded_file_path"])
        report["source"] = {"pdf": str(pdf), "sha256": sha256(pdf),
                            "inventory": str(args.inventory),
                            "inventory_sha256": sha256(args.inventory),
                            "pymupdf_version": fitz.VersionBind}
        if report["source"]["sha256"] != inventory["source"]["sha256"]:
            errors.append("PDF SHA-256 does not match the uploaded-release source recorded by the inventory")
        with fitz.open(pdf) as document:
            bookmarks = numbered_bookmarks(document)
            chapter9 = extract_chapter(document, bookmarks, 9, errors)
            chapter10 = extract_chapter(document, bookmarks, 10, errors)
            report["source"]["physical_pdf_pages"] = len(document)
        topics = [section for section in chapter9 if instruction_topic(section)]
        controls = [s for s in topics if heading_names(s["title"])[0] in {"{}", "@"}]
        actual = [s for s in topics if s not in controls]
        counts = {
            "instruction_description_topics": len(topics),
            "actual_instruction_topics": len(actual),
            "control_syntax_topics": len(controls),
            "syntax_blocks": sum(s["syntax_blocks"] for s in chapter9),
            "categories": sum(bool(re.fullmatch(r"9\.7\.\d+", s["section"])) for s in chapter9),
            "special_register_sections": len(chapter10),
        }
        report["observed_counts"] = counts
        for key, expected in EXPECTED.items():
            if counts[key] != expected:
                errors.append(f"Count mismatch for {key}: {counts[key]} != {expected}")
        unattributed = [s["section"] for s in chapter9 if s["syntax_blocks"] and not instruction_topic(s)]
        wrong_per_topic = {s["section"]: s["syntax_blocks"] for s in topics if s["syntax_blocks"] != 1}
        if unattributed or wrong_per_topic:
            errors.append("Syntax blocks do not correspond one-to-one to instruction-description leaves")
        if any(s["predefined_syntax_blocks"] != 1 for s in chapter10):
            errors.append("Chapter 10 sections do not each contain exactly one Syntax (predefined) block")
        report["pdf_crosscheck"] = {
            "body_section_headings_matched": len(chapter9) + len(chapter10),
            "chapter9_sections": len(chapter9),
            "unattributed_syntax_sections": unattributed,
            "instruction_topics_with_wrong_syntax_count": wrong_per_topic,
            "control_syntax_sections": [s["section"] for s in controls],
        }
        source_topics = {s["section"]: s for s in topics}
        source_categories = {s["section"]: s for s in chapter9 if re.fullmatch(r"9\.7\.\d+", s["section"])}
        entries = inventory["instruction_topics"]
        ids = [entry["section"] for entry in entries]
        if len(ids) != len(set(ids)):
            errors.append("Inventory has duplicate instruction-topic section IDs")
        if set(ids) != set(source_topics):
            errors.append("Inventory instruction-topic section IDs differ from the PDF")
        metadata_mismatches = []
        source_excerpt_mismatches = {}
        for entry in entries:
            source = source_topics.get(entry["section"])
            if source is None:
                continue
            expected_kind = "control_syntax" if heading_names(source["title"])[0] in {"{}", "@"} else "instruction"
            if (entry["heading"] != source["title"] or entry["pdf_page_start"] != source["pdf_page"] or
                entry["printed_page_start"] != source["pdf_page"] - 12 or
                entry["heading_mnemonics"] != heading_names(source["title"]) or
                entry["entry_kind"] != expected_kind or
                not all(entry.get(key) for key in ("syntax_source_excerpt", "ptx_isa_notes_source_excerpt", "target_isa_notes_source_excerpt"))):
                metadata_mismatches.append(entry["section"])
            extracted = {
                "syntax_source_excerpt": source_excerpt(source["body"], "Syntax", ["Description"]),
                "ptx_isa_notes_source_excerpt": source_excerpt(source["body"], "PTX ISA Notes", ["Target ISA Notes", "Examples"]),
                "target_isa_notes_source_excerpt": source_excerpt(source["body"], "Target ISA Notes", ["Examples"]),
            }
            mismatched_fields = [key for key, value in extracted.items() if entry.get(key) != value]
            if mismatched_fields:
                source_excerpt_mismatches[entry["section"]] = mismatched_fields
        if metadata_mismatches:
            errors.append(f"Inventory heading/page/kind/evidence mismatches: {metadata_mismatches}")
        if source_excerpt_mismatches:
            errors.append(f"Inventory evidence excerpts differ from PDF in {len(source_excerpt_mismatches)} sections")
        inventory_categories = {s["section"] for s in inventory["categories"]}
        if inventory_categories != set(source_categories):
            errors.append("Inventory category IDs differ from the PDF's 21 categories")
        stored_counts = inventory["counts"]
        count_fields = {
            "instruction_description_leaf_topics_including_control_syntax": counts["instruction_description_topics"],
            "actual_instruction_description_leaf_topics": counts["actual_instruction_topics"],
            "nonopcode_control_syntax_topics": counts["control_syntax_topics"],
            "syntax_blocks_in_chapter9": counts["syntax_blocks"],
            "categories_under_9_7": counts["categories"],
            "syntax_blocks_unattributed": len(unattributed),
        }
        for key, value in count_fields.items():
            if stored_counts.get(key) != value:
                errors.append(f"Stored inventory count differs from source for {key}")
        report["inventory_validation"] = {
            "matched_instruction_sections": len(set(ids) & set(source_topics)),
            "metadata_mismatches": metadata_mismatches,
            "source_excerpt_fields_checked": len(entries) * 3,
            "source_excerpt_mismatches": source_excerpt_mismatches,
            "duplicate_section_ids": [key for key, value in Counter(ids).items() if value > 1],
        }
        # The independently indexed special registers remain outside the instruction schema/counts.
        special_sections = {s["section"] for s in chapter10}
        report["special_registers"] = {"source_sections": len(special_sections),
                                       "index": str(args.special_register_index)}
        if args.special_register_index.is_file():
            special = json.loads(args.special_register_index.read_text(encoding="utf-8"))
            special_entries = special["special_register_topics"]
            by_section = {s["section"]: s for s in chapter10}
            special_ids = [s["section"] for s in special_entries]
            special_errors = [s["section"] for s in special_entries if
                              s["section"] not in by_section or
                              s["heading"] != by_section[s["section"]]["title"] or
                              s["pdf_page_start"] != by_section[s["section"]]["pdf_page"]]
            if set(special_ids) != special_sections or len(special_ids) != len(set(special_ids)) or special_errors:
                errors.append("Special-register index does not match all 35 PDF section headings/pages")
            report["special_registers"].update({"status": "pass" if not special_errors and set(special_ids) == special_sections and len(special_ids) == 35 else "fail",
                                               "indexed_sections": len(special_ids),
                                               "metadata_mismatches": special_errors,
                                               "index_sha256": sha256(args.special_register_index)})
        else:
            report["special_registers"]["status"] = "index_not_present"
        # Preserve source validation independently of a main document still being drafted.
        report["source_inventory_status"] = "pass" if not errors else "fail"
        report["document_coverage"] = document_coverage(
            args.document, set(source_topics), {s["section"] for s in actual},
            {s["section"] for s in controls},
            {s["section"] for s in chapter9} | special_sections, special_sections,
            args.require_document, args.require_special_registers, errors)
        report["status"] = ("fail" if errors else
                            "pending_document" if report["document_coverage"]["status"] == "pending_document" else "pass")
    except (OSError, ValueError, KeyError, StopIteration, ImportError) as exception:
        errors.append(f"{type(exception).__name__}: {exception}")
        report["status"] = "fail"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pdf", type=Path, help="Uploaded PTX 9.4 PDF; default: source path recorded in inventory")
    parser.add_argument("--inventory", type=Path, default=HERE / "research/ptx94_instruction_inventory.json")
    parser.add_argument("--special-register-index", type=Path, default=HERE / "research/ptx94_special_register_inventory.json")
    parser.add_argument("--document", type=Path, default=HERE / "SM_ARCHITECTURE.md")
    parser.add_argument("--require-document", action="store_true", help="Fail instead of pending if the SM main document is absent")
    parser.add_argument("--require-special-registers", action="store_true", help="Also require explicit main-document rows for all 35 Chapter 10 sections")
    parser.add_argument("--output", type=Path, default=HERE / "research/instruction_coverage_check.json")
    args = parser.parse_args()
    report = run(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{report['status'].upper()}: {args.output}")
    for message in report["errors"]:
        print(f"  {message}", file=sys.stderr)
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
