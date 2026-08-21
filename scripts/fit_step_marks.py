#!/usr/bin/env python3
"""Acceptance harness for the step marks: step_type (17) and interval_num (18).

THE CRITERION, written down so it can be checked rather than admired:

    FROM THE FIT ALONE, WITH NO DURATION HEURISTIC, A CONSUMER MUST BE ABLE TO
    SELECT EXACTLY THE WORK SECONDS AND GROUP THEM BY INTERVAL.

WHY IT NEEDS A HARNESS AT ALL. In the files this app wrote before these fields,
a lap is just a lap: on activity i178249719 there are 17 laps and nothing
distinguishes the eight 180 s work pieces from the rests, the warm-up or the
cool-down. Every consumer had to guess from duration -- the analyses in #124 and
#149 all filtered laps on "170 <= duration <= 190" -- and that guess is wrong in
both directions:

  * it DROPS a piece shortened for chop. One ran 820 s of a planned 900 and
    vanished from the analysis entirely.
  * it MISCLASSIFIES a rest that happens to run a piece's length, which on a
    3'/3' session is every rest.

The scenario below contains ONE OF EACH, on purpose, so the two selections can
be compared on the same file: the field-based one must recover the intended set
exactly, and the duration heuristic must NOT. A harness in which both succeed
would prove the fields are redundant.

WHAT THIS PROVES AND WHAT IT DOES NOT -- read before quoting it.

  IT PROVES the SELECTION RULE. A real FIT byte stream carrying these two
  developer fields, with the field_description messages a decoder needs, is
  built, written, read back through a decoder that resolves developer fields BY
  NAME (as a consumer would -- it is not handed the ids), and queried using ONLY
  step_type and interval_num.

  IT DOES NOT PROVE THAT THIS APP WRITES SUCH A FILE. The bytes here are
  synthetic. Nothing in this repository can obtain a Session or decode a file
  the app produced; the write side is pinned in source/StepMarkTest.mc, which
  observes the ARGUMENT of each setData call, and the gap between the two is a
  [Local] simulator session. Do not describe this harness as a decode of a
  StrongRow activity.

  THE CODES ARE READ OUT OF THE SOURCE, never transcribed. SFIT_*, IVL_* and the
  four (name, id, type, scope) tuples are parsed from source/StrongRowView.mc,
  so a renumbering there moves this harness with it or fails it loudly. That is
  the same anti-drift rule scripts/check_ceiling_notes.py applies to prose.

  THE DECODER IS OURS, and that is a real limitation: an encoder and a decoder
  written together can share a misreading of the FIT spec and agree anyway. Two
  things narrow it. The decoder is STRUCTURE-DRIVEN -- it reads the definition
  messages and applies them, and resolves developer fields through the
  field_description messages by name, so an encoder that wrote the wrong id or
  name into a description would fail it. And when python-fitparse is importable
  (it is not in the CI container) the self-test decodes the SAME BYTES with it
  as an independent reading; scripts/test_fit_step_marks.py reports which legs
  ran.

Usage:
  fit_step_marks.py [--root DIR] [--write PATH]

Exit 0 = the criterion holds on the generated file, 1 = it does not.
"""

import argparse
import os
import re
import struct
import sys

# ---------------------------------------------------------------------------
# FIT base types used here. The value is the fit_base_type_id byte that goes
# into a field_description and into a definition message.
BT_ENUM = 0x00
BT_UINT8 = 0x02
BT_STRING = 0x07
BT_UINT16 = 0x84
BT_UINT32 = 0x86
BT_BYTE = 0x0D

BT_SIZE = {BT_ENUM: 1, BT_UINT8: 1, BT_STRING: 1, BT_UINT16: 2,
           BT_UINT32: 4, BT_BYTE: 1}

MESG_FILE_ID = 0
MESG_LAP = 19
MESG_RECORD = 20
MESG_DEV_DATA_ID = 207
MESG_FIELD_DESC = 206

# Monkey C type name -> (fit_base_type_id, struct format)
MC_TYPE = {
    "DATA_TYPE_UINT8": (BT_UINT8, "<B"),
    "DATA_TYPE_UINT16": (BT_UINT16, "<H"),
    "DATA_TYPE_UINT32": (BT_UINT32, "<I"),
}

MC_SCOPE = {
    "MESG_TYPE_RECORD": MESG_RECORD,
    "MESG_TYPE_LAP": MESG_LAP,
}


def crc16(data, crc=0):
    """The FIT CRC, as the FIT protocol document defines it."""
    table = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
             0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
    for byte in bytearray(data):
        tmp = table[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ table[byte & 0xF]
        tmp = table[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ table[(byte >> 4) & 0xF]
    return crc


# ---------------------------------------------------------------------------
# Reading the app's own constants, so this harness cannot drift from them.

def _src(root):
    path = os.path.join(root, "source", "StrongRowView.mc")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read(), path


def read_codes(root):
    """SFIT_* / IVL_* as the source declares them. Fails closed."""
    text, path = _src(root)
    want = ["SFIT_NONE", "SFIT_WARM", "SFIT_WORK", "SFIT_REST", "SFIT_GATE",
            "SFIT_COOL", "SFIT_DONE", "IVL_NONE", "IVL_MAX"]
    out = {}
    for name in want:
        m = re.search(r"^const\s+%s\s*=\s*(\d+)\s*;" % name, text, re.M)
        if not m:
            raise SystemExit(
                "FAIL: %s declares no `const %s` -- this harness reads the wire "
                "codes from the source and refuses to invent them." % (path, name))
        out[name] = int(m.group(1))
    return out


def read_fields(root):
    """The four step-mark createField calls, as declared.

    Returns [{name, id, base_type, fmt, mesg}], in declaration order. Fails
    closed if any of the four is missing: a harness that silently tested three
    fields would pass while the fourth was deleted.
    """
    text, path = _src(root)
    pat = re.compile(
        r'"(?P<name>step_type|interval_num|lap_step_type|lap_interval_num)"\s*,\s*'
        r'(?P<id>\d+)\s*,\s*Fit\.(?P<type>DATA_TYPE_\w+)\s*,\s*'
        r'\{\s*:mesgType\s*=>\s*Fit\.(?P<mesg>MESG_TYPE_\w+)')
    found = {}
    for m in pat.finditer(text):
        base, fmt = MC_TYPE[m.group("type")]
        found[m.group("name")] = {
            "name": m.group("name"),
            "id": int(m.group("id")),
            "base_type": base,
            "fmt": fmt,
            "mesg": MC_SCOPE[m.group("mesg")],
        }
    missing = [n for n in ("step_type", "interval_num",
                           "lap_step_type", "lap_interval_num")
               if n not in found]
    if missing:
        raise SystemExit(
            "FAIL: %s declares no createField for %s -- the acceptance harness "
            "cannot test a field the app does not create."
            % (path, ", ".join(missing)))
    return [found["step_type"], found["interval_num"],
            found["lap_step_type"], found["lap_interval_num"]]


# ---------------------------------------------------------------------------
# Encoding

class FitWriter(object):
    """A minimal FIT encoder: enough for file_id, developer fields, records and
    laps. Definition messages are emitted once per local message type."""

    def __init__(self):
        self.body = bytearray()
        self.defined = {}

    def define(self, local, global_num, fields, dev_fields=()):
        """fields: [(field_def_num, size, base_type)];
           dev_fields: [(field_def_num, size, dev_data_index)]"""
        hdr = 0x40 | local
        if dev_fields:
            hdr |= 0x20
        out = bytearray([hdr, 0, 0])
        out += struct.pack("<H", global_num)
        out.append(len(fields))
        for num, size, base in fields:
            out += bytearray([num, size, base])
        if dev_fields:
            out.append(len(dev_fields))
            for num, size, idx in dev_fields:
                out += bytearray([num, size, idx])
        self.body += out
        self.defined[local] = (fields, dev_fields)

    def data(self, local, payload):
        self.body += bytearray([local]) + payload

    def to_bytes(self):
        head = bytearray([14, 0x20])
        head += struct.pack("<H", 2140)
        head += struct.pack("<I", len(self.body))
        head += b".FIT"
        head += struct.pack("<H", crc16(bytes(head)))
        whole = bytes(head) + bytes(self.body)
        return whole + struct.pack("<H", crc16(whole))


def _string_field(value, size):
    raw = value.encode("utf-8")[:size - 1]
    return raw + b"\x00" * (size - len(raw))


def build(timeline, codes, fields, t0=1000000000, describe=None):
    """Encode a synthetic activity from `timeline`.

    timeline: [(step_code, interval_num, seconds)] in order. One record per
    second and one lap per entry.

    `describe` names the developer fields that get a field_description message;
    the default is all four. It exists for the self-test, which needs a file
    carrying an UNDESCRIBED developer field to prove the decoder refuses it --
    an undescribed field is unreadable by any consumer, and a decoder that
    guessed at one would be inventing data.
    """
    w = FitWriter()

    # file_id: type=activity(4), manufacturer=development(255).
    w.define(0, MESG_FILE_ID,
             [(0, 1, BT_ENUM), (1, 2, BT_UINT16), (4, 4, BT_UINT32)])
    w.data(0, bytearray([4]) + struct.pack("<H", 255) + struct.pack("<I", t0))

    # developer_data_id: a 16-byte application id and index 0.
    w.define(1, MESG_DEV_DATA_ID, [(1, 16, BT_BYTE), (3, 1, BT_UINT8)])
    w.data(1, bytearray(b"StrongRowSynth\x00\x00") + bytearray([0]))

    # One field_description per developer field. field_name and units are
    # fixed-size strings; a decoder reads the NAME from here, which is what
    # makes the read side independent of the ids this harness parsed.
    w.define(2, MESG_FIELD_DESC,
             [(0, 1, BT_UINT8), (1, 1, BT_UINT8), (2, 1, BT_UINT8),
              (3, 24, BT_STRING), (8, 4, BT_STRING), (14, 2, BT_UINT16)])
    for f in fields:
        if describe is not None and f["name"] not in describe:
            continue
        w.data(2, bytearray([0, f["id"], f["base_type"]])
               + _string_field(f["name"], 24)
               + _string_field("n", 4)
               + struct.pack("<H", f["mesg"]))

    rec_dev = [(f["id"], BT_SIZE[f["base_type"]], 0)
               for f in fields if f["mesg"] == MESG_RECORD]
    lap_dev = [(f["id"], BT_SIZE[f["base_type"]], 0)
               for f in fields if f["mesg"] == MESG_LAP]
    rec_fmt = [f["fmt"] for f in fields if f["mesg"] == MESG_RECORD]
    lap_fmt = [f["fmt"] for f in fields if f["mesg"] == MESG_LAP]

    w.define(3, MESG_RECORD, [(253, 4, BT_UINT32)], rec_dev)
    w.define(4, MESG_LAP,
             [(253, 4, BT_UINT32), (2, 4, BT_UINT32), (7, 4, BT_UINT32)],
             lap_dev)

    t = t0
    for step, ivl, secs in timeline:
        start = t
        for _ in range(secs):
            payload = struct.pack("<I", t)
            payload += struct.pack(rec_fmt[0], step)
            payload += struct.pack(rec_fmt[1], ivl)
            w.data(3, bytearray(payload))
            t += 1
        lap = struct.pack("<I", t) + struct.pack("<I", start)
        lap += struct.pack("<I", secs * 1000)
        lap += struct.pack(lap_fmt[0], step)
        lap += struct.pack(lap_fmt[1], ivl)
        w.data(4, bytearray(lap))
    return w.to_bytes(), t0


# ---------------------------------------------------------------------------
# Decoding

def decode(data):
    """Structure-driven FIT decode.

    Returns (records, laps), each a list of dicts keyed by developer field NAME
    plus 'timestamp' (and 'elapsed_s' for laps). Developer fields are resolved
    through the field_description messages, exactly as a consumer would: this
    function is never told which ids to expect.
    """
    hdr_size = data[0]
    body = data[hdr_size:len(data) - 2]
    defs = {}
    dev_names = {}
    records = []
    laps = []
    i = 0
    while i < len(body):
        hdr = body[i]
        i += 1
        if hdr & 0x80:
            raise ValueError("compressed timestamp headers are not emitted here")
        local = hdr & 0x0F
        if hdr & 0x40:
            arch = body[i + 1]
            if arch != 0:
                raise ValueError("only little-endian definitions are emitted")
            gnum = struct.unpack("<H", body[i + 2:i + 4])[0]
            nfields = body[i + 4]
            i += 5
            flds = []
            for _ in range(nfields):
                flds.append((body[i], body[i + 1], body[i + 2]))
                i += 3
            devs = []
            if hdr & 0x20:
                ndev = body[i]
                i += 1
                for _ in range(ndev):
                    devs.append((body[i], body[i + 1], body[i + 2]))
                    i += 3
            defs[local] = (gnum, flds, devs)
            continue

        gnum, flds, devs = defs[local]
        vals = {}
        for num, size, base in flds:
            raw = body[i:i + size]
            i += size
            vals[num] = raw
        dvals = {}
        for num, size, idx in devs:
            dvals[num] = body[i:i + size]
            i += size

        if gnum == MESG_FIELD_DESC:
            fid = vals[1][0]
            name = vals[3].split(b"\x00")[0].decode("utf-8")
            dev_names[fid] = (name, vals[2][0])
            continue
        if gnum not in (MESG_RECORD, MESG_LAP):
            continue

        row = {"timestamp": struct.unpack("<I", vals[253])[0]}
        if gnum == MESG_LAP:
            row["elapsed_s"] = struct.unpack("<I", vals[7])[0] / 1000.0
        for num, raw in dvals.items():
            if num not in dev_names:
                # A developer field with no description is unreadable by any
                # consumer; say so rather than guessing its meaning.
                raise ValueError(
                    "developer field %d appears in a %s message with no "
                    "field_description" % (num, gnum))
            name, base = dev_names[num]
            if base == BT_UINT8:
                row[name] = raw[0]
            elif base == BT_UINT16:
                row[name] = struct.unpack("<H", raw)[0]
            else:
                row[name] = struct.unpack("<I", raw)[0]
        (records if gnum == MESG_RECORD else laps).append(row)
    return records, laps


# ---------------------------------------------------------------------------
# The two selections

def select_by_fields(records, codes):
    """THE QUERY THE CRITERION IS ABOUT: work seconds grouped by interval,
    using ONLY step_type and interval_num. No duration is read."""
    out = {}
    for r in records:
        if r.get("step_type") == codes["SFIT_WORK"]:
            ivl = r.get("interval_num")
            if ivl == codes["IVL_NONE"]:
                raise ValueError(
                    "record at %d says SFIT_WORK with interval_num 0: the two "
                    "fields disagree about whether this second is a work second"
                    % r["timestamp"])
            out.setdefault(ivl, set()).add(r["timestamp"])
    return out


def select_by_duration(laps, lo=170.0, hi=190.0):
    """The heuristic every consumer had to use before the fields existed --
    reproduced here as the differential, not as an alternative."""
    picked = []
    for n, lap in enumerate(laps, 1):
        if lo <= lap["elapsed_s"] <= hi:
            picked.append(n)
    return picked


# ---------------------------------------------------------------------------
# The scenario

def scenario(codes):
    """The timeline, chosen to contain ONE OF EACH failure of the heuristic.

    Modelled on the maintainer's own session shape: a warm-up, work pieces of
    180 s, rests, a cool-down. Two entries carry the point:

      * REST 1 runs 180 s -- exactly a piece's length. Any duration filter that
        selects the pieces selects this rest too.
      * WORK 3 runs 120 s -- a piece shortened, as one really was when it was
        aborted for chop at 820 s of a planned 900. Any duration filter that
        excludes the rest excludes this piece.

    Returns (timeline, intended) where intended maps interval -> second count.
    """
    tl = [
        (codes["SFIT_WARM"], codes["IVL_NONE"], 60),
        (codes["SFIT_WORK"], 1, 180),
        (codes["SFIT_REST"], codes["IVL_NONE"], 180),
        (codes["SFIT_WORK"], 2, 180),
        (codes["SFIT_REST"], codes["IVL_NONE"], 120),
        (codes["SFIT_WORK"], 3, 120),
        (codes["SFIT_COOL"], codes["IVL_NONE"], 60),
        (codes["SFIT_DONE"], codes["IVL_NONE"], 10),
    ]
    intended = {}
    t = 0
    for step, ivl, secs in tl:
        if step == codes["SFIT_WORK"]:
            intended.setdefault(ivl, set()).update(range(t, t + secs))
        t += secs
    return tl, intended


def check(root, write_path=None, verbose=True):
    codes = read_codes(root)
    fields = read_fields(root)
    tl, intended = scenario(codes)
    data, t0 = build(tl, codes, fields)
    if write_path:
        with open(write_path, "wb") as fh:
            fh.write(data)

    records, laps = decode(data)
    got = select_by_fields(records, codes)
    # Intended seconds are offsets from t0; the decoded ones are absolute.
    want = dict((k, set(t0 + s for s in v)) for k, v in intended.items())

    problems = []
    if set(got.keys()) != set(want.keys()):
        problems.append(
            "the field-based selection found intervals %s, the step machine "
            "intended %s" % (sorted(got.keys()), sorted(want.keys())))
    for k in sorted(set(got.keys()) & set(want.keys())):
        if got[k] != want[k]:
            problems.append(
                "interval %d: %d seconds selected, %d intended, %d in one and "
                "not the other" % (k, len(got[k]), len(want[k]),
                                   len(got[k] ^ want[k])))

    # The differential. If the duration heuristic recovered the same set, these
    # fields would be redundant and this harness would be proving nothing.
    heur = select_by_duration(laps)
    heur_steps = [laps[n - 1].get("lap_step_type") for n in heur]
    work_laps = [n for n, lap in enumerate(laps, 1)
                 if lap.get("lap_step_type") == codes["SFIT_WORK"]]
    if heur == work_laps:
        problems.append(
            "the 170-190 s duration heuristic selected exactly the work laps "
            "on this file, so the scenario does not exercise the failure these "
            "fields exist to fix -- fix the scenario, not the assertion")

    if verbose:
        print("scenario: %d records, %d laps, %d work seconds intended"
              % (len(records), len(laps),
                 sum(len(v) for v in want.values())))
        print("field-based selection : %s"
              % ", ".join("interval %d = %d s" % (k, len(got[k]))
                          for k in sorted(got)))
        print("duration heuristic    : laps %s (lap_step_type %s)"
              % (heur, heur_steps))
        print("the work laps really are: %s" % work_laps)
        for k in sorted(want):
            print("  interval %d: intended %d s, selected %d s, exact match %s"
                  % (k, len(want[k]), len(got.get(k, ())),
                     got.get(k) == want[k]))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--write", default=None,
                    help="also write the synthetic .fit to this path")
    args = ap.parse_args()
    problems = check(args.root, args.write)
    if problems:
        print("FAIL: the acceptance criterion does not hold.")
        for p in problems:
            print("  - %s" % p)
        return 1
    print("OK: from the file alone, with no duration heuristic, the work "
          "seconds are recovered exactly and grouped by interval.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
