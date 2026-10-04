#!/usr/bin/env bash
# End-to-end smoke test of an installed mailcow release on a kind cluster created from
# ci/e2e/kind-config.yaml and installed with ci/kind-values.yaml (NodePorts reachable on the host).
# Prints a test log suitable for a pull request. Exit 0 = all checks passed.
#
#   helm/mailcow/ci/e2e/smoke.sh [--allow-any-context]
#
# Environment: KUBE_CONTEXT (default: current context; must start with kind- unless
# --allow-any-context), NS (mailcow), RELEASE (mailcow), MAILCOW_HOSTNAME (mail.example.org),
# HOST_ADDR (127.0.0.1, where the NodePorts are mapped), SECRET (<release>-secrets, holds API_KEY).
# Host tools: kubectl, python3, curl, jq, openssl.
#
#   1. every release pod Ready (CronJob, TLS bootstrap and strategy-fix Job pods excluded)
#   2. web UI answers on https://$HOST_ADDR:30443 (Host: $MAILCOW_HOSTNAME)
#   3. API: add domain + mailbox
#   4. SMTP submission STARTTLS + AUTH via NodePort 30587 from the host, send to self
#   5. IMAPS via NodePort 30993: message arrives within 60s, COPY to Junk -> rspamd learns spam
#   6. dockerapi Kubernetes backend: mail queue via API, container status non-empty;
#      rspamd stats via the controller socket; rspamd resolves bare service names
#   7. SOGo served via nginx
#   8. with NetworkPolicy on: a foreign pod cannot reach postfix/dovecot
# ok/ko always succeed, so `test && ok ... || ko ...` reports exactly one of them
# shellcheck disable=SC2015
set -uo pipefail
. "$(dirname "$0")/lib.sh"

allow=""
for a in "$@"; do
  case "$a" in
    --allow-any-context) allow="$a" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
need_tools kubectl python3 curl jq openssl
select_cluster "$allow"

HOST="${MAILCOW_HOSTNAME:-mail.example.org}"
ADDR="${HOST_ADDR:-127.0.0.1}"
SECRET="${SECRET:-$RELEASE-secrets}"
DOMAIN="${HOST#*.}"
LP="smoke$(openssl rand -hex 4)"
USER_="$LP@$DOMAIN"
PASS="Sm0ke-$(openssl rand -hex 8)-pass!"
SEL="app.kubernetes.io/instance=$RELEASE"

pass=0; fail=0; results=()
ok() { echo "PASS  $*"; pass=$((pass+1)); results+=("PASS  $*"); }
ko() { echo "FAIL  $*"; fail=$((fail+1)); results+=("FAIL  $*"); }
curl_() { curl -sk --max-time 30 --resolve "$HOST:30443:$ADDR" "$@"; }
rspamd_logs() { # $1 = --since window
  local d
  d=$(K get deploy -l "$SEL,app.kubernetes.io/component=rspamd" -o name 2>/dev/null | head -1)
  [ -n "$d" ] && K logs "$d" -c rspamd-mailcow --since="$1" 2>/dev/null
}

echo "== mailcow kubernetes smoke $(date -u +%FT%TZ)  release=$RELEASE ns=$NS host=$HOST"
K get pods -o wide

# 1
# Job pods (CronJobs, backups, hooks) finish and never turn Ready: wait for the long-running ones
if K wait --for=condition=Ready pod \
     -l "$SEL,app.kubernetes.io/component notin (cron,tls-bootstrap,strategy-fix,backup)" \
     --field-selector=status.phase!=Succeeded,status.phase!=Failed \
     --timeout=600s >/dev/null 2>&1; then
  ok "all pods Ready"
else
  ko "pods not Ready: $(K get pods -l "$SEL" --no-headers 2>/dev/null \
    | awk '{split($2,r,"/"); if ($3 != "Completed" && ($3 != "Running" || r[1] != r[2])) printf "%s(%s %s) ", $1, $2, $3}')"
fi

# 2
code=$(curl_ -o /dev/null -w '%{http_code}' "https://$HOST:30443/")
[ "$code" = 200 ] && ok "web UI 200" || ko "web UI http $code"

# 3
KEY=$(K get secret "$SECRET" -o jsonpath='{.data.API_KEY}' 2>/dev/null | base64 -d)
[ -n "$KEY" ] || ko "no API_KEY in secret $SECRET"
api() { curl_ -H "X-API-Key: $KEY" -H 'Content-Type: application/json' "https://$HOST:30443/api/v1/$1" "${@:2}"; }
created=0
cleanup() { [ "$created" = 1 ] && api delete/mailbox -d "[\"$USER_\"]" >/dev/null 2>&1; created=0; }
trap cleanup EXIT

r=$(api add/domain -d "{\"domain\":\"$DOMAIN\",\"active\":\"1\",\"mailboxes\":\"10\",\"maxquota\":\"1024\",\"quota\":\"2048\",\"defquota\":\"512\",\"aliases\":\"10\",\"restart_sogo\":\"0\"}")
grep -q '"type":"success"\|already exists\|domain_exists' <<<"$r" && ok "API add domain $DOMAIN" || ko "API add domain: ${r:0:300}"
r=$(api add/mailbox -d "{\"local_part\":\"$LP\",\"domain\":\"$DOMAIN\",\"password\":\"$PASS\",\"password2\":\"$PASS\",\"active\":\"1\",\"quota\":\"100\",\"force_pw_update\":\"0\"}")
if grep -q '"type":"success"' <<<"$r"; then created=1; ok "API add mailbox $USER_"; else ko "API add mailbox: ${r:0:300}"; fi

# 4 + 5: from the host, so the NodePorts and the NetworkPolicy public path are exercised
py=$(cat <<PY
import smtplib, imaplib, ssl, time, sys, uuid
ctx = ssl._create_unverified_context(); tag = str(uuid.uuid4())
addr, u, p = "$ADDR", "$USER_", "$PASS"
try:
    s = smtplib.SMTP(addr, 30587, timeout=30); s.starttls(context=ctx); s.login(u, p)
    body = " ".join(f"word{n} lorem ipsum dolor sit amet consectetur" for n in range(40))
    s.sendmail(u, [u], f"From: {u}\r\nTo: {u}\r\nSubject: smoke {tag}\r\n\r\n{body}\r\n"); s.quit()
    print("PASS  smtp submission via NodePort 30587 (public path) auth+send")
except Exception as e:
    print("FAIL  smtp submission:", e); sys.exit(1)
err = None
for i in range(30):
    try:
        m = imaplib.IMAP4_SSL(addr, 30993, ssl_context=ctx); m.login(u, p); m.select("INBOX")
        t, d = m.search(None, "SUBJECT", f'"smoke {tag}"'); m.logout()
        if d and d[0]:
            print(f"PASS  imaps via NodePort 30993 delivery in ~{i*2}s")
            m = imaplib.IMAP4_SSL(addr, 30993, ssl_context=ctx); m.login(u, p); m.select("INBOX")
            t, d = m.search(None, "SUBJECT", f'"smoke {tag}"'); r = m.copy(d[0].split()[0], "Junk"); m.logout()
            print("PASS  imap COPY to Junk (triggers sieve learnspam)" if r[0] == "OK" else f"FAIL  imap COPY to Junk: {r}")
            sys.exit(0)
    except Exception as e:
        err = e
    time.sleep(2)
print("FAIL  message not in INBOX after 60s", f"(last error: {err})" if err else ""); sys.exit(1)
PY
)
learned0=$(api get/logs/rspamd-stats | jq -r '.learned // 0' 2>/dev/null)
out=$(python3 -c "$py" 2>&1)
if grep -q '^\(PASS\|FAIL\)' <<<"$out"; then
  while IFS= read -r line; do
    case "$line" in PASS*) ok "${line#PASS  }" ;; FAIL*) ko "${line#FAIL  }" ;; esac
  done < <(grep -E '^(PASS|FAIL)' <<<"$out")
else
  ko "python smtp/imap: ${out:0:300}"
fi

# 6
r=$(api get/mailq/all); grep -q '^\[' <<<"$r" && ok "API mailq (dockerapi exec into postfix)" || ko "API mailq: ${r:0:200}"
r=$(api get/status/containers); n=$(jq 'length' <<<"$r" 2>/dev/null || echo 0)
[ "${n:-0}" -gt 0 ] && ok "API container status ($n entries)" || ko "API container status: ${r:0:200}"

# 6b rspamd controller via its unix socket (php-fpm) and the dovecot sieve learn pipe
r=$(api get/logs/rspamd-stats); grep -q '"scanned"' <<<"$r" && ok "API rspamd-stats (php-fpm -> rspamd.sock)" || ko "API rspamd-stats: ${r:0:200}"
learned=""
for _ in 1 2 3 4 5 6; do
  learned1=$(api get/logs/rspamd-stats | jq -r '.learned // 0' 2>/dev/null)
  if [ "${learned1:-0}" -gt "${learned0:-0}" ]; then learned="learned $learned0 -> $learned1"; break; fi
  # a well-trained bayes skips messages it already classifies as spam: the request still arrived
  if rspamd_logs 2m | grep -q 'already in class spam'; then learned="bayes skip: already in class spam"; break; fi
  sleep 3
done
[ -n "$learned" ] && ok "sieve learnspam reached rspamd (dovecot -> rspamd.sock; $learned)" \
  || ko "no learn request reached rspamd after COPY to Junk (dovecot rspamd-pipe-spam -> rspamd.sock)"

# 6c rspamd's own resolver ignores search domains: bare service names (http://nginx:9081 for the
#    quarantine exporter, dynmaps on nginx:8081) must still resolve
n=$(rspamd_logs 2m | grep -c 'unable to resolve host')
[ "$n" = 0 ] && ok "rspamd resolves bare service names (no 'unable to resolve host')" || ko "rspamd: $n x 'unable to resolve host' in the last 2m"

# 7
code=$(curl_ -o /dev/null -w '%{http_code}' "https://$HOST:30443/SOGo/")
[[ "$code" =~ ^(200|302)$ ]] && ok "SOGo via nginx ($code)" || ko "SOGo http $code"

# 8 relay protection: with NetworkPolicy on, a foreign in-cluster pod (pod CIDR = trusted by
#   mailcow) must not reach postfix/dovecot; only release pods may.
if [ "$(K get networkpolicy --no-headers 2>/dev/null | wc -l)" -gt 1 ]; then
  # shellcheck disable=SC2016  # expanded by the probe pod's shell
  r=$(K run "netpol-probe-$(openssl rand -hex 3)" --rm -i --restart=Never --image=busybox:1.37 \
      --pod-running-timeout=180s --command -- \
      sh -c 'for t in postfix:25 postfix:587 postfix:588 dovecot:143; do nc -z -w 3 ${t%:*} ${t#*:} && echo "OPEN $t" || echo "closed $t"; done' 2>&1)
  if grep -q '^OPEN' <<<"$r"; then
    ko "foreign pod reached: $(grep '^OPEN' <<<"$r" | tr '\n' ' ')"
  elif [ "$(grep -c '^closed ' <<<"$r")" = 4 ]; then
    ok "foreign pod blocked from postfix/dovecot (NetworkPolicy)"
  else
    ko "NetworkPolicy probe pod did not run: ${r:0:300}"
  fi
else
  echo "skip  relay-protection check (NetworkPolicy off)"
fi

# cleanup: the domain caps mailboxes, so every run removes its own
cleanup

echo
echo "== summary ($KUBE_CONTEXT ns=$NS release=$RELEASE)"
printf '%s\n' "${results[@]}"
echo "== result: $pass passed, $fail failed"
[ "$fail" = 0 ]
