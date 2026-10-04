#!/usr/bin/env bash
# Collects bounded diagnostics of a mailcow release (pod status, describe, events, logs) into a directory,
# e.g. to upload as a CI artifact after a failed end-to-end run.
#
#   helm/mailcow/ci/e2e/collect-logs.sh <out-dir> [--allow-any-context]
#
# Environment: KUBE_CONTEXT (default: current context; must start with kind- unless
# --allow-any-context), NS (mailcow), RELEASE (mailcow), LOG_TAIL (lines per container, 400).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

out="" allow=""
for a in "$@"; do
  case "$a" in
    --allow-any-context) allow="$a" ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) die "unknown argument: $a" ;;
    *) out="$a" ;;
  esac
done
[ -n "$out" ] || die "usage: collect-logs.sh <out-dir> [--allow-any-context]"
need_tools kubectl
select_cluster "$allow"
tail_n="${LOG_TAIL:-400}"
mkdir -p "$out/logs" "$out/describe"

K get all,pvc,networkpolicy,configmap,secret,job,cronjob -o wide >"$out/resources.txt" 2>&1
K get events --sort-by=.lastTimestamp >"$out/events.txt" 2>&1
kubectl --context "$KUBE_CONTEXT" describe nodes >"$out/nodes.txt" 2>&1
kubectl --context "$KUBE_CONTEXT" get pods -A -o wide >"$out/pods-all-namespaces.txt" 2>&1
if command -v helm >/dev/null 2>&1; then
  { helm --kube-context "$KUBE_CONTEXT" -n "$NS" status "$RELEASE"
    helm --kube-context "$KUBE_CONTEXT" -n "$NS" history "$RELEASE"; } >"$out/helm.txt" 2>&1
fi

for p in $(K get pods -o name 2>/dev/null); do
  p=${p#pod/}
  K describe pod "$p" >"$out/describe/$p.txt" 2>&1
  for c in $(K get pod "$p" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
    K logs "$p" -c "$c" --tail="$tail_n" --limit-bytes=1048576 --timestamps >"$out/logs/$p.$c.log" 2>&1
    # previous instance of a restarted container
    K logs "$p" -c "$c" --previous --tail="$tail_n" --limit-bytes=1048576 --timestamps \
      >"$out/logs/$p.$c.previous.log" 2>/dev/null || rm -f "$out/logs/$p.$c.previous.log"
  done
done
echo "diagnostics written to $out ($(du -sh "$out" | cut -f1))"
