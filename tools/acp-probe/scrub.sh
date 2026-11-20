#!/bin/sh
# Usage: scrub.sh IN.jsonl > OUT.jsonl
# Removes home paths, usernames, tokens and account details from a transcript.
U=$(id -un)
H="$HOME"
sed -E \
  -e "s#$H#/home/user#g" \
  -e "s#/private/tmp/[^\"\\ ]*#/tmp/scratch#g" \
  -e "s#/Users/[A-Za-z0-9._-]+#/home/user#g" \
  -e "s#/var/folders/[^\"\\ ]*#/tmp/scratch#g" \
  -e "s#$U#user#g" \
  -e 's#[Bb]earer [A-Za-z0-9._~+/=-]+#Bearer REDACTED#g' \
  -e 's#(sk|pk|ghp|gho|xox[bap]|AKIA)[-_A-Za-z0-9]{12,}#REDACTED_TOKEN#g' \
  -e 's#eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+#REDACTED_JWT#g' \
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#user@example.com#g' \
  -e 's#"(account_?[Ii]d|accountId|email|chatgpt_[a-z_]+|token|access_token|refresh_token|api_?[Kk]ey)":"[^"]*"#"\1":"REDACTED"#g' \
  -e 's#(account_?[Ii]d|accountId|email|token|api_?[Kk]ey)\\":\\"[^\\"]*\\"#\1\\":\\"REDACTED\\"#g' \
  "$1"
