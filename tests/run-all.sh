#!/usr/bin/env bash
# Run every test suite. Exits non-zero if any of them fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  printf '\n\033[1m== %s ==\033[0m\n' "$(basename "$t")"
  "$t" || rc=1
done
if (( rc )); then
  printf '\n\033[31mSome tests failed.\033[0m\n\n'
else
  printf '\n\033[32mAll suites passed.\033[0m\n\n'
fi
exit $rc
