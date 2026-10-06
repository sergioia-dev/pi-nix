#!/usr/bin/env python3
"""Self-check for the three code patches in this directory.

The patches are carried locally (see ../graphify.nix) until upstream releases
them, so nothing else in the toolchain would notice if one of them stopped
doing what it claims, or if a rebase onto a newer tag quietly dropped a hunk
that `patch` accepted as fuzzy. This script exercises the *installed* modules:

  * h4-reconcile-source-files  `_unit_rel`, `_reconcile_source_files`
  * h1-omission-recovery       `_reported_source_files`,
                               `_missing_dispatched_rels` and the recovery
                               branch of `_extract_with_adaptive_retry`
  * h3-save-cache-warning      `_path_looks_mangled`

`extract_files_direct` is stubbed out and every fixture is written under
`TMPDIR`, so the check needs no network, no API key and no corpus. It runs as
part of `nix build` on the top-level derivation.

Run it by hand:  <graphifyEnv>/bin/python3.14 nix/patches/selfcheck-graphify-fixes.py
"""

import pathlib
import sys
import tempfile
import unicodedata

import graphify.llm as L
from graphify.cache import _path_looks_mangled
from graphify.llm import (
    _missing_dispatched_rels,
    _reconcile_source_files,
    _reported_source_files,
    _unit_rel,
)

FAILS: list[str] = []


def check(cond: bool, label: str) -> None:
    print(("  PASS " if cond else "  FAIL ") + label)
    if not cond:
        FAILS.append(label)


# ---------------------------------------------------------------------------
# Fixtures: a corpus whose names carry the two shapes the BANCO-WIKI run hit —
# percent-encoded dashes and decomposed accents.
#
root = pathlib.Path(tempfile.mkdtemp(prefix="graphify-selfcheck-"))
(root / "419---Depositos-Judiciales-BAC").mkdir()
(root / "sub").mkdir()
(root / "other").mkdir()

f_plain = root / "419---Depositos-Judiciales-BAC" / "informe.md"
f_accent = root / "sub" / "Dep\u00f3sitos.md"  # NFC on disk
f_notes = root / "sub" / "notes.md"
f_dup_a = root / "sub" / "dup.md"
f_dup_b = root / "other" / "dup.md"
f_blank = root / "sub" / "blank.md"
for p in (f_plain, f_accent, f_notes, f_dup_a, f_dup_b, f_blank):
    p.write_text("some content\n", encoding="utf-8")
f_blank.write_text("   \n\n", encoding="utf-8")

units = [f_plain, f_accent, f_notes]
rel_plain = "419---Depositos-Judiciales-BAC/informe.md"
nfd = unicodedata.normalize("NFD", "sub/Dep\u00f3sitos.md")
nfc = unicodedata.normalize("NFC", "sub/Dep\u00f3sitos.md")

print("H4: _unit_rel")
check(_unit_rel(f_plain, root) == rel_plain, "unit_rel is the posix relative path")
check(
    _unit_rel(pathlib.Path("/elsewhere/x.md"), root) == "/elsewhere/x.md",
    "a unit outside the root falls back to its own path",
)


def reconcile(pairs):
    """pairs: [(source_file, expected_after)] over `units`; returns corrected count."""
    result = {"nodes": [{"source_file": sf, "label": "n"} for sf, _ in pairs], "edges": []}
    n = _reconcile_source_files(result, units, root)
    got = [item["source_file"] for item in result["nodes"]]
    exp = [e for _, e in pairs]
    check(got == exp, f"reconcile {[sf for sf, _ in pairs]} -> {got}")
    return n


print("H4: _reconcile_source_files")
reconcile([(rel_plain, rel_plain)])  # exact spelling: untouched
reconcile([("419-%2D-Depositos-Judiciales-BAC/informe.md", rel_plain)])  # percent-encoded
reconcile([(nfd, nfc)])  # decomposed accent
reconcile([("sub/Depo%CC%81sitos.md", nfc)])  # percent-encoded NFD accent
reconcile([("./sub/notes.md", "sub/notes.md")])  # ./ prefix
reconcile([("sub//notes.md", "sub/notes.md")])  # doubled slash
reconcile([("notes.md", "sub/notes.md")])  # unique basename
reconcile([(str(f_plain), rel_plain)])  # absolute path
reconcile([("concept:retry-policy", "concept:retry-policy")])  # legitimate non-path
reconcile([("sub/unknown.md", "sub/unknown.md")])  # not dispatched: untouched

check(
    _reconcile_source_files({"nodes": [{"source_file": "dup.md"}]}, [f_dup_a, f_dup_b], root) == 0,
    "an ambiguous basename is never guessed",
)

n = reconcile([(rel_plain, rel_plain), ("419-%2D-Depositos-Judiciales-BAC/informe.md", rel_plain)])
check(n == 1, f"only the mangled item counts as corrected (got {n})")

print("H4 -> H1 interaction: reconciliation must run before omission detection")
chunk = [f_plain, f_accent, f_notes]
mangled = {
    "nodes": [
        {"source_file": "419-%2D-Depositos-Judiciales-BAC/informe.md"},
        {"source_file": nfd},
        {"source_file": "sub/notes.md"},
    ]
}
check(
    _missing_dispatched_rels(chunk, mangled, root) != [],
    "before reconciliation, mangled paths look like omissions",
)
_reconcile_source_files(mangled, chunk, root)
check(_missing_dispatched_rels(chunk, mangled, root) == [], "after reconciliation the chunk is complete")

print("H1: _reported_source_files / _missing_dispatched_rels")
check(
    _reported_source_files(
        {
            "nodes": [{"source_file": "a"}],
            "edges": [{"source_file": "b"}],
            "hyperedges": [{"source_file": "c"}],
        }
    )
    == {"a", "b", "c"},
    "collects nodes+edges+hyperedges",
)
partial = {"nodes": [{"source_file": rel_plain}]}
check(
    _missing_dispatched_rels(chunk, partial, root) == [nfc, "sub/notes.md"],
    "reports only the omitted files, in prompt order",
)
check(
    _missing_dispatched_rels(chunk, {"nodes": [{"source_file": r} for r in (rel_plain, nfc, "sub/notes.md")]}, root) == [],
    "a complete chunk has no omissions",
)
check(_missing_dispatched_rels([f_blank], {"nodes": []}, root) == [], "a whitespace-only file is not an omission")
check(
    _missing_dispatched_rels([root / "sub" / "missing.md"], {"nodes": []}, root) == [],
    "an unreadable file is not an omission",
)
check(
    _missing_dispatched_rels(chunk, {"nodes": []}, root) == [rel_plain, nfc, "sub/notes.md"],
    "an empty parse reports every text file",
)

print("H3: _path_looks_mangled")
check(_path_looks_mangled("419-%2D-x.md") is True, "percent-encoded")
check(_path_looks_mangled(nfd) is True, "non-NFC")
check(_path_looks_mangled(nfc) is False, "NFC path")
check(_path_looks_mangled("sub/plain.md") is False, "plain path")
check(_path_looks_mangled("") is False, "empty string")
check(_path_looks_mangled("100%25done.md") is True, "escaped percent")

# ---------------------------------------------------------------------------
# H1/H2 recovery, driven through the real retry loop with the extractor stubbed.
#
root2 = pathlib.Path(tempfile.mkdtemp(prefix="graphify-selfcheck-retry-"))
rchunk = [root2 / f"f{i}.md" for i in range(3)]
for p in rchunk:
    p.write_text(f"# {p.name}\n\nreal content\n", encoding="utf-8")
rrels = [f"f{i}.md" for i in range(3)]

calls: list[list[str]] = []


def _result(paths, *, itok=10, otok=1, model="m", reason="stop"):
    return {
        "nodes": [{"source_file": p} for p in paths],
        "edges": [],
        "hyperedges": [],
        "input_tokens": itok,
        "output_tokens": otok,
        "model": model,
        "finish_reason": reason,
    }


def install(report_first):
    """Stub `extract_files_direct`: the first call (the full chunk) reports
    `report_first`, every later call (a re-dispatched subset) reports everything
    it was handed."""
    calls.clear()

    def fake(c, backend=None, api_key=None, model=None, root=None, deep_mode=False):
        got = [_unit_rel(u, root) for u in c]
        calls.append(got)
        if len(calls) == 1:
            return _result(report_first)
        return _result(got, itok=5)

    L.extract_files_direct = fake


real_extract = L.extract_files_direct

print("H1: a silent partial omission re-dispatches only the omitted units")
install([rrels[0]])
res = L._extract_with_adaptive_retry(list(rchunk), "gemini", "k", "m", root2, 3)
check(calls == [rrels, rrels[1:]], f"full chunk, then the omitted subset only (calls={calls})")
check(sorted(n["source_file"] for n in res["nodes"]) == rrels, "every dispatched file reaches the merged result")
check(res["input_tokens"] == 15 and res["output_tokens"] == 2, "token accounting is summed, not dropped")
check(res["finish_reason"] == "stop", "the merged result reports a clean finish")
check(res.get("_partial_files", []) == [], "nothing is left marked partial once the gap is recovered")
check(not any(n.get("_partial") for n in res["nodes"]), "the already-paid-for items stay cacheable")

print("H2: the recovery is scoped, so covered files are not re-billed")
check(all(rrels[0] not in c for c in calls[1:]), f"the reported file is never re-sent (calls={calls})")

print("H1: a complete response costs no extra call")
install(rrels)
res = L._extract_with_adaptive_retry(list(rchunk), "gemini", "k", "m", root2, 3)
check(calls == [rrels], f"exactly one call (calls={calls})")
check(res.get("_partial_files", []) == [], "nothing marked partial")

print("H1: at the depth cap, only the omitted files are stamped partial")
install([rrels[0]])
res = L._extract_with_adaptive_retry(list(rchunk), "gemini", "k", "m", root2, 0)
check(calls == [rrels], f"no recursion at max_depth=0 (calls={calls})")
check(res["_partial_files"] == rrels[1:], f"the omitted files are stamped partial (got {res['_partial_files']})")
check(not any(n.get("_partial") for n in res["nodes"]), "the covered item is not stamped partial")

print("H1: a fully omitted chunk is stamped partial instead of bisected 2**depth times")
install([])
res = L._extract_with_adaptive_retry(list(rchunk), "gemini", "k", "m", root2, 3)
check(calls == [rrels], f"no re-derivation storm (calls={calls})")
check(res["_partial_files"] == rrels, "every dispatched file is stamped partial")

print("H1: a whitespace-only file never triggers the recovery path")
install([rrels[0]])
res = L._extract_with_adaptive_retry([rchunk[0], f_blank], "gemini", "k", "m", root, 3)
check(res.get("_partial_files", []) == [], "an empty file is treated as extracted, not omitted")

L.extract_files_direct = real_extract

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("ALL CHECKS PASSED")
