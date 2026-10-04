#!/usr/bin/env bash
# Restores a backup written by the chart's backup CronJobs (backup.enabled) into a running release:
# the kubectl counterpart of `helper-scripts/backup_and_restore.sh restore`. Also restores the
# vmail/crypt/redis/rspamd/postfix archives and the MariaDB physical backup of a compose
# backup_and_restore.sh backup copied into the backup PVC (migration from compose).
#
#   restore.sh --namespace NS --release REL --list [--backup mailcow-YYYY-MM-DD-HH-MM-SS]
#   restore.sh --namespace NS --release REL --backup mailcow-YYYY-MM-DD-HH-MM-SS \
#              [--components all|mysql,redis,crypt,vmail,rspamd,postfix,sogo] [--resync] [--yes]
#
# Options:
#   --namespace NS        namespace of the release (required)
#   --release REL         Helm release name (required)
#   --backup DIR          backup directory in the backup PVC (required unless --list)
#   --components LIST     comma separated, default all (every component found in DIR)
#   --list                list backups (and the contents of --backup), change nothing
#   --resync              run `doveadm force-resync -A '*'` after a vmail restore (asked otherwise)
#   --yes                 do not ask for confirmation
#   --context CTX         kubectl context (default: the current context)
#   --fullname NAME       chart fullname if it is not the default (<release>-mailcow, or <release>
#                         when the release name contains "mailcow"), i.e. with fullnameOverride
#   --backup-claim PVC    backup PVC (default: the one the backup CronJobs mount)
#   --image IMAGE         archiver image (default: the backup CronJobs' image)
#   --db-image IMAGE      MariaDB client image (default: the mysql backup CronJob's image)
#   --timeout DURATION    wait for pods to start/stop, in seconds (default 600s)
#   env KUBECTL           kubectl binary (default kubectl)
#
# What it does: shows the kubectl context and asks; scales the writers of the selected components
# (and watchdog) to 0; starts a pod `<fullname>-restore` that mounts the backup PVC read-only and the
# target PVCs, on whatever node their volumes allow; extracts the archives over the target volumes
# (like backup_and_restore.sh: nothing is deleted first, except the MariaDB data directory for a
# physical restore); loads backup_mysql.sql.* through the `mysql` Service (bundled or external
# database); deletes the pod and scales everything back to its previous replica count, also when a
# step fails.
set -euo pipefail

NS="" REL="" DIR="" COMPONENTS="all" LIST="" RESYNC="" YES="" CONTEXT="" FULL="" CLAIM="" IMAGE="" DBIMAGE=""
TIMEOUT="600s"
ALL=(mysql redis crypt vmail rspamd postfix sogo)

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS=${2:-}; shift ;;
    --release) REL=${2:-}; shift ;;
    --backup) DIR=${2:-}; shift ;;
    --components) COMPONENTS=${2:-}; shift ;;
    --list) LIST=1 ;;
    --resync) RESYNC=1 ;;
    --yes) YES=1 ;;
    --context) CONTEXT=${2:-}; shift ;;
    --fullname) FULL=${2:-}; shift ;;
    --backup-claim) CLAIM=${2:-}; shift ;;
    --image) IMAGE=${2:-}; shift ;;
    --db-image) DBIMAGE=${2:-}; shift ;;
    --timeout) TIMEOUT=${2:-}; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

[ -n "${NS}" ] || die "--namespace is required"
[[ "${TIMEOUT}" =~ ^[0-9]+s$ ]] || die "--timeout takes seconds, e.g. 600s"
[ -n "${REL}" ] || die "--release is required"
[ -n "${LIST}" ] || [ -n "${DIR}" ] || die "--backup is required (find one with --list)"
if [ -n "${DIR}" ] && [[ ! "${DIR}" =~ ^[A-Za-z0-9._-]+$ ]]; then die "--backup must be a directory name in the backup PVC, e.g. mailcow-2026-10-04-02-00-00"; fi
KUBECTL=${KUBECTL:-kubectl}
command -v "${KUBECTL}" >/dev/null || die "${KUBECTL} not found"

KC=("${KUBECTL}")
[ -n "${CONTEXT}" ] && KC+=(--context "${CONTEXT}")
k() { "${KC[@]}" -n "${NS}" "$@"; }

if [ -z "${FULL}" ]; then
  if [[ "${REL}" == *mailcow* ]]; then FULL=${REL}; else FULL="${REL}-mailcow"; fi
fi
SEL="app.kubernetes.io/instance=${REL}"
CTX=${CONTEXT:-$("${KUBECTL}" config current-context 2>/dev/null || true)}
SERVER=$("${KC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
echo "kubectl context: ${CTX:-<none>} (${SERVER:-unknown server})"
echo "namespace:       ${NS}"
echo "release:         ${REL} (objects ${FULL}-*)"

# ---------- discovery (read-only) ----------
# "<kind>/<name> <replicas>" of every Deployment/StatefulSet of a component, kind lower case
workloads() {
  local obj rep
  k get deploy,sts -l "${SEL},app.kubernetes.io/component=$1" \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | while read -r obj rep; do [ -n "${obj}" ] && echo "$(tr '[:upper:]' '[:lower:]' <<<"${obj%%/*}")/${obj#*/} ${rep}"; done || true
}
# first workload of a component: "<kind>/<name>"
workload() { workloads "$1" | head -n 1 | cut -d' ' -f1; }
# claimName of volume $2 in the pod template of component $1
claim_of() {
  local w; w=$(workload "$1"); [ -n "${w}" ] || return 0
  k get "${w}" -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$2\")].persistentVolumeClaim.claimName}"
}
cronjob_jsonpath() {
  k get cronjob -l "${SEL},app.kubernetes.io/component=backup,mailcow.email/backup-group $1" -o jsonpath="$2" 2>/dev/null || true
}

NAME_LABEL=$(k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null || true)
[ -n "${NAME_LABEL}" ] || die "no dovecot StatefulSet with label ${SEL} in namespace ${NS}: wrong --namespace/--release/--context?"
[ -n "${CLAIM}" ] || CLAIM=$(cronjob_jsonpath "notin (x)" '{.items[0].spec.jobTemplate.spec.template.spec.volumes[?(@.name=="backup")].persistentVolumeClaim.claimName}')
[ -n "${CLAIM}" ] || CLAIM="${FULL}-backup"
k get pvc "${CLAIM}" >/dev/null || die "backup PVC ${CLAIM} not found (--backup-claim)"
[ -n "${IMAGE}" ] || IMAGE=$(cronjob_jsonpath "notin (mysql)" '{.items[0].spec.jobTemplate.spec.template.spec.containers[0].image}')
[ -n "${IMAGE}" ] || IMAGE="ghcr.io/mailcow/backup:latest"
[ -n "${DBIMAGE}" ] || DBIMAGE=$(cronjob_jsonpath "in (mysql)" '{.items[0].spec.jobTemplate.spec.template.spec.containers[0].image}')
if [ -z "${DBIMAGE}" ]; then
  DBIMAGE=$(k get sts -l "${SEL},app.kubernetes.io/component=mysql" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
fi
[ -n "${DBIMAGE}" ] || DBIMAGE="mariadb:10.11"
SECRET=$(k get sts -l "${SEL},app.kubernetes.io/component=dovecot" \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="DBPASS")].valueFrom.secretKeyRef.name}')
DBNAME=$(k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="DBNAME")].value}')
DBUSER=$(k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="DBUSER")].value}')
DBPORT=$(k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="DBPORT")].value}')
# scheduling bits of the release's pods (podDefaults, imagePullSecrets), copied from dovecot (JSON = YAML flow)
spec_of_dovecot() { k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath="{.items[0].spec.template.spec.$1}"; }
PULL_SECRETS=$(spec_of_dovecot imagePullSecrets)
NODE_SELECTOR=$(spec_of_dovecot nodeSelector)
TOLERATIONS=$(spec_of_dovecot tolerations)
[ -n "${PULL_SECRETS}" ] || PULL_SECRETS="[]"
[ -n "${NODE_SELECTOR}" ] || NODE_SELECTOR="{}"
[ -n "${TOLERATIONS}" ] || TOLERATIONS="[]"

POD="${FULL}-restore"
cleanup_pod() { k delete pod "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

# pod manifest: tools container (+ db container), backup PVC read-only + "name|claim|mountPath|subPath" mounts
pod_manifest() {
  local name=$1 db=$2; shift 2
  local m n c p s
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: ${NAME_LABEL}
    app.kubernetes.io/instance: ${REL}
    app.kubernetes.io/component: backup
    mailcow.email/restore: "true"
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  imagePullSecrets: ${PULL_SECRETS}
  nodeSelector: ${NODE_SELECTOR}
  tolerations: ${TOLERATIONS}
  containers:
    - name: tools
      image: ${IMAGE}
      command: ["sleep", "infinity"]
      securityContext:
        runAsUser: 0
      volumeMounts:
        - {name: backup, mountPath: /backup, readOnly: true}
EOF
  for m in "$@"; do
    IFS='|' read -r n c p s <<<"${m}"
    echo "        - {name: ${n}, mountPath: ${p}${s:+, subPath: ${s}}}"
  done
  if [ -n "${db}" ]; then
    cat <<EOF
    - name: db
      image: ${DBIMAGE}
      command: ["sleep", "infinity"]
      env:
        - {name: DBNAME, value: "${DBNAME}"}
        - {name: DBUSER, value: "${DBUSER}"}
        - {name: DBPORT, value: "${DBPORT:-3306}"}
        - name: MYSQL_PWD
          valueFrom: {secretKeyRef: {name: "${SECRET}", key: DBPASS}}
      volumeMounts:
        - {name: backup, mountPath: /backup, readOnly: true}
EOF
  fi
  cat <<EOF
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: ${CLAIM}}
EOF
  local seen=" "
  for m in "$@"; do
    IFS='|' read -r n c p s <<<"${m}"
    [[ "${seen}" == *" ${n} "* ]] && continue
    seen+="${n} "
    echo "    - {name: ${n}, persistentVolumeClaim: {claimName: ${c}}}"
  done
}

start_pod() { # name db mounts...
  local name=$1
  cleanup_pod "${name}"
  k wait --for=delete "pod/${name}" --timeout="${TIMEOUT}" >/dev/null 2>&1 || true
  pod_manifest "$@" | k apply -f - >/dev/null
  if ! k wait --for=condition=Ready "pod/${name}" --timeout="${TIMEOUT}" >/dev/null; then
    k describe pod "${name}" | sed -n '/^Events:/,$p' >&2
    die "pod ${name} did not start (volumes on different nodes? ReadWriteOnce volume still in use elsewhere?)"
  fi
}

# ---------- inspect the backup ----------
INSPECT="${FULL}-restore-inspect"
trap 'cleanup_pod "${INSPECT}"' EXIT
echo "backup PVC:      ${CLAIM}"
start_pod "${INSPECT}" ""
if [ -n "${LIST}" ]; then
  echo "backups in ${CLAIM}:"
  k exec "${INSPECT}" -c tools -- sh -c 'cd /backup && ls -1d mailcow-* 2>/dev/null | sort' | sed 's/^/  /'
  if [ -n "${DIR}" ]; then
    echo "${DIR}:"
    k exec "${INSPECT}" -c tools -- sh -c "cd '/backup/${DIR}' && ls -lAh" | sed 's/^/  /'
  fi
  exit 0
fi
FILES=$(k exec "${INSPECT}" -c tools -- sh -c "cd '/backup/${DIR}' 2>/dev/null && ls -1A") || die "backup ${DIR} not found in ${CLAIM} (see --list)"
NODE_ARCH=$(k exec "${INSPECT}" -c tools -- uname -m)
cleanup_pod "${INSPECT}"
trap - EXIT

# archive of a component in DIR: prints "<file>|<decompressor>" (zst preferred, like the script)
archive_of() {
  local f
  for f in "$1.tar.zst|zstd -d" "$1.tar.gz|pigz -d" "$1.sql.zst|zstd -dc" "$1.sql.gz|gzip -dc"; do
    if grep -qx "${f%%|*}" <<<"${FILES}"; then echo "${f}"; return 0; fi
  done
}
declare -A ARCH=()
for c in "${ALL[@]}"; do
  case "${c}" in
    mysql) a=$(archive_of backup_mysql); [ -n "${a}" ] || { a=$(archive_of backup_mariadb); [ -n "${a}" ] && a="${a}|physical"; } ;;
    sogo) a=$(archive_of backup_sogo) ;;
    *) a=$(archive_of "backup_${c}") ;;
  esac
  [ -n "${a}" ] && ARCH[${c}]=${a}
done
[ ${#ARCH[@]} -gt 0 ] || die "no restorable archives in ${DIR}"

SELECTED=()
if [ "${COMPONENTS}" = "all" ]; then
  for c in "${ALL[@]}"; do [ -n "${ARCH[${c}]:-}" ] && SELECTED+=("${c}"); done
else
  IFS=',' read -r -a want <<<"${COMPONENTS}"
  for c in "${want[@]}"; do
    [[ " ${ALL[*]} " == *" ${c} "* ]] || die "unknown component ${c} (${ALL[*]})"
    [ -n "${ARCH[${c}]:-}" ] || die "${DIR} has no archive for ${c}"
    SELECTED+=("${c}")
  done
fi
has() { [[ " ${SELECTED[*]} " == *" $1 "* ]]; }

# component checks
EXT_DB=$(k get svc mysql -o jsonpath='{.metadata.labels.mailcow\.email/external}' 2>/dev/null || true)
EXT_REDIS=$(k get svc redis -o jsonpath='{.metadata.labels.mailcow\.email/external}' 2>/dev/null || true)
PHYSICAL=""
if has mysql && [[ "${ARCH[mysql]}" == *"|physical" ]]; then
  [ -z "${EXT_DB}" ] || die "${DIR} has a MariaDB physical backup (compose mariabackup); it cannot be restored into an external database"
  PHYSICAL=1
fi
if has redis && [ -n "${EXT_REDIS}" ]; then
  die "externalRedis: restore ${DIR}/backup_redis.tar.zst (dump.rdb) with your Redis provider's import, then rerun without redis"
fi
if has rspamd; then
  MARK=$(grep -E '^\.(x86_64|aarch64)' <<<"${FILES}" | head -n 1 | sed 's/^\.//' || true)
  if [ -z "${MARK}" ]; then
    echo "warning: no architecture marker in ${DIR}; if rspamd crashes after the restore, empty its PVC"
  elif [ "${MARK}" != "${NODE_ARCH}" ]; then
    echo "warning: rspamd data is from ${MARK}, this node is ${NODE_ARCH}: skipping rspamd (not portable)"
    keep=(); for c in "${SELECTED[@]}"; do [ "${c}" = rspamd ] || keep+=("${c}"); done
    SELECTED=("${keep[@]}")
    [ ${#SELECTED[@]} -gt 0 ] || die "nothing left to restore"
  fi
fi
if has postfix; then
  [ -z "$(k get sts -l "${SEL},app.kubernetes.io/component=postfix" -o jsonpath='{.items[0].spec.volumeClaimTemplates}')" ] \
    || die "postfix.spoolPerPod: one queue PVC per pod, restore the postfix archive by hand (README \"Backup and restore\")"
fi

# writers stopped while their data is replaced
declare -A STOP=([watchdog]=1)
for c in "${SELECTED[@]}"; do
  case "${c}" in
    mysql) for w in php-fpm sogo dovecot postfix acme; do STOP[${w}]=1; done; [ -n "${PHYSICAL}" ] && STOP[mysql]=1 ;;
    redis) STOP[redis]=1 ;;
    crypt|vmail) STOP[dovecot]=1 ;;
    rspamd) STOP[rspamd]=1 ;;
    postfix) STOP[postfix]=1 ;;
    sogo) STOP[sogo]=1 ;;
  esac
done

echo "backup:          ${DIR} (${CLAIM})"
for c in "${SELECTED[@]}"; do echo "  restore ${c} from ${ARCH[${c}]%%|*}"; done
echo "scaled to 0 meanwhile: ${!STOP[*]}"
has crypt || ! has vmail || echo "note: vmail without crypt: mail encrypted with other mail_crypt keys stays unreadable"
[ -z "${PHYSICAL}" ] || echo "note: MariaDB physical backup: the data directory of the mysql PVC is replaced (its users and passwords come from the backup)"
if [ -z "${YES}" ]; then
  [ -t 0 ] || die "no terminal for the confirmation: pass --yes"
  read -r -p "Data on these volumes is overwritten. Type the namespace (${NS}) to continue: " answer
  [ "${answer}" = "${NS}" ] || die "aborted"
fi

# ---------- scale down ----------
declare -A ORIG=()
restore_scale() {
  local obj
  for obj in "${!ORIG[@]}"; do
    echo "scale ${obj} back to ${ORIG[${obj}]}"
    k scale "${obj}" --replicas="${ORIG[${obj}]}" >/dev/null || echo "warning: could not scale ${obj} back to ${ORIG[${obj}]}" >&2
  done
}
finish() {
  local rc=$?
  cleanup_pod "${POD}"
  restore_scale
  [ "${rc}" -eq 0 ] || echo "restore FAILED (exit ${rc}): the volumes may be partially restored, workloads were scaled back" >&2
}
trap finish EXIT

for w in "${!STOP[@]}"; do
  while read -r obj rep; do
    [ -n "${obj}" ] || continue
    ORIG[${obj}]=${rep}
    echo "scale ${obj} to 0 (was ${rep})"
    k scale "${obj}" --replicas=0 >/dev/null
  done < <(workloads "${w}")
done
echo "waiting for the pods to stop"
stopsel="${SEL},app.kubernetes.io/component in ($(IFS=,; echo "${!STOP[*]}"))"
deadline=$(( $(date +%s) + ${TIMEOUT%s} ))  # TIMEOUT validated as <n>s
until [ -z "$(k get pod -l "${stopsel}" -o name)" ]; do
  [ "$(date +%s)" -lt "${deadline}" ] || die "pods still running after ${TIMEOUT}: $(k get pod -l "${stopsel}" -o name | tr '\n' ' ')"
  sleep 3
done

# ---------- restore pod ----------
MOUNTS=()
for c in "${SELECTED[@]}"; do
  case "${c}" in
    vmail) MOUNTS+=("vmail|$(claim_of dovecot vmail)|/vmail|") ;;
    crypt) MOUNTS+=("crypt|$(claim_of dovecot crypt)|/crypt|") ;;
    redis) MOUNTS+=("redis|$(claim_of redis data)|/redis|") ;;
    rspamd) cl=$(claim_of rspamd rspamd); MOUNTS+=("rspamd|${cl}|/rspamd|data" "rspamd|${cl}|/rspamd_override|override") ;;
    postfix) MOUNTS+=("spool|$(claim_of postfix spool)|/postfix|") ;;
    sogo) MOUNTS+=("sogo-backup|$(claim_of sogo backup)|/sogo_backup|") ;;
    mysql) [ -z "${PHYSICAL}" ] || MOUNTS+=("mysql|$(claim_of mysql data)|/backup_mariadb|") ;;
  esac
done
for m in "${MOUNTS[@]}"; do
  [[ "${m}" != *"||"* ]] || die "could not find the PVC for ${m%%|*} in the release's workloads"
done
DB=""
has mysql && [ -z "${PHYSICAL}" ] && DB=1
echo "starting ${POD}"
start_pod "${POD}" "${DB}" "${MOUNTS[@]}"

extract() { # component
  local file=${ARCH[$1]%%|*} rest=${ARCH[$1]#*|}
  local prog=${rest%%|*}
  echo "restore $1: ${file}"
  k exec "${POD}" -c tools -- tar --numeric-owner --use-compress-program="${prog}" -Pxpf "/backup/${DIR}/${file}"
}

# order: keys before mail, database before the rest
for c in mysql redis crypt vmail rspamd postfix sogo; do
  has "${c}" || continue
  case "${c}" in
    mysql)
      if [ -n "${PHYSICAL}" ]; then
        echo "mysql: physical backup, emptying the data directory first"
        k exec "${POD}" -c tools -- bash -c 'shopt -s dotglob; rm -rf /backup_mariadb/*'
        extract mysql
        k exec "${POD}" -c tools -- chown -R 999:999 /backup_mariadb
      else
        file=${ARCH[mysql]%%|*}; prog=${ARCH[mysql]#*|}
        echo "restore mysql: ${file} into ${DBNAME} as ${DBUSER} via Service mysql"
        k exec "${POD}" -c db -- bash -c "set -o pipefail; ${prog} '/backup/${DIR}/${file}' \
          | mariadb -h mysql -P \"\${DBPORT}\" -u \"\${DBUSER}\" --max-allowed-packet=1G \"\${DBNAME}\""
      fi
      ;;
    *) extract "${c}" ;;
  esac
done

if [ -n "${PHYSICAL}" ]; then
  # the restored data directory carries the compose install's users: the Secret must match them
  conf=$(k exec "${POD}" -c tools -- sh -c "cat '/backup/${DIR}/mailcow.conf' 2>/dev/null" || true)
  if [ -z "${conf}" ]; then
    echo "warning: no mailcow.conf in ${DIR}: set DBPASS and DBROOT in Secret ${SECRET} to the passwords of the restored database"
  else
    v=$(sed -n 's/^DBNAME=//p' <<<"${conf}" | tail -n 1)
    [ "${v}" = "${DBNAME}" ] || echo "warning: DBNAME of the backup (${v}) differs from the release's: set mailcow.dbName: ${v}"
    v=$(sed -n 's/^DBUSER=//p' <<<"${conf}" | tail -n 1)
    [ "${v}" = "${DBUSER}" ] || echo "warning: DBUSER of the backup (${v}) differs from the release's: set mailcow.dbUser: ${v}"
    patch=""
    for key in DBPASS DBROOT; do
      v=$(sed -n "s/^${key}=//p" <<<"${conf}" | tail -n 1)
      cur=$(k get secret "${SECRET}" -o jsonpath="{.data.${key}}" | base64 -d)
      [ "${v}" = "${cur}" ] || patch+="\"${key}\":\"$(printf '%s' "${v}" | base64 -w0)\","
    done
    if [ -n "${patch}" ]; then
      ans="y"
      if [ -z "${YES}" ]; then read -r -p "DBPASS/DBROOT of the backup differ from Secret ${SECRET}. Update the Secret? [y/N] " ans; fi
      if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
        k patch secret "${SECRET}" --type merge -p "{\"data\":{${patch%,}}}" >/dev/null && echo "Secret ${SECRET} updated"
      else
        echo "warning: the pods cannot log in to the restored database until Secret ${SECRET} has its DBPASS/DBROOT"
      fi
    fi
  fi
fi

cleanup_pod "${POD}"
restore_scale
ORIG=()
trap - EXIT

if has vmail; then
  echo
  echo "In most cases a full resync is not needed. After checking the mailboxes you can run:"
  echo "  kubectl -n ${NS} exec $(workload dovecot) -c dovecot-mailcow -- doveadm force-resync -A '*'"
  ans="n"
  if [ -n "${RESYNC}" ]; then ans="y"
  elif [ -z "${YES}" ] && [ -t 0 ]; then read -r -p "Force a resync now? [y/N] " ans; fi
  if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
    k rollout status "$(workload dovecot)" --timeout="${TIMEOUT}"
    k exec "$(workload dovecot)" -c dovecot-mailcow -- doveadm force-resync -A '*'
  fi
fi
echo "restore of ${DIR} done"
