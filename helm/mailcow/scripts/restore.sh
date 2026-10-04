#!/usr/bin/env bash
# Restores a backup written by the chart's backup CronJobs (backup.enabled) into a running release:
# the kubectl counterpart of `helper-scripts/backup_and_restore.sh restore`. Also restores the
# vmail/crypt/redis/postfix archives and the MariaDB physical backup of a compose
# backup_and_restore.sh backup copied into the backup PVC (migration from compose); a compose rspamd
# archive is skipped (the chart keeps rspamd's state in Redis only).
#
#   restore.sh --namespace NS --release REL --list [--backup mailcow-YYYY-MM-DD-HH-MM-SS]
#   restore.sh --namespace NS --release REL --backup mailcow-YYYY-MM-DD-HH-MM-SS \
#              [--components all|mysql,redis,crypt,vmail,postfix,sogo] [--resync] [--yes]
#
# Options:
#   --namespace NS        namespace of the release (required)
#   --release REL         Helm release name (required)
#   --backup DIR          backup directory in the backup PVC (required unless --list)
#   --components LIST     comma separated, default all (every component found in DIR that this
#                         release can take; the others are skipped with a warning)
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
# Requires bash >= 4.4, kubectl and GNU coreutils (macOS: brew install bash coreutils). The archiver
# image needs GNU tar, zstd and pigz (the chart's backup image has them).
#
# What it does: shows the kubectl context and asks you to type <namespace>@<context>; suspends the
# release's backup CronJobs; scales the writers of the selected components (and watchdog) to 0; starts
# a pod `<fullname>-restore` that mounts the backup PVC read-only and the target PVCs, on whatever
# node their volumes allow; extracts the archives over the target volumes (like
# backup_and_restore.sh: nothing is deleted first, except the MariaDB data directory for a physical
# restore); loads backup_mysql.sql.* through the `mysql` Service (bundled or external database);
# deletes the pod, scales everything back to its previous replica count and resumes the CronJobs,
# also when a step fails. The previous replica counts and suspend flags are kept in annotations
# (mailcow.email/restore-replicas, mailcow.email/restore-suspend) until they are put back, so a rerun
# after an interrupted restore still finds them.
set -euo pipefail

NS="" REL="" DIR="" COMPONENTS="all" LIST="" RESYNC="" YES="" CONTEXT="" FULL="" CLAIM="" IMAGE="" DBIMAGE=""
TIMEOUT="600s"
ALL=(mysql redis crypt vmail rspamd postfix sogo)
# fallback archiver image = the chart's backup.image default (check-tags.sh keeps them equal)
DEFAULT_IMAGE="ghcr.io/mailcow/backup:latest@sha256:4ccba992011ef9a340e10587bbb7a0aaddfe3f91f3f61665c66bd4094e7475fb"
ANN_REPLICAS="mailcow.email/restore-replicas"
ANN_SUSPEND="mailcow.email/restore-suspend"

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
[ -n "${CTX}" ] || die "no kubectl context: pass --context"
SERVER=$("${KC[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
echo "kubectl context: ${CTX} (${SERVER:-unknown server})"
echo "namespace:       ${NS}"
echo "release:         ${REL} (objects ${FULL}-*)"

# ---------- discovery (read-only) ----------
# "<kind>/<name> <replicas> <saved replicas>" of every Deployment/StatefulSet of a component, kind lower
# case; <saved replicas> = the restore-replicas annotation of an interrupted run (usually empty)
workloads() {
  local obj rep ann
  k get deploy,sts -l "${SEL},app.kubernetes.io/component=$1" \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas} {.metadata.annotations.mailcow\.email/restore-replicas}{"\n"}{end}' 2>/dev/null \
    | while read -r obj rep ann; do
        [ -n "${obj}" ] && echo "$(tr '[:upper:]' '[:lower:]' <<<"${obj%%/*}")/${obj#*/} ${rep} ${ann}"
      done || true
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
[ -n "${IMAGE}" ] || IMAGE=${DEFAULT_IMAGE}
[ -n "${DBIMAGE}" ] || DBIMAGE=$(cronjob_jsonpath "in (mysql)" '{.items[0].spec.jobTemplate.spec.template.spec.containers[0].image}')
if [ -z "${DBIMAGE}" ]; then
  DBIMAGE=$(k get sts -l "${SEL},app.kubernetes.io/component=mysql" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
fi
[ -n "${DBIMAGE}" ] || DBIMAGE="mariadb:10.11"
# retention of the backup runs (env of the group that prunes; empty without backup CronJobs)
backup_env() {
  cronjob_jsonpath "notin (x)" "{range .items[*].spec.jobTemplate.spec.template.spec.containers[*].env[?(@.name==\"$1\")]}{.value}{\"\\n\"}{end}" | head -n 1
}
RETENTION_DAYS=$(backup_env RETENTION_DAYS)
KEEP=$(backup_env KEEP)
dovecot_env() {
  k get sts -l "${SEL},app.kubernetes.io/component=dovecot" -o jsonpath="{.items[0].spec.template.spec.containers[0].env[?(@.name==\"$1\")].$2}"
}
SECRET=$(dovecot_env DBPASS valueFrom.secretKeyRef.name)
DBNAME=$(dovecot_env DBNAME value)
DBUSER=$(dovecot_env DBUSER value)
DBPORT=$(dovecot_env DBPORT value)
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
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 1Gi}
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
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: 2Gi}
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
RUNS=$(k exec "${INSPECT}" -c tools -- sh -c 'cd /backup && ls -1d mailcow-* 2>/dev/null | sort' || true)
if [ -n "${LIST}" ]; then
  echo "backups in ${CLAIM}:"
  [ -z "${RUNS}" ] || while IFS= read -r r; do echo "  ${r}"; done <<<"${RUNS}"
  if [ -n "${DIR}" ]; then
    echo "${DIR}:"
    k exec "${INSPECT}" -c tools -- sh -c "cd '/backup/${DIR}' && ls -lAh" | sed 's/^/  /'
  fi
  exit 0
fi
FILES=$(k exec "${INSPECT}" -c tools -- sh -c "cd '/backup/${DIR}' 2>/dev/null && ls -1A") || die "backup ${DIR} not found in ${CLAIM} (see --list)"

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
drop() { local keep=() c; for c in "${SELECTED[@]}"; do [ "${c}" = "$1" ] || keep+=("${c}"); done; SELECTED=("${keep[@]}"); }
# a component this release cannot take: skipped with --components all, an error when asked for by name
cannot() { # component reason
  if [ "${COMPONENTS}" = "all" ]; then echo "warning: skipping $1: $2"; drop "$1"; else die "$2 (leave $1 out of --components)"; fi
}

# component checks
EXT_DB=$(k get svc mysql -o jsonpath='{.metadata.labels.mailcow\.email/external}' 2>/dev/null || true)
EXT_REDIS=$(k get svc redis -o jsonpath='{.metadata.labels.mailcow\.email/external}' 2>/dev/null || true)
PHYSICAL="" CONF=""
if has mysql && [[ "${ARCH[mysql]}" == *"|physical" ]]; then
  [ -z "${EXT_DB}" ] || die "${DIR} has a MariaDB physical backup (compose mariabackup); it cannot be restored into an external database"
  PHYSICAL=1
  # the restored data directory carries the compose install's database, users and passwords
  CONF=$(k exec "${INSPECT}" -c tools -- sh -c "cat '/backup/${DIR}/mailcow.conf' 2>/dev/null" || true)
  if [ -z "${CONF}" ]; then
    echo "warning: no mailcow.conf in ${DIR}: DBNAME/DBUSER cannot be checked; afterwards set DBPASS and DBROOT in Secret ${SECRET} to the passwords of the restored database"
  else
    v=$(sed -n 's/^DBNAME=//p' <<<"${CONF}" | tail -n 1)
    [ "${v}" = "${DBNAME}" ] || die "DBNAME of the backup (${v}) differs from the release's (${DBNAME}): set mailcow.dbName: ${v}, helm upgrade, then rerun"
    v=$(sed -n 's/^DBUSER=//p' <<<"${CONF}" | tail -n 1)
    [ "${v}" = "${DBUSER}" ] || die "DBUSER of the backup (${v}) differs from the release's (${DBUSER}): set mailcow.dbUser: ${v}, helm upgrade, then rerun"
  fi
  # the chart's own Secret keeps patched values on upgrade (lookup); anything else may be reverted
  owner=$(k get secret "${SECRET}" -o jsonpath='{.metadata.ownerReferences[*].kind}' 2>/dev/null || true)
  if [ "${SECRET}" != "${REL}-secrets" ] || [ -n "${owner}" ]; then
    echo "warning: Secret ${SECRET} is ${owner:+owned by ${owner}, }not the one the chart generates (existingSecret?): if it is managed elsewhere (External Secrets, Sealed Secrets, GitOps), set DBPASS/DBROOT there too, or the restore's patch is reverted"
  fi
fi
# a compose vmail archive keeps mail under <domain>/<user>/${MAILDIR_SUB}: dovecot must look in the
# same place, or every mailbox looks empty after the restore (generate_config.sh writes
# MAILDIR_SUB=Maildir, older updated installs have it empty)
if has vmail; then
  [ -n "${CONF}" ] || CONF=$(k exec "${INSPECT}" -c tools -- sh -c "cat '/backup/${DIR}/mailcow.conf' 2>/dev/null" || true)
  if [ -n "${CONF}" ]; then
    v=$(sed -n 's/^MAILDIR_SUB=//p' <<<"${CONF}" | tail -n 1)
    rel=$(dovecot_env MAILDIR_SUB value)
    [ "${v}" = "${rel}" ] || die "MAILDIR_SUB of the backup (${v:-empty}) differs from the release's (${rel:-empty}): set mailcow.maildirSub: \"${v}\", helm upgrade, then rerun (otherwise the restored mail is not where dovecot looks)"
  fi
fi
if has redis && [ -n "${EXT_REDIS}" ]; then
  cannot redis "externalRedis: restore ${DIR}/backup_redis.tar.zst (dump.rdb) with your Redis provider's import"
fi
if has postfix && [ -n "$(k get sts -l "${SEL},app.kubernetes.io/component=postfix" -o jsonpath='{.items[0].spec.volumeClaimTemplates}')" ]; then
  cannot postfix "postfix.spoolPerPod: one queue PVC per pod, restore the postfix archive by hand (README \"Backup and restore\")"
fi
if has rspamd; then
  # the chart keeps no rspamd volume: per-pod /var/lib/rspamd, Bayes/fuzzy/history/ratelimits in Redis
  cannot rspamd "rspamd has no volume in this chart (its state lives in Redis, restore redis instead)"
fi
[ ${#SELECTED[@]} -gt 0 ] || die "nothing left to restore"

# would the next backup run (within a day with a daily schedule) prune DIR? Same rules as the
# CronJobs' retention: age by the time in the name, and the number of newer directories
if [[ "${DIR}" =~ ^mailcow-([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
  why="" stamp="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
  if [[ "${RETENTION_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    t=$(date -u -d "${stamp}" +%s 2>/dev/null || true)
    if [ -n "${t}" ] && [ $(( $(date -u +%s) + 86400 - t )) -gt $(( RETENTION_DAYS * 86400 )) ]; then
      why="older than backup.retentionDays (${RETENTION_DAYS}) by the next run"
    fi
  fi
  if [[ "${KEEP}" =~ ^[1-9][0-9]*$ ]]; then
    # the next run adds one directory, then keeps the newest KEEP
    newer=$(awk -v d="${DIR}" '$0 > d' <<<"${RUNS}" | grep -c . || true)
    [ $(( newer + 1 )) -lt "${KEEP}" ] || why="${why:+${why}, }${newer} newer backups + the next run >= backup.keep (${KEEP})"
  fi
  [ -z "${why}" ] || echo "warning: the next backup run deletes ${DIR} (${why}); the backup CronJobs are suspended during the restore, copy the directory elsewhere if you need it again"
fi

# target PVCs, resolved before anything is changed
MOUNTS=()
for c in "${SELECTED[@]}"; do
  case "${c}" in
    vmail) MOUNTS+=("vmail|$(claim_of dovecot vmail)|/vmail|") ;;
    crypt) MOUNTS+=("crypt|$(claim_of dovecot crypt)|/crypt|") ;;
    redis) MOUNTS+=("redis|$(claim_of redis data)|/redis|") ;;
    postfix) MOUNTS+=("spool|$(claim_of postfix spool)|/postfix|") ;;
    sogo) MOUNTS+=("sogo-backup|$(claim_of sogo backup)|/sogo_backup|") ;;
    mysql) [ -z "${PHYSICAL}" ] || MOUNTS+=("mysql|$(claim_of mysql data)|/backup_mariadb|") ;;
  esac
done
for m in "${MOUNTS[@]}"; do
  [[ "${m}" != *"||"* ]] || die "could not find the PVC for ${m%%|*} in the release's workloads"
done
cleanup_pod "${INSPECT}"
trap - EXIT

# writers stopped while their data is replaced
declare -A STOP=([watchdog]=1)
for c in "${SELECTED[@]}"; do
  case "${c}" in
    mysql) for w in php-fpm sogo dovecot postfix acme; do STOP[${w}]=1; done; [ -n "${PHYSICAL}" ] && STOP[mysql]=1 ;;
    redis) STOP[redis]=1 ;;
    crypt|vmail) STOP[dovecot]=1 ;;
    postfix) STOP[postfix]=1 ;;
    sogo) STOP[sogo]=1 ;;
  esac
done
# "<kind>/<name> <replicas> <saved replicas>" to scale to 0, plus workloads an interrupted restore
# left scaled down (they are scaled back to their saved count at the end)
PLAN=()
for w in "${!STOP[@]}"; do
  while read -r obj rep ann; do [ -n "${obj}" ] && PLAN+=("${obj} ${rep} ${ann}"); done < <(workloads "${w}")
done
while read -r obj ann; do
  [ -n "${ann}" ] || continue
  obj="$(tr '[:upper:]' '[:lower:]' <<<"${obj%%/*}")/${obj#*/}"
  [[ " ${PLAN[*]} " == *" ${obj} "* ]] || PLAN+=("${obj} 0 ${ann}")
done < <(k get deploy,sts -l "${SEL}" -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.annotations.mailcow\.email/restore-replicas}{"\n"}{end}' 2>/dev/null || true)
# "<name> <suspend> <saved suspend>" of the backup CronJobs (the suspend of an interrupted run is saved)
CRONJOBS=()
while read -r name susp ann; do [ -n "${name}" ] && CRONJOBS+=("${name} ${susp:-false} ${ann}"); done < <(
  k get cronjob -l "${SEL},app.kubernetes.io/component=backup" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.suspend} {.metadata.annotations.mailcow\.email/restore-suspend}{"\n"}{end}' 2>/dev/null || true)

echo "backup:          ${DIR} (${CLAIM})"
for c in "${SELECTED[@]}"; do echo "  restore ${c} from ${ARCH[${c}]%%|*}"; done
for p in "${PLAN[@]}"; do
  read -r obj rep ann <<<"${p}"
  echo "  scale ${obj} to 0 meanwhile (back to ${ann:-${rep}}${ann:+, saved by an interrupted restore})"
done
[ ${#CRONJOBS[@]} -eq 0 ] || echo "  suspend meanwhile: $(printf '%s\n' "${CRONJOBS[@]}" | cut -d' ' -f1 | tr '\n' ' ')"
has crypt || ! has vmail || echo "note: vmail without crypt: mail encrypted with other mail_crypt keys stays unreadable"
[ -z "${PHYSICAL}" ] || echo "note: MariaDB physical backup: the data directory of the mysql PVC is replaced (its users and passwords come from the backup)"
if [ -z "${YES}" ]; then
  [ -t 0 ] || die "no terminal for the confirmation: pass --yes"
  read -r -p "Data on these volumes is overwritten. Type ${NS}@${CTX} to continue: " answer
  [ "${answer}" = "${NS}@${CTX}" ] || die "aborted"
fi

# ---------- suspend backups, scale down ----------
declare -A ORIG=() SUSP=()
restore_scale() {
  local obj
  for obj in "${!ORIG[@]}"; do
    echo "scale ${obj} back to ${ORIG[${obj}]}"
    if k scale "${obj}" --replicas="${ORIG[${obj}]}" >/dev/null; then
      k annotate "${obj}" "${ANN_REPLICAS}-" >/dev/null 2>&1 || true
      unset "ORIG[${obj}]"
    else
      echo "warning: could not scale ${obj} back to ${ORIG[${obj}]} (kept in its ${ANN_REPLICAS} annotation)" >&2
    fi
  done
}
restore_suspend() {
  local cj
  for cj in "${!SUSP[@]}"; do
    if k patch cronjob "${cj}" --type merge -p "{\"spec\":{\"suspend\":${SUSP[${cj}]}}}" >/dev/null; then
      k annotate cronjob "${cj}" "${ANN_SUSPEND}-" >/dev/null 2>&1 || true
      [ "${SUSP[${cj}]}" = true ] || echo "resumed cronjob/${cj}"
      unset "SUSP[${cj}]"
    else
      echo "warning: could not set suspend=${SUSP[${cj}]} on cronjob/${cj} (kept in its ${ANN_SUSPEND} annotation)" >&2
    fi
  done
}
finish() {
  local rc=$?
  cleanup_pod "${POD}"
  restore_scale
  restore_suspend
  [ "${rc}" -eq 0 ] || echo "restore FAILED (exit ${rc}): the volumes may be partially restored, workloads were scaled back" >&2
}
trap finish EXIT

# no backup run may write into (or prune) the backup PVC meanwhile
for p in "${CRONJOBS[@]}"; do
  read -r name susp ann <<<"${p}"
  SUSP[${name}]=${ann:-${susp}}
  [ -n "${ann}" ] || k annotate cronjob "${name}" "${ANN_SUSPEND}=${susp}" --overwrite >/dev/null
  k patch cronjob "${name}" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
  echo "suspended cronjob/${name}"
done
active=$(k get pod -l "${SEL},app.kubernetes.io/component=backup,mailcow.email/restore!=true" \
  --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name 2>/dev/null || true)
[ -z "${active}" ] || die "a backup run is still active ($(tr '\n' ' ' <<<"${active}")): rerun when it has finished"

for p in "${PLAN[@]}"; do
  read -r obj rep ann <<<"${p}"
  ORIG[${obj}]=${ann:-${rep}}
  # saved first: a rerun after an interruption scales back to this, not to 0
  [ -n "${ann}" ] || k annotate "${obj}" "${ANN_REPLICAS}=${rep}" --overwrite >/dev/null
  echo "scale ${obj} to 0 (was ${ORIG[${obj}]})"
  k scale "${obj}" --replicas=0 >/dev/null
done
echo "waiting for the pods to stop"
stopsel="${SEL},app.kubernetes.io/component in ($(IFS=,; echo "${!STOP[*]}"))"
deadline=$(( $(date +%s) + ${TIMEOUT%s} ))  # TIMEOUT validated as <n>s
until [ -z "$(k get pod -l "${stopsel}" -o name)" ]; do
  [ "$(date +%s)" -lt "${deadline}" ] || die "pods still running after ${TIMEOUT}: $(k get pod -l "${stopsel}" -o name | tr '\n' ' ')"
  sleep 3
done

# ---------- restore pod ----------
DB=""
has mysql && [ -z "${PHYSICAL}" ] && DB=1
echo "starting ${POD}"
start_pod "${POD}" "${DB}" "${MOUNTS[@]}"

# tar prints a progress line per ~100 MB read (also keeps the exec stream from idling out)
extract() { # component
  local file=${ARCH[$1]%%|*} rest=${ARCH[$1]#*|}
  local prog=${rest%%|*}
  echo "restore $1: ${file}"
  k exec "${POD}" -c tools -- tar --numeric-owner --use-compress-program="${prog}" \
    --checkpoint=10000 --checkpoint-action="echo=$1: %{r}T" -Pxpf "/backup/${DIR}/${file}"
}

# logical dump into the mysql Service; prints how much of the dump was read every 30 s (progress,
# and keeps the exec stream from idling out during long imports)
# shellcheck disable=SC2016  # the script runs in the db container
IMPORT='set -o pipefail
f=$1; dec=$2
exec 3<"$f"
size=$(stat -c %s "$f" 2>/dev/null || echo 0)
(
  while sleep 30 >/dev/null 2>&1; do
    pos=0
    while read -r key val; do [ "$key" = "pos:" ] && pos=$val; done < "/proc/$$/fdinfo/3"
    echo "mysql: $(( size > 0 ? pos * 100 / size : 0 ))% of the dump read ($(( pos >> 20 )) of $(( size >> 20 )) MiB)"
  done
) &
tick=$!
trap "kill $tick 2>/dev/null" EXIT
$dec <&3 | mariadb -h mysql -P "$DBPORT" -u "$DBUSER" --max-allowed-packet=1G "$DBNAME"'

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
        k exec "${POD}" -c db -- bash -c "${IMPORT}" import "/backup/${DIR}/${file}" "${prog}"
      fi
      ;;
    *) extract "${c}" ;;
  esac
done

if [ -n "${PHYSICAL}" ] && [ -n "${CONF}" ]; then
  # the restored data directory carries the compose install's users: the Secret must match them
  patch=""
  for key in DBPASS DBROOT; do
    v=$(sed -n "s/^${key}=//p" <<<"${CONF}" | tail -n 1)
    cur=$(k get secret "${SECRET}" -o jsonpath="{.data.${key}}" | base64 -d)
    [ "${v}" = "${cur}" ] || patch+="\"${key}\":\"$(printf '%s' "${v}" | base64 | tr -d '\n')\","
  done
  if [ -n "${patch}" ]; then
    ans="y"
    if [ -z "${YES}" ]; then read -r -p "DBPASS/DBROOT of the backup differ from Secret ${SECRET}. Update the Secret? [y/N] " ans; fi
    if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
      # the patch carries the passwords: on stdin, never on the command line
      k patch secret "${SECRET}" --type merge --patch-file /dev/stdin >/dev/null <<<"{\"data\":{${patch%,}}}" \
        && echo "Secret ${SECRET} updated"
    else
      echo "warning: the pods cannot log in to the restored database until Secret ${SECRET} has its DBPASS/DBROOT"
    fi
  fi
  unset patch v cur CONF
fi

cleanup_pod "${POD}"
restore_scale
restore_suspend
[ ${#ORIG[@]} -eq 0 ] && [ ${#SUSP[@]} -eq 0 ] || exit 1
trap - EXIT

if has vmail; then
  echo
  # the index volume is not restored: messages expunged after the backup stay hidden until dovecot
  # resyncs, and one pass may re-add only part of them ("Expunged message reappeared")
  echo "Messages deleted after the backup stay hidden until dovecot resyncs. To do it later run (repeat"
  echo "until the message counts stop changing):"
  echo "  kubectl --context ${CTX} -n ${NS} exec $(workload dovecot) -c dovecot-mailcow -- doveadm force-resync -A '*'"
  ans="n"
  if [ -n "${RESYNC}" ]; then ans="y"
  elif [ -z "${YES}" ] && [ -t 0 ]; then read -r -p "Force a resync now? [y/N] " ans; fi
  if [[ "${ans,,}" =~ ^(y|yes)$ ]]; then
    k rollout status "$(workload dovecot)" --timeout="${TIMEOUT}"
    msgs() { k exec "$(workload dovecot)" -c dovecot-mailcow -- doveadm -f flow mailbox status -A messages '*' 2>/dev/null \
      | sed -n 's/.*messages=\([0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}'; }
    before=$(msgs)
    for pass in 1 2 3; do
      k exec "$(workload dovecot)" -c dovecot-mailcow -- doveadm force-resync -A '*'
      after=$(msgs)
      echo "resync pass ${pass}: ${before} -> ${after} messages"
      [ "${after}" = "${before}" ] && break
      before=${after}
    done
  fi
fi
echo "restore of ${DIR} done"
