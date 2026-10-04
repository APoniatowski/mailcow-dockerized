# mailcow Helm chart

Runs [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) on Kubernetes with the
same images as `docker-compose.yml`. Status: **chart 0.1.0, experimental**. It relies on opt-in environment
variables of the mailcow images (see [Environment contract](#environment-contract)); read
[Security](#security) before exposing it.

## Install

```bash
# one release per namespace: Services use the fixed compose names
helm install mailcow helm/mailcow -n mailcow --create-namespace \
  --set mailcow.hostname=mail.example.org \
  --set mailcow.networks=10.244.0.0/16 \
  --set unbound.clusterIP=10.96.53.53 \
  --set files.image.repository=ghcr.io/<owner>/mailcow-files
```

### Files image

Every pod copies its config from the files image: the tracked files of `data/{web,conf,assets,hooks}`
at one commit, plus openssl, curl, socat, tzdata and kubectl (TLS bootstrap, relays, cron scheduler).
`files.image.tag` defaults to the chart's `appVersion` (the mailcow release).

The workflow `.github/workflows/files_image.yml` builds it for linux/amd64 and linux/arm64 from `git
archive HEAD` (tracked files only) and pushes `ghcr.io/<owner>/mailcow-files`:

| trigger | tags |
|---|---|
| push to `master` / `staging` | `:<branch>`, `:sha-<short sha>` |
| release tag (`2026-09`, `2026-09a`, ...) | `:<tag>` (= `appVersion`, the default `files.image.tag`) |
| manual run (workflow_dispatch) | as above, for the selected branch or tag |
| pull request | build only, nothing pushed |

Publishing it from a fork:

1. Enable Actions on the fork (Settings > Actions; a fresh fork also asks for confirmation on the
   Actions tab). No secrets needed: the workflow pushes with `GITHUB_TOKEN`.
2. Push a release tag, `master` or `staging`, or run the workflow manually.
3. The first push creates a **private** package `mailcow-files`: make it public (Packages >
   mailcow-files > Package settings > Change visibility), or keep it private and give the chart a
   ghcr.io pull secret through `imagePullSecrets`.
4. Set `files.image.repository: ghcr.io/<owner, lower case>/mailcow-files` (tag: `appVersion` by
   default, or a branch / `sha-` tag).

Building it by hand (e.g. for the local kind cluster), from a clean export:

```bash
git archive HEAD | docker build -f helm/mailcow/files-image/Dockerfile \
  --build-arg MAILCOW_VERSION=$(git describe --tags --abbrev=0) \
  --build-arg MAILCOW_COMMIT=$(git rev-parse HEAD) \
  -t registry.example.org/mailcow-files:2026-09 -
```

or from the working tree with BuildKit (`docker buildx build -f helm/mailcow/files-image/Dockerfile
-t ... .`), which applies `Dockerfile.dockerignore`: it mirrors every `data/` entry of `.gitignore` and
re-includes the tracked files those patterns match, so the generated and secret files a compose
installation leaves in the working tree (`mailcow.conf`-derived configs, `data/conf/rspamd/override.d/*`,
`sogo/plist_ldap`, nginx `*.conf`, postfix maps, certificates, hooks) stay out. The legacy builder
ignores that file and would copy everything; the Dockerfile then fails on a list of known secret
files. Untracked files that `.gitignore` does not cover still get in from a working tree: hence `git
archive`. `--build-arg KUBECTL_VERSION=v1.xx.y` picks the kubectl of the cron scheduler.

GitOps and other client-side renderers (Argo CD, Flux with `helm template`-style rendering, `helm
template | kubectl apply`) cannot run `lookup`: every render would generate new passwords and a new
rspamd relay CA. Use `existingSecret` (release passwords) and `rspamd.socketRelay.tls.existingSecret`
there, and set `clusterDNS` explicitly.

Requires Kubernetes >= 1.29 (native sidecar containers, beta and on by default since 1.29, GA in
1.33; `kubeVersion` in `Chart.yaml`). Before installing, check these cluster-specific values:

| value | what | how to find it |
|---|---|---|
| `unbound.clusterIP` | fixed ClusterIP of the `unbound` Service, nameserver of most mailcow pods | an unused IP inside the **service CIDR** (`kubectl cluster-info dump \| grep service-cluster-ip-range`); default `10.96.53.53` fits kind/kubeadm `10.96.0.0/12` |
| `clusterDNS` | kube-dns/CoreDNS ClusterIP, unbound forwards `clusterDomain` to it | empty (default): looked up from `kube-system/kube-dns` at install/upgrade (needs `get services` in kube-system; `10.96.0.10` when nothing is found, e.g. offline renders); otherwise `kubectl -n kube-system get svc kube-dns` |
| `unbound.forwarders` | optional upstream resolvers (`[1.1.1.1, 9.9.9.9]`, `IP@port` allowed) for everything outside `clusterDomain`; empty = full recursion from the root servers like compose | set it when outbound port 53 is filtered or intercepted (recursion from the root then fails: every external lookup SERVFAILs); the forwarders must pass DNSSEC records through, validation stays on |
| `mailcow.networks` | `MAILCOW_NETWORKS`: CIDRs trusted as internal (postfix `mynetworks`, rspamd, dovecot) | the **pod CIDR** only. Never node or LB ranges: SNAT'd outside clients would become trusted relays |
| `mail.proxyProtocol`, `mail.proxyTrustedNetworks` | PROXY protocol on the mail ports (default off). On, `proxyTrustedNetworks` is required | the addresses your load balancer connects to the pods from, see [Security](#client-addresses-externaltrafficpolicy-local-or-proxy-protocol-is-required) |
| `mailcow.sogoTrustedNets` | `SOGO_TRUSTED_NETS`: where SOGo's dovecot logins come from | defaults to `mailcow.networks` with a warning, see [Security](#security) |

Login: `admin` / `moohoo`. API key: `kubectl -n mailcow get secret mailcow-secrets -o jsonpath='{.data.API_KEY}' | base64 -d`
(effective once `mailcow.apiAllowFrom` is set).

## Architecture

| compose service | Kubernetes |
|---|---|
| unbound | Deployment + Service `unbound` with fixed ClusterIP; repo `unbound.conf` + appended `forward-zone` for `clusterDomain` → `clusterDNS` (`domain-insecure`, DNSSEC stays on for the rest), plus `forward-zone "."` → `unbound.forwarders` when set |
| mysql, redis | StatefulSet (1 replica, PVC), or an external server (`externalDatabase` / `externalRedis`, optionally over TLS through a proxy: [External database / Redis](#external-database--redis)). Clients use TCP (`DBHOST=mysql`) |
| dovecot | StatefulSet (1 replica) |
| postfix | StatefulSet `<fullname>-postfix`, `postfix.replicas` (default 1; > 1 with a queue PVC per pod in StatefulSet `<fullname>-postfix-spool`, [Scaling](#scaling)) |
| rspamd | Deployment, `rspamd.replicas` or an HPA, `hostname: rspamd` (worker-proxy binds `rspamd:9900`, the own pod IP in every replica), per-pod `/var/lib/rspamd`; controller socket relayed over TCP 11335 with mutual TLS ([Storage](#storage)) |
| php-fpm, sogo, nginx | Deployment, `replicas` or an HPA ([Scaling](#scaling)) |
| clamd, olefy, memcached, postfix-tlspol | Deployment |
| dockerapi | Deployment + ServiceAccount/Role (pods list/delete, pods/exec create/get, replicasets get, deployments/statefulsets patch, metrics.k8s.io pods get), `DOCKERAPI_BACKEND=kubernetes`; restart = rollout restart of the owning Deployment/StatefulSet; Services `dockerapi`/`dockerapi-mailcow`, NetworkPolicy always on. **See [Namespace](#namespace)** |
| acme | optional (`acme.enabled`), default off → cert-manager / Secret / self-signed |
| watchdog | optional (`watchdog.enabled`); probes do the self-healing |
| netfilter | not shipped: fail2ban is not supported on Kubernetes, see [Brute-force protection](#brute-force-protection-no-fail2ban) |
| ofelia | `cronjobs.mode`: one scheduler Deployment with busybox crond (default) or one CronJob per ofelia job; either runs `kubectl exec` into the main container ([CronJobs](#cronjobs-ofelia)) |

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

They are copied over the base slice on every pod start (also into the shared dir
`conf/rspamd/custom`, where they overwrite UI edits). Paths are relative to `data/` and may only use
letters, digits and `. _ - @ +` (the chart fails otherwise). `extraFiles` content ends up in a
ConfigMap; for credentials (`conf/acme/dns-01.conf`, `conf/sogo/plist_ldap`, ...) reference a Secret
you manage instead, same semantics, applied after `extraFiles`:

```yaml
extraSecretFiles:
  conf/acme/dns-01.conf: {secretName: mailcow-acme-dns, key: dns-01.conf}
  conf/sogo/plist_ldap: {secretName: mailcow-sogo-ldap, key: plist_ldap}
```

### Storage

| PVC | mounted by |
|---|---|
| `vmail`, `vmail-index`, `crypt` | dovecot (**back up `crypt`**, without it mail is unreadable; [Backup and restore](#backup-and-restore)) |
| `mysql`, `redis`, `postfix-tlspol`, `sogo-backup`, `clamd-db` | their component (`mysql`/`redis` not created with `externalDatabase`/`externalRedis`) |
| `postfix` | postfix (+ watchdog, same node). With `postfix.spoolPerPod`: one claim `spool-<fullname>-postfix-spool-<n>` per pod instead, not mounted by watchdog ([Scaling](#scaling)) |
| `shared` (subPaths) | see below |

Only directories that one pod writes and another reads at runtime remain on `shared`:

| subPath | written by | read by |
|---|---|---|
| `rspamd-custom` (`data/conf/rspamd/custom`) | php-fpm (UI maps), dovecot (`sa-rules` CronJob) | rspamd |
| `rspamd-override/worker-controller-password.inc` (rspamd UI password, compose: `data/conf/rspamd/override.d`) | dockerapi (`rspamd/worker_password`, exec into one rspamd pod, then a rollout restart of the Deployment) | every rspamd replica |
| `global-sieve/{before,after}` | php-fpm (UI global filters) | dovecot |
| `ssl`, `acme-challenge` (only `acme.enabled`) | acme | nginx, postfix, dovecot, watchdog |

So `shared` is mounted by php-fpm, dovecot and rspamd, plus acme, nginx, postfix and watchdog with
`acme.enabled`. sogo never mounts it, nor do nginx, postfix and watchdog without acme.

`persistence.shared.accessMode` defaults to ReadWriteMany (multi-node: the pods above may run
anywhere). With ReadWriteOnce (single node, or no RWX storage class) the pods that mount it get the
label `mailcow.email/shared-volume` and a required podAffinity to each other, so they land on the
node holding the volume; every other pod schedules freely. `global-sieve/{before,after}` start as the
repo's `data/conf/dovecot/global_sieve_*` (or `extraFiles` with those paths) and are only re-seeded
while missing or empty. Data PVCs and the generated Secret are kept on `helm uninstall`
(`persistence.keep`). `persistence.storageClass` is the default class of every PVC; each volume
(`persistence.<volume>.storageClass`, `backup.persistence.storageClass`) may override it (`"-"` =
`storageClassName: ""`, no dynamic provisioning).

Not shared (compose shares them through bind mounts or named volumes):

- SOGo credentials: dovecot's entrypoint writes `sieve.creds`, `cron.creds` (`/etc/sogo`) and
  `sogo-sso.pass` (`/etc/phpfpm`) on every start. In the chart these two directories are pod-local
  `emptyDir`s in dovecot (`imapsync_runner.pl` reads its local `sieve.creds`), and the seed
  initContainers of sogo (`/etc/sogo/{sieve,cron}.creds`, next to the repo's `data/conf/sogo`) and
  php-fpm (`/etc/sogo-sso/sogo-sso.pass`) write byte-identical files from the same Secret keys
  (`DOVECOT_MASTER_USER`, `DOVECOT_MASTER_PASS`, `SOGO_SSO_PASS`, same `echo`/`echo -n` as the
  entrypoint). With `existingSecret` nothing new is needed: those keys were already required. The
  SOGo CronJobs read the files in the sogo pod.
- rspamd's `/var/lib/rspamd` (compose: `rspamd-vol-1`, shared with php-fpm, dovecot, postfix and
  watchdog for the controller socket) is an `emptyDir` per rspamd pod. What rspamd keeps there is
  per-instance and rebuilt on demand: the controller socket, the controller's counters (`stats.ucl`:
  scanned/learned numbers shown in the UI), downloaded map and hyperscan caches. Everything that must
  survive lives in Redis: mailcow's `local.d/redis.conf` (written by the entrypoint) points every
  module at `redis:6379`, and `statistic.conf` (Bayes), `worker-fuzzy.inc` (fuzzy hashes),
  `history_redis.conf`, ratelimits, greylisting and reputation use it.
- rspamd's controller socket (`/var/lib/rspamd/rspamd.sock`, trusted without password by
  `worker-controller.inc`: full controller access): the rspamd pod runs a native sidecar
  `rspamd-sock-relay` (socat, files image) that forwards TCP 11335 to the socket with **mutual TLS**
  (`OPENSSL-LISTEN ... verify=1`): only clients presenting a certificate signed by the relay CA get a
  connection. php-fpm, dovecot, postfix and watchdog get an `emptyDir` at `/var/lib/rspamd` and a
  native sidecar `rspamd-sock` that listens on `/var/lib/rspamd/rspamd.sock` (mode 0666, like rspamd's
  own) and connects per connection to `rspamd-mailcow.<ns>.svc.<clusterDomain>:11335` with the client
  certificate, verifying the server certificate against the CA and that name (`OPENSSL ...
  verify=1`). Clients and rspamd config are unchanged; rspamd still sees unix-socket clients.
  - Certificates: Secret `<fullname>-rspamd-relay-tls` (`ca.crt`, `tls.crt`/`tls.key` with the SANs
    `rspamd-mailcow`, `rspamd` and their `.<ns>.svc[.<clusterDomain>]` names, `client.crt`/`client.key`),
    generated by the chart (`genCA`/`genSignedCert`, `rspamd.socketRelay.tls.days`, default 10 years)
    and kept on upgrade (`lookup`; regenerated if missing or incomplete). Or bring your own with
    `rspamd.socketRelay.tls.existingSecret` (required for GitOps renderers). The relay containers
    mount only their half (server: CA + server pair; clients: CA + client pair) read-only, mode 0444
    because they run as uid 10900 and Secret files are root-owned; no other container mounts them.
  - socat loads the server certificate once at start: the rspamd pod carries a checksum annotation of
    the generated Secret and restarts when the chart regenerates it. With `existingSecret`, restart
    rspamd yourself after rotating (`kubectl rollout restart deployment/<fullname>-rspamd`); clients
    read their files per connection once the kubelet has synced the Secret (a minute or two).
  - The always-on NetworkPolicy for 11335 stays as defense in depth.
  - Both relays run as uid/gid 10900, which no mailcow image uses (postfix 101, dovecot 401/402/5000,
    sogo 999; `nobody` 65534 runs the imapsync CronJob inside dovecot), with every capability
    dropped and a read-only root filesystem: in pods with a shared process namespace (`tls-reload`)
    they share no uid with any daemon. `rspamd.socketRelay.resources` sizes the sidecars.
  - The relay listens dual-stack (`pf=ip6,ipv6only=0`) when the pod has IPv6 (non-empty
    `/proc/net/if_inet6`) and IPv4-only (`pf=ip4`) otherwise, decided at container start, so it works
    on IPv4, IPv6 and dual-stack clusters. The client relays connect by name; socat (1.8) tries every
    A/AAAA address of the Service in turn.

### External database / Redis

`externalDatabase.enabled` / `externalRedis.enabled` replace the in-cluster StatefulSets with a server
you run (managed service, operator, VM). The chart then renders no mysql / redis StatefulSet, PVC or
NetworkPolicy, and the Services `mysql` + `mysql-mailcow` / `redis` + `redis-mailcow` alias the
external `host`, so every component keeps using the names it uses today (`DBHOST=mysql`, `redis:6379`):

| `host` | Services | ports |
|---|---|---|
| DNS name (lower-cased, RFC 1123) | `type: ExternalName` (a CNAME to `host`) | no port mapping: clients connect to `host:port` |
| IPv4 or IPv6 literal (`192.0.2.10`, `2001:db8::10`, brackets allowed) | selector-less ClusterIP Service (single stack, the address's family) + EndpointSlice `<service>-external` | Service port → `host:port` |

Notes on the aliases:

- ExternalName is a plain DNS CNAME. The usual ExternalName caveats (TLS certificate names, HTTP
  `Host`/SNI) do not apply: MySQL and Redis carry no host name in the protocol.
- Most mailcow pods resolve through unbound, which forwards `clusterDomain` to kube-dns and resolves
  the CNAME target itself: by full recursion, or through `unbound.forwarders`. A name that only a
  private resolver knows (e.g. a private cloud DNS zone) needs `unbound.forwarders` pointing at a
  resolver that knows it, or use the IP address.
- An IPv6 address needs an IPv6-capable (single- or dual-stack) cluster, and vice versa: the Service
  family must match the address.
- Switching an existing release between the in-cluster server and an external one (or between DNS
  and IP hosts, or `tls.enabled` on and off) changes the Service type; if Helm reports an immutable field, delete the four
  Services and upgrade again. Data does not move by itself: dump the in-cluster database
  (`mariadb-dump`) and restore it into the external one before switching.

#### Database (`externalDatabase`)

`DBPORT` becomes `externalDatabase.port` on every client; `DBHOST` stays `mysql`. Before installing,
the DBA prepares:

- the database `mailcow.dbName` (`utf8mb4`) and the user `mailcow.dbUser` with the password `DBPASS`
  from the release Secret (`existingSecret`, or read it from the generated one), with
  `GRANT ALL PRIVILEGES ON <dbName>.* TO <dbUser>`: mailcow creates and alters its tables and views
  on every php-fpm start, drops a SOGo trigger, and php-fpm (re)creates the scheduled events
  `clean_spamalias`, `clean_oauth2` and `clean_sasl_log` (needs `EVENT`);
- `event_scheduler=ON` on the server (compose's `data/conf/mysql/my.cnf` sets it). Without it the
  events exist but never run: expired spam aliases, OAuth2 tokens and old SASL log rows pile up;
- the time zone tables (`mysql_tzinfo_to_sql /usr/share/zoneinfo | mariadb -u root mysql`, or the
  managed service's equivalent). With the bundled MariaDB php-fpm imports them through dockerapi;
  its start-up check (`CONVERT_TZ('…','Europe/Berlin','UTC')`) returns NULL while they are missing;
- a `max_allowed_packet` large enough for big sieve scripts and quarantine items (compose: 192M).

php-fpm gets `SKIP_MYSQL_UPGRADE=y`: it skips the `mysql_upgrade` and time zone import it would
otherwise run through dockerapi inside the mysql pod (there is none), and only warns in its log if
`CONVERT_TZ` returns NULL. `DBROOT` (Secret) is then unused, except by watchdog's MySQL replication
checks (`WATCHDOG_MYSQL_REPLICATION_CHECKS`, off by default). Backups, upgrades, replication and
high availability of the database are yours.

#### Redis (`externalRedis`)

- Its password must equal `REDISPASS` from the release Secret (`requirepass`, or the default user's
  password). mailcow's Redis clients (PHP, Python, Lua, `redis-cli`) speak plain TCP; for TLS see
  [TLS to the external database / Redis](#tls-to-the-external-database--redis).
- mailcow components hard-code port 6379. With a DNS `host` the port must therefore be 6379 (the chart
  fails otherwise, ExternalName cannot remap ports); with an IP `host` the Services listen on 6379 and
  the EndpointSlice maps it to `externalRedis.port`. With `externalRedis.tls.enabled` any port works.
- rspamd sends `SLAVEOF NO ONE` on every start (compose behaviour): point `host` at a primary, never
  at a replica. Managed services that reject the command just log an error.
- Give mailcow a Redis of its own: its keys are unprefixed, in the default database. mailcow keeps
  settings, rspamd's Bayes/fuzzy data and logs there, so the server needs persistence (RDB/AOF) and
  backups.
- watchdog (off by default) checks Redis with `check_tcp -4`: with an IPv6 Redis its Redis check
  fails. Its restart action for mysql/redis finds no pod with either external server.

#### TLS to the external database / Redis

mailcow's clients have no TLS settings for MySQL or Redis. `externalDatabase.tls.enabled` /
`externalRedis.tls.enabled` put a proxy in between: it listens in plain text inside the namespace and
opens TLS connections to `host:port`. The Services `mysql` + `mysql-mailcow` / `redis` + `redis-mailcow`
then become ordinary ClusterIP Services selecting the proxy pods (no ExternalName / EndpointSlice), so
clients keep using the same names and ports (`DBHOST=mysql`, `DBPORT=3306`, `redis:6379`). Without
`tls.enabled` nothing changes.

| | Redis: `<fullname>-redis-tls` | MySQL/MariaDB: `<fullname>-db-tls` |
|---|---|---|
| proxy | socat from the files image (TLS is a plain wrapper around the Redis protocol) | ProxySQL 2.x (`externalDatabase.tls.image`, GPL-3.0): MySQL switches to TLS inside its protocol, a byte relay cannot add it |
| listens | 6379, plain | 3306, plain (ProxySQL user = `DBUSER`/`DBPASS` from the release Secret) |
| server certificate | `caSecret` (`ca.crt`), empty = public CA bundle of the files image; name = `serverName`, empty = `host` (an IP `host` is checked against the certificate's IP addresses); `serverName` is also the SNI | `caSecret` (`ca.crt`), required with `verify: true`. **Chain only: ProxySQL does not check the server name** (below) |
| client certificate | `clientCertSecret` (`tls.crt`/`tls.key`), optional | `clientCertSecret` (`tls.crt`/`tls.key`), optional (users with `REQUIRE X509`) |
| no verification | `insecureSkipVerify: true` | `verify: false` |
| replicas | `externalRedis.tls.replicas` (PDB and soft spread above 1) | `externalDatabase.tls.replicas` (same) |
| rotation | certificate files are read per connection: no restart needed | read at start: `kubectl rollout restart deployment/<fullname>-db-tls` after a rotation |

Both run as uid 10900 with a read-only root filesystem and every capability dropped, use the cluster DNS
(kube-dns, not unbound: in-cluster Service names and private zones the cluster resolves work), and are
hidden from dockerapi (not part of the UI's container list). A NetworkPolicy, rendered even with
`networkPolicy.enabled: false`, admits only pods of this release to the plain port: the proxy hands its
client certificate to whoever connects. With `networkPolicy.egress.enabled` a server inside
`networkPolicy.egress.clusterCIDRs` (an operator in another namespace) must be added to
`networkPolicy.egress.extraTo`, as without TLS.

Redis relay: at start it logs one verification of the server certificate (`TLS check ...: ok` or
`FAILED` with the reason, e.g. `hostname mismatch`, `certificate required`) and relays either way;
socat itself logs errors only, so a later failure shows up as connection errors in the clients and the
server's log. Tested against `redis:7.4` with `--tls-port`, `--port 0` and `--tls-auth-clients yes`
(wrong CA, wrong name and missing client certificate are refused, `PING`/`SET`/`GET` through the relay work)
and under the load of a full release start-up on a local kind cluster. socat forks one process (~5 MiB)
per client connection: start-up peaked at ~120 MiB, steady state is 6-14 MiB. Defaults: memory limit
256Mi and `externalRedis.tls.maxChildren: 40` (socat `max-children`): further connections are not
refused but wait in the listen backlog until a child exits, so a connection storm cannot exceed the
limit. Raise both together (about 5 MiB per child) if more Redis connections stay open at once
(several rspamd/php-fpm/dovecot replicas): a client queued behind long-lived connections stalls.

ProxySQL (`proxysql.cnf` is generated by an initContainer on every pod start):

- Multiplexing is off: every client connection gets its own TLS connection to the server for its
  lifetime, so session state (`SET NAMES`, `SET FOREIGN_KEY_CHECKS`, transactions, server-side prepared
  statements of PDO with `ATTR_EMULATE_PREPARES => false`) behaves as on a direct connection. Verified
  through ProxySQL 2.7.3 against `mariadb:10.11` with `--require-secure-transport=ON`: `SHOW STATUS
  LIKE 'Ssl_cipher'` on the proxied session returns the server's TLS cipher; php-fpm's `init_db.inc.php`
  creates the full schema; the entrypoint's `DROP EVENT` / `CREATE EVENT` blocks (`DELIMITER`),
  `mariadb-admin status` (the start-up wait loops), multi-statement queries, PDO transactions, rollback,
  `lastInsertId`, utf8mb4, a 50 MiB value and `mariadb-dump --single-transaction` + restore (backups) work.
- **The server name is not verified.** ProxySQL (2.7 and 3.0) checks the certificate chain against
  `caSecret` but has no setting to check the host name: any certificate signed by that CA is accepted.
  Use a CA that signs only database servers you trust (a private CA, or the provider's database CA:
  then any database server of that provider/region with a certificate from it could impersonate yours).
  Never a public CA bundle (the chart requires `caSecret` with `verify: true`). If you need host name
  verification, the alternative is TLS in mailcow's clients themselves, which needs image changes
  (PDO `MYSQL_ATTR_SSL_CA`, dovecot/postfix/SOGo connection settings, the `mariadb` CLI calls).
- The monitor is off (`mysql-monitor_enabled=false`, no extra user needed); a server that refuses
  connections is shunned for 10 s and retried. The admin interface listens on 127.0.0.1:6032 only, with
  a random password from Secret `<fullname>-db-tls` (kept on upgrade); the startup and liveness
  probes use it (`SELECT 1`; a bare TCP probe makes ProxySQL log an "unhealthy client" warning per
  probe). The readiness probe logs in as `DBUSER` on 3306 and runs `SELECT VERSION()`, which ProxySQL
  forwards to the server: a proxy pod that cannot reach the server (down, TLS or login refused) is
  taken out of the Service, and a rollout with a broken setting (e.g. wrong `caSecret`) stops at the
  first new pod instead of replacing working ones. A database outage therefore leaves `mysql` without
  endpoints (clients fail to connect instead of getting ProxySQL's error after its 10 s connect
  timeout; with `networkPolicy.egress.enabled` they wait for their own timeout, see Egress), while
  liveness stays local, so the proxy is not restarted. It costs one server connection per pod every
  10 s (visible if the server logs connections).
- ProxySQL announces itself as `8.0.11` in the handshake unless `serverVersion` is set; queries,
  including `SELECT VERSION()`, still reach the real server. mailcow does not check the version.
- Only `DBUSER` exists in ProxySQL: watchdog's MySQL replication checks (`DBROOT`, off by default) and
  `scripts/restore.sh` physical restores (bundled server only anyway) do not go through it. The server
  user authenticates with `mysql_native_password` (MariaDB default); tested with MariaDB only.
- `--no-version-check`: ProxySQL does not phone home for its latest version.

### TLS

`/etc/ssl/mail` in postfix, dovecot, nginx (and watchdog), first match wins:

1. `acme.enabled`: mailcow ACME client writes to the shared `ssl` dir (snake-oil seeded first).
2. `tls.certManager.enabled`: Certificate (`issuerRef`) → Secret `<fullname>-tls`.
3. `tls.existingSecret`.
4. otherwise a pre-install **and pre-upgrade** hook Job (`tls-bootstrap`) creates a self-signed
   snake-oil Secret once (like `generate_config.sh`). It is not rendered when the Secret already
   exists (`lookup`); if it runs anyway it keeps an existing Secret (HTTP 409). It runs as uid 10900
   with a read-only root filesystem, every capability dropped and an in-memory `emptyDir` for the key;
   its ServiceAccount (Secret `create` only) and RBAC are deleted once the hook succeeds.

Switching `tls.certManager.enabled` off deletes the Certificate but not its Secret `<fullname>-tls`
(cert-manager only removes it with `--enable-certificate-owner-ref`). The bootstrap hook then finds
the Secret and is skipped, so the pods keep serving the last issued certificate, which nobody renews
any more. To get the self-signed bootstrap back, `kubectl delete secret <fullname>-tls` right before
the `helm upgrade` that switches it off (the hook then creates a new snake-oil Secret).

For 2–4 the Secret is mounted as a whole volume at `/etc/ssl/mail-tls` (`cert.pem`/`key.pem`)
and `/etc/ssl/mail` holds `dhparams.pem` (files image) plus symlinks, so renewed certificates appear
in the pods without a restart (kubelet syncs Secret volumes within a minute or two). The daemons
only read certificates when they (re)load, so every nginx, postfix and dovecot pod runs a native
sidecar `tls-reload` (`tls.reload.enabled`, default on). It hashes `cert.pem` + `key.pem` every
`tls.reload.interval` seconds (default 300) and, when the hash changes, sends SIGHUP to the master
process of its own pod, found by name in the shared process namespace:

| pod | master process (`comm`, command line) | SIGHUP |
|---|---|---|
| nginx | `nginx`, `nginx: master process ...` | reload: new workers with the new certificate, old ones finish their connections (= `nginx -s reload`) |
| postfix | `master`, `/usr/lib/postfix/sbin/master -w` (started by `postfix start`) | re-reads its configuration, running daemons exit when idle (= `postfix reload`, which sends exactly this signal) |
| dovecot | `dovecot`, `/usr/sbin/dovecot -F` (supervisord) | reload (= `doveadm reload`) |

All three are graceful: open connections finish, new ones get the new certificate. Each pod reloads
itself, so every replica is covered, and the new certificate is in use within `interval` plus the
kubelet sync delay after a renewal. If no master process is found (container restarting) the sidecar
retries on the next check; a restarted daemon has read the new files anyway.

`shareProcessNamespace: true` is set on those three pods only when the sidecar is rendered. All
containers of such a pod then see each other's processes: the main container (root and the daemons'
own users), the `rspamd-sock` relay (postfix, dovecot; uid 10900) and `tls-reload`. What each can do:

- Every process can list the pod's processes and read the world-readable `/proc/<pid>/{comm,cmdline,status}`
  (command lines are visible pod-wide, as on any host without `hidepid`).
- Reading another process's environment or memory, or its files through `/proc/<pid>/root`, needs
  the kernel's ptrace access check: same uid **and** the caller's capabilities a superset of the
  target's, or `CAP_SYS_PTRACE`, which no container has. The relay (10900) shares no uid with any
  daemon, so it cannot look into dovecot's `nobody` imapsync runs (which handle the dovecot master
  password) or anything else, and no daemon can read the relay's client key.
- `tls-reload` runs the files image's busybox shell as **uid 0**: the masters run as root, and a
  process may signal another of the same uid without a capability. It can therefore signal (e.g.
  kill) root processes of the pod. It cannot read their environment, memory or files: it has no
  capabilities, so its permitted set is not a superset of the root daemons', and the daemons' other
  uids differ. It cannot signal the relay (other uid). This is acceptable because it is a fixed loop
  from the chart (no input but the mounted TLS Secret, the only volume it mounts), opens no network
  listener, has a read-only root filesystem, `allowPrivilegeEscalation: false` and every capability
  dropped; the main container already runs as root with more capabilities next to it.
- The main container (root with the runtime's default capabilities, which include `CAP_KILL`) can
  signal the sidecars, which it could disrupt anyway. The `seed` initContainer has exited before the
  main container starts.

Side effect: the pause container is PID 1 and reaps orphans (postfix's daemonised master is
re-parented to it instead of supervisord; nothing in the images depends on that).

cert-manager renews at 2/3 of the certificate lifetime by default (30 days before expiry for
90-day Let's Encrypt certificates; `tls.certManager.renewBefore` overrides it). With `acme.enabled`
no sidecar is rendered: the acme container reloads/restarts the daemons through dockerapi itself.

### Client IPs and exposure

- Mail: one Service `<fullname>-mail` (`mail.service.type` LoadBalancer, NodePort or ClusterIP)
  selects postfix **and** dovecot pods through named target ports (one IP for MX and IMAP).
  `mail.proxyProtocol: false` (default): plain ports with `externalTrafficPolicy: Local`.
  `true` maps 25/465/587/143/993/110/995/4190 to the PROXY listeners
  10025/10465/10587/10143/10993/10110/10995/14190; the load balancer must send PROXY headers, and the
  required `mail.proxyTrustedNetworks` becomes dovecot's `haproxy_trusted_networks` and the only
  allowed source of the PROXY ports. Either way the client address must reach postfix unchanged, see
  [Security](#security). `mail.service.allocateLoadBalancerNodePorts` (unset = Kubernetes default
  `true`) can drop the node ports for load balancers that target pod IPs.
- HTTP: `<fullname>-http` (`http.service.type` LoadBalancer, NodePort or ClusterIP;
  `http.service.loadBalancerSourceRanges`) and/or `http.ingress` (plain HTTP backend; keep
  `mailcow.httpRedirect: n`, set `mailcow.trustedProxies` to the controller's pod CIDR if it is not RFC 1918).
  `externalTrafficPolicy` and the node ports are only rendered for NodePort/LoadBalancer, the
  `loadBalancer*` fields only for LoadBalancer.

### CronJobs (ofelia)

| job | schedule | target |
|---|---|---|
| phpfpm-keycloak-sync, phpfpm-ldap-sync | `* * * * *` | php-fpm |
| sogo-sessions, sogo-ealarms / sogo-eautoreply / sogo-backup | `* * * * *` / `*/5 * * * *` / `0 0 * * *` | sogo |
| dovecot-imapsync-runner, dovecot-trim-logs | `* * * * *` | dovecot |
| dovecot-quarantine / dovecot-maildir-gc / dovecot-repl-health | `*/20` / `*/30` / `*/5 * * * *` | dovecot |
| dovecot-clean-q-aged, dovecot-fts | `0 0 * * *` | dovecot |
| dovecot-sarules (`@every 24h`) | `0 3 * * *` | dovecot |

Every job is a `kubectl exec <workload> -c <svc>-mailcow -- /bin/bash -c '<ofelia command>'`: the
`MASTER` guards run unchanged inside the target container. With replicas, `kubectl exec
deployment/<name>` picks one pod, so each job still runs once per schedule (the `MASTER`-guarded SOGo
jobs must run once, not per replica). Schedules are in `mailcow.tz`; override per job with
`cronjobs.jobs.<name>.{enabled,schedule}` (both modes). `cronjobs.enabled: false` runs no jobs and
removes the ServiceAccount and Role too. The Role (shared by both modes) can `get` only the targeted
workloads (`<fullname>-php-fpm`, `-sogo`, `-dovecot`) but `pods/exec` cannot be scoped to them.

`cronjobs.mode` picks how the jobs are started:

| | `scheduler` (default) | `cronjob` |
|---|---|---|
| objects | Deployment `<fullname>-cron` (1 replica, `Recreate`) + ConfigMap with the crontab | one CronJob `<fullname>-<job>` per job |
| runs | busybox `crond` in the files image starts `kubectl exec` (files image, `/usr/local/bin/kubectl`) | a pod per run with `cronjobs.image` (kubectl) |
| pods per day (defaults: 14 jobs, 6 of them every minute) | 0 (one long-running pod) | ~9,300 short-lived pods, each with an API token, an image check, scheduler and kubelet work |
| API load | the same ~9,300 `pods/exec` calls a day | the exec calls plus pod and Job objects |
| overlap | crond never starts a job while its previous run is still active; ofelia's `no-overlap` jobs (`phpfpm-keycloak-sync`, `phpfpm-ldap-sync`, `dovecot-imapsync-runner`) also hold `flock -n /tmp/<job>.lock` for the run | `concurrencyPolicy: Forbid` |
| missed runs | lost while the scheduler pod is down (rescheduling, node drain, upgrade), like compose's single ofelia container | started late if the controller catches up within `startingDeadlineSeconds` (120 s) |
| logs | the scheduler pod's log: crond's `USER mailcow pid ... cmd ... run-job <job>` per start, every output line prefixed `[<job>]`, `[<job>] failed (exit N)` on errors | one pod log per run, kept until `ttlSecondsAfterFinished` |
| failures | logged, nothing retried (ofelia behaviour) | Job marked failed (`backoffLimit: 0`), nothing retried |

Scheduler details:

- One replica only: two schedulers would run every job twice. `Recreate` stops the old pod before
  the new one starts; a run in progress during an upgrade is cut off with its `kubectl exec` session
  (the command in the target container may finish or be killed, as with a restarted ofelia).
- `crond` starts as root with only `CAP_SETUID`/`CAP_SETGID` (every other capability dropped,
  read-only root filesystem, no privilege escalation): busybox crond switches to the crontab's user for
  every job (initgroups/setgid/setuid; as non-root every job fails with `can't set groups: Operation
  not permitted`) and only reads root-owned crontabs. The jobs run as user `mailcow` (uid 10900,
  files image) without capabilities. Pod Security: allowed by `baseline`, not by `restricted`.
- `TZ=mailcow.tz` (the files image carries tzdata); the pod restarts when a schedule or job changes.
- `cronjobs.scheduler.resources`: crond plus one kubectl process (a few tens of MiB) per running job.
- kubectl comes from the files image (`ARG KUBECTL_VERSION` in its Dockerfile, default = the chart's
  `cronjobs.image.tag`); either way kubectl should stay within one minor version of the cluster
  (kubectl's version skew policy). Rebuild the files image with `--build-arg KUBECTL_VERSION=...` for an
  older or newer cluster.
- Run a job by hand: `kubectl -n mailcow exec deploy/<fullname>-cron -- su mailcow -s /bin/sh -c '/etc/mailcow-cron/run-job dovecot-quarantine'`.

With `mode: cronjob`, disable what you do not use and slow down the rest to cut the pod churn, e.g.:

```yaml
cronjobs:
  jobs:
    phpfpm-keycloak-sync: {enabled: false}       # no Keycloak/LDAP identity provider configured
    phpfpm-ldap-sync: {enabled: false}
    dovecot-imapsync-runner: {schedule: "*/5 * * * *"}   # sync jobs start up to 5 min later
```

### Scaling

| component | scales | how |
|---|---|---|
| nginx | yes | `nginx.replicas` or `nginx.autoscaling`. Stateless; each pod copies the SOGo web assets from the sogo image (initContainer) |
| sogo | yes | `sogo.replicas` or `sogo.autoscaling`. Sessions live in memcached and MySQL, `SOGO_ENCRYPTION_KEY` is stable (Secret), any pod serves any request |
| php-fpm | yes | `phpFpm.replicas` or `phpFpm.autoscaling`. PHP sessions in Redis; every pod is `MASTER=y` |
| postfix | yes | `postfix.replicas` with `postfix.spoolPerPod: true` (queue per pod), no HPA |
| dovecot | no | several instances need shared maildir storage with locking (NFS + director-style routing) or dsync replication, which Dovecot 2.4 removed |
| rspamd | yes | `rspamd.replicas` or `rspamd.autoscaling`. State in Redis, `/var/lib/rspamd` per pod, UI password on `shared` (all replicas read it, a password change restarts them all). Every pod has `hostname: rspamd`, so worker-proxy's `rspamd:9900` is its own address. The controller relay (11335) and postfix's milter reach any replica through the Service. Per pod: the UI's scanned/learned counters (each UI request may land on another replica); Bayes learning, fuzzy hashes, history and ratelimits are shared through Redis |
| mysql, redis, unbound, memcached, clamd, olefy, postfix-tlspol, dockerapi, watchdog, acme | no | single instance as in compose |

For every component with more than one pod (replicas > 1 or an HPA) the chart adds a
PodDisruptionBudget (`maxUnavailable: 1`); singletons get none, so node drains are never blocked.
Replicated pods get a soft `topologySpreadConstraints` over `kubernetes.io/hostname`
(`ScheduleAnyway`) unless a ReadWriteOnce volume pins them to one node anyway:

- php-fpm mounts `shared`: with ReadWriteOnce all php-fpm pods run on its node (podAffinity), with
  ReadWriteMany they spread. The same holds for nginx and postfix with `acme.enabled`.
- sogo mounts `sogo-backup`: with ReadWriteOnce (default) sogo pods carry a required podAffinity to
  each other, so replicas and the extra pod of a rolling update land on the volume's node. Set
  `persistence.sogoBackup.accessMode: ReadWriteMany` to spread them.

HPA (`<component>.autoscaling.enabled`, `minReplicas`, `maxReplicas`,
`targetCPUUtilizationPercentage` of the pod's CPU requests) needs metrics-server; without it the
HPA still keeps `minReplicas`. Keep `replicas` at 1 with an HPA (the chart fails otherwise): the
Deployment is rendered without `spec.replicas`. Switching an existing release to the HPA drops the
field, so the Deployment falls back to 1 pod until the HPA scales it to `minReplicas`.

What the admin UI shows: dockerapi lists every pod, but the UI keys containers by compose service
and picks the first match, so the container overview, restart buttons and the mail queue view each
act on one pod per component.

#### SOGo: rolling updates

`bootstrap-sogo.sh` kills sogod and loops while `nc -z sogo-mailcow 20000` succeeds. The pod sets
`hostname: sogo-mailcow`, which Kubernetes writes into the pod's `/etc/hosts` with the pod's own IP,
and the image resolves `files` before `dns`; the check therefore only sees the pod itself, never
the `sogo-mailcow` Service with older pods behind it. sogo uses `RollingUpdate`. The
`MASTER`-guarded bootstrap step (`DROP TRIGGER IF EXISTS`) is idempotent.

#### php-fpm: start-up and upgrades

The entrypoint runs, before php-fpm starts: `mysql_upgrade` through dockerapi (every pod, unless
`SKIP_MYSQL_UPGRADE`), and with `MASTER=y` Redis defaults (set only when missing), `init_db`
(schema migration), a `DOMAIN_MAP` rebuild, the API keys (`DELETE` + `INSERT`) and
`DROP EVENT` / `CREATE EVENT`. `init_db` also runs on web requests (`prerequisites.inc.php`) and
migrates whenever the stored schema version differs from the one in its own code, with no lock.

- All pods are `MASTER=y`. `MASTER=n` is not a "worker" mode: the UI then shows `[ slave ]`, reads
  mailbox quota from `quota2replica` and skips `init_db`.
- Pods starting together (or an HPA scale-up) repeat those steps; they converge: Redis defaults
  are idempotent, the last `DOMAIN_MAP` rebuild wins with the full map, a duplicate API key or event
  makes the losing session stop while the winner completes, and an `init_db` run that fails on a
  concurrent change is completed by the next request. `mysql_upgrade` is a no-op unless the MariaDB
  version changed; then several pods may each apply it and restart mysql and postfix once.
- Upgrades: two mailcow versions must not run side by side. A pod with the older files image sees
  the newer schema version and migrates the schema back to its own definition on its next request
  (dropping columns the new version added); the new pods migrate forward again. So php-fpm uses
  `Recreate` (`phpFpm.updateStrategy`): all old pods stop before
  new ones start, as with `docker compose up -d`. While php-fpm restarts, the UI, SOGo (nginx
  authenticates SOGo requests through php-fpm) and password logins to dovecot/postfix (mailcowauth)
  fail; dovecot's auth cache covers recently seen users. `RollingUpdate` avoids the gap but is only
  safe for upgrades that keep the files image and the php-fpm image.

#### postfix: one queue per pod

`postfix.replicas > 1` requires `postfix.spoolPerPod: true`: postfix then runs as StatefulSet
`<fullname>-postfix-spool` (pods `<fullname>-postfix-spool-<n>`) with `volumeClaimTemplates`
(`spool-<fullname>-postfix-spool-<n>`, size/class/access mode from `persistence.postfix`) instead of
StatefulSet `<fullname>-postfix` with the single `<fullname>-postfix` PVC. Kubernetes keeps those
claims on scale-down and uninstall. With `spoolPerPod: false` (default) nothing changes for existing
releases. Trade-offs:

- Queued mail lives in the pod that accepted it. Scaling down leaves the removed pods' claims with
  their queue: flush them first (`postqueue -f` in the highest-numbered pods) or scale up again to
  deliver it.
- Admin UI queue view, flush and delete act on one pod (see above). Per pod:
  `kubectl -n <ns> exec <fullname>-postfix-spool-<n> -c postfix-mailcow -- mailq`.
- watchdog no longer mounts a queue: its mail queue check always counts 0.
- postfix rate limits (`bruteForce`, anvil) count per pod: a client spread over N pods gets up to N
  times the limits.

The two modes use different StatefulSet names because a StatefulSet's volumes cannot change in
place. Switching `spoolPerPod` on an existing release is a plain `helm upgrade`: Helm creates the
new StatefulSet and then deletes the old one with its pod, in the same upgrade and without waiting
for the new pods. Services, NetworkPolicies and the PodDisruptionBudget select postfix by label and
follow. New SMTP connections fail from the old pod's shutdown until the new pod 0 is ready (sending
servers retry). Mail still queued in the old pod is not moved: drain it first. Procedure (release
and namespace `mailcow`, chart defaults for the names):

```bash
# 1. drain the queue: repeat until mailq says "Mail queue is empty" (mail to dead destinations may stay)
kubectl -n mailcow exec mailcow-postfix-0 -c postfix-mailcow -- postqueue -f
kubectl -n mailcow exec mailcow-postfix-0 -c postfix-mailcow -- mailq
# optional, keeps what is left: clone the old volume as the new pod 0's claim (CSI volume cloning,
# same storage class); a point-in-time copy, mail accepted after it stays on the old volume only
kubectl -n mailcow apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: spool-mailcow-postfix-spool-0
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 2Gi}}
  dataSource: {kind: PersistentVolumeClaim, name: mailcow-postfix}
EOF
# 2. creates StatefulSet mailcow-postfix-spool, deletes mailcow-postfix and its pod
helm upgrade mailcow helm/mailcow -n mailcow --reuse-values \
  --set postfix.spoolPerPod=true --set postfix.replicas=2
# 3. the old claim is kept (persistence.keep) for manual recovery; delete it once empty or cloned
kubectl -n mailcow delete pvc mailcow-postfix
```

With `persistence.keep: false` Helm deletes the `mailcow-postfix` claim in step 2 (once the old pod
is gone): drain or clone first. Going back (`spoolPerPod: false`, `replicas: 1`) works the same way
round: drain every `mailcow-postfix-spool-<n>` pod, upgrade; Helm creates `mailcow-postfix` (claim
`mailcow-postfix`: a new one, or the kept one with whatever was left on it) and deletes
`mailcow-postfix-spool`. The `spool-mailcow-postfix-spool-<n>` claims stay until you delete them.

## Backup and restore

`backup.enabled: true` (off by default) renders the CronJob form of
`helper-scripts/backup_and_restore.sh`: the same data sets, archive names and archive paths, written
to a `backup` PVC. `scripts/restore.sh` restores them with `kubectl`. Large mailstores are better
served by volume snapshots ([below](#volume-snapshots-and-off-site-copies)); the CronJobs are a
self-contained baseline.

> **Back up `crypt`.** It holds dovecot's mail_crypt key pair. Every stored message is encrypted
> with it: a vmail backup without the matching `crypt` backup cannot be read by anyone. The
> archives therefore contain private keys: restrict access to the backup storage and encrypt it at
> rest. The backup Jobs create every directory with mode 700 and every file with mode 600 (`umask 077`).

### What is backed up

| `backup.components` | file in the backup directory | how | `backup_and_restore.sh` |
|---|---|---|---|
| `mysql` | `backup_mysql.sql.zst` (`.sql.gz` if the client image has no zstd) | `mariadb-dump --single-transaction --routines --triggers --events` of `mailcow.dbName` as `mailcow.dbUser`, through the `mysql` Service | `backup_mariadb.tar.zst`, mariabackup (physical) |
| `redis` | `backup_redis.tar.zst` (`/redis/dump.rdb`) | `redis-cli --rdb` through `redis-mailcow` (replication protocol) | `SAVE`, then the redis volume (same layout) |
| `crypt` | `backup_crypt.tar.zst` (`/crypt`) | tar of the crypt PVC, read-only | same |
| `vmail` | `backup_vmail.tar.zst` (`/vmail`) | tar of the vmail PVC, read-only | same |
| `postfix` | `backup_postfix.tar.zst` (`/postfix`) | tar of the queue PVC; skipped with `postfix.spoolPerPod` | same |
| `sogo` (off) | `backup_sogo.tar.zst` (`/sogo_backup`) | tar of `sogo-backup` (SOGo's own nightly per-user exports) | not included |
| - | `mailcow-helm.info` | release, chart, image tags, DBNAME/DBUSER; no secrets | copies `mailcow.conf` (with passwords) |

Archives are `tar --use-compress-program="zstd --rsyncable -T<backup.threads>" -Pcpf`, exactly the
script's call (absolute member paths), made with the same image (`ghcr.io/mailcow/backup`, Debian:
GNU tar, zstd, pigz; tag pinned by digest in `backup.image`). A compose `backup_and_restore.sh
restore` can read the vmail, crypt, redis and postfix archives, and `restore.sh` reads a
compose backup directory (see [Migrating from compose](#migrating-from-compose)).

No rspamd archive (the script's `backup_rspamd.tar.zst` of `rspamd-vol-1`): the chart keeps no rspamd
volume. rspamd's Bayes, fuzzy hashes, history and ratelimits are in Redis (`redis` group); its
`/var/lib/rspamd` is per pod and disposable (see [Storage](#storage)).

Not backed up, as in the script: `vmail-index` (dovecot rebuilds indexes), `clamd-db` (freshclam
downloads it), `postfix-tlspol` (a cache), and configuration. Compose keeps configuration in the git
checkout; here it is your values file and `extraFiles` (keep them in Git) plus the `shared` PVC
(`rspamd-custom` maps, the rspamd UI password in `rspamd-override` and the `global-sieve` filters edited
in the UI): copy those subPaths if you change them in the UI. The release Secret (`<release>-secrets` or `existingSecret`) is not backed up
either; the backup Jobs have no API access. Export it once and store it encrypted next to the backups:

```bash
kubectl -n mailcow get secret mailcow-secrets -o yaml > mailcow-secrets.yaml   # contains every password
```

A restored database works with a new Secret (the dump carries no users or grants), but API keys,
SOGo's encryption key and the dovecot master credentials then change.

### Layout, schedule, retention

```
<backup PVC>/
  mailcow-2026-10-04-02-00-00/      # UTC, scheduled time of the run (script: mailcow-<local date>)
    backup_mysql.sql.zst  backup_redis.tar.zst  backup_crypt.tar.zst  backup_vmail.tar.zst
    backup_postfix.tar.zst  mailcow-helm.info
```

One CronJob per group: `<fullname>-backup-{mysql,redis,mail,postfix,sogo}` (`mail` = crypt,
then vmail). The volume groups must run on the node of their owner's ReadWriteOnce volume (required
podAffinity to dovecot, postfix or sogo) and those owners may sit on different nodes, so one
pod with several containers cannot carry them all. Every group runs on `backup.schedule` (in
`mailcow.tz`) and picks its directory from the Job name, which the CronJob controller sets to
`<cronjob>-<scheduled time in minutes since the epoch>`: all groups of one run land in one directory,
retries (`backup.backoffLimit`) too. An archive is written as `.<name>.tmp` and renamed when
complete, so a file without the dot is whole. `concurrencyPolicy: Forbid`,
`backup.activeDeadlineSeconds` (6 h) kills a stuck or unschedulable Job so it cannot block the next
nights, `ttlSecondsAfterFinished` keeps finished Jobs and their logs for a day.

Retention runs at the end of the first enabled group (normally `mysql`): directories whose name is
more than `backup.retentionDays` × 24 h old are deleted, then all but the newest `backup.keep` (each
0 = off). The current run's directory is never deleted. Only `mailcow-YYYY-MM-DD-HH-MM-SS`
directories are touched.

A manual run outside the schedule: give all Jobs the same minute suffix so they share a directory
(other names fall back to the current time, one directory per group):

```bash
m=$(( $(date +%s) / 60 ))
for g in mysql redis mail postfix; do
  kubectl -n mailcow create job --from=cronjob/mailcow-backup-$g mailcow-backup-$g-$m
done
kubectl -n mailcow get jobs -l app.kubernetes.io/component=backup
```

### Scheduling and storage

- `backup.persistence.accessMode: ReadWriteOnce` (default): all backup Jobs must mount the volume on
  one node. The mysql, redis and mail Jobs require the dovecot pod's node; the postfix and sogo Jobs
  require their owner's node (their volume is RWO) and only *prefer* dovecot's, because the scheduler
  counts an existing pod for required pod affinity only if it matches every required term, so "next
  to postfix AND next to dovecot" can never be required. On a single node this just works; if
  postfix or sogo run on another node than dovecot, their Jobs land there and fail with a
  multi-attach error on the backup volume: use RWX backup storage (next point). NOTES.txt lists the
  components that are not pinned next to dovecot.
- The backup PVC the chart creates is also mounted read-only at `/backup` in the dovecot pod, which
  never uses it: with `WaitForFirstConsumer` storage classes (kind's local-path, most cloud defaults) a
  claim only binds once a pod uses it, and otherwise only the backup Jobs would, so `helm install --wait`
  would wait for it until the timeout. It binds on dovecot's node, where every backup Job with a
  ReadWriteOnce backup PVC runs anyway. It grants dovecot nothing new: it already holds all mail, the
  mail_crypt keys and `DBPASS`/`REDISPASS`. Not done for `existingClaim` (already bound).
- Multi-node: `backup.persistence.accessMode: ReadWriteMany`, or `backup.persistence.existingClaim`
  on RWX storage (NFS, CephFS, EFS, ...; set `accessMode` to what it is). Each volume group then only
  follows its owner (when the owner's volume is ReadWriteOnce).
- The Jobs run as root with every capability dropped except `DAC_OVERRIDE` (read mailboxes of any
  owner; allowed by the Pod Security `baseline` profile, unlike `DAC_READ_SEARCH`; every source volume
  is mounted read-only), read-only root filesystem, no service account token. They write as root
  (directories 700, files 600): an NFS export needs `no_root_squash`, or replace
  `backup.securityContext` / `backup.podSecurityContext`.
- Node-local storage (local-path, hostPath) pins the backup PVC to the node of its first Job; if
  dovecot moves, the Jobs cannot follow.
- ReadWriteOncePod cannot work (the chart fails): the Jobs mount volumes their owners have mounted.
- Backup pods carry the release labels with component `backup`: the mysql/redis NetworkPolicies and
  the egress policy treat them as release pods.

### Database and Redis: network dumps

mailcow's script runs mariabackup next to the data directory. On Kubernetes that would mean
mounting the mysql ReadWriteOnce volume on its node with a matching server version, and it cannot
work with `externalDatabase`. The chart dumps over the network instead: `--single-transaction` gives
a consistent snapshot of mailcow's InnoDB tables without locking, the dump covers `mailcow.dbName`
only (no `CREATE DATABASE`, no `mysql.*` users), runs as `mailcow.dbUser` (no root needed, managed
databases work) and restores into any release as that user. Caveats: views keep
`DEFINER=<dbUser>`, so restore as the same user (or with SUPER); MariaDB >= 10.11.8 clients write a
`/*M!999999\- enable the sandbox mode */` first line that MySQL clients reject (`tail -n +2`); a big
quarantine table makes the restore slower than a physical copy. `backup.mysql.image` (default: the
chart's `mysql.image`) sets the client for a newer external server.

Redis: `redis-cli --rdb` streams an RDB snapshot over the replication protocol into
`/redis/dump.rdb`, the file the script archives. Many managed Redis services refuse `SYNC`: turn
`components.redis` off there and use the provider's snapshots.

Volume archives are read from the live volumes, as the script does. A maildir is safe to copy file
by file; files dovecot renames or expunges during the run are reported (tar exit 1, logged, archive
kept). The database dump and the vmail archive are not taken at the same instant.

### Restore

`scripts/restore.sh` runs on your workstation with `kubectl`. Requirements: bash >= 4.4 and GNU
coreutils (macOS: `brew install bash coreutils`), and RBAC in the release namespace for:

| resource | verbs | why |
|---|---|---|
| pods | create, get, list, watch, delete | inspect and restore pods (`kubectl apply`, `wait`, `delete`) |
| pods/exec | create | list the backup, extract archives, run `doveadm force-resync` |
| events | list | scheduling events of a restore pod that does not start (`kubectl describe`) |
| persistentvolumeclaims | get | backup and target claims |
| services | get | the `mysql` Service (bundled or external database) |
| secrets | get; patch | read `DBPASS`; patch `DBPASS`/`DBROOT` only for a compose MariaDB (physical) restore |
| cronjobs | get, list, patch | find the backup CronJobs and their retention, suspend them during the restore (flag kept in an annotation) |
| deployments, statefulsets | get, list, patch; `deployments/scale`, `statefulsets/scale` update/patch | scale writers down and back; previous replica counts kept in an annotation |

It prints the kubectl context and server it will use and asks you to type `<namespace>@<context>`
(or `--yes`). Suspend Argo CD / Flux self-heal (auto-sync) for the release while restoring: the
script scales workloads to 0, suspends CronJobs and may patch the Secret, which a GitOps controller
would revert mid-restore.

```bash
# 1. which backups exist, what is in one
helm/mailcow/scripts/restore.sh --namespace mailcow --release mailcow --list
helm/mailcow/scripts/restore.sh --namespace mailcow --release mailcow --list --backup mailcow-2026-10-04-02-00-00

# 2. restore everything found in it, or a selection
helm/mailcow/scripts/restore.sh --namespace mailcow --release mailcow --backup mailcow-2026-10-04-02-00-00
helm/mailcow/scripts/restore.sh --namespace mailcow --release mailcow --backup mailcow-2026-10-04-02-00-00 \
  --components crypt,vmail --resync
```

What it does:

1. Starts `<fullname>-restore-inspect` (backup PVC read-only) to list the backup. Refuses to start
   while a backup run is active, and warns
   if the next backup run would prune the directory being restored (retention).
2. `--components all` takes every component found in the directory that this release can take:
   `redis` is skipped with `externalRedis`, `postfix` with `postfix.spoolPerPod`, and `rspamd` (a
   compose archive) always: the chart has no rspamd volume (with a warning).
3. Suspends the release's backup CronJobs (no run may write into or prune the backup PVC meanwhile),
   then scales watchdog and the writers of the selected components to 0 and waits for their pods to
   go: `vmail`/`crypt` dovecot; `redis` redis; `postfix` postfix; `sogo` sogo;
   `mysql` php-fpm, sogo, dovecot, postfix, acme (+ mysql for a physical restore). The previous
   replica counts and suspend flags are stored in the annotations `mailcow.email/restore-replicas` /
   `mailcow.email/restore-suspend`, so a rerun after an interrupted restore still scales back correctly.
4. Starts `<fullname>-restore`, which mounts the backup PVC read-only and each target PVC at the
   archive's path (`/vmail`, `/crypt`, `/redis`, `/postfix`,
   `/sogo_backup`), plus a `db` container from the mysql client image only for a logical database
   restore. It schedules wherever the volumes allow (their owners are stopped); with node-local
   storage on several nodes it may not fit anywhere, and the script shows the scheduling events.
5. Extracts the archives over the volumes (`tar --numeric-owner -Pxpf`; nothing is deleted first,
   as in the script) and pipes `backup_mysql.sql.*` into `mariadb` through the `mysql` Service (the
   bundled or the external database).
6. Deletes the pod, scales everything back to its previous replica count and resumes the CronJobs,
   also after a failure (the volumes may then be partially restored: rerun the restore). Optionally
   runs `doveadm force-resync -A '*'` (`--resync`, or asked), repeated until the message count is
   stable (up to 3 passes: one pass may re-add only part of the expunged messages).

Not handled by the script: Redis of `externalRedis` (load `dump.rdb` with the provider's tools) and
`postfix.spoolPerPod` queues (extract `backup_postfix.tar.zst` into one spool PVC with a pod like
the restore pod, while that postfix pod is scaled down; or let the old queue go).

Disaster recovery into a new cluster:

1. Recreate the Secret from your export (and `existingSecret: <name>`) or let the chart generate a
   new one; install the chart with the same values and `backup.enabled: true`.
2. Make the backups visible: `backup.persistence.existingClaim` on the restored NFS export, or copy
   a backup directory into the new backup PVC (e.g. `kubectl cp` into a pod that mounts it). Copy it
   under a name the retention ignores, e.g. `restore-2026-10-04` (retention only touches
   `mailcow-YYYY-MM-DD-HH-MM-SS`), or raise `backup.retentionDays` / `backup.keep` first: an old
   `mailcow-...` directory is otherwise pruned by the next backup run.
3. `restore.sh --backup <dir>` (all components), then log in, check a few mailboxes and open an
   older message (proves the crypt keys match).

#### Migrating from compose

`restore.sh` restores a directory written by `backup_and_restore.sh backup all`: vmail, crypt,
redis and postfix archives are identical (its rspamd archive is skipped: rspamd's Bayes and fuzzy data
come back with the redis archive). Copy the compose directory into the backup PVC
under a name the retention ignores (e.g. `restore-2026-10-04`, see above). The MariaDB part is a
physical `backup_mariadb.tar.zst`: with the bundled database the script stops mysql and its clients,
empties the mysql PVC, extracts it (`chown 999:999`) and, if the passwords in the directory's
`mailcow.conf` differ from the release Secret, offers to set `DBPASS`/`DBROOT` in the Secret (the
restored data directory carries the compose users). With `existingSecret` or a Secret managed
elsewhere (external-secrets, sealed-secrets, GitOps) that patch may be reverted: update the source
instead. Set `mailcow.dbName`/`mailcow.dbUser` and `mailcow.maildirSub` to the compose values (`DBNAME`,
`DBUSER`, `MAILDIR_SUB` in its `mailcow.conf`; new compose installs have `MAILDIR_SUB=Maildir`, the
chart's default, older updated ones an empty value) before installing (a mismatch stops the script
before any change), and keep the MariaDB major version (`mysql.image`) the same. It cannot go
into an external database (load a `mariadb-dump` there instead). After the migration set the rspamd
UI password again in the admin UI: compose keeps it in `data/conf/rspamd/override.d`, which is not
part of a compose backup.

### Volume snapshots and off-site copies

For large mailstores, prefer CSI VolumeSnapshots (or Velero with CSI snapshots): seconds instead
of hours, crash-consistent per volume, no tar of millions of files. Snapshot `vmail`, `crypt`,
`mysql` and `redis` together (a VolumeGroupSnapshot or one Velero backup of the namespace); InnoDB
and Redis recover from a crash-consistent copy, maildir tolerates it. Keep the logical database dump
anyway: it is small, portable across versions and storage classes, and readable without the
cluster. The backup PVC lives in the cluster too: copy it off-site (Velero file-system backup,
restic/rclone from a pod that mounts it, or an existingClaim on storage that is replicated).

### Test your restores

A backup you never restored is a hope. Periodically restore the latest directory into a scratch
release (another namespace or the local kind cluster: same values, copy the directory into its
backup PVC, `restore.sh --yes`), then log in, count mailboxes, read an old encrypted message, open a
SOGo calendar. Watch the Jobs: `kubectl get jobs -l app.kubernetes.io/component=backup`, and alert
on failed ones (kube-state-metrics `kube_job_status_failed`) and on a missing directory for last
night.

## Environment contract

Every variable below is opt-in in the images: compose leaves it empty and keeps its old behaviour.
The chart sets them; images at the tags pinned in `docker-compose.yml` support all of them.

| variable | set on | value |
|---|---|---|
| `DBHOST`, `DBPORT` | php-fpm, sogo, dovecot, postfix, acme, watchdog | `mysql`, `3306` or `externalDatabase.port` (TCP instead of the unix socket) |
| `SKIP_MYSQL_UPGRADE` | php-fpm | `y` with `externalDatabase.enabled` (no `mysql_upgrade` / tzinfo import through dockerapi), `n` otherwise |
| `DOVECOTHOST`, `POSTFIXHOST` | sogo | `dovecot`, `postfix` (IMAP/Sieve/SMTP endpoints in sogo.conf) |
| `POSTFIXHOST` | rspamd | `postfix.<ns>.svc.<clusterDomain>` (rspamd's resolver ignores search domains) |
| `SKIP_OLEFY` | rspamd | `skip.olefy` as `y`/`n`: the entrypoint already reads it (drops `external_services.conf`), compose does not pass it to rspamd |
| `DOCKERAPIHOST` | php-fpm, dovecot, acme, watchdog | `dockerapi` (the UI uses that literal name, so the Service is called exactly `dockerapi`) |
| `SOGOHOST`, `PHPFPMHOST`, `RSPAMDHOST` | nginx | `sogo-mailcow`, `php-fpm-mailcow`, `rspamd-mailcow` |
| `NGINXHOST` | acme | `nginx` |
| `WAIT_TCP=y` | nginx, acme, postfix-tlspol | wait for dependencies with TCP connects instead of `ping` |
| `TLSPOL_DNS` | postfix-tlspol | `<unbound.clusterIP>:53` (`[<IPv6>]:53` for an IPv6 ClusterIP) |
| `MAILCOW_NETWORKS` | rspamd, postfix, php-fpm | `mailcow.networks` (in rspamd it replaces **both** compose defaults, the IPv4 and the IPv6 network) |
| `SOGO_TRUSTED_NETS` | dovecot, php-fpm | `mailcow.sogoTrustedNets` (empty = `mailcow.networks`) |
| `DOVECOT_TRUSTED_NETS`, `RSPAMD_TRUSTED_NETS` | rspamd | `mailcow.dovecotTrustedNets` / `rspamdTrustedNets` (empty = `mailcow.networks`); unset, rspamd waits forever for `dig dovecot` |
| `SOGO_SSO_PASS`, `DOVECOT_MASTER_USER/PASS` | dovecot (+ seed initContainers of sogo, php-fpm) | release Secret (stable SOGo SSO, sieve.creds, cron.creds; sogo/php-fpm derive the same files, see [Storage](#storage)). `SOGO_SSO_PASS` `[A-Za-z0-9]` only: dovecot exits otherwise, and the sogo/php-fpm seed initContainers fail with a message |
| `SOGO_ENCRYPTION_KEY` | sogo | release Secret, `[A-Za-z0-9_-]` only (sogo exits otherwise; checked by sogo's seed initContainer) |
| `DOCKERAPI_BACKEND=kubernetes`, `COMPOSE_PROJECT_NAME`, `K8S_POD_SELECTOR` | dockerapi | pods matched by `app.kubernetes.io/name=mailcow,app.kubernetes.io/instance=<release>,app.kubernetes.io/component notin (cron,backup,tls-bootstrap,redis-tls,db-tls)` in the ServiceAccount's namespace |

List values (`MAILCOW_NETWORKS`, `*_TRUSTED_NETS`) are comma-separated without spaces (a space breaks
dovecot's `/source_env.sh` export), IPv6 without brackets (`10.244.0.0/16,fd00:10:244::/56`). The
images drop `/0` entries and anything that is not an address/CIDR with only a warning; the chart
fails the render for them instead (`mailcow.networks`, `sogoTrustedNets`, `dovecotTrustedNets`,
`rspamdTrustedNets`, `mail.proxyTrustedNetworks`) and strips spaces around entries. mailcow's clients
reach the database and Redis without TLS; TLS to an external server goes through the chart's proxies
([TLS to the external database / Redis](#tls-to-the-external-database--redis)).

## Security

### What the trusted networks grant

On Kubernetes these lists contain the pod CIDR, because pod IPs change. Whatever connects from an
address inside them gets compose's "inside the mailcow network" privileges:

| list | trusted for |
|---|---|
| `MAILCOW_NETWORKS` | postfix `mynetworks`: relay to any destination without authentication (`permit_mynetworks`); rspamd `local_addrs`; exempt from the postfix client limits (`bruteForce.limitExceptions`) |
| `DOVECOT_TRUSTED_NETS` | rspamd `SIEVE_HOST`: mail is DKIM-signed for mailcow domains (`sign_networks`) and exempt from `SPOOFED_UNAUTH` |
| `RSPAMD_TRUSTED_NETS` | rspamd `RSPAMD_HOST`: exempt from `SPOOFED_UNAUTH` |
| `SOGO_TRUSTED_NETS` | dovecot plaintext auth without TLS; mailcowauth skips the per-protocol access check (a user with IMAP disabled can still log in) and accepts the SOGo SSO password |

rspamd compares the **SMTP client** address, not the postfix pod's, so all of this hinges on postfix
seeing real client addresses.

### Client addresses: externalTrafficPolicy Local or PROXY protocol is required

With `externalTrafficPolicy: Cluster` kube-proxy SNATs incoming connections, often not to the node's
own address but to one inside the pod CIDR: the address of the node's bridge/gateway or tunnel
interface (kindnet: `10.244.0.1`; flannel: `cni0`/`flannel.1`; Calico/Cilium: their tunnel or host
interface address). An outside client then appears to postfix as a member of `MAILCOW_NETWORKS`:
**open relay**, DKIM-signed spoofing. So:

- `mail.proxyProtocol: false` (default): the chart sets `externalTrafficPolicy: Local` (only nodes
  running the pod answer, the source address stays intact). Do not override it with `Cluster`;
  NOTES.txt warns if you do.
- `mail.proxyProtocol: true`: the load balancer passes the real address in a PROXY header to the
  PROXY listeners. The default stays `externalTrafficPolicy: Local`: wherever the LB targets node
  ports the pod then sees the LB's own address, which is what `proxyTrustedNetworks` must hold (table
  below), instead of a SNAT address you would have to trust. Override with `Cluster` only for LBs that
  cannot health-check nodes, and then trust exactly the per-node SNAT addresses.

#### PROXY protocol: who may send PROXY headers

postfix's PROXY listeners (10025/10465/10587, as in compose) have no trusted-source setting: they
believe the client address in **any** PROXY header. Whoever can open a connection to them can claim
any address, including one in `MAILCOW_NETWORKS` (relay without authentication, DKIM signing,
exempt from rate limits). dovecot has `haproxy_trusted_networks`, but its usual RFC 1918 examples
include the pod CIDR. So with `mail.proxyProtocol: true` the chart requires
`mail.proxyTrustedNetworks` (the render fails without it) and uses it for both:

- dovecot `haproxy_trusted_networks` (nothing else is trusted; without PROXY protocol the setting
  stays unset, so dovecot accepts no PROXY header, as in compose);
- the **only** allowed source (`ipBlock`s) of the PROXY ports in the postfix/dovecot NetworkPolicies,
  which are then rendered even with `networkPolicy.enabled: false` (the other ports stay open to
  anyone in that case). Pods of the release still reach every port.

What to put there: the addresses the PROXY connections arrive from at the pod, and nothing wider.

| load balancer | source the pod sees | `proxyTrustedNetworks` |
|---|---|---|
| targets pod IPs (AWS NLB `ip` targets, ...) | the LB's own private addresses (NLB: its subnet IPs) | the LB subnets / addresses. Consider `mail.service.allocateLoadBalancerNodePorts: false` (no node ports at all) |
| proxy-mode LB on node ports (haproxy/nginx stream/hardware LB in front of the nodes, AWS NLB `instance` targets with client IP preservation off), `externalTrafficPolicy: Local` (**recommended**) | the LB's address (its interface/private IPs, or the VIP pool it connects from) | the LB addresses |
| same, `externalTrafficPolicy: Cluster` | a SNAT address: the receiving node's address or, depending on the CNI, its bridge/tunnel address inside the pod CIDR (kindnet: `10.244.0.1`) | avoid. If you must: exactly those per-node addresses (never the whole pod CIDR), **and** firewall the node ports so that only the LB reaches them, since every client that reaches a node port directly is SNAT'd to the same trusted address |
| LB that keeps the client address (pass-through: MetalLB, kube-vip, NLB `instance` with client IP preservation) and sends PROXY | the real client, so no address identifies the LB | PROXY protocol does not fit: use `mail.proxyProtocol: false` with `externalTrafficPolicy: Local` |

Never the pod CIDR (every pod in the cluster could then forge addresses). Informational: postfix's
`mynetworks` always contains `127.0.0.0/8` and `::1` (postfix.sh, as in compose); an LB on the same
host that hands over a loopback address as the client (in a PROXY header, or as the TCP source with
host networking) makes that client trusted, so such a proxy must pass the real client address. NOTES.txt warns about the
node-port cases (`NodePort`, or `LoadBalancer` with node ports allocated). NetworkPolicy semantics for
SNAT'd and node-originated traffic differ per CNI (many always admit traffic from the local node):
treat the node-port firewall as the real boundary, and use `loadBalancerSourceRanges` where the cloud
supports it. `allocateLoadBalancerNodePorts` is not turned off by default because instance-mode cloud
load balancers need the node ports.

### SOGo

`mailcow.sogoTrustedNets` defaults to `mailcow.networks` (every pod in the cluster), and NOTES.txt
warns about it. If your CNI can assign the sogo pod addresses from a dedicated range (e.g. a Calico
IPPool selected by namespace/pod annotation), set `mailcow.sogoTrustedNets` to that range.

### NetworkPolicy

Requires a CNI that enforces NetworkPolicy (Calico, Cilium, ...); otherwise the
objects are ignored silently.

> **dockerapi without NetworkPolicy enforcement.** dockerapi is an unauthenticated HTTPS API that
> executes commands in, and restarts, every mailcow container. The chart limits it with an always-on
> NetworkPolicy, but on a CNI that does not enforce NetworkPolicy (e.g. plain flannel) **every pod in
> the cluster can reach it**. Use an enforcing CNI, and run mailcow in a dedicated namespace
> ([Namespace](#namespace)).

- Always: dockerapi :443 only from php-fpm, watchdog, acme and dovecot pods.
- Always: rspamd's controller relay :11335 only from php-fpm, dovecot, postfix and watchdog pods, in
  addition to its mutual TLS ([Storage](#storage)). It forwards to the controller's unix socket,
  which rspamd trusts like localhost: no password, full controller access (learn, fuzzy add/delete,
  settings, maps, history). The same policy opens rspamd's other ports (11333, 11334, 9900, 11445)
  to release pods with `networkPolicy.enabled`, and to anyone without it (a policy selecting the pod
  would block them otherwise). No other rule mentions 11335. Without an enforcing CNI, or from the
  node itself (kubelet, hostNetwork pods, which most CNIs never filter), 11335 is reachable, but
  only with a client certificate from the relay CA.
- With `mail.proxyProtocol: true`, always: the postfix/dovecot PROXY ports only from
  `mail.proxyTrustedNetworks` (above).
- `networkPolicy.enabled` (default `true`): every port of mysql, redis (unless external), memcached,
  clamd, olefy, php-fpm, sogo, postfix-tlspol, unbound, postfix and dovecot (rspamd: every port but
  11335) only from pods of this release; the PROXY listeners from `mail.proxyTrustedNetworks`, or
  without PROXY protocol the plain client ports from `networkPolicy.publicMailFrom`; nginx
  http/https from anywhere. Without it, any pod in the cluster can relay through postfix, since it
  connects from the pod CIDR.
- `networkPolicy.publicMailFrom` (plain client ports only, `mail.proxyProtocol: false`) empty
  (default): the client ports allow `0.0.0.0/0` except every
  IPv4 entry of `mailcow.networks`, and `::/0` except every IPv6 entry (bare addresses become /32 or
  /128). Pods of this release still reach every port through the pod selector. Every other source
  inside the pod CIDR is one mailcow trusts (relay without auth), so it must not reach the client
  ports:
  - Calico applies `ipBlock` to pod addresses, so `except` blocks other pods;
  - Cilium never matches pods with CIDR rules, so other pods are blocked either way;
  - ingress traffic SNAT'd into the pod CIDR (e.g. flannel's `cni0`/`flannel.1` address with
    `externalTrafficPolicy: Cluster`) is blocked too. That traffic would otherwise be an open relay,
    so blocking is the safe outcome.

  Set `publicMailFrom` to your load balancer / node ranges where you can, to narrow it further.
- The policies above are ingress only. Kubelet probes come from the node, which NetworkPolicy does
  not block. Egress is unrestricted unless `networkPolicy.egress.enabled` (below).

#### Egress (optional)

`networkPolicy.egress.enabled` (default `false`) adds egress policies. Off by default because a mail
server legitimately talks to the whole internet (outbound SMTP to any MX, DNS recursion, blocklists),
so the policy can only fence off the cluster, and the addresses it needs differ per cluster. When on,
every pod of the release may reach:

| rule | why |
|---|---|
| pods of this release, all ports | mailcow components talk to each other |
| cluster DNS pods: namespace `networkPolicy.egress.dns.namespace` (`kube-system`), labels `dns.podLabels` (`k8s-app: kube-dns`), port `dns.port` (53) UDP+TCP | unbound's `clusterDomain` forward-zone; pods without unbound DNS |
| `0.0.0.0/0` and `::/0` except `networkPolicy.egress.clusterCIDRs` (empty = the `mailcow.networks` entries + `networkPolicy.egress.serviceCIDR`, default `10.96.0.0/12`) | the internet: postfix outbound 25, unbound recursion / `unbound.forwarders`, clamd freshclam, rspamd fuzzy and DNS lists, `sa-rules` download, Keycloak/LDAP sync, imapsync, SOGo remote calendars, acme |
| `networkPolicy.egress.extraTo` (raw peers, all ports) | in-cluster targets you need |

plus, for dockerapi, the cron scheduler or CronJob runner and the TLS bootstrap hook Job only, the Kubernetes API server:
`networkPolicy.egress.apiServerCIDRs` on `apiServerPorts` (443, 6443). `apiServerCIDRs` is required
when egress is on (the chart fails without it): use the **endpoint** addresses from
`kubectl get endpoints kubernetes -n default` (e.g. `172.18.0.2` on kind), not the `kubernetes`
Service ClusterIP (NetworkPolicy sees the address after the Service translation).

Everything else in the cluster is blocked: other workloads' pods (pod CIDR) and ClusterIPs. Rules
are additive, so `apiServerCIDRs` and `extraTo` get through even inside `clusterCIDRs`. Notes:

- External database / Redis: a host outside `clusterCIDRs` is covered by the internet rule. One inside
  (an operator-managed database, a Redis in another namespace) must be added to `extraTo`, e.g.
  `[{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: db}}, podSelector: {matchLabels: {app.kubernetes.io/name: mariadb}}}]`.
  An ExternalName pointing at an in-cluster Service name resolves to a ClusterIP in the service CIDR
  and then to that Service's pods: blocked unless they are in `extraTo`.
- Node and VPC/LAN addresses are not in the default `clusterCIDRs`, so they stay reachable (kind's
  API server on the node address is reachable through the internet rule anyway). Add those ranges
  to `clusterCIDRs` to block them too; then list the API server in `apiServerCIDRs` and anything
  else you need (e.g. a database VM) in `extraTo`.
- Cilium does not match the API server or cluster nodes with CIDR rules by default; allow the API
  server with a CiliumNetworkPolicy (`toEntities: [kube-apiserver]`) or Cilium's
  `policy-cidr-match-mode: nodes`. NodeLocal DNSCache (`169.254.20.10`) is outside the cluster CIDRs
  and therefore reachable.
- Skipped components (`skip.*`) keep their Services, which then have no endpoints. kube-proxy
  rejects a connection to such a ClusterIP at once, but the destination stays in the service CIDR, so
  the egress policy drops it first and the client waits for its timeout. The chart therefore stops
  every client of a skipped component: with `skip.clamd` rspamd gets
  `conf/rspamd/override.d/antivirus.conf` with `enabled = false;` (no `CLAM_VIRUS` /
  `VIRUS_FOUND`; otherwise ~15 s per message), with `skip.olefy` it gets `SKIP_OLEFY=y` (no
  `external_services.conf`), and nginx drops the SOGo locations with `skip.sogo`. Custom
  configuration (extraFiles) that points at a skipped component hits the same timeout.

### Namespace

Install mailcow into a namespace of its own. RBAC cannot be scoped to labels: dockerapi's Role allows
exec into and deletion of **every** pod in the namespace and a rolling restart (restartedAt
annotation patch) of **every** Deployment and StatefulSet in it (without the apps rules it would fall
back to deleting single pods), and the cron scheduler or CronJob runner can exec into every pod too.

## Brute-force protection (no fail2ban)

compose's netfilter container (fail2ban-style bans written to the host's iptables/nftables) is not
part of the chart:

- it needs a privileged (or NET_ADMIN/NET_RAW) hostNetwork pod on every node that rewrites the
  node's firewall, next to the rules kube-proxy and the CNI own;
- eBPF dataplanes (Cilium, Calico eBPF) and IPVS forward Service traffic before or outside the
  iptables chains it inserts into, so a ban may be bypassed;
- behind PROXY protocol the TCP source on the node is the load balancer: banning the address mailcow
  logs does nothing, banning the TCP source blocks all mail;
- the load balancer, cloud firewall or ingress in front of the cluster can drop traffic before it
  reaches any node.

### What the chart does

`bruteForce` (default on) appends postfix anvil limits to `main.cf` (after `extra.cf`, so it wins over
an `extraFiles` `extra.cf`; set `bruteForce.enabled: false` to manage them there yourself):

| value | postfix parameter | default | meaning |
|---|---|---|---|
| `rateTimeUnit` | `anvil_rate_time_unit` | `60s` | window of the rate limits |
| `authRateLimit` | `smtpd_client_auth_rate_limit` | `10` | AUTH commands per client and window |
| `connectionRateLimit` | `smtpd_client_connection_rate_limit` | `60` | connection attempts per client and window |
| `connectionCountLimit` | `smtpd_client_connection_count_limit` | `20` | simultaneous connections per client |
| `limitExceptions` | `smtpd_client_event_limit_exceptions` | `$mynetworks` | clients exempt from all limits (`MAILCOW_NETWORKS`: sogo, watchdog, quarantine/BCC and other internal traffic) |

`0` disables a limit. Postfix's own defaults are 50 simultaneous connections and no rate limits.

- The limits apply to every smtpd service in `master.cf` (none overrides them with `-o`): the smtpd
  behind postscreen on 25 and 10025 (only connections that pass postscreen), smtps 465, submission
  587, and the PROXY listeners 10465/10587. 25/10025 offer no AUTH, so `authRateLimit` matters on
  465/587/10465/10587. The internal listeners 588-591 are only used from `$mynetworks` and therefore
  exempt.
- anvil counts per master.cf service and client address (IPv6 aggregated per /84,
  `smtpd_client_ipv6_prefix_length`). A client over a limit gets a temporary (4xx) error; it is not
  banned and gets through again once the window has passed.
- With PROXY protocol the client address is the one from the PROXY header (smtpd's
  `smtpd_upstream_proxy_protocol`, or postscreen passing it on), so the limits hit the real client,
  not the load balancer (which is why only `mail.proxyTrustedNetworks` may send such headers). Without PROXY protocol they rely on `externalTrafficPolicy: Local`; with
  SNAT every client would share the node's address and its limits.
- Many users behind one NAT share a client address. Raise `authRateLimit` / `connectionCountLimit`
  if such sites log in to SMTP at the same time.

Unchanged and already active:

- dovecot's auth penalty: after failed logins from an IP, dovecot delays further authentications
  from it (doubling, up to 15 s). Behind the PROXY listeners the IP is the one from the PROXY header.
- SOGo blocks a login name for 15 min after 10 failed logins within 15 min (`sogo.conf`).
- The mailcow UI delays repeated failed logins per session.

The admin UI's **Fail2ban** settings have no effect on Kubernetes: its settings
are stored but nothing enforces them, and the list of active bans stays empty. Failed UI, API and
autodiscover logins are still published to redis, but nothing consumes them.

### At the edge

IP-level banning belongs in front of the cluster, where the real client address and the ability to
drop traffic meet. Options:

- CrowdSec: its Kubernetes log acquisition reads the postfix/dovecot/nginx pod logs, and a bouncer
  enforces decisions at the ingress controller, load balancer or cloud firewall.
- A WAF or CDN in front of the HTTP Service/Ingress (e.g. Cloudflare) for the web UI, SOGo and
  autodiscover/ActiveSync; mail ports cannot be proxied this way.
- Cloud firewall or security group rules on the load balancer for static allow/deny lists (e.g.
  limit submission/IMAP to known ranges where that is possible).

## Limitations (chart 0.1.0)

- dovecot runs a single replica; postfix replicas each have their own queue (UI queue view
  shows one pod), rspamd replicas each show their own UI counters, php-fpm restarts with `Recreate` (short UI/login gap on upgrades), see
  [Scaling](#scaling).
- `shared` needs RWX for php-fpm, dovecot and rspamd to spread over nodes; with RWO they share one
  node ([Storage](#storage)). rspamd.sock no longer ties pods to a node (TCP relay).
- Kubernetes >= 1.29 (native sidecars for the rspamd socket relays).
- No fail2ban (netfilter); see [Brute-force protection](#brute-force-protection-no-fail2ban).
- `redis` `net.core.somaxconn` is an unsafe sysctl (`redis.sysctls`, off by default); compose
  ulimits for dovecot have no pod equivalent (runtime defaults are higher).
- Backups are opt-in (`backup.enabled`); with a ReadWriteOnce backup PVC the volume owners must
  share dovecot's node, and `postfix.spoolPerPod` queues are not backed up ([Backup and restore](#backup-and-restore)).
- Egress NetworkPolicies are optional and off by default (`networkPolicy.egress`): they fence off the
  cluster, not the internet.
- External database / Redis: supported (`externalDatabase`, `externalRedis`), but the database must
  be prepared by hand (user, grants, `event_scheduler`, time zone tables); without TLS, Redis must
  listen on 6379 when given by DNS name ([External database / Redis](#external-database--redis)).
- The rspamd socket relay listens dual-stack when the pod has IPv6, IPv4-only otherwise; IPv6-only
  and dual-stack clusters work. Other IPv6 caveats (nginx `mailcow.enableIpv6`, watchdog's IPv4-only
  checks) are unchanged.
- The files image comes from the repository's workflow (`ghcr.io/<owner>/mailcow-files`) or your own
  build; point `files.image.repository` at it ([Files image](#files-image)).
- `lookup`-based generation (release Secret, rspamd relay TLS, `clusterDNS`, skipping the TLS
  bootstrap Job) needs a real `helm install/upgrade`; GitOps renderers must use the `existingSecret`
  values and an explicit `clusterDNS`.
- TLS to an external database or Redis only through the chart's proxies; ProxySQL verifies the
  database certificate's chain, not its host name ([TLS to the external database / Redis](#tls-to-the-external-database--redis)).
- The ofelia jobs run from a single scheduler pod (jobs are missed while it is down, like ofelia), or
  as CronJobs with ~9,300 short-lived pods a day ([CronJobs](#cronjobs-ofelia)).

## Development

- `helm/mailcow/scripts/check-tags.sh [--fix]`: chart image tags must equal `docker-compose.yml`;
  `backup.image` must equal `DEBIAN_DOCKER_IMAGE` of `helper-scripts/backup_and_restore.sh`, and the
  fallback image of `scripts/restore.sh` (`DEFAULT_IMAGE`, incl. digest) must equal `backup.image`.
  `--fix` rewrites repository and tag of the compose-mapped components; the backup image and digest
  are fixed by hand. It skips the compose services the chart does not ship (ofelia, netfilter).
- `ci/*-values.yaml` (each rendered and schema-checked by the chart workflow):
  - `kind`: local kind cluster (NodePorts 30080/30443/30025/30465/30587/30143/30993/32190, RWO shared,
    self-signed TLS, clamd skipped, no PROXY protocol, NetworkPolicy on with the default `publicMailFrom`);
  - `certmanager`: cert-manager + Ingress, ofelia jobs off (no scheduler, CronJobs or runner RBAC);
  - `cronjob`: the ofelia jobs as CronJobs (`cronjobs.mode: cronjob`) with per-job overrides, SOGo
    skipped, pod annotations;
  - `ha`: RWX shared, rspamd HPA, NLB with PROXY protocol (ip targets, `proxyTrustedNetworks` = VPC,
    `allocateLoadBalancerNodePorts: false`), watchdog, NetworkPolicy;
  - `acme`: acme + extraFiles + watchdog, postfix limits off, NetworkPolicy off with PROXY protocol
    (the PROXY-port policies are still rendered), `http.service.loadBalancerSourceRanges`;
  - `proxy-nodeport`: PROXY protocol on a NodePort Service behind an external LB (bare-address
    `proxyTrustedNetworks`), HTTP as ClusterIP, `extraSecretFiles`, an existing rspamd relay TLS
    Secret, `podDefaults.annotations`, `clusterDNS` lookup, backups;
  - `netpol`: NetworkPolicy without PROXY protocol, custom `publicMailFrom`, dual-stack networks;
  - `external-dns` / `external-ip`: external MySQL/Redis by DNS name (ExternalName, DBPORT 3307) and
    by IPv4/IPv6 address (EndpointSlices, Redis 6379 -> 6380);
  - `external-tls` / `external-tls-insecure`: the TLS proxies, verified with CA Secrets, client
    certificates, server name, 2 ProxySQL replicas and egress policies (DNS database, IPv6 Redis), and
    without certificate checks by IPv4 address with 2 relay replicas and NetworkPolicy off;
  - `egress`: egress policies on a dual-stack cluster with an in-cluster external database in `extraTo`;
  - `scale`: nginx HPA, sogo/php-fpm/rspamd 2 replicas, postfix 2 with a queue per pod, watchdog without the
    queue mount, 60 s TLS reload checks (layer it on `kind-values.yaml`);
  - `backup`: the defaults (ReadWriteOnce backup PVC, every group incl. sogo, retention by age and
    count; layer it on `kind-values.yaml`) and `backup-rwx`, a multi-node variant (RWX existingClaim
    and mail volumes, external database and Redis, newer client image, postfix queue per pod = not
    backed up).
- `ci/e2e/`: `kind-config.yaml` (the kind cluster: host ports to the NodePorts), `smoke.sh` (checks
  against a running release: pods Ready, UI/API, SMTP/IMAP through the NodePorts, NetworkPolicy relay
  protection with a foreign pod, ...), `collect-logs.sh` (diagnostics on failure), `lib.sh` (shared
  helpers).
- Workflows: `.github/workflows/helm_chart.yml` (lint, render of every `ci/*-values.yaml`,
  kubeconform against Kubernetes 1.29 and 1.33, `check-tags.sh`) and `.github/workflows/helm_e2e.yml`
  (builds the images, installs the chart on kind with `kind-values.yaml`, plus the scale leg and a
  "kind + backup" leg that runs a backup -> restore round trip, then `smoke.sh`).
- `scripts/restore.sh`: restore a backup directory ([Backup and restore](#restore)); `KUBECTL` selects the binary.
