#!/usr/bin/env python3
"""Render audit findings (JSON) into a self-contained HTML report, verifying every location.

Usage:
    python3 render_report.py findings.json --out report.html [--allow-unverified]

Every location's `quote` is checked against the cited line of the source file under
meta.source_root (comments ignored). Line numbers that are off by a few lines, or quotes found
elsewhere in the same file, are corrected and listed. Locations whose quote can't be found are
marked "unverified" in the report and make the script exit 1, so they get fixed before hand-off.

Terminology variants without explicit `locations` are located automatically: every whole-word,
case-sensitive occurrence of `form` (or of the Python regex in `pattern`) in the document body.

Schema: references/findings-schema.md
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import html
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from texmap import flatten, strip_comment  # noqa: E402

SEVERITIES = ("high", "medium", "low")
SEV_LABEL = {"high": "High", "medium": "Medium", "low": "Low"}
EDITOR_SCHEMES = {"vscode", "vscode-insiders", "cursor", "windsurf"}
GOOD_STATUS = {"consistent", "ok", "supported", "addressed"}
WARN_STATUS = {"partial", "unclear", "weak", "check"}


def esc(s) -> str:
    return html.escape(str(s if s is not None else ""), quote=True)


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def md_inline(s: str | None) -> str:
    """Escape, then allow `code`, **bold**, *italic* and blank-line paragraphs."""
    if not s:
        return ""
    paras = []
    for chunk in re.split(r"\n\s*\n", s.strip()):
        t = esc(chunk)
        t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
        t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
        t = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<em>\1</em>", t)
        paras.append(f"<p>{t}</p>")
    return "".join(paras)


class Sources:
    def __init__(self, root: str, main: str | None):
        self.root = root
        self.cache: dict[str, list[str] | None] = {}
        self.doc = None
        self.warnings: list[str] = []
        if main:
            try:
                self.doc = flatten(os.path.join(root, main), root)
            except SystemExit as e:
                self.warnings.append(f"could not map {main}: {e}")

    def lines(self, rel: str) -> list[str] | None:
        if rel not in self.cache:
            p = os.path.join(self.root, rel)
            if os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as f:
                    self.cache[rel] = [strip_comment(l) for l in f.read().splitlines()]
            else:
                self.cache[rel] = None
        return self.cache[rel]

    def section(self, rel: str, num: int) -> str:
        return self.doc.section_of(rel, num) if self.doc else ""


class Verifier:
    def __init__(self, src: Sources):
        self.src = src
        self.stats = {"ok": 0, "corrected": 0, "unverified": 0}
        self.problems: list[str] = []
        self.corrections: list[str] = []

    def check(self, loc: dict, where: str):
        rel = str(loc.get("file") or "")
        try:
            line = int(loc.get("line") or 0)
        except (TypeError, ValueError):
            line = 0
        q = norm(loc.get("quote") or "")
        lines = self.src.lines(rel)
        if lines is None:
            loc.update(status="unverified", line=line, context="")
            self.stats["unverified"] += 1
            self.problems.append(f"{where}: file not found under source_root: {rel!r}")
            return

        def hit(n: int) -> bool:
            if not 1 <= n <= len(lines):
                return False
            if q in norm(lines[n - 1]):
                return True
            # a quote may wrap onto the next line, but must actually start on this one
            return n < len(lines) and q not in norm(lines[n]) and q in norm(lines[n - 1] + " " + lines[n])

        if not q:
            status = "ok" if 1 <= line <= len(lines) else "unverified"
        elif hit(line):
            status = "ok"
        else:
            found = next((n for d in range(1, 6) for n in (line - d, line + d) if hit(n)), None)
            if found is None:
                hits = [n for n in range(1, len(lines) + 1) if hit(n)]
                found = min(hits, key=lambda n: abs(n - line)) if hits else None
            if found is not None:
                self.corrections.append(f"{where}: {rel}:{line} -> {rel}:{found}")
                line, status = found, "corrected"
            else:
                status = "unverified"
                self.problems.append(f"{where}: quote not found in {rel} near line {line}: {q[:70]!r}")
        self.stats[status] += 1
        loc.update(status=status, line=line, context=lines[line - 1] if 1 <= line <= len(lines) else "")
        loc["section"] = loc.get("section") or self.src.section(rel, line)


def snippet(text: str, a: int, b: int, pad: int = 28) -> str:
    s, e = max(0, a - pad), min(len(text), b + pad)
    if s > 0:
        sp = text.find(" ", s, a)
        s = sp + 1 if sp != -1 else a
    if e < len(text):
        sp = text.rfind(" ", b, e)
        e = sp if sp != -1 else b
    return text[s:e].strip()


def auto_locate(src: Sources, variant: dict) -> list[dict]:
    if not src.doc:
        src.warnings.append(f"variant {variant.get('form')!r}: no main_file, cannot auto-locate")
        return []
    form = variant.get("form", "")
    if variant.get("pattern"):
        rx = variant["pattern"]
    else:
        rx = r"(?<![\w-])" + r"\s+".join(map(re.escape, form.split())) + r"(?![\w-])"
    flags = 0 if variant.get("case_sensitive", True) else re.I
    out = []
    for L in src.doc.body():
        for m in re.finditer(rx, L.text, flags):
            out.append({"file": L.file, "line": L.num, "quote": snippet(L.text, m.start(), m.end()), "match": m.group(0)})
    return out


def context_html(ctx: str, quote: str, match: str | None = None) -> str:
    c, q = norm(ctx), norm(quote)
    target = norm(match or quote)
    # find the quote first, then the match inside it, so the right occurrence gets highlighted
    qi = c.find(q) if q else -1
    i = c.find(target, max(qi, 0)) if target else -1
    if i < 0 and target:
        i = c.lower().find(target.lower())
    if i < 0:
        return esc(c[:240] + ("…" if len(c) > 240 else ""))
    s, e = max(0, i - 110), min(len(c), i + len(target) + 110)
    return (
        ("…" if s > 0 else "") + esc(c[s:i]) + "<mark>" + esc(c[i : i + len(target)]) + "</mark>"
        + esc(c[i + len(target) : e]) + ("…" if e < len(c) else "")
    )


class Renderer:
    def __init__(self, data: dict, src: Sources):
        self.meta = data.get("meta", {})
        self.src = src
        self.ol = self.meta.get("overleaf_url") or None
        gh = self.meta.get("github_blob_base") or None
        self.gh = gh.rstrip("/") if gh else None
        sch = self.meta.get("editor_scheme")
        self.editor = sch if sch in EDITOR_SCHEMES else None

    def loc_html(self, loc: dict, compact: bool = False) -> str:
        rel, n = loc["file"], loc["line"]
        q = loc.get("quote") or loc.get("match") or ""
        label = f"{rel}:{n}"
        attrs = f'data-file="{esc(rel)}" data-line="{n}" data-quote="{esc(q)}"'
        if self.ol:
            main = (f'<a class="loc-link" href="{esc(self.ol)}" target="overleaf" {attrs} '
                    f'title="Open the Overleaf project and copy this snippet">{esc(label)}</a>')
        else:
            main = f'<button type="button" class="loc-link" {attrs} title="Copy snippet">{esc(label)}</button>'
        extra = []
        if self.gh:
            extra.append(f'<a class="alt" href="{esc(self.gh)}/{esc(urllib.parse.quote(rel))}#L{n}" target="_blank" rel="noopener">GitHub</a>')
        if self.editor:
            abs_path = os.path.join(self.src.root, rel)
            extra.append(f'<a class="alt" href="{self.editor}://file{esc(urllib.parse.quote(abs_path))}:{n}">Editor</a>')
        if q:
            extra.append(f'<button type="button" class="alt copy-btn" data-quote="{esc(q)}">Copy snippet</button>')
        status = loc.get("status")
        flag = ""
        if status == "unverified":
            flag = '<span class="flag bad" title="Quote not found at this location">unverified</span>'
        role = f'<span class="role">{esc(loc["role"])}</span>' if loc.get("role") else ""
        sect = f'<span class="sect">{esc(loc["section"])}</span>' if loc.get("section") and not compact else ""
        ctx = loc.get("context") or ""
        ctx_html = f'<div class="ctx">{context_html(ctx, q, loc.get("match"))}</div>' if ctx and not compact else ""
        if compact and q:
            ctx_html = f'<div class="ctx small">{esc(q)}</div>'
        note = f'<div class="note">{md_inline(loc["note"])}</div>' if loc.get("note") and not compact else ""
        return (f'<li class="loc"><div class="loc-head">{role}{main}{flag}{sect}'
                f'<span class="alts">{"".join(extra)}</span></div>{ctx_html}{note}</li>')

    def locs_html(self, locs: list[dict], show: int = 6) -> str:
        if not locs:
            return ""
        head = "".join(self.loc_html(l) for l in locs[:show])
        rest = locs[show:]
        more = ""
        if rest:
            more = (f'<details class="more"><summary>{len(rest)} more location{"s" if len(rest) != 1 else ""}</summary>'
                    f'<ul class="locs">{"".join(self.loc_html(l) for l in rest)}</ul></details>')
        return f'<ul class="locs">{head}</ul>{more}'

    def finding_html(self, f: dict, kind: str) -> str:
        sev = f["severity"]
        search = [f.get("title", ""), f.get("category", ""), f.get("explanation", ""), f.get("recommendation", "")]
        body = [f'<div class="expl">{md_inline(f.get("explanation"))}</div>']
        if f.get("recommendation"):
            body.append(f'<div class="rec"><span class="rec-label">Suggested fix</span>{md_inline(f["recommendation"])}</div>')
        for v in f.get("variants", []):
            search.append(v.get("form", ""))
            count = v.get("count", len(v.get("locations", [])))
            keep = '<span class="keep">keep</span>' if v.get("preferred") else ""
            body.append(
                f'<div class="variant"><div class="vhead"><code class="form">{esc(v.get("form"))}</code>'
                f'<span class="count">×{count}</span>{keep}</div>{self.locs_html(v.get("locations", []), 4)}</div>'
            )
        if f.get("locations"):
            body.append(self.locs_html(f["locations"], 8))
        for l in f.get("locations", []) + [l for v in f.get("variants", []) for l in v.get("locations", [])]:
            search.append(l.get("file", ""))
        return (
            f'<article class="finding sev-{sev}" id="{esc(f["id"])}" data-sev="{sev}" '
            f'data-search="{esc(" ".join(search).lower())}">'
            f'<header class="fhead"><span class="badge {sev}">{SEV_LABEL[sev]}</span>'
            f'<span class="cat">{esc(f.get("category", ""))}</span><a class="fid" href="#{esc(f["id"])}">{esc(f["id"])}</a>'
            f'<label class="done"><input type="checkbox" class="resolve"> Resolved</label></header>'
            f'<h4>{esc(f.get("title", ""))}</h4>{"".join(body)}</article>'
        )

    def group_html(self, findings: list[dict], kind: str) -> str:
        if not findings:
            return '<p class="empty">No findings.</p>'
        groups: dict[str, list[dict]] = {}
        for f in findings:
            groups.setdefault(f.get("category") or "Other", []).append(f)
        out = []
        for cat, fs in groups.items():
            fs = sorted(fs, key=lambda f: SEVERITIES.index(f["severity"]))
            out.append(f'<div class="group"><h3>{esc(cat)} <span class="gcount">{len(fs)}</span></h3>'
                       + "".join(self.finding_html(f, kind) for f in fs) + "</div>")
        return "".join(out)

    def trace_html(self, rows: list[dict]) -> str:
        if not rows:
            return ""
        def cell(loc):
            return f'<ul class="locs compact">{self.loc_html(loc, compact=True)}</ul>' if loc else '<span class="none">none</span>'
        trs = []
        for r in rows:
            st = str(r.get("status", "")).lower()
            cls = "good" if st in GOOD_STATUS else "warn" if st in WARN_STATUS else "bad"
            link = f' <a class="fid" href="#{esc(r["finding"])}">{esc(r["finding"])}</a>' if r.get("finding") else ""
            trs.append(
                f'<tr><td class="item">{esc(r.get("item"))}</td><td>{cell(r.get("intro"))}</td>'
                f'<td>{cell(r.get("results"))}</td><td>{cell(r.get("discussion"))}</td>'
                f'<td><span class="status {cls}">{esc(r.get("status", ""))}</span>{link}'
                f'<div class="tnote">{md_inline(r.get("note"))}</div></td></tr>'
            )
        return (
            '<section id="trace"><h2>Hypothesis traceability</h2>'
            '<p class="lede">Each question or prediction from the introduction, where it is tested, and how the discussion treats it.</p>'
            '<div class="table-wrap"><table><thead><tr><th>Prediction / question</th><th>Introduction</th>'
            '<th>Results</th><th>Discussion</th><th>Status</th></tr></thead><tbody>'
            + "".join(trs) + "</tbody></table></div></section>"
        )


def counts(fs: list[dict]) -> dict[str, int]:
    return {s: sum(1 for f in fs if f["severity"] == s) for s in SEVERITIES}


def normalize(data: dict, warnings: list[str]):
    for kind, prefix in (("terminology", "T"), ("logic", "L")):
        fs = data.setdefault(kind, [])
        for i, f in enumerate(fs, 1):
            f.setdefault("id", f"{prefix}{i}")
            sev = str(f.get("severity", "medium")).lower()
            if sev not in SEVERITIES:
                warnings.append(f"{f['id']}: unknown severity {f.get('severity')!r}, using medium")
                sev = "medium"
            f["severity"] = sev
    data.setdefault("traceability", [])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("findings")
    ap.add_argument("--out", required=True)
    ap.add_argument("--allow-unverified", action="store_true", help="exit 0 even if some quotes were not found")
    args = ap.parse_args()

    try:
        with open(args.findings, encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as e:
        sys.exit(f"render_report: invalid JSON in {args.findings}: {e} "
                 "(LaTeX backslashes must be written as \\\\ inside JSON strings)")
    meta = data.setdefault("meta", {})
    root = os.path.abspath(os.path.expanduser(meta.get("source_root") or "."))
    meta["source_root"] = root
    src = Sources(root, meta.get("main_file"))
    warnings = list(src.warnings)
    normalize(data, warnings)
    ver = Verifier(src)

    for f in data["terminology"]:
        for v in f.get("variants", []):
            if not v.get("locations"):
                v["locations"] = auto_locate(src, v)
                v.setdefault("count", len(v["locations"]))
            for j, l in enumerate(v["locations"]):
                l.setdefault("quote", v.get("form", ""))
                ver.check(l, f"{f['id']} variant {v.get('form')!r} #{j + 1}")
        for j, l in enumerate(f.get("locations", [])):
            ver.check(l, f"{f['id']} location #{j + 1}")
    for f in data["logic"]:
        for j, l in enumerate(f.get("locations", [])):
            ver.check(l, f"{f['id']} location #{j + 1}")
    for i, r in enumerate(data["traceability"], 1):
        for col in ("intro", "results", "discussion"):
            if r.get(col):
                ver.check(r[col], f"traceability row {i} {col}")

    R = Renderer(data, src)
    tc, lc = counts(data["terminology"]), counts(data["logic"])
    generated = meta.get("generated") or datetime.date.today().isoformat()
    title = meta.get("title") or "Untitled manuscript"
    key = "msaudit:" + hashlib.sha1(f"{title}|{generated}".encode()).hexdigest()[:10] + ":"

    def stat_row(name, c, anchor):
        cells = "".join(f'<td><span class="badge {s}">{c[s]}</span></td>' for s in SEVERITIES)
        return f'<tr><th><a href="#{anchor}">{name}</a></th>{cells}<td>{sum(c.values())}</td></tr>'

    how = []
    if R.ol:
        how.append("Overleaf has no link that opens a file at a given line, so clicking a location like "
                   "<code>intro.tex:42</code> opens the project in a single reused tab and copies a short snippet "
                   "from that line. In Overleaf, open that file, press <kbd>Ctrl</kbd>+<kbd>F</kbd> "
                   "(<kbd>⌘</kbd><kbd>F</kbd> on a Mac) and paste.")
    else:
        how.append("Clicking a location copies a short snippet from that line so you can find it with your editor's search.")
    if R.gh:
        how.append("<strong>GitHub</strong> links jump to the exact line.")
    if R.editor:
        how.append("<strong>Editor</strong> links open the local copy at the line.")
    how.append(f"Line numbers refer to the copy analyzed on {esc(generated)}; if the project changed since, the snippet search still works.")

    unverified_banner = ""
    if ver.stats["unverified"]:
        unverified_banner = (f'<div class="banner">{ver.stats["unverified"]} location(s) could not be verified against the source '
                             "and are marked <em>unverified</em>.</div>")
    scope = meta.get("scope_notes") or []
    scope_html = ("<section id='scope'><h2>Scope and caveats</h2><ul class='scope'>"
                  + "".join(f"<li>{md_inline(s)}</li>" for s in scope) + "</ul></section>") if scope else ""
    project_links = []
    if R.ol:
        project_links.append(f'<a href="{esc(R.ol)}" target="overleaf">Overleaf project ↗</a>')
    if R.gh:
        project_links.append(f'<a href="{esc(R.gh)}" target="_blank" rel="noopener">GitHub ↗</a>')

    body = f"""
<header class="top">
  <p class="eyebrow">Manuscript consistency audit</p>
  <h1>{esc(title)}</h1>
  <p class="sub">{esc(meta.get('main_file') or '')}{' · ' if meta.get('main_file') else ''}analyzed {esc(generated)}{' · ' + ' · '.join(project_links) if project_links else ''}</p>
</header>
{unverified_banner}
<section id="summary" class="summary">
  <div class="summary-grid">
    <div>
      {md_inline(meta.get('summary')) or '<p class="muted">No summary provided.</p>'}
    </div>
    <table class="stats"><thead><tr><th></th><th>High</th><th>Medium</th><th>Low</th><th>Total</th></tr></thead>
      <tbody>{stat_row('Terminology', tc, 'terminology')}{stat_row('Logic and narrative', lc, 'logic')}</tbody></table>
  </div>
  <div class="how"><span class="how-label">Using the links</span> {' '.join(how)}</div>
</section>
<nav class="toolbar" aria-label="Filters">
  <div class="toggles">
    {''.join(f'<button type="button" class="tog {s}" data-sev-toggle="{s}" aria-pressed="true">{SEV_LABEL[s]} <span>{tc[s] + lc[s]}</span></button>' for s in SEVERITIES)}
  </div>
  <input id="q" type="search" placeholder="Filter by word, file, category…" aria-label="Filter findings">
  <label class="hide"><input type="checkbox" id="hide-resolved"> Hide resolved</label>
  <span id="shown" class="muted"></span>
</nav>
<section id="terminology"><h2>1. Terminology</h2>
  <p class="lede">The same thing named differently, one name used for different things, and acronym, notation and style drift.</p>
  {R.group_html(data['terminology'], 'terminology')}
</section>
<section id="logic"><h2>2. Logic and narrative</h2>
  <p class="lede">Where the introduction's motivation and predictions, the results as reported, and the discussion's interpretation disagree.</p>
  {R.group_html(data['logic'], 'logic')}
</section>
{R.trace_html(data['traceability'])}
{scope_html}
<div id="toast" class="toast" role="status" aria-live="polite"></div>
"""
    page = TEMPLATE.replace("__TITLE__", esc(f"Audit: {title}")).replace("__KEY__", esc(key)).replace("__CSS__", CSS).replace("__BODY__", body).replace("__JS__", JS)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(page)

    s = ver.stats
    print(f"Wrote {args.out}")
    print(f"  terminology: {sum(tc.values())} (high {tc['high']}, medium {tc['medium']}, low {tc['low']})")
    print(f"  logic:       {sum(lc.values())} (high {lc['high']}, medium {lc['medium']}, low {lc['low']})")
    print(f"  locations:   {s['ok']} verified, {s['corrected']} line-corrected, {s['unverified']} unverified")
    for c in ver.corrections:
        print(f"  corrected  {c}")
    for w in warnings:
        print(f"  warning    {w}")
    for p in ver.problems:
        print(f"  UNVERIFIED {p}")
    if s["unverified"] and not args.allow_unverified:
        sys.exit(1)


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>__CSS__</style>
</head>
<body data-key="__KEY__">
<div class="wrap">
__BODY__
</div>
<script>__JS__</script>
</body>
</html>
"""

CSS = r"""
:root{
  --bg:#f7f6f3; --surface:#ffffff; --text:#1d1d1f; --muted:#5f6166; --border:#e4e1db; --accent:#1a5fb4;
  --code-bg:#f2f0eb; --mark:#fde68a; --mark-text:#1d1d1f;
  --high:#b42318; --high-bg:#fdecea; --medium:#a15c07; --medium-bg:#fdf2e1; --low:#475467; --low-bg:#edf0f4;
  --good:#067647; --good-bg:#e5f5ea; --warn:#a15c07; --warn-bg:#fdf2e1; --bad:#b42318; --bad-bg:#fdecea;
  color-scheme: light;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#121214; --surface:#1b1b1f; --text:#ececf1; --muted:#a3a3ad; --border:#2f2f36; --accent:#8ab8ff;
    --code-bg:#24242b; --mark:#6b5800; --mark-text:#fff8d6;
    --high:#ff8b80; --high-bg:#3b1a18; --medium:#f4b65a; --medium-bg:#382912; --low:#aab5c5; --low-bg:#232831;
    --good:#72d6a0; --good-bg:#14301f; --warn:#f4b65a; --warn-bg:#382912; --bad:#ff8b80; --bad-bg:#3b1a18;
    color-scheme: dark;
  }
}
:root[data-theme="dark"]{
  --bg:#121214; --surface:#1b1b1f; --text:#ececf1; --muted:#a3a3ad; --border:#2f2f36; --accent:#8ab8ff;
  --code-bg:#24242b; --mark:#6b5800; --mark-text:#fff8d6;
  --high:#ff8b80; --high-bg:#3b1a18; --medium:#f4b65a; --medium-bg:#382912; --low:#aab5c5; --low-bg:#232831;
  --good:#72d6a0; --good-bg:#14301f; --warn:#f4b65a; --warn-bg:#382912; --bad:#ff8b80; --bad-bg:#3b1a18;
  color-scheme: dark;
}
*{box-sizing:border-box}
[hidden]{display:none !important}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,"Helvetica Neue",sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:28px 16px 96px}
a{color:var(--accent)}
code,kbd,.ctx,.loc-link,.form{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
code{font-size:.9em;background:var(--code-bg);padding:1px 5px;border-radius:4px}
kbd{font-size:.82em;border:1px solid var(--border);border-bottom-width:2px;border-radius:4px;padding:0 4px;background:var(--surface)}
h1,h2{font-family:"Iowan Old Style","Charter","Source Serif Pro",Georgia,serif;font-weight:600;letter-spacing:-.01em}
h1{font-size:30px;line-height:1.2;margin:4px 0 6px}
h2{font-size:23px;margin:44px 0 4px;padding-bottom:6px;border-bottom:1px solid var(--border)}
h3{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:26px 0 8px;font-weight:600}
h4{font-size:16.5px;margin:6px 0 6px;line-height:1.35}
p{margin:0 0 8px}
.eyebrow{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0}
.sub,.muted,.lede{color:var(--muted)}
.sub{margin:0}
.lede{margin:6px 0 4px}
.banner{margin:18px 0 0;padding:10px 14px;border-radius:8px;background:var(--bad-bg);color:var(--bad);border:1px solid var(--bad)}
.summary{margin-top:22px;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px}
.summary-grid{display:grid;grid-template-columns:1fr auto;gap:18px;align-items:start}
.stats{border-collapse:collapse;font-size:13.5px}
.stats th,.stats td{padding:4px 8px;text-align:center}
.stats tbody th{text-align:left;font-weight:600;white-space:nowrap}
.stats thead th{color:var(--muted);font-weight:500;font-size:12px}
.how{margin-top:14px;padding-top:12px;border-top:1px solid var(--border);font-size:13.5px;color:var(--muted)}
.how-label,.rec-label{display:inline-block;font-size:11px;text-transform:uppercase;letter-spacing:.06em;font-weight:600;color:var(--text);margin-right:6px}
.toolbar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px 12px;align-items:center;margin:18px -16px 0;padding:10px 16px;
  background:color-mix(in srgb,var(--bg) 90%,transparent);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);border-bottom:1px solid var(--border)}
.toggles{display:flex;gap:6px}
.tog{font:inherit;font-size:13px;border:1px solid var(--border);background:var(--surface);color:var(--muted);border-radius:999px;padding:3px 11px;cursor:pointer}
.tog span{font-weight:600;margin-left:2px}
.tog[aria-pressed="true"].high{background:var(--high-bg);color:var(--high);border-color:var(--high)}
.tog[aria-pressed="true"].medium{background:var(--medium-bg);color:var(--medium);border-color:var(--medium)}
.tog[aria-pressed="true"].low{background:var(--low-bg);color:var(--low);border-color:var(--low)}
#q{flex:1 1 200px;min-width:0;font:inherit;font-size:14px;padding:6px 10px;border:1px solid var(--border);border-radius:8px;background:var(--surface);color:var(--text)}
.hide{font-size:13px;color:var(--muted);white-space:nowrap}
#shown{font-size:13px}
.badge{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;padding:2px 8px;border-radius:999px;min-width:2.2em;text-align:center}
.badge.high{background:var(--high-bg);color:var(--high)}
.badge.medium{background:var(--medium-bg);color:var(--medium)}
.badge.low{background:var(--low-bg);color:var(--low)}
.gcount{font-weight:500;margin-left:4px}
.finding{background:var(--surface);border:1px solid var(--border);border-left:4px solid var(--low);border-radius:10px;padding:14px 18px 12px;margin:10px 0;scroll-margin-top:70px}
.finding.sev-high{border-left-color:var(--high)}
.finding.sev-medium{border-left-color:var(--medium)}
.finding.resolved{opacity:.55}
.finding.resolved h4{text-decoration:line-through}
.fhead{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;font-size:13px}
.cat{color:var(--muted)}
.fid{color:var(--muted);font-family:ui-monospace,Menlo,monospace;font-size:12px;text-decoration:none}
.done{margin-left:auto;color:var(--muted);font-size:12.5px;cursor:pointer;white-space:nowrap}
.expl p:last-child,.rec p:last-child{margin-bottom:0}
.rec{margin:10px 0 2px;padding:8px 12px;border-radius:8px;background:var(--code-bg)}
.rec p{display:inline}
.variant{margin-top:12px}
.vhead{display:flex;align-items:baseline;gap:8px}
.form{font-size:14px;font-weight:600}
.count{color:var(--muted);font-size:13px}
.keep{font-size:11px;text-transform:uppercase;letter-spacing:.05em;font-weight:700;color:var(--good);background:var(--good-bg);padding:1px 7px;border-radius:999px}
.locs{list-style:none;margin:6px 0 0;padding:0}
.loc{padding:7px 0;border-top:1px dashed var(--border)}
.loc:first-child{border-top:0}
.loc-head{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 10px;font-size:13px}
.loc-link{font-size:13px;color:var(--accent);background:none;border:0;padding:0;cursor:pointer;text-decoration:underline;text-underline-offset:2px;word-break:break-all;text-align:left}
.role{font-size:11px;text-transform:uppercase;letter-spacing:.05em;font-weight:600;color:var(--text);background:var(--code-bg);padding:1px 7px;border-radius:4px}
.sect{color:var(--muted);font-size:12.5px}
.alts{display:inline-flex;gap:10px;margin-left:auto}
.alt{font:inherit;font-size:12px;color:var(--muted);background:none;border:0;padding:0;cursor:pointer;text-decoration:underline;text-underline-offset:2px}
.flag{font-size:11px;padding:1px 6px;border-radius:4px;background:var(--warn-bg);color:var(--warn)}
.flag.bad{background:var(--bad-bg);color:var(--bad)}
.ctx{font-size:12.5px;line-height:1.5;background:var(--code-bg);color:var(--muted);padding:6px 9px;border-radius:6px;margin-top:5px;white-space:pre-wrap;word-break:break-word}
.ctx.small{font-size:12px;padding:3px 7px}
mark{background:var(--mark);color:var(--mark-text);border-radius:2px;padding:0 1px}
.note{font-size:13px;color:var(--muted);margin-top:4px}
details.more{margin-top:4px}
details.more summary{cursor:pointer;color:var(--muted);font-size:13px;padding:4px 0}
.table-wrap{overflow-x:auto;margin-top:10px;border:1px solid var(--border);border-radius:10px;background:var(--surface)}
table{width:100%}
#trace table{border-collapse:collapse;font-size:13.5px;min-width:720px}
#trace th,#trace td{padding:10px 12px;border-bottom:1px solid var(--border);vertical-align:top;text-align:left}
#trace thead th{font-size:12px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
#trace tr:last-child td{border-bottom:0}
#trace .item{font-weight:600;width:24%}
.compact .loc{padding:0}
.none{color:var(--muted);font-style:italic}
.status{display:inline-block;font-size:12px;font-weight:600;padding:1px 8px;border-radius:999px}
.status.good{background:var(--good-bg);color:var(--good)}
.status.warn{background:var(--warn-bg);color:var(--warn)}
.status.bad{background:var(--bad-bg);color:var(--bad)}
.tnote{font-size:12.5px;color:var(--muted);margin-top:4px}
.scope li{margin:4px 0}
.empty{color:var(--muted);font-style:italic}
.toast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%) translateY(20px);max-width:min(640px,calc(100% - 32px));
  background:var(--text);color:var(--bg);padding:10px 16px;border-radius:10px;font-size:13.5px;box-shadow:0 6px 24px rgba(0,0,0,.18);
  opacity:0;pointer-events:none;transition:opacity .18s,transform .18s}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
@media (max-width:700px){
  .summary-grid{grid-template-columns:1fr}
  .alts{margin-left:0}
  .done{margin-left:0}
  h1{font-size:25px}
}
@media print{
  .toolbar,.toast,.alts,.done{display:none !important}
  body{background:#fff}
  .finding{break-inside:avoid}
  details.more{display:block}
  details.more>*{display:block}
}
"""

JS = r"""
(() => {
  const KEY = document.body.dataset.key || 'msaudit:';
  const store = {
    get(k) { try { return localStorage.getItem(KEY + k); } catch (e) { return null; } },
    set(k, v) { try { v === null ? localStorage.removeItem(KEY + k) : localStorage.setItem(KEY + k, v); } catch (e) {} }
  };
  const toast = document.getElementById('toast');
  let timer;
  function say(msg) {
    toast.textContent = msg;
    toast.classList.add('show');
    clearTimeout(timer);
    timer = setTimeout(() => toast.classList.remove('show'), 5000);
  }
  function copy(text) {
    let ok = false;
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { ok = document.execCommand('copy'); } catch (e) {}
    ta.remove();
    if (!ok && navigator.clipboard) { navigator.clipboard.writeText(text).catch(() => {}); ok = true; }
    return ok;
  }
  const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
  const findKey = isMac ? '⌘F' : 'Ctrl+F';
  let overleaf = null;

  document.addEventListener('click', (e) => {
    const el = e.target.closest('.loc-link, .copy-btn');
    if (!el) return;
    const q = el.dataset.quote || '';
    if (el.classList.contains('copy-btn')) {
      e.preventDefault();
      say(copy(q) ? 'Copied: ' + q : 'Could not copy; select the text manually.');
      return;
    }
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) { if (q) copy(q); return; }
    e.preventDefault();
    const copied = q ? copy(q) : false;
    const file = el.dataset.file;
    if (el.tagName === 'A') {
      const reuse = overleaf && !overleaf.closed;
      if (reuse) { try { overleaf.focus(); } catch (err) {} }
      else { overleaf = window.open(el.href, 'overleaf'); }
      say((copied ? 'Snippet copied. ' : '') + (reuse ? 'Switch to the Overleaf tab, ' : 'In Overleaf, ') +
          'open ' + file + ', press ' + findKey + (copied ? ' and paste.' : ' and search for line ' + el.dataset.line + '.'));
    } else {
      say(copied ? 'Copied snippet from ' + file + ':' + el.dataset.line : file + ':' + el.dataset.line);
    }
  });

  const cards = Array.from(document.querySelectorAll('.finding'));
  const active = new Set(['high', 'medium', 'low']);
  const q = document.getElementById('q');
  const hide = document.getElementById('hide-resolved');
  const shown = document.getElementById('shown');
  function apply() {
    const term = q.value.trim().toLowerCase();
    let n = 0;
    for (const c of cards) {
      const ok = active.has(c.dataset.sev) && (!term || c.dataset.search.includes(term)) &&
                 !(hide.checked && c.classList.contains('resolved'));
      c.hidden = !ok;
      if (ok) n++;
    }
    document.querySelectorAll('.group').forEach(g => { g.hidden = !g.querySelector('.finding:not([hidden])'); });
    shown.textContent = n + ' of ' + cards.length + ' shown';
  }
  document.querySelectorAll('[data-sev-toggle]').forEach(b => b.addEventListener('click', () => {
    const s = b.dataset.sevToggle;
    active.has(s) ? active.delete(s) : active.add(s);
    b.setAttribute('aria-pressed', String(active.has(s)));
    apply();
  }));
  q.addEventListener('input', apply);
  hide.addEventListener('change', () => { store.set('hide', hide.checked ? '1' : null); apply(); });
  if (store.get('hide') === '1') hide.checked = true;
  for (const c of cards) {
    const cb = c.querySelector('.resolve');
    if (store.get(c.id) === '1') { cb.checked = true; c.classList.add('resolved'); }
    cb.addEventListener('change', () => {
      c.classList.toggle('resolved', cb.checked);
      store.set(c.id, cb.checked ? '1' : null);
      apply();
    });
  }
  apply();
})();
"""

if __name__ == "__main__":
    main()
