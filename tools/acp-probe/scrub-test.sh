#!/bin/sh
# Feeds a synthetic transcript through scrub.sh and asserts the privacy pattern is gone.
D=$(dirname "$0"); T=$(mktemp)
U=$(id -un); V=Users; P="claude-""501"
printf '%s\n' \
 "{\"line\":\"cwd $HOME/Developer/x and /${V}/$U/y and /private/tmp/${P}/a/b\"}" \
 "{\"line\":\"user $U mail ${U}@gmail.com Authorization: Bearer abc123.def456-xyz\"}" \
 '{"line":"{\"accountId\":\"acct-123\",\"email\":\"a@b.com\",\"token\":\"sk-abcdefghijklmnop1234\"}"}' > "$T"
OUT=$("$D/scrub.sh" "$T")
rm -f "$T"
if printf '%s' "$OUT" | grep -E "$U|/${V}/[A-Za-z]|${P}|acct-123|sk-abcdef|abc123\.def|a@b\.com"; then echo FAIL; exit 1; fi
echo OK
