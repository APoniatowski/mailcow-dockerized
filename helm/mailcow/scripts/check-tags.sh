#!/usr/bin/env bash
# Asserts the chart's default image tags equal the tags pinned in docker-compose.yml.
# Usage: helm/mailcow/scripts/check-tags.sh [--fix]   (exit 0 = in sync; --fix rewrites values.yaml tags)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

python3 - "$repo/docker-compose.yml" "$here/../values.yaml" "${1:-}" <<'PY'
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
    elif fix:
        repo_, tag = want.rsplit(":", 1)
        # rewrite the first `    tag:` line inside the component's top-level block
        lines, n, inblock = text.split("\n"), 0, False
        for i, line in enumerate(lines):
            if re.match(r"^\S", line):
                inblock = line.startswith(mapping[svc] + ":")
            elif inblock and re.match(r"^    tag: ", line):
                lines[i] = '    tag: "%s"' % tag; n = 1; break
        text = "\n".join(lines)
        print(f"fixed {svc:24} {have} -> {want}" if n else f"FAIL  {svc}: could not rewrite"); fail |= (n == 0)
    else:
        print(f"FAIL  {svc:24} compose={want} chart={have}"); fail = 1
if fix:
    open(sys.argv[2], "w").write(text)
print("TAGS IN SYNC" if not fail else "TAGS DIFFER")
sys.exit(fail)
PY
