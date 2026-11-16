#!/usr/bin/env python3
"""Heuristic scan for terminology inconsistencies in a LaTeX (or Markdown) manuscript.

Usage:
    python3 term_candidates.py <project_dir | main.tex> [--out candidates.md] [--max-locs 8]

Reports, with file:line locations:
  A. hyphenation / spacing / closed-compound variants   (long-term vs long term, dataset vs data set)
  B. mid-sentence capitalization variants               (Bayesian vs bayesian, Working Memory vs working memory)
  C. acronyms: defined twice, used before definition, never defined, long form still used after
     the acronym is introduced, defined but barely used, glossary acronyms typed by hand
  D. UK/US spelling mixes                                (behaviour vs behavior, modelling vs modeling)
  E. cross-reference and label styles                    (Fig. vs Figure, \\ref vs \\cref, Experiment 1 vs Exp. 1)
  F. number and statistics formatting                    (p < .05 vs p < 0.05, 200ms vs 200 ms, % vs percent)

Everything here is a candidate to check in context, not a finding: compound modifiers are
hyphenated before a noun and open after it, journals require some acronyms to be redefined in
the abstract and captions, and some styles use "Figure" at sentence start and "Fig." elsewhere.
"""
from __future__ import annotations

import argparse
import bisect
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from texmap import Document, Line, flatten, plain_text  # noqa: E402

STOPWORDS = set(
    """a an the and or but nor of in on at to for from by with without within into onto upon
    as is are was were be been being it its this that these those there their they them we our
    you your he she his her not no any some every each all both either neither one ones may might
    can could will would shall should must do does did done have has had how what when where which
    who whom why than then so such very more most less least also only just over under after
    before about above below up down out off again further once here per via vs""".split()
)
COMMON_ACRONYMS = set(
    """II III IV VI VII VIII IX XI XII XIII XIV XV XX PhD MSc BSc MA MD USA UK US EU UN LaTeX TeX
    BibTeX OK DOI URL ID IDs AM PM GMT UTC MATLAB GitHub JavaScript PsychoPy SciPy NumPy PyTorch
    TensorFlow iOS macOS""".split()
)
ACR = r"(?=(?:[a-z0-9\-]*[A-Z]){2})[A-Za-z][A-Za-z0-9\-]{1,11}"
ACR_TOKEN_RE = re.compile(rf"(?<![\w\-])({ACR})(?![\w\-])")
ACR_DEF_RE = re.compile(rf"\(\s*({ACR})\s*(?:[;,][^()]*)?\)")
ACR_REV_DEF_RE = re.compile(rf"(?<![\w\-])({ACR})\s*\(\s*([a-z][^()]{{2,80}})\)")
WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*(?:[-'][A-Za-z0-9]+)*")
BEGIN_MATH_RE = re.compile(r"\\begin\{(equation|align|gather|multline|eqnarray|displaymath|flalign|alignat)\*?\}")
END_MATH_RE = re.compile(r"\\end\{(equation|align|gather|multline|eqnarray|displaymath|flalign|alignat)\*?\}")
BOUNDARY_CMDS_RE = re.compile(
    r"\\(caption|item|footnote|section|subsection|subsubsection|paragraph|chapter|title)\*?(\[[^\]]*\])?\s*\{?"
)
UK_US_PAIRS = [
    ("grey", "gray"), ("judgement", "judgment"), ("judgements", "judgments"),
    ("acknowledgement", "acknowledgment"), ("programme", "program"), ("programmes", "programs"),
    ("towards", "toward"), ("amongst", "among"), ("whilst", "while"), ("learnt", "learned"),
    ("focussed", "focused"), ("focussing", "focusing"), ("defence", "defense"), ("offence", "offense"),
    ("licence", "license"), ("ageing", "aging"), ("enrolment", "enrollment"), ("fulfil", "fulfill"),
    ("skilful", "skillful"), ("oestrogen", "estrogen"), ("anaesthesia", "anesthesia"),
    ("paediatric", "pediatric"), ("haemoglobin", "hemoglobin"), ("foetal", "fetal"),
    ("manoeuvre", "maneuver"), ("catalogue", "catalog"), ("dialogue", "dialog"), ("analogue", "analog"),
    ("afterwards", "afterward"), ("backwards", "backward"), ("forwards", "forward"), ("upwards", "upward"),
]
UK_US_RULES = [
    (re.compile(r"^(\w{2,})is(e|ed|es|ing|ation|ations|er|ers|able)$"), r"\1iz\2"),
    (re.compile(r"^(\w{2,})ys(e|ed|es|ing|er|ers)$"), r"\1yz\2"),
    (re.compile(r"^(\w{3,})our(s|ed|ing|al|ally|ite|ites|able)?$"), r"\1or\2"),
    (re.compile(r"^(\w{2,})([bt])re(s|d)?$"), r"\1\2er\3"),
    (re.compile(r"^(\w*[aeiou])ll(ed|ing|er|ers)$"), r"\1l\2"),
]


@dataclass
class Para:
    text: str
    starts: list[int]
    lines: list[Line]
    heading: bool

    def line_at(self, offset: int) -> Line:
        return self.lines[max(0, bisect.bisect_right(self.starts, offset) - 1)]


@dataclass
class Tok:
    text: str
    para: int
    start: int
    end: int
    initial: bool
    heading: bool
    labelled: bool
    line: Line


def clean(raw: str) -> str:
    return plain_text(BOUNDARY_CMDS_RE.sub(" . ", raw))


def build_paragraphs(doc: Document) -> list[Para]:
    paras: list[Para] = []
    buf: list[str] = []
    starts: list[int] = []
    lines: list[Line] = []
    in_math = False

    def flush(heading: bool = False):
        nonlocal buf, starts, lines
        if buf:
            paras.append(Para(" ".join(buf), starts, lines, heading))
        buf, starts, lines = [], [], []

    for L in doc.body():
        raw = L.text
        if L.heading:
            flush()
            buf, starts, lines = [clean(raw)], [0], [L]
            flush(heading=True)
            continue
        if not raw.strip():
            flush()
            continue
        if in_math:
            m = END_MATH_RE.search(raw)
            if not m:
                continue
            in_math = False
            raw = raw[m.end() :]
        m = BEGIN_MATH_RE.search(raw)
        if m:
            end = END_MATH_RE.search(raw, m.end())
            if end:
                raw = raw[: m.start()] + " " + raw[end.end() :]
            else:
                raw, in_math = raw[: m.start()], True
        text = clean(raw)
        if not text:
            continue
        starts.append(sum(len(b) + 1 for b in buf))
        buf.append(text)
        lines.append(L)
    flush()
    return paras


def tokenize(paras: list[Para]) -> list[Tok]:
    toks: list[Tok] = []
    for pi, p in enumerate(paras):
        prev_end = 0
        for m in WORD_RE.finditer(p.text):
            gap = p.text[prev_end : m.start()]
            initial = prev_end == 0 or bool(re.search(r"[.?!:]", gap))
            labelled = bool(re.match(r"\s*(\d|[IVX]+\b|[A-Z]\b)", p.text[m.end() : m.end() + 6]))
            toks.append(Tok(m.group(0), pi, m.start(), m.end(), initial, p.heading, labelled, p.line_at(m.start())))
            prev_end = m.end()
    return toks


def loc(L: Line) -> str:
    return f"{L.file}:{L.num}"


def fmt_locs(lines: list[Line], cap: int) -> str:
    seen, out = set(), []
    for L in lines:
        k = loc(L)
        if k not in seen:
            seen.add(k)
            out.append(k)
    more = f" (+{len(out) - cap} more lines)" if len(out) > cap else ""
    return ", ".join(out[:cap]) + more


# ---------------------------------------------------------------- A. compounds
def check_compounds(toks: list[Tok]) -> list[tuple[str, dict[str, list[Line]]]]:
    forms: dict[str, dict[str, list[Line]]] = defaultdict(lambda: defaultdict(list))
    hyphen_parts: dict[str, int] = {}
    for t in toks:
        w = t.text.lower()
        if len(w.replace("-", "")) < 4 or "'" in w:
            continue
        key = w.replace("-", "")
        forms[key][w].append(t.line)
        if "-" in w:
            hyphen_parts[key] = max(hyphen_parts.get(key, 0), w.count("-") + 1)
    uni_keys = set(forms)
    for i in range(len(toks)):
        for k in (2, 3, 4, 5):
            grp = toks[i : i + k]
            if len(grp) < k or any(g.para != toks[i].para or "-" in g.text or "'" in g.text for g in grp):
                break
            words = [g.text.lower() for g in grp]
            key = "".join(words)
            if key not in uni_keys:
                continue
            closed_ok = k == 2 and not any(w in STOPWORDS or len(w) < 2 for w in words)
            if closed_ok or hyphen_parts.get(key) == k:
                forms[key][" ".join(words)].append(grp[0].line)
    out = [(key, f) for key, f in forms.items() if len(f) > 1]
    out.sort(key=lambda kv: -sum(len(v) for v in kv[1].values()))
    return out


# ---------------------------------------------------------------- B. capitalization
def check_case(toks: list[Tok]):
    covered: set[int] = set()
    bigrams: dict[str, dict[str, list[Line]]] = defaultdict(lambda: defaultdict(list))
    for i in range(len(toks) - 1):
        a, b = toks[i], toks[i + 1]
        # a sentence-initial first word is fine: "Working Memory" is still Title Case there
        if a.para != b.para or a.heading or b.labelled:
            continue
        if not (a.text.isalpha() and b.text.isalpha() and len(a.text) > 2 and len(b.text) > 2):
            continue
        if a.text.lower() in STOPWORDS or b.text.lower() in STOPWORDS:
            continue
        if a.text.istitle() and b.text.istitle():
            bigrams[f"{a.text} {b.text}".lower()][f"{a.text} {b.text}"].append(a.line)
            covered.update((i, i + 1))
        elif a.text.islower() and b.text.islower():
            key = f"{a.text} {b.text}"
            bigrams[key][key].append(a.line)
    # keep only phrases written both in Title Case and lowercase mid-sentence
    big_out = [(k, f) for k, f in bigrams.items() if len(f) > 1]
    real_covered = set()
    title_keys = {k for k, _ in big_out}
    for i in range(len(toks) - 1):
        if i in covered and f"{toks[i].text} {toks[i + 1].text}".lower() in title_keys:
            real_covered.update((i, i + 1))

    uni: dict[str, dict[str, list[Line]]] = defaultdict(lambda: defaultdict(list))
    for i, t in enumerate(toks):
        w = t.text
        if t.initial or t.heading or t.labelled or i in real_covered or len(w) < 3:
            continue
        uppers = sum(c.isupper() for c in w)
        if uppers > 1 or (uppers == 1 and not w[0].isupper()):
            continue
        uni[w.lower()][w].append(t.line)
    uni_out = [(k, f) for k, f in uni.items() if len(f) > 1]
    big_out.sort(key=lambda kv: -sum(len(v) for v in kv[1].values()))
    uni_out.sort(key=lambda kv: -sum(len(v) for v in kv[1].values()))
    return big_out, uni_out


# ---------------------------------------------------------------- C. acronyms
def schwartz_hearst(short: str, long_cand: str) -> str | None:
    """Shortest suffix of long_cand whose letters cover short in order (Schwartz & Hearst 2003)."""
    s_low, l_low = short.lower(), long_cand.lower()
    s, l = len(s_low) - 1, len(l_low) - 1
    while s >= 0:
        c = s_low[s]
        if not c.isalnum():
            s -= 1
            continue
        while l >= 0 and (l_low[l] != c or (s == 0 and l > 0 and l_low[l - 1].isalnum())):
            l -= 1
        if l < 0:
            return None
        l -= 1
        s -= 1
    start = long_cand.rfind(" ", 0, l + 1) + 1
    result = long_cand[start:].strip()
    return result if len(result) > len(short) else None


def norm_acr(a: str) -> str:
    if len(a) > 2 and a.endswith("s") and a[-2].isupper():
        return a[:-1]
    return a


def check_acronyms(doc: Document, paras: list[Para]):
    defs: dict[str, list[tuple[str, Line, tuple[int, int]]]] = defaultdict(list)
    uses: dict[str, list[tuple[Line, tuple[int, int]]]] = defaultdict(list)
    for pi, p in enumerate(paras):
        def_spans = []
        for m in ACR_DEF_RE.finditer(p.text):
            short = norm_acr(m.group(1))
            before = p.text[: m.start()].rstrip()
            words = before.split()
            window = " ".join(words[-min(len(short) + 5, 2 * len(short)) :])
            long_form = schwartz_hearst(short, window)
            if long_form:
                defs[short].append((long_form, p.line_at(m.start()), (pi, m.start())))
                def_spans.append((m.start(), m.end()))
        for m in ACR_REV_DEF_RE.finditer(p.text):
            short = norm_acr(m.group(1))
            long_form = schwartz_hearst(short, m.group(2).strip())
            if long_form and long_form.lower().startswith(m.group(2).strip().lower()[:3]):
                defs[short].append((m.group(2).strip(), p.line_at(m.start()), (pi, m.start())))
                def_spans.append((m.start(2) - 1, m.end()))
        for m in ACR_TOKEN_RE.finditer(p.text):
            if any(a <= m.start() < b for a, b in def_spans):
                continue
            a = norm_acr(m.group(1))
            if a in COMMON_ACRONYMS or re.fullmatch(r"[IVXLC]+", a):
                continue
            uses[a].append((p.line_at(m.start()), (pi, m.start())))

    glossary = {}
    for L in doc.lines:
        for m in re.finditer(r"\\newacronym(?:\[[^\]]*\])?\{([^{}]*)\}\{([^{}]*)\}\{([^{}]*)\}", L.text):
            glossary[m.group(2)] = (m.group(1), m.group(3), L)

    report = defaultdict(list)
    for a, ds in defs.items():
        if a in glossary:
            continue
        ds.sort(key=lambda d: d[2])
        first_order = ds[0][2]
        if len(ds) > 1:
            expansions = {re.sub(r"\W+", " ", d[0].lower()).strip().rstrip("s") for d in ds}
            tag = "DIFFERENT expansions" if len(expansions) > 1 else "same expansion"
            items = "; ".join(f'"{d[0]}" at {loc(d[1])}{where(d[1])}' for d in ds)
            report["defined more than once"].append(f"{a} ({tag}): {items}")
        us = sorted(uses.get(a, []), key=lambda u: u[1])
        early = [u for u in us if u[1] < first_order]
        if early:
            report["used before its first definition"].append(
                f"{a}: first used at {loc(early[0][0])}, defined at {loc(ds[0][1])}"
            )
        after = [u for u in us if u[1] > first_order]
        if len(after) <= 1:
            report["defined but used at most once afterwards"].append(
                f"{a} (\"{ds[0][0]}\", defined {loc(ds[0][1])}): {len(after)} later use(s)"
            )
        long_form = ds[0][0]
        pat = re.compile(r"(?<![\w-])" + r"\s+".join(map(re.escape, long_form.split())) + r"s?(?![\w-])", re.I)
        reuse = []
        for pi, p in enumerate(paras):
            for m in pat.finditer(p.text):
                if (pi, m.start()) > first_order and not any(
                    d[2][0] == pi and 0 <= d[2][1] - m.end() < 4 for d in ds
                ):
                    reuse.append(p.line_at(m.start()))
        if reuse:
            report["long form still written out after the acronym is defined"].append(
                f"{a} = \"{long_form}\" (defined {loc(ds[0][1])}): long form {len(reuse)}x after, "
                f"acronym {len(after)}x after; long form at {fmt_locs(reuse, 6)}"
            )
    for a, us in sorted(uses.items(), key=lambda kv: -len(kv[1])):
        if a in defs or a in glossary:
            continue
        report["used but never defined"].append(f"{a}: {len(us)}x, first at {loc(us[0][0])}")
    if glossary:
        for short, (key, long_form, L) in glossary.items():
            raw = uses.get(short, [])
            if raw:
                report["glossary acronym typed directly instead of via \\gls"].append(
                    f"{short} (\\newacronym{{{key}}} at {loc(L)}): {len(raw)} raw use(s) at "
                    f"{fmt_locs([u[0] for u in raw], 6)}"
                )
    return report


def where(L: Line) -> str:
    if "\\caption" in L.text:
        return " [caption]"
    if L.section.split(" › ")[0].lower().startswith("abstract"):
        return " [abstract]"
    return ""


# ---------------------------------------------------------------- D. spelling
def to_us(w: str) -> str | None:
    for rx, rep in UK_US_RULES:
        if rx.match(w):
            return rx.sub(rep, w)
    return None


def check_spelling(toks: list[Tok]):
    vocab: dict[str, list[Line]] = defaultdict(list)
    for t in toks:
        vocab[t.text.lower()].append(t.line)
    pairs = []
    seen = set()
    for w in list(vocab):
        us = to_us(w)
        if us and us != w and us in vocab and (w, us) not in seen:
            pairs.append((w, us))
            seen.add((w, us))
    for uk, us in UK_US_PAIRS:
        if uk in vocab and us in vocab and (uk, us) not in seen:
            pairs.append((uk, us))
    return [(uk, us, vocab[uk], vocab[us]) for uk, us in pairs]


# ---------------------------------------------------------------- E/F. styles
STYLE_GROUPS = {
    "Figure references": [
        ("Fig.", r"\bFig\.(?!s)"), ("Figs.", r"\bFigs\."), ("Figure", r"\bFigures?\b"),
        ("fig.", r"\bfigs?\.(?!\w)"), ("figure + \\ref (lowercase)", r"\bfigures?\s*~?\s*\\(?:ref|cref)\{"),
    ],
    "Equation references": [
        ("Eq.", r"\bEqs?\.(?!\w)"), ("Equation", r"\bEquations?\b"), ("eq.", r"\beqs?\.(?!\w)"),
        ("\\eqref only", r"(?<![A-Za-z.~ ])\s*\\eqref\{"),
    ],
    "Table references": [("Table", r"\bTables?\b"), ("Tab.", r"\bTabs?\.(?!\w)"), ("table + \\ref (lowercase)", r"\btables?\s*~?\s*\\(?:ref|cref)\{")],
    "Section references": [
        ("Section", r"\bSections?\s*~?\s*\\(?:ref|cref)\{"), ("Sec.", r"\bSecs?\.(?!\w)"),
        ("section + \\ref (lowercase)", r"\bsections?\s*~?\s*\\(?:ref|cref)\{"), ("§", r"§|\\S(?![A-Za-z])"),
    ],
    "Supplement naming": [
        ("Supplementary", r"\bSupplementary\b"), ("Supplemental", r"\bSupplemental\b"),
        ("Supplement", r"\bSupplement\b"), ("Supporting Information", r"\bSupporting Information\b"),
        ("SI", r"\bSI\b"), ("Appendix", r"\bAppendix\b"),
    ],
    "Cross-reference commands": [
        ("\\ref", r"\\ref\{"), ("\\cref/\\Cref", r"\\[cC]ref\{"), ("\\autoref", r"\\autoref\{"),
    ],
    "Percent": [("\\%", r"\\%"), ("percent / per cent", r"\bper\s?cent\b")],
    "p-value leading zero": [
        ("p < .05 (no leading zero)", r"(?:\\textit\{p\}|\\emph\{p\}|\$p\$?|(?<![\w\\])p)\s*\$?\s*(?:<|>|=|\\le|\\ge|\\leq|\\geq)\s*\$?\s*\.\d"),
        ("p < 0.05 (leading zero)", r"(?:\\textit\{p\}|\\emph\{p\}|\$p\$?|(?<![\w\\])p)\s*\$?\s*(?:<|>|=|\\le|\\ge|\\leq|\\geq)\s*\$?\s*0\.\d"),
    ],
    "e.g. / i.e. punctuation": [
        ("e.g.,", r"\be\.g\.,"), ("e.g. (no comma)", r"\be\.g\.(?![,\w])"),
        ("i.e.,", r"\bi\.e\.,"), ("i.e. (no comma)", r"\bi\.e\.(?![,\w])"),
    ],
    "et al. punctuation": [("et al.", r"\bet al\."), ("et al (no period)", r"\bet al\b(?!\.)")],
    "Number-unit spacing": [
        ("spaced (200 ms)", r"\b\d+(?:\.\d+)?(?:\s|~|\\,|\\ )(?:ms|Hz|kHz|cm|mm|km|kg|mg|ml|mL|min|dB)\b"),
        ("unspaced (200ms)", r"\b\d+(?:\.\d+)?(?:ms|Hz|kHz|cm|mm|km|kg|mg|ml|mL|min|dB)\b"),
    ],
}
LABEL_RE = re.compile(
    r"\b(Experiments?|experiments?|Exps?\.|Expts?\.|Stud(?:y|ies)|stud(?:y|ies)|Hypothes[ie]s|hypothes[ie]s|"
    r"Predictions?|predictions?|Models?|models?|Conditions?|conditions?)\s*~?\s*(\d+[a-z]?|[IVX]+\b|[A-Z]\b|\\ref)"
)


def check_styles(doc: Document):
    body = doc.body()
    out = []
    for group, pats in STYLE_GROUPS.items():
        hits = []
        for label, rx in pats:
            r = re.compile(rx)
            ls = [L for L in body for _ in r.finditer(L.text)]
            if ls:
                hits.append((label, ls))
        if len(hits) > 1:
            out.append((group, hits))
    labels: dict[str, dict[str, list[Line]]] = defaultdict(lambda: defaultdict(list))
    for L in body:
        for m in LABEL_RE.finditer(L.text):
            w = m.group(1)
            fam = re.sub(r"[^a-z]", "", w.lower())[:4]
            fam = {"expe": "experiment", "exps": "experiment", "exp": "experiment", "expt": "experiment",
                   "stud": "study", "hypo": "hypothesis", "pred": "prediction", "mode": "model",
                   "cond": "condition"}.get(fam, fam)
            labels[fam][w].append(L)
    for L in body:
        for m in re.finditer(r"(?<![\w\\])H\d\b", L.text):
            labels["hypothesis"]["H1-style"].append(L)
    for fam, forms in labels.items():
        if len(forms) > 1:
            out.append((f"Numbered labels: {fam}", sorted(forms.items(), key=lambda kv: -len(kv[1]))))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--root")
    ap.add_argument("--out")
    ap.add_argument("--max-locs", type=int, default=8)
    args = ap.parse_args()
    cap = args.max_locs

    doc = flatten(args.path, args.root)
    paras = build_paragraphs(doc)
    toks = tokenize(paras)
    w = []
    w.append(f"# Terminology candidates for {doc.main}")
    w.append("Heuristic output. Verify every item in context before reporting it.\n")

    w.append("## A. Hyphenation / spacing / closed-compound variants")
    w.append("Hyphenated compound modifiers before a noun (\"long-term memory\") and open forms elsewhere "
             "(\"in the long term\") are both correct. Flag only same-role mixes.")
    comp = check_compounds(toks)
    for key, forms in comp:
        parts = [f'"{f}" x{len(ls)} [{fmt_locs(ls, cap)}]' for f, ls in sorted(forms.items(), key=lambda kv: -len(kv[1]))]
        w.append("- " + " vs ".join(parts))
    if not comp:
        w.append("- none found")

    w.append("\n## B. Mid-sentence capitalization variants")
    big, uni = check_case(toks)
    for key, forms in big + uni:
        parts = [f'"{f}" x{len(ls)} [{fmt_locs(ls, cap)}]' for f, ls in sorted(forms.items(), key=lambda kv: -len(kv[1]))]
        w.append("- " + " vs ".join(parts))
    if not (big or uni):
        w.append("- none found")

    w.append("\n## C. Acronyms")
    acr = check_acronyms(doc, paras)
    order = ["defined more than once", "used before its first definition",
             "long form still written out after the acronym is defined", "used but never defined",
             "defined but used at most once afterwards", "glossary acronym typed directly instead of via \\gls"]
    for k in order:
        if acr.get(k):
            w.append(f"### {k}")
            w.extend(f"- {item}" for item in acr[k])
    if not any(acr.values()):
        w.append("- none found")

    w.append("\n## D. UK/US spelling mixes")
    sp = check_spelling(toks)
    for uk, us, lu, ls in sp:
        w.append(f'- "{uk}" x{len(lu)} [{fmt_locs(lu, cap)}] vs "{us}" x{len(ls)} [{fmt_locs(ls, cap)}]')
    if not sp:
        w.append("- none found")

    w.append("\n## E/F. Reference, label and formatting styles (groups with more than one style)")
    st = check_styles(doc)
    for group, hits in st:
        w.append(f"### {group}")
        for label, ls in hits:
            w.append(f"- {label}: x{len(ls)} [{fmt_locs(ls, cap)}]")
    if not st:
        w.append("- none found")

    text = "\n".join(w) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        n = len(comp) + len(big) + len(uni) + sum(len(v) for v in acr.values()) + len(sp) + len(st)
        print(f"Wrote {args.out}: {n} candidate groups")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
