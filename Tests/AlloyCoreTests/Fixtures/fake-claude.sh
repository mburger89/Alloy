#!/bin/sh
# Test double for `claude`. Run as: /bin/sh fake-claude.sh <args...>
# Env: FAKE_FIXTURE (jsonl file to replay), FAKE_BIG=1 (emit a 9 MB assistant line first).
if [ "$FAKE_TRAPINT" = "1" ]; then trap '' INT; fi
if [ "$FAKE_TRAPTERM" = "1" ]; then trap '' TERM; fi
printf '{"type":"argv","args":"%s"}\n' "$*"
if [ "$FAKE_BIG" = "1" ]; then
  printf '{"type":"assistant","message":{"id":"big","content":[{"type":"text","text":"'
  head -c 9000000 /dev/zero | tr '\0' 'a'
  printf '"}]}}\n'
fi
if [ -n "$FAKE_FIXTURE" ]; then cat "$FAKE_FIXTURE"; fi
if [ "$FAKE_GRANDCHILD" = "1" ]; then
  # A background child inherits stdout/stderr and outlives us. Its PID is reported in the type.
  sleep 30 &
  printf '{"type":"pid-%s"}\n' "$!"
  exit 0
fi
while IFS= read -r line; do
  esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"type":"echo","line":"%s"}\n' "$esc"
done
