#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="$1"
FRAGMENT_FILE="$2"

if [ ! -f "$FRAGMENT_FILE" ]; then
  echo "Fragment file not found: $FRAGMENT_FILE" >&2
  exit 1
fi

touch "$TARGET_FILE"

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue

  key="$(printf '%s\n' "$line" | sed -E 's/^# ([A-Z0-9_]+) is not set$/\1/; s/^([A-Z0-9_]+)=.*$/\1/')"

  sed -i -E "/^${key}=|^# ${key} is not set$/d" "$TARGET_FILE"
  printf '%s\n' "$line" >> "$TARGET_FILE"
done < "$FRAGMENT_FILE"
