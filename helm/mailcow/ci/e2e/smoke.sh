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
#   1. every release pod Ready (CronJob, backup and TLS bootstrap Job pods excluded)
#   2. web UI answers on https://$HOST_ADDR:30443 (Host: $MAILCOW_HOSTNAME)
#   3. API: add domain + mailbox
#   4. SMTP submission STARTTLS + AUTH via NodePort 30587 from the host, send to self
#   5. IMAPS via NodePort 30993: message arrives within 60s, COPY to Junk -> rspamd learns spam
#   6. dockerapi Kubernetes backend: mail queue via API, container status non-empty;
#      rspamd stats via the controller socket; rspamd resolves bare service names (rspamd logs
#      since the start of the run, which must not be empty)
#   7. SOGo served via nginx
#   8. with networkPolicy.enabled: a foreign pod cannot reach postfix/dovecot by ClusterIP, while
#      it does reach nginx (positive control; probe broken = FAIL)
# ok/ko always succeed, so `test && ok ... || ko ...` reports exactly one of them
# shellcheck disable=SC2015
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

allow=""
for a in "$@"; do
  case "$a" in
    --allow-any-context) allow="$a" ;;
    -h|--help) sed -n '2,/^# ok\/ko/{/^# ok\/ko/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
need_tools kubectl python3 curl jq openssl
select_cluster "$allow"
# log checks only look at what happened during this run
START=$(date -u +%FT%TZ)

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
rspamd_logs() { # logs of every rspamd pod since the start of the run
  K logs -l "$SEL,app.kubernetes.io/component=rspamd" -c rspamd-mailcow --since-time="$START" \
    --tail=-1 --max-log-requests=10 2>/dev/null
}

echo "== mailcow kubernetes smoke $(date -u +%FT%TZ)  release=$RELEASE ns=$NS host=$HOST"
K get pods -o wide

# 1
# Job pods (CronJobs, backups, hooks) finish and never turn Ready: wait for the long-running ones
if K wait --for=condition=Ready pod \
     -l "$SEL,app.kubernetes.io/component notin (cron,tls-bootstrap,backup)" \
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
print("TAG", tag)
try:
    s = smtplib.SMTP(addr, 30587, timeout=30); s.starttls(context=ctx); s.login(u, p)
    body = " ".join(f"word{n} lorem ipsum dolor sit amet consectetur" for n in range(40))
    # the Message-ID carries the tag, so rspamd's learn log lines can be matched to this message
    hdr = f"From: {u}\r\nTo: {u}\r\nSubject: smoke {tag}\r\nMessage-ID: <smoke-{tag}@{u.split('@')[1]}>\r\n"
    s.sendmail(u, [u], f"{hdr}\r\n{body}\r\n"); s.quit()
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
TAG=$(sed -n 's/^TAG //p' <<<"$out" | head -1)
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
  # with rspamd replicas the counter is per pod and the stats request may hit another one: the
  # controller's own log line (any rspamd pod) proves the learn as well
  if [ -n "$TAG" ] && rspamd_logs | grep 'learned message as spam' | grep -qF "smoke-$TAG"; then
    learned="rspamd log: learned message as spam (smoke-$TAG)"; break
  fi
  # a well-trained bayes skips messages it already classifies as spam: the request still arrived.
  # Only lines since the start of this run count; the one naming this message's Message-ID is preferred
  skips=$(rspamd_logs | grep 'already in class spam')
  if [ -n "$TAG" ] && grep -qF "smoke-$TAG" <<<"$skips"; then learned="bayes skip of this message: already in class spam"; break; fi
  if [ -n "$skips" ]; then learned="bayes skip since $START: already in class spam"; break; fi
  sleep 3
done
[ -n "$learned" ] && ok "sieve learnspam reached rspamd (dovecot -> rspamd.sock; $learned)" \
  || ko "no learn request reached rspamd after COPY to Junk (dovecot rspamd-pipe-spam -> rspamd.sock)"

# 6c rspamd's own resolver ignores search domains: bare service names (http://nginx:9081 for the
#    quarantine exporter, dynmaps on nginx:8081) must still resolve. No logs = nothing proven.
logs=$(rspamd_logs)
n=$(grep -c 'unable to resolve host' <<<"$logs")
if [ -z "$logs" ]; then ko "rspamd: no logs since $START (cannot check name resolution)"
elif [ "$n" = 0 ]; then ok "rspamd resolves bare service names (no 'unable to resolve host' since $START)"
else ko "rspamd: $n x 'unable to resolve host' since $START"
fi

# 7
code=$(curl_ -o /dev/null -w '%{http_code}' "https://$HOST:30443/SOGo/")
[[ "$code" =~ ^(200|302)$ ]] && ok "SOGo via nginx ($code)" || ko "SOGo http $code"

# 8 relay protection: with networkPolicy.enabled, a foreign in-cluster pod (pod CIDR = trusted by
#   mailcow) must not reach postfix/dovecot; only release pods may. Probed by ClusterIP (no DNS
#   involved); nginx http is open to everyone, so a probe that cannot reach it is broken and proves
#   nothing. Gate: the postfix policy, plus the memcached one, which only networkPolicy.enabled
#   renders (with mail.proxyProtocol alone the postfix policy exists but leaves port 25 open).
np() { K get networkpolicy -l "$SEL,app.kubernetes.io/component=$1" -o name 2>/dev/null; }
if [ -n "$(np postfix)" ] && [ -n "$(np memcached)" ]; then
  svc_ip() { K get svc "$1" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }
  pf=$(svc_ip postfix); dc=$(svc_ip dovecot); ng=$(svc_ip nginx)
  ngp=$(K get svc nginx -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null)
  if [ -z "$pf" ] || [ -z "$dc" ] || [ -z "$ng" ] || [ -z "$ngp" ]; then
    ko "relay-protection: Service ClusterIPs not found (postfix=$pf dovecot=$dc nginx=$ng:$ngp)"
  else
    # shellcheck disable=SC2016  # expanded by the probe pod's shell
    r=$(K run "netpol-probe-$(openssl rand -hex 3)" --rm -i --restart=Never --image=busybox:1.37 \
        --pod-running-timeout=180s --command -- \
        sh -c 'for t in "$@"; do n=${t%%=*}; a=${t#*=}; nc -z -w 3 "${a%:*}" "${a##*:}" && echo "OPEN $n" || echo "closed $n"; done' \
        probe "control=$ng:$ngp" "postfix:25=$pf:25" "postfix:587=$pf:587" "postfix:588=$pf:588" "dovecot:143=$dc:143" 2>&1)
    if ! grep -qx 'OPEN control' <<<"$r"; then
      ko "relay-protection probe broken: positive control nginx $ng:$ngp (open to all) not reachable: ${r:0:300}"
    elif grep '^OPEN ' <<<"$r" | grep -qvx 'OPEN control'; then
      ko "foreign pod reached: $(grep '^OPEN ' <<<"$r" | grep -vx 'OPEN control' | tr '\n' ' ')"
    elif [ "$(grep -c '^closed ' <<<"$r")" = 4 ]; then
      ok "foreign pod blocked from postfix/dovecot by ClusterIP, reaches nginx (NetworkPolicy)"
    else
      ko "relay-protection probe output incomplete: ${r:0:300}"
    fi
  fi
else
  echo "skip  relay-protection check (networkPolicy.enabled off: no postfix/memcached NetworkPolicy)"
fi

# cleanup: the domain caps mailboxes, so every run removes its own
cleanup

echo
echo "== summary ($KUBE_CONTEXT ns=$NS release=$RELEASE)"
printf '%s\n' "${results[@]}"
echo "== result: $pass passed, $fail failed"
[ "$fail" = 0 ]
