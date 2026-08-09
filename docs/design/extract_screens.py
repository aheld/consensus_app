#!/usr/bin/env python3
"""Split the Claude Design doc into one standalone HTML file per screen.

The design markup inside <x-dc> is plain HTML with inline styles, so each
screen renders identically without the dc-runtime. We emit one file per screen
so builders and critics can open a single target side by side with ours.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "create-and-share.dc.html")
OUT = os.path.join(HERE, "screens")

HEAD = """<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:ital,wght@0,400..700;1,400..700&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
body{{margin:0;background:#DDF0E2;font-family:'Instrument Sans',system-ui,sans-serif;color:#17211C;
     display:flex;align-items:flex-start;justify-content:flex-start;padding:0}}
@keyframes blink{{50%{{opacity:0}}}}
</style></head><body>
"""
TAIL = "\n</body></html>\n"


def section_ids(lines):
    """Every `dv-opt` option id in the document, in source order (1a, 1b, 1c, 2a, 4a…)."""
    return re.findall(r'class="dv-opt" id="([^"]+)"', "\n".join(lines))


def section(lines, sec_id):
    """The lines of one `dv-opt` block.

    Bounded by the *next* `dv-opt` as well as by div depth: sibling options sit at the
    same depth inside one `.dv-opts` row, and depth alone runs straight past them.
    """
    start = next(i for i, l in enumerate(lines) if f'class="dv-opt" id="{sec_id}"' in l)
    nxt = next(
        (i for i, l in enumerate(lines) if i > start and 'class="dv-opt" id="' in l),
        len(lines),
    )
    depth = 0
    for i in range(start, nxt):
        depth += lines[i].count("<div") - lines[i].count("</div")
        if i > start and depth <= 0:
            return lines[start : i + 1]
    return lines[start:nxt]


STARTS = (
    '<div style="display:flex;flex-direction:column;gap:8px">',  # captioned phone frame
    '<div style="width:1280px',  # the bare desktop console in 1b
)


def screens(block):
    """Yield (caption, html) for each column-0 screen block inside a section.

    Some options (the feedback entry points in `4x`, the app mark in `2x`) are a single
    annotated specimen rather than a row of captioned phone frames and match none of
    STARTS. Those fall through to the whole-section fallback below, which is why this
    returns `[]` rather than raising for them.
    """
    out = []
    i = 0
    while i < len(block):
        if block[i].startswith(STARTS):
            depth, j = 0, i
            while j < len(block):
                depth += block[j].count("<div") - block[j].count("</div")
                if depth <= 0:
                    break
                j += 1
            html = "\n".join(block[i : j + 1])
            caps = re.findall(r'text-align:center">([^<]+)</div>', html)
            out.append((caps[-1].strip() if caps else f"screen{len(out)}", html))
            i = j + 1
        else:
            i += 1
    return out


def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:60] or "screen"


def main():
    src = open(SRC, encoding="utf-8").read().split("\n")
    os.makedirs(OUT, exist_ok=True)
    index = []
    for sec in section_ids(src):
        block = section(src, sec)
        found = screens(block)
        if not found:
            # A single annotated specimen (feedback entry points, app mark) — emit the
            # whole option block, captioned from its own `dv-olabel`.
            label = re.search(r'class="dv-olabel">.*?</a>(.*?)</div>', "\n".join(block))
            cap = re.sub(r"<[^>]+>", "", label.group(1)).strip() if label else sec
            found = [(cap, "\n".join(block))]
        for n, (cap, html) in enumerate(found):
            name = f"{sec}-{n}-{slug(cap)}.html"
            with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
                f.write(HEAD.format(title=f"{sec} · {cap}") + html + TAIL)
            index.append((sec, n, cap, name))
            print(f"{sec}[{n}] {cap!r} -> screens/{name}")
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
        f.write(HEAD.format(title="Design screens"))
        f.write("<div style='padding:24px;font:14px/1.7 sans-serif'><h1>Design reference screens</h1><ul>")
        for sec, n, cap, name in index:
            f.write(f"<li><code>{sec}[{n}]</code> <a href='{name}'>{cap}</a></li>")
        f.write("</ul></div>" + TAIL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
