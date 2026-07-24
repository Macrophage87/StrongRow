#!/bin/sh
# Print the Connect IQ product ids from manifest.xml, one per line.
#
# Pure POSIX shell + grep/sed so it runs anywhere, including inside the SDK
# container image where python may not be installed. The CI device matrix IS
# this list: the compile and release jobs iterate exactly the manifest's
# devices, so adding/removing an <iq:product> automatically re-shapes CI.
#
# Fail-closed: a manifest that yields zero devices exits NON-ZERO, so a build
# can never go green having compiled nothing. Newlines are collapsed first so a
# multiline "<iq:product\n id=.../>" is still matched (attribute order and
# surrounding whitespace don't matter).
#
# scripts/check_manifest_appid.py cross-checks this extractor against a real XML
# parse in the (required) manifest-lint job, so if a manifest reformat ever made
# this regex disagree with the XML, that job goes red rather than the build
# silently compiling the wrong device set.
set -eu

MANIFEST="${1:-manifest.xml}"

# grep exits 1 on no match; `|| true` keeps set -e from aborting so the empty
# case is handled explicitly below rather than as an opaque pipeline failure.
devices=$(
  tr '\n' ' ' < "$MANIFEST" \
    | grep -oE '<iq:product[[:space:]][^>]*id="[^"]+"' \
    | sed -E 's/.*id="([^"]+)".*/\1/'
) || true

if [ -z "$devices" ]; then
  echo "ERROR: no <iq:product> devices found in $MANIFEST" >&2
  exit 1
fi

printf '%s\n' "$devices"
