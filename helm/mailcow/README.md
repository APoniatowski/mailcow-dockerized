# mailcow Helm chart

Runs [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) on Kubernetes with the
same images as `docker-compose.yml`. Status: **0.1, experimental**. Several features depend on
opt-in image changes that are still being upstreamed (see [Image prerequisites](#image-prerequisites)).

## Install

```bash
# 1. files image: data/web, data/conf, data/assets, data/hooks of this checkout (context = repo root)
docker build -f helm/mailcow/files-image/Dockerfile \
  --build-arg MAILCOW_VERSION=$(git describe --tags --abbrev=0) \
  -t registry.example.org/mailcow-files:2026-09 .
docker push registry.example.org/mailcow-files:2026-09

# 2. release (one release per namespace: Services use the fixed compose names)
helm install mailcow helm/mailcow -n mailcow --create-namespace \
  --set mailcow.hostname=mail.example.org \
  --set mailcow.networks=10.244.0.0/16 \
  --set unbound.clusterIP=10.96.53.53 \
  --set files.image.repository=registry.example.org/mailcow-files
```

Before installing, check three cluster-specific values:

| value | what | how to find it |
|---|---|---|
| `unbound.clusterIP` | fixed ClusterIP of the `unbound` Service, nameserver of most mailcow pods | an unused IP inside the **service CIDR** (`kubectl cluster-info dump \| grep service-cluster-ip-range`); default `10.96.53.53` fits kind/kubeadm `10.96.0.0/12` |
| `clusterDNS` | kube-dns/CoreDNS ClusterIP, unbound forwards `clusterDomain` to it | `kubectl -n kube-system get svc kube-dns` |
| `mailcow.networks` | `MAILCOW_NETWORKS`: CIDRs trusted as internal (postfix `mynetworks`, rspamd, dovecot) | the **pod CIDR** only. Never node or LB ranges: SNAT'd outside clients would become trusted relays |

Login: `admin` / `moohoo`. API key: `kubectl -n mailcow get secret mailcow-secrets -o jsonpath='{.data.API_KEY}' | base64 -d`
(effective once `mailcow.apiAllowFrom` is set).

## Architecture

| compose service | Kubernetes |
|---|---|
| unbound | Deployment + Service `unbound` with fixed ClusterIP; repo `unbound.conf` + appended `forward-zone` for `clusterDomain` → `clusterDNS` (`domain-insecure`, DNSSEC stays on for the rest) |
| mysql, redis | StatefulSet (1 replica, PVC). Clients use TCP (`DBHOST=mysql`) |
| dovecot, postfix | StatefulSet (1 replica) |
| rspamd | Deployment, `hostname: rspamd` (worker-proxy binds `rspamd:9900`) |
| php-fpm, sogo, nginx, clamd, olefy, memcached, postfix-tlspol | Deployment |
| dockerapi | Deployment + ServiceAccount/Role (pods get/list/watch/delete, pods/exec, metrics.k8s.io), `DOCKERAPI_BACKEND=kubernetes` |
| acme | optional (`acme.enabled`), default off → cert-manager / Secret / self-signed |
| watchdog | optional (`watchdog.enabled`); probes do the self-healing |
| netfilter | optional hostNetwork DaemonSet (`netfilter.enabled`) |
| ofelia | one CronJob per ofelia job, `kubectl exec` into the main container |

Naming contract: pods carry `app.kubernetes.io/component=<svc>` (`<svc>` = compose service minus
`-mailcow`, e.g. `php-fpm`), the main container is named `<svc>-mailcow`. Every compose alias
(`phpfpm`, `redis`, …) and container name (`php-fpm-mailcow`, `redis-mailcow`, …) is a ClusterIP Service.

Pods that use `dns: ${IPV4_NETWORK}.254` in compose get `dnsPolicy: None` with the unbound ClusterIP
as nameserver and `<ns>.svc.<clusterDomain>`, `svc.<clusterDomain>`, `<clusterDomain>` as search
domains (ndots 5), so Service names keep resolving through unbound.

### Config files (files image)

Each pod has an initContainer `seed` that copies its slice of `data/` from the files image into an
`emptyDir` (`/seed/<path relative to data/>`); main containers mount it with `subPath` at exactly
the compose bind targets, so entrypoints can still write generated files. User overrides:

```yaml
extraFiles:
  conf/postfix/extra.cf: |
    smtpd_banner = $myhostname ESMTP
  conf/nginx/site.custom.custom: |
    location /foo { return 204; }
  hooks/dovecot/10-x.sh: |     # made executable
    #!/bin/sh
```

They are copied over the base slice on every pod start (also into shared dirs such as
`conf/rspamd/custom` and `conf/sogo`, where they overwrite UI edits).

### Storage

| PVC | mounted by |
|---|---|
| `vmail`, `vmail-index`, `crypt` | dovecot (**back up `crypt`**, without it mail is unreadable) |
| `mysql`, `redis`, `postfix-tlspol`, `sogo-backup`, `clamd-db` | their component |
| `postfix` | postfix (+ watchdog, same node) |
| `shared` (subPaths) | `rspamd-vol` (rspamd.sock + state: rspamd, php-fpm, dovecot, postfix, watchdog), `rspamd-custom`, `rspamd-override` (UI password), `sogo-conf` (sogo.conf + dovecot-written creds), `sogo-sso`, `global-sieve`, `ssl` + `acme-challenge` (acme only) |

`persistence.shared.accessMode` defaults to ReadWriteMany. With ReadWriteOnce every pod mounting it
gets a required podAffinity to one node (single-node clusters). Even with RWX, rspamd.sock is a unix
socket, so its users effectively need one node (phase 3: rspamd controller over TCP). Data PVCs and
the generated Secret are kept on `helm uninstall` (`persistence.keep`).

### TLS

`/etc/ssl/mail` in postfix, dovecot, nginx (and watchdog), first match wins:

1. `acme.enabled`: mailcow ACME client writes to the shared `ssl` dir (snake-oil seeded first).
2. `tls.certManager.enabled`: Certificate (`issuerRef`) → Secret `<fullname>-tls`.
3. `tls.existingSecret`.
4. otherwise a pre-install hook Job creates a self-signed snake-oil Secret once (like `generate_config.sh`).

For 2–4 the Secret is mounted as a whole volume at `/etc/ssl/mail-tls` (`cert.pem`/`key.pem`)
and `/etc/ssl/mail` holds `dhparams.pem` (files image) plus symlinks, so renewed certificates appear
in the pods without a restart. The daemons still need a reload to use them (planned: P1.7 /
Reloader); until then restart postfix, dovecot and nginx after a renewal.

### Client IPs and exposure

- Mail: one Service `<fullname>-mail` selects postfix **and** dovecot pods through named target
  ports (one IP for MX and IMAP). `mail.proxyProtocol: true` (default) maps 25/465/587/143/993/110/995/4190
  to the PROXY listeners 10025/10465/10587/10143/10993/10110/10995/14190; the load balancer must send
  PROXY headers, and `mail.proxyTrustedNetworks` becomes dovecot's `haproxy_trusted_networks`.
  `false`: plain ports with `externalTrafficPolicy: Local`.
- HTTP: `<fullname>-http` LoadBalancer/NodePort and/or `http.ingress` (plain HTTP backend; keep
  `mailcow.httpRedirect: n`, set `mailcow.trustedProxies` to the controller's pod CIDR if it is not RFC 1918).

### CronJobs (ofelia)

| job | schedule | target |
|---|---|---|
| phpfpm-keycloak-sync, phpfpm-ldap-sync | `* * * * *` | php-fpm |
| sogo-sessions, sogo-ealarms / sogo-eautoreply / sogo-backup | `* * * * *` / `*/5 * * * *` / `0 0 * * *` | sogo |
| dovecot-imapsync-runner, dovecot-trim-logs | `* * * * *` | dovecot |
| dovecot-quarantine / dovecot-maildir-gc / dovecot-repl-health | `*/20` / `*/30` / `*/5 * * * *` | dovecot |
| dovecot-clean-q-aged, dovecot-fts | `0 0 * * *` | dovecot |
| dovecot-sarules (`@every 24h`) | `0 3 * * *` | dovecot |

All `concurrencyPolicy: Forbid`, time zone `mailcow.tz`; the `MASTER` guards run unchanged inside
the target container. Override with `cronjobs.jobs.<name>.{enabled,schedule}`.

## Image prerequisites

The chart already sets these opt-in variables; images ignore them until the matching change lands:

| id | env set by the chart | effect when supported |
|---|---|---|
| P1.1 | `DBHOST=mysql`, `DBPORT=3306` | MySQL over TCP (today: socket, which does not exist across pods) |
| P1.2 | `SOGO_IMAP_HOST`, `SOGO_SIEVE_HOST`, `SOGO_SMTP_HOST`, `RSPAMD_BCC_HOST`, `DOCKERAPI_HOST`, `REDIS_HOST` (netfilter); nginx `SOGOHOST` (exists) | no static compose IPs / `*_mailcow-network` names; TCP instead of `ping` waits |
| P1.3 | `MAILCOW_NETWORKS`, `SOGO_TRUSTED_NETS` | CIDR-based trust instead of `${IPV4_NETWORK}.x` |
| P1.4 | `SOGO_SSO_PASS`, `SOGO_ENCRYPTION_KEY` (+ `DOVECOT_MASTER_USER/PASS`, honoured today) | stable SOGo SSO/cron/sieve credentials across restarts |
| P1.5 | `DOCKERAPI_BACKEND=kubernetes`, `POD_NAMESPACE` | queue view, restarts, mysql_upgrade etc. through the Kubernetes API |

## Limitations (0.1)

- dovecot/postfix single replica; rspamd/php-fpm/dovecot/postfix share a node through rspamd.sock.
- fail2ban-style bans only with the netfilter DaemonSet, and only when client IPs reach the node
  unmodified (no PROXY protocol, no SNAT).
- `redis` `net.core.somaxconn` is an unsafe sysctl (`redis.sysctls`, off by default); compose
  ulimits for dovecot have no pod equivalent (runtime defaults are higher).
- NetworkPolicy (`networkPolicy.enabled`) only restricts mysql, redis and doveadm (12345) to the namespace.
- No external database support yet (php-fpm waits for the mysql pod via dockerapi).

## Development

- `helm/mailcow/scripts/check-tags.sh [--fix]`: chart image tags must equal `docker-compose.yml`.
- `ci/*-values.yaml`: kind (NodePorts 30080/30443/30025/30465/30587/30143/30993/34190, RWO shared,
  self-signed TLS, clamd skipped), cert-manager + Ingress, HA (RWX, LB + PROXY, netfilter,
  watchdog, NetworkPolicy), acme + extraFiles.
