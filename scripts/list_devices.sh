#!/bin/sh
# Print the Connect IQ product ids from manifest.xml, one per line.
#
# Pure POSIX shell + grep/sed so it runs anywhere, including inside the SDK
# container image where python may not be installed. The CI device matrix IS
# this list: the compile and release jobs iterate exactly the manifest's
# devices, so adding/removing an <iq:product> automatically re-shapes CI.
set -eu

MANIFEST="${1:-manifest.xml}"

grep -oE '<iq:product[[:space:]][^>]*id="[^"]+"' "$MANIFEST" \
  | sed -E 's/.*id="([^"]+)".*/\1/'
