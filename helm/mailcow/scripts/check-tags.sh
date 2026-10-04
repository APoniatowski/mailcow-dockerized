#!/usr/bin/env bash
# Asserts the chart's default images (repository and tag) equal the images pinned in
# docker-compose.yml, the backup image (not a compose service) equals DEBIAN_DOCKER_IMAGE of
# helper-scripts/backup_and_restore.sh, and the fallback image of scripts/restore.sh equals
# backup.image (repository:tag@digest).
# Usage: helm/mailcow/scripts/check-tags.sh [--fix]
#   exit 0 = in sync, 1 = differences, 2 = usage error. --fix rewrites the repository and tag of the
#   compose-mapped components in values.yaml; the backup image and its digest are fixed by hand.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

fix=""
for a in "$@"; do
  case "$a" in
    --fix) fix=--fix ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; sed -n '6,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done

python3 - "$repo/docker-compose.yml" "$here/../values.yaml" "$fix" "$repo/helper-scripts/backup_and_restore.sh" "$here/restore.sh" <<'PY'
import re, sys, yaml

compose = yaml.safe_load(open(sys.argv[1]))["services"]
values = yaml.safe_load(open(sys.argv[2]))

# compose service -> values key. Not shipped by the chart: ofelia (replaced by CronJobs) and
# netfilter (fail2ban; not supported on Kubernetes, see README).
mapping = {
    "unbound-mailcow": "unbound", "mysql-mailcow": "mysql", "redis-mailcow": "redis",
    "clamd-mailcow": "clamd", "rspamd-mailcow": "rspamd", "php-fpm-mailcow": "phpFpm",
    "sogo-mailcow": "sogo", "dovecot-mailcow": "dovecot", "postfix-mailcow": "postfix",
    "postfix-tlspol-mailcow": "postfixTlspol", "memcached-mailcow": "memcached",
    "nginx-mailcow": "nginx", "acme-mailcow": "acme",
    "watchdog-mailcow": "watchdog", "dockerapi-mailcow": "dockerapi", "olefy-mailcow": "olefy",
}
skip = {"ofelia-mailcow", "netfilter-mailcow"}

def rewrite(text, key, repository, tag):
    """Set repository and tag in the `  image:` block of top-level key `key`; returns (text, n)."""
    lines, block, image, n = text.split("\n"), False, False, 0
    for i, line in enumerate(lines):
        if re.match(r"^\S", line):
            block, image = line.startswith(key + ":"), False
        elif block and re.match(r"^  \S", line):
            image = line.rstrip() == "  image:"
        elif block and image and re.match(r"^    repository: ", line):
            lines[i] = "    repository: %s" % repository; n += 1
        elif block and image and re.match(r"^    tag: ", line):
            lines[i] = '    tag: "%s"' % tag; n += 1
    return "\n".join(lines), n

fix = sys.argv[3] == "--fix"
text = open(sys.argv[2]).read() if fix else None
fail = 0
for svc, spec in compose.items():
    if svc in skip:
        print(f"skip  {svc:24} not shipped by the chart"); continue
    if svc not in mapping:
        print(f"FAIL  {svc}: compose service has no chart mapping"); fail = 1; continue
    want = spec["image"]
    img = values[mapping[svc]]["image"]
    have = f'{img["repository"]}:{img["tag"]}'
    if have == want:
        print(f"ok    {svc:24} {want}")
    elif not fix:
        print(f"FAIL  {svc:24} compose={want} chart={have}"); fail = 1
    elif "@" in want or not re.fullmatch(r"[^\s:]+(:\d+)?(/[^\s:]+)*:[\w][\w.-]*", want):
        print(f"FAIL  {svc:24} compose={want} chart={have} (not fixable: not repository:tag)"); fail = 1
    elif img.get("digest"):
        print(f"FAIL  {svc:24} compose={want} chart={have} (not fixable: image.digest is pinned, update it by hand)"); fail = 1
    else:
        repository, tag = want.rsplit(":", 1)
        new, n = rewrite(text, mapping[svc], repository, tag)
        got = yaml.safe_load(new)[mapping[svc]]["image"]
        if n == 2 and f'{got["repository"]}:{got["tag"]}' == want:
            text = new
            print(f"fixed {svc:24} {have} -> {want}")
        else:
            print(f"FAIL  {svc:24} compose={want} chart={have} (not fixable: no `image:` block with repository and tag lines)"); fail = 1
# backup.image: the image backup_and_restore.sh runs (reported only; --fix leaves it, the digest is pinned by hand)
m = re.search(r'^DEBIAN_DOCKER_IMAGE="([^"]+)"', open(sys.argv[4]).read(), re.M)
bimg = values["backup"]["image"]
have = f'{bimg["repository"]}:{bimg["tag"]}'
if not m:
    print("FAIL  backup: DEBIAN_DOCKER_IMAGE not found in backup_and_restore.sh"); fail = 1
elif have == m.group(1):
    print(f"ok    {'backup (helper script)':24} {have}")
else:
    print(f"FAIL  {'backup (helper script)':24} script={m.group(1)} chart={have}"); fail = 1
# restore.sh falls back to the chart's default backup image when no backup CronJob exists
m = re.search(r'^DEFAULT_IMAGE="([^"]+)"', open(sys.argv[5]).read(), re.M)
full = have + (f'@{bimg["digest"]}' if bimg.get("digest") else "")
if not m:
    print("FAIL  restore.sh: DEFAULT_IMAGE not found"); fail = 1
elif m.group(1) == full:
    print(f"ok    {'backup (restore.sh)':24} {full}")
else:
    print(f"FAIL  {'backup (restore.sh)':24} restore.sh={m.group(1)} chart={full}"); fail = 1
if fix:
    open(sys.argv[2], "w").write(text)
print("TAGS IN SYNC" if not fail else "TAGS DIFFER")
sys.exit(fail)
PY
