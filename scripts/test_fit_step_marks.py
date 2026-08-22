#!/usr/bin/env python3
"""RED/GREEN self-test for scripts/fit_step_marks.py.

WHY A HARNESS NEEDS A HARNESS. fit_step_marks.py is the only thing in this
repository that checks the step marks' acceptance criterion, and a checker that
cannot fail is worth nothing. Each case below FEEDS IT A FILE THAT IS WRONG IN
ONE NAMED WAY and requires it to say so -- the same shape
scripts/test_check_ceiling_notes.py and scripts/test_cue_replay.py use.

The four mutants are the four ways this feature can actually be broken:

  1. LATCHED   a work interval's records carry the previous step's code. This
               is not hypothetical: record-scope FitContributor fields LATCH, so
               a withheld setData re-emits the last value, and the whole reason
               the app writes these marks on EVERY tick is to stop exactly this.
  2. ZEROED    a record says SFIT_WORK with interval_num 0. The two fields then
               disagree about whether the second is work, and a consumer
               grouping by interval would silently drop it.
  3. RENAMED   the field_description carries a different name. A consumer
               resolves developer fields by NAME, so the query finds nothing --
               and must not pass by finding nothing.
  4. UNDESCRIBED  a developer field appears in a record with no
               field_description. It is unreadable by any consumer; the decoder
               must refuse it rather than guess.

Pure Python: no container, no SDK, no network. Runs on a stock runner.

THE fitparse LEG, when python-fitparse is importable, decodes the SAME BYTES
with a third-party decoder that knows nothing about this repository -- which is
what keeps "our encoder and our decoder agree" from being the whole of the
evidence. It is NOT in the CI container, so the leg is skipped there and says
so; it is not a silent pass either way.

Exit 0 = every case behaved, 1 = one did not.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
sys.path.insert(0, HERE)

import fit_step_marks as F   # noqa: E402


FAILURES = []


def case(name, ok, detail=""):
    print("  %-46s %s" % (name, "OK" if ok else "FAIL"))
    if not ok:
        FAILURES.append("%s: %s" % (name, detail))


def intended_from(tl, codes, t0):
    out = {}
    t = t0
    for step, ivl, secs in tl:
        if step == codes["SFIT_WORK"]:
            out.setdefault(ivl, set()).update(range(t, t + secs))
        t += secs
    return out


def main():
    codes = F.read_codes(ROOT)
    fields = F.read_fields(ROOT)
    t0 = 1000000000
    print("step marks, as the source declares them:")
    print("  codes  %s" % ", ".join("%s=%d" % (k, codes[k])
                                    for k in sorted(codes)))
    for f in fields:
        print("  field  %-18s id %-3d base 0x%02X mesg %d"
              % (f["name"], f["id"], f["base_type"], f["mesg"]))

    print("\nGREEN: the shipped scenario")
    problems = F.check(ROOT, verbose=False)
    case("the criterion holds on a correct file", not problems,
         "; ".join(problems))

    tl, intended = F.scenario(codes)
    want = dict((k, set(t0 + s for s in v)) for k, v in intended.items())

    print("\nRED: four mutants, each wrong in one named way")

    # 1. LATCHED -- the third work interval re-emits the preceding rest's code.
    mut = list(tl)
    mut[5] = (codes["SFIT_REST"], codes["IVL_NONE"], 120)
    data, _ = F.build(mut, codes, fields, t0)
    recs, _ = F.decode(data)
    got = F.select_by_fields(recs, codes)
    case("a latched work interval is not selected",
         set(got.keys()) != set(want.keys()),
         "a shortened piece whose records re-emitted the rest's code was still "
         "recovered, so the harness cannot see the latch it exists to guard")

    # 2. ZEROED -- SFIT_WORK with interval_num 0.
    mut = list(tl)
    mut[1] = (codes["SFIT_WORK"], codes["IVL_NONE"], 180)
    data, _ = F.build(mut, codes, fields, t0)
    recs, _ = F.decode(data)
    raised = False
    try:
        F.select_by_fields(recs, codes)
    except ValueError:
        raised = True
    case("work seconds with interval 0 are refused", raised,
         "the query accepted a record whose two marks disagree about whether "
         "the second is work")

    # 3. RENAMED -- the description says something else, so the query finds
    #    nothing. Finding nothing must not read as success.
    renamed = [dict(f) for f in fields]
    renamed[0]["name"] = "step_kind"
    data, _ = F.build(tl, codes, renamed, t0)
    recs, _ = F.decode(data)
    got = F.select_by_fields(recs, codes)
    case("a renamed field yields no work seconds", got == {},
         "a file whose step mark is described under another name still "
         "answered the query, so the query is not reading the description")

    # 4. UNDESCRIBED -- a developer field with no field_description at all.
    data, _ = F.build(tl, codes, fields, t0,
                      describe=set(["interval_num", "lap_step_type",
                                    "lap_interval_num"]))
    raised = False
    try:
        F.decode(data)
    except ValueError:
        raised = True
    case("an undescribed developer field is refused", raised,
         "the decoder read a developer field that carried no "
         "field_description, which no consumer could resolve")

    print("\nINDEPENDENT DECODE")
    try:
        import fitparse                             # noqa: F401
    except ImportError:
        print("  python-fitparse is not importable here, so the same bytes "
              "were NOT read by a third-party decoder in this run.")
        print("  (It is absent from the CI container by design -- the leg is "
              "skipped, never silently passed.)")
    else:
        import io
        data, base = F.build(tl, codes, fields, t0)
        ff = fitparse.FitFile(io.BytesIO(data))
        recs = list(ff.get_messages("record"))
        laps = list(ff.get_messages("lap"))
        by_ivl = {}
        for r in recs:
            d = dict((x.name, x.value) for x in r)
            if d.get("step_type") == codes["SFIT_WORK"]:
                by_ivl[d.get("interval_num")] = \
                    by_ivl.get(d.get("interval_num"), 0) + 1
        mine = dict((k, len(v)) for k, v in want.items())
        case("fitparse reads the same file", len(recs) == 910 and len(laps) == 8,
             "fitparse saw %d records and %d laps" % (len(recs), len(laps)))
        case("fitparse recovers the same work seconds", by_ivl == mine,
             "fitparse: %s, intended: %s" % (by_ivl, mine))
        print("  fitparse decoded %d records and %d laps; work seconds by "
              "interval %s" % (len(recs), len(laps), by_ivl))

    print("")
    if FAILURES:
        print("FAIL: %d case(s)." % len(FAILURES))
        for f in FAILURES:
            print("  - %s" % f)
        return 1
    print("OK: the acceptance harness fails on every mutant and passes on the "
          "shipped scenario.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
