#!/bin/bash
# selftest.sh - check the shared helpers: redact, the timeout fallback, is_apple.
# Usage: selftest.sh        exits non-zero and names each failing case
set -u
. "$(dirname "$0")/lib.sh"
usage_if_help "$@"

fail=0
check() {  # check NAME INPUT EXPECTED
  local got
  got=$(printf '%s\n' "$2" | redact)
  if [ "$got" != "$3" ]; then echo "FAIL redact $1: got [$got] want [$3]"; fail=1; fi
}
check flag-space   'srv --api-key abc123 --port 80'          'srv --api-key <redacted> --port 80'
check flag-equals  'cli --auth-token=zz9 run'                 'cli --auth-token=<redacted> run'
check author       'git log --author me'                      'git log --author me'
check quoted       'x --password "two words" y'               'x --password <redacted> y'
check single-quote "x --secret 'a b' y"                       'x --secret <redacted> y'
check passphrase   'gpg --passphrase hunter2'                 'gpg --passphrase <redacted>'
check mysql-p      'mysql -uroot -phunter2 db'                'mysql -uroot -p<redacted> db'
check dash-p       'tool -p hunter2'                          'tool -p <redacted>'
check header       'curl -H "Authorization: Bearer abcdefghij"' 'curl -H "Authorization: Bearer <redacted>'
check url-userinfo 'git clone https://me:tok123@github.com/x' 'git clone https://<redacted>@github.com/x'
check env-assign   'GITHUB_TOKEN=ghp_abc node x.js'           'GITHUB_TOKEN=<redacted> node x.js'
check harmless     'ls -la /tmp'                              'ls -la /tmp'

out=$(timeout 1 sleep 5; echo "rc=$?")
case "$out" in rc=124|rc=142) ;; *) echo "FAIL timeout: $out"; fail=1 ;; esac
timed_out 142 || { echo "FAIL timed_out 142"; fail=1; }

is_apple "macOS Software Signing" || { echo "FAIL is_apple macOS"; fail=1; }
is_apple "Apple Development: Someone (X)" && { echo "FAIL is_apple dev cert"; fail=1; }

[ "$fail" = 0 ] && echo "selftest: all passed"
exit "$fail"
