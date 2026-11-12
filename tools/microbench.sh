#!/bin/bash
# Micro-benchmarks for Alloy's hot paths (package-benchmark, in Benchmarks/).
#   tools/microbench.sh update   store the current results as the local baseline "local"
#   tools/microbench.sh check    compare against that baseline; non-zero exit on a regression
#                                (p50 wall clock or p50 peak resident memory more than 10% above it).
#                                package-benchmark's relative thresholds are symmetric, so a p50 more than 10%
#                                BETTER also makes it exit 4, which `swift package` flattens into a plain
#                                failure. check detects that case from the tool's output ("... is BETTER than
#                                the 'local' baseline thresholds." with no "WORSE") and exits 0 with a note to
#                                run `update`. A regression, a crash, or any other failure still exits non-zero.
#   tools/microbench.sh run      run the suite and print results
# Baselines are machine-specific and git-ignored (Benchmarks/.benchmarkBaselines/).
set -euo pipefail
cd "$(dirname "$0")/../Benchmarks"
export BENCHMARK_DISABLE_JEMALLOC=true   # no jemalloc: no Homebrew dependency

mode="${1:-run}"; [ $# -gt 0 ] && shift   # remaining arguments (for example --filter "Wire decode") go to package-benchmark
case "$mode" in
  update) exec swift package --allow-writing-to-package-directory benchmark baseline update local "$@" ;;
  check)
    out="$(mktemp)"; trap 'rm -f "$out"' EXIT
    set +e
    swift package benchmark baseline check local "$@" 2>&1 | tee "$out"
    code=${PIPESTATUS[0]}
    set -e
    if [ "$code" -ne 0 ] && grep -q "is BETTER than the" "$out" \
       && ! grep -qE "is WORSE than|crashed|Could not|No benchmarks matching|not found" "$out"; then
      echo "faster than the 'local' baseline; run tools/microbench.sh update to record it"
      exit 0
    fi
    exit "$code" ;;
  run)    exec swift package benchmark "$@" ;;
  *) echo "usage: $0 [run|update|check] [package-benchmark options]" >&2; exit 2 ;;
esac
