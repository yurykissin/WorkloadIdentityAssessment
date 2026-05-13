#!/usr/bin/env python3
"""Rebuild kb/INDEX.md — a flat heading index for fast call-mode lookup.

Run from project root:
    python3 scripts/build-index.py
"""
import os, re

KB = os.path.join(os.path.dirname(__file__), "..", "kb")
KB = os.path.abspath(KB)

out = ["# KB INDEX — fast lookup table",
       "",
       "Single grep this file for any heading across the KB. Each row points to a heading in a KB article.",
       "Format: `H<level> · <article-path>:<line> · <heading text>`",
       "",
       "_Auto-generated. Re-run `scripts/build-index.py` after editing KB._",
       ""]

per_section = {}
for root, dirs, files in os.walk(KB):
    files.sort()
    dirs.sort()
    for f in files:
        if not f.endswith(".md") or f in ("INDEX.md", "README.md"):
            continue
        p = os.path.join(root, f)
        rel = os.path.relpath(p, KB)
        section = rel.split(os.sep)[0] if os.sep in rel else "_root"
        per_section.setdefault(section, [])
        with open(p) as fh:
            for i, line in enumerate(fh, 1):
                m = re.match(r"^(#{1,3})\s+(.+?)\s*$", line)
                if m:
                    lvl = len(m.group(1))
                    txt = m.group(2)
                    per_section[section].append((lvl, rel, i, txt))

for sec in sorted(per_section):
    out.append(f"## {sec}")
    out.append("")
    out.append("| Lvl | Heading | Path:Line |")
    out.append("|-----|---------|-----------|")
    for lvl, rel, i, txt in per_section[sec]:
        heading = txt.replace("|", "\\|")
        path = f"`kb/{rel}:{i}`"
        out.append(f"| H{lvl} | {heading} | {path} |")
    out.append("")

target = os.path.join(KB, "INDEX.md")
with open(target, "w") as fh:
    fh.write("\n".join(out))

total = sum(len(v) for v in per_section.values())
print(f"wrote {target}")
print(f"  {total} headings across {len(per_section)} sections")
print(f"  {os.path.getsize(target)} bytes")
