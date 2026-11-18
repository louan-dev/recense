# Derived from Spec: FEAT-01 (pronunciation cases, `python3 -I text/test_rules.py`)
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).parent))
import clean, re
meta, rules = clean.load("mpep"); sp = clean.stage(rules, "speech")
cases = {
 "See MPEP § 1901.07(a).": "See M.P.E.P. section nineteen oh-one point oh seven a.",
 "under 37 CFR 1.291(d) applies": "under 37 C.F.R. one point two nine one d applies",
 "35 U.S.C. 122(c)": "35 U.S. Code one twenty-two c",
 "§ 609.04": "section six oh-nine point oh four",
 "§ 2100": "section twenty-one hundred",
}
bad = 0
for i, want in cases.items():
    got = clean.apply(i, sp)
    if got != want: bad += 1; print("FAIL", repr(i), "->", repr(got), "want", repr(want))
print("ok" if not bad else f"{bad} failed")
