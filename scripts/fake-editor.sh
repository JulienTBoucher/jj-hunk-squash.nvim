#!/bin/sh
# Fake diff editor for jj-hunk-squash.nvim.
# jj invokes this as: fake-editor.sh <left_dir> <right_dir>
# Copies the synthesized content into right/<target> and exits.
# jj then squashes the difference between left/ and right/.
set -e

RIGHT_DIR="$2"
if [ -z "$RIGHT_DIR" ] || [ -z "$JJ_HUNKSQUASH_TARGET_RELPATH" ]; then
  echo "jj-hunk-squash: missing required arguments or env vars" >&2
  exit 1
fi
if [ ! -f "$JJ_HUNKSQUASH_CONTENT_FILE" ]; then
  echo "jj-hunk-squash: content file not found: $JJ_HUNKSQUASH_CONTENT_FILE" >&2
  exit 1
fi

TARGET="$RIGHT_DIR/$JJ_HUNKSQUASH_TARGET_RELPATH"
mkdir -p "$(dirname "$TARGET")"

# Remove read-only bit (jj may copy permissions from left/)
if [ -f "$TARGET" ]; then
  chmod u+w "$TARGET"
fi

cp "$JJ_HUNKSQUASH_CONTENT_FILE" "$TARGET"
