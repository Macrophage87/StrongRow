#!/usr/bin/env python3
"""Fail-closed manifest sanity check for a Connect IQ app.

A bad application id still compiles cleanly and still passes the unit tests,
yet the Connect IQ Store rejects it at submission time. The SDK build jobs
therefore cannot catch this class of error, so this runner-free check does.

It verifies, from manifest.xml alone (no SDK, no network):
  * exactly one <iq:application> element exists;
  * its `id` is a real 32-hex-digit Connect IQ app id (dashes/braces allowed,
    they are normalised away) and NOT a placeholder (all-zeros, all-same-digit,
    or a known template GUID);
  * `entry`, `name` and `type` are present and `type` is a known app type;
  * at least one <iq:product> is listed (an empty product list ships to nobody).

Exit code 0 = OK, 1 = a problem was found. Every failure prints WHY.
"""

import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

MANIFEST = sys.argv[1] if len(sys.argv) > 1 else "manifest.xml"

IQ_NS = "http://www.garmin.com/xml/connectiq"

# App ids that ship in project templates / examples and must never reach a build.
KNOWN_PLACEHOLDER_IDS = {
    "00000000000000000000000000000000",
    "ffffffffffffffffffffffffffffffff",
    # The GUID the Connect IQ "New Project" wizard historically stamped in.
    "a3421feed289106a538cb9547ab12095",
}

VALID_APP_TYPES = {
    "watch-app",
    "watchface",
    "widget",
    "datafield",
    "audio-content-provider-app",
    "background",
    "glance",
}


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def main():
    try:
        tree = ET.parse(MANIFEST)
    except (ET.ParseError, OSError) as exc:
        fail(f"could not parse {MANIFEST!r}: {exc}")

    root = tree.getroot()
    # findall() (direct children) for <application> because there must be
    # exactly one. iter() (any depth) is used for <product> below so products
    # are found wherever they nest under <iq:products>. Do NOT "simplify" that
    # iter() into findall(): findall would look only one level down and report
    # zero products.
    apps = root.findall(f"{{{IQ_NS}}}application")
    if len(apps) != 1:
        fail(f"expected exactly one <iq:application>, found {len(apps)}")
    app = apps[0]

    app_id = app.get("id")
    if not app_id:
        fail("<iq:application> has no `id` attribute")

    # Normalise: strip braces and dashes, lowercase. CIQ stores a 32-hex id.
    normalized = re.sub(r"[{}\-]", "", app_id).lower()

    if not re.fullmatch(r"[0-9a-f]{32}", normalized):
        fail(
            f"app id {app_id!r} is not a valid 32-hex-digit Connect IQ id "
            f"(normalised {normalized!r})"
        )

    if normalized in KNOWN_PLACEHOLDER_IDS:
        fail(f"app id {app_id!r} is a known placeholder/template id")

    if len(set(normalized)) == 1:
        fail(f"app id {app_id!r} is all one digit — a placeholder, not a real id")

    entry = app.get("entry")
    if not entry:
        fail("<iq:application> has no `entry` attribute")

    name = app.get("name")
    if not name:
        fail("<iq:application> has no `name` attribute")

    app_type = app.get("type")
    if not app_type:
        fail("<iq:application> has no `type` attribute")
    if app_type not in VALID_APP_TYPES:
        fail(
            f"app type {app_type!r} is not a known Connect IQ type "
            f"({sorted(VALID_APP_TYPES)})"
        )

    products = [
        p.get("id")
        for p in app.iter(f"{{{IQ_NS}}}product")
        if p.get("id")
    ]
    if not products:
        fail("no <iq:product> devices listed — the app targets no device")

    # Cross-check the shell device extractor (list_devices.sh, which the
    # container build jobs use because python may be absent in the SDK image)
    # against this XML parse. If a manifest reformat ever made the line-anchored
    # regex disagree with the parser, THIS required job goes red — closing the
    # "green while compiling the wrong/zero device set" gap. Ordered comparison
    # is intentional: both sources emit products in document order.
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "list_devices.sh")
    if os.path.exists(helper):
        try:
            out = subprocess.run(
                ["sh", helper, MANIFEST],
                capture_output=True, text=True, check=True,
            ).stdout
        except subprocess.CalledProcessError as exc:
            fail(f"list_devices.sh failed: {exc.stderr.strip() or exc}")
        shell_devices = [d for d in out.splitlines() if d.strip()]
        if shell_devices != products:
            fail(
                "device extractor disagrees with the XML parse — the CI matrix "
                "would not equal the manifest:\n"
                f"  manifest.xml products : {products}\n"
                f"  list_devices.sh       : {shell_devices}"
            )

    print("OK: manifest looks store-shaped")
    print(f"  app id : {app_id}")
    print(f"  entry  : {entry}")
    print(f"  type   : {app_type}")
    print(f"  products ({len(products)}): {', '.join(products)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
