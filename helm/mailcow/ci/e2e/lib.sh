# Sourced by the ci/e2e scripts. Resolves the target cluster and refuses anything but a kind cluster.
#   KUBE_CONTEXT  kubectl context (default: the current context)
#   NS            namespace of the release (default: mailcow)
#   RELEASE       Helm release name (default: mailcow)
# Contexts not named kind-* are refused unless the script got --allow-any-context; an API server
# that is not on 127.0.0.1/localhost only gets a warning.
# shellcheck shell=bash

NS="${NS:-mailcow}"
RELEASE="${RELEASE:-mailcow}"

die() { echo "error: $*" >&2; exit 2; }

need_tools() {
  local t missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}"
}

# select_cluster [--allow-any-context]  -> sets KUBE_CONTEXT, checks it is reachable
select_cluster() {
  local allow_any="${1:-}"
  KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
  [ -n "$KUBE_CONTEXT" ] || die "no kubectl context: set KUBE_CONTEXT"
  echo "kubectl context: $KUBE_CONTEXT  namespace: $NS  release: $RELEASE"
  case "$KUBE_CONTEXT" in
    kind-*) ;;
    *) [ "$allow_any" = --allow-any-context ] \
         || die "refusing to use context '$KUBE_CONTEXT': only kind-* contexts unless --allow-any-context is given" ;;
  esac
  # a kind cluster's API server listens on the loopback address (reads the kubeconfig, no API call)
  local server
  server=$(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  case "$server" in
    https://127.0.0.1:*|https://localhost:*|https://\[::1\]:*) ;;
    *) echo "warning: API server of context '$KUBE_CONTEXT' is '${server:-unknown}', not 127.0.0.1/localhost: is this really a local kind cluster?" >&2 ;;
  esac
  kubectl --context "$KUBE_CONTEXT" get --raw /readyz >/dev/null 2>&1 \
    || die "cluster of context '$KUBE_CONTEXT' is not reachable"
}

K() { kubectl --context "$KUBE_CONTEXT" -n "$NS" "$@"; }
