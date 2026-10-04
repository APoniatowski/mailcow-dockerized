# mailcow Helm chart

Runs [mailcow-dockerized](https://github.com/mailcow/mailcow-dockerized) on Kubernetes with the
same images as `docker-compose.yml`. Status: **0.1, experimental**. It relies on opt-in environment
variables of the mailcow images (see [Environment contract](#environment-contract)); read
[Security](#security) before exposing it.

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

Requires Kubernetes >= 1.29 (native sidecar containers, beta and on by default since 1.29, GA in
1.33; `kubeVersion` in `Chart.yaml`). Before installing, check these cluster-specific values:

| value | what | how to find it |
|---|---|---|
| `unbound.clusterIP` | fixed ClusterIP of the `unbound` Service, nameserver of most mailcow pods | an unused IP inside the **service CIDR** (`kubectl cluster-info dump \| grep service-cluster-ip-range`); default `10.96.53.53` fits kind/kubeadm `10.96.0.0/12` |
| `clusterDNS` | kube-dns/CoreDNS ClusterIP, unbound forwards `clusterDomain` to it | `kubectl -n kube-system get svc kube-dns` |
| `unbound.forwarders` | optional upstream resolvers (`[1.1.1.1, 9.9.9.9]`, `IP@port` allowed) for everything outside `clusterDomain`; empty = full recursion from the root servers like compose | set it when outbound port 53 is filtered or intercepted (recursion from the root then fails: every external lookup SERVFAILs); the forwarders must pass DNSSEC records through, validation stays on |
| `mailcow.networks` | `MAILCOW_NETWORKS`: CIDRs trusted as internal (postfix `mynetworks`, rspamd, dovecot) | the **pod CIDR** only. Never node or LB ranges: SNAT'd outside clients would become trusted relays |
| `mailcow.sogoTrustedNets` | `SOGO_TRUSTED_NETS`: where SOGo's dovecot logins come from | defaults to `mailcow.networks` with a warning, see [Security](#security) |

Login: `admin` / `moohoo`. API key: `kubectl -n mailcow get secret mailcow-secrets -o jsonpath='{.data.API_KEY}' | base64 -d`
(effective once `mailcow.apiAllowFrom` is set).

## Architecture

| compose service | Kubernetes |
|---|---|
| unbound | Deployment + Service `unbound` with fixed ClusterIP; repo `unbound.conf` + appended `forward-zone` for `clusterDomain` → `clusterDNS` (`domain-insecure`, DNSSEC stays on for the rest), plus `forward-zone "."` → `unbound.forwarders` when set |
| mysql, redis | StatefulSet (1 replica, PVC), or an external server (`externalDatabase` / `externalRedis`, [External database / Redis](#external-database--redis)). Clients use TCP (`DBHOST=mysql`) |
| dovecot | StatefulSet (1 replica) |
| postfix | StatefulSet `<fullname>-postfix`, `postfix.replicas` (default 1; > 1 with a queue PVC per pod in StatefulSet `<fullname>-postfix-spool`, [Scaling](#scaling)) |
| rspamd | Deployment (1 replica), `hostname: rspamd` (worker-proxy binds `rspamd:9900`), own PVC; controller socket relayed over TCP 11335 ([Storage](#storage)) |
| php-fpm, sogo, nginx | Deployment, `replicas` or an HPA ([Scaling](#scaling)) |
| clamd, olefy, memcached, postfix-tlspol | Deployment |
| dockerapi | Deployment + ServiceAccount/Role (pods get/list/delete, pods/exec, metrics.k8s.io pods get), `DOCKERAPI_BACKEND=kubernetes`; Services `dockerapi`/`dockerapi-mailcow`, NetworkPolicy always on |
| acme | optional (`acme.enabled`), default off → cert-manager / Secret / self-signed |
| watchdog | optional (`watchdog.enabled`); probes do the self-healing |
| netfilter | not shipped: fail2ban is not supported on Kubernetes, see [Brute-force protection](#brute-force-protection-no-fail2ban) |
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

They are copied over the base slice on every pod start (also into the shared dir
`conf/rspamd/custom`, where they overwrite UI edits).

### Storage

| PVC | mounted by |
|---|---|
| `vmail`, `vmail-index`, `crypt` | dovecot (**back up `crypt`**, without it mail is unreadable; [Backup and restore](#backup-and-restore)) |
| `mysql`, `redis`, `postfix-tlspol`, `sogo-backup`, `clamd-db` | their component (`mysql`/`redis` not created with `externalDatabase`/`externalRedis`) |
| `rspamd` | rspamd: `data/` = `/var/lib/rspamd` (controller socket, non-critical state; bayes and fuzzy hashes live in Redis), `override/worker-controller-password.inc` (UI password) |
| `postfix` | postfix (+ watchdog, same node). With `postfix.spoolPerPod`: one claim `spool-<fullname>-postfix-spool-<n>` per pod instead, not mounted by watchdog ([Scaling](#scaling)) |
| `shared` (subPaths) | see below |

Only directories that one pod writes and another reads at runtime remain on `shared`:

| subPath | written by | read by |
|---|---|---|
| `rspamd-custom` (`data/conf/rspamd/custom`) | php-fpm (UI maps), dovecot (`sa-rules` CronJob) | rspamd |
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
(`persistence.keep`).

Not shared (compose shares them through bind mounts or named volumes):

- SOGo credentials: dovecot's entrypoint writes `sieve.creds`, `cron.creds` (`/etc/sogo`) and
  `sogo-sso.pass` (`/etc/phpfpm`) on every start. In the chart these two directories are pod-local
  `emptyDir`s in dovecot (`imapsync_runner.pl` reads its local `sieve.creds`), and the seed
  initContainers of sogo (`/etc/sogo/{sieve,cron}.creds`, next to the repo's `data/conf/sogo`) and
  php-fpm (`/etc/sogo-sso/sogo-sso.pass`) write byte-identical files from the same Secret keys
  (`DOVECOT_MASTER_USER`, `DOVECOT_MASTER_PASS`, `SOGO_SSO_PASS`, same `echo`/`echo -n` as the
  entrypoint). With `existingSecret` nothing new is needed: those keys were already required. The
  SOGo CronJobs read the files in the sogo pod.
- rspamd's controller socket (`/var/lib/rspamd/rspamd.sock`, trusted without password by
  `worker-controller.inc`): the rspamd pod runs a native sidecar `rspamd-sock-relay` (socat, files
  image) that forwards TCP 11335 to the socket. php-fpm, dovecot, postfix and watchdog get an
  `emptyDir` at `/var/lib/rspamd` and a native sidecar `rspamd-sock` that listens on
  `/var/lib/rspamd/rspamd.sock` (mode 0666, like rspamd's own) and connects to
  `rspamd-mailcow.<ns>.svc.<clusterDomain>:11335` per connection. Clients and rspamd config are
  unchanged; rspamd still sees unix-socket clients. `rspamd.socketRelay.resources` sizes the sidecars.
  The relay listens dual-stack (`TCP6-LISTEN`, `ipv6only=0`) when the pod has IPv6 (non-empty
  `/proc/net/if_inet6`) and IPv4-only otherwise, decided at container start, so it works on IPv4,
  IPv6 and dual-stack clusters. The client relays connect by name; socat (1.8) tries every A/AAAA
  address of the Service in turn.

#### Upgrading from chart < 0.5.0

- rspamd's state (`shared/rspamd-vol`) and UI password (`shared/rspamd-override`) move to the new
  `rspamd` PVC: rspamd's seed initContainer copies both once (marker `.migrated-from-shared` on the
  new PVC), so the rspamd UI password keeps working. Only if the old data is not on the `shared` PVC
  at that point (e.g. a new `shared` claim), set the rspamd UI password again in the admin UI.
- The `shared` subdirs `rspamd-vol`, `rspamd-override`, `sogo-conf` and `sogo-sso` are unused
  afterwards and can be deleted. `sogo-conf` held UI-independent copies of `data/conf/sogo`; use
  `extraFiles` (`conf/sogo/...`) for SOGo customisation, as before.
- postfix, sogo and nginx (without acme) lose the shared-volume podAffinity and may be rescheduled
  to other nodes.

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
  and IP hosts) changes the Service type; if Helm reports an immutable field, delete the four
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
  password). No TLS: mailcow's Redis clients (PHP, Python, Lua, `redis-cli`) speak plain TCP.
- mailcow components hard-code port 6379. With a DNS `host` the port must therefore be 6379 (the chart
  fails otherwise, ExternalName cannot remap ports); with an IP `host` the Services listen on 6379 and
  the EndpointSlice maps it to `externalRedis.port`.
- rspamd sends `SLAVEOF NO ONE` on every start (compose behaviour): point `host` at a primary, never
  at a replica. Managed services that reject the command just log an error.
- Give mailcow a Redis of its own: its keys are unprefixed, in the default database. mailcow keeps
  settings, rspamd's Bayes/fuzzy data and logs there, so the server needs persistence (RDB/AOF) and
  backups.
- watchdog (off by default) checks Redis with `check_tcp -4`: with an IPv6 Redis its Redis check
  fails. Its restart action for mysql/redis finds no pod with either external server.

### TLS

`/etc/ssl/mail` in postfix, dovecot, nginx (and watchdog), first match wins:

1. `acme.enabled`: mailcow ACME client writes to the shared `ssl` dir (snake-oil seeded first).
2. `tls.certManager.enabled`: Certificate (`issuerRef`) → Secret `<fullname>-tls`.
3. `tls.existingSecret`.
4. otherwise a pre-install hook Job creates a self-signed snake-oil Secret once (like `generate_config.sh`).

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

The sidecar runs the files image's busybox shell as uid 0 (the masters run as root, and a process
may signal another of the same uid without any capability) with every capability dropped,
`allowPrivilegeEscalation: false` and a read-only root filesystem; it mounts only the TLS Secret.
`shareProcessNamespace: true` is set on those three pods only when the sidecar is rendered. It
makes the containers of the pod see each other's processes: the main container, the `rspamd-sock`
relay (uid 65534) and `tls-reload`. Reading another process's environment, memory or root
filesystem still needs ptrace rights (same uid and no extra capabilities on the target, or
`CAP_SYS_PTRACE`, which no container has), so the relay and the sidecar cannot look into the
daemons; the main container (root) can signal the sidecars, which it could disrupt anyway. The
`seed` initContainer has exited before the main container starts. Side effect: the pause container
is PID 1 and reaps orphans (postfix's daemonised master is re-parented to it instead of supervisord;
nothing in the images depends on that).

cert-manager renews at 2/3 of the certificate lifetime by default (30 days before expiry for
90-day Let's Encrypt certificates; `tls.certManager.renewBefore` overrides it). With `acme.enabled`
no sidecar is rendered: the acme container reloads/restarts the daemons through dockerapi itself.

Upgrading from chart < 0.7.0: the `cert-reload` CronJob is gone (Helm deletes it) and
`tls.reload.schedule` is ignored.

### Client IPs and exposure

- Mail: one Service `<fullname>-mail` selects postfix **and** dovecot pods through named target
  ports (one IP for MX and IMAP). `mail.proxyProtocol: true` (default) maps 25/465/587/143/993/110/995/4190
  to the PROXY listeners 10025/10465/10587/10143/10993/10110/10995/14190; the load balancer must send
  PROXY headers, and `mail.proxyTrustedNetworks` becomes dovecot's `haproxy_trusted_networks`.
  `false`: plain ports with `externalTrafficPolicy: Local`. Either way the client address must reach
  postfix unchanged, see [Security](#security).
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
the target container. Override with `cronjobs.jobs.<name>.{enabled,schedule}`. With replicas,
`kubectl exec deployment/<name>` picks one pod, so each job still runs once per schedule (the
`MASTER`-guarded SOGo jobs must run once, not per replica). `cronjobs.enabled: false` removes the
runner's ServiceAccount and Role too.

### Scaling

| component | scales | how |
|---|---|---|
| nginx | yes | `nginx.replicas` or `nginx.autoscaling`. Stateless; each pod copies the SOGo web assets from the sogo image (initContainer) |
| sogo | yes | `sogo.replicas` or `sogo.autoscaling`. Sessions live in memcached and MySQL, `SOGO_ENCRYPTION_KEY` is stable (Secret), any pod serves any request |
| php-fpm | yes | `phpFpm.replicas` or `phpFpm.autoscaling`. PHP sessions in Redis; every pod is `MASTER=y` |
| postfix | yes | `postfix.replicas` with `postfix.spoolPerPod: true` (queue per pod), no HPA |
| dovecot | no | several instances need shared maildir storage with locking (NFS + director-style routing) or dsync replication, which Dovecot 2.4 removed |
| rspamd | no | `/var/lib/rspamd` (controller socket, state) and the UI password file are on its own RWO PVC; worker-proxy binds the pod hostname `rspamd` |
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
the `sogo-mailcow` Service with older pods behind it. sogo uses `RollingUpdate` (chart < 0.7.0:
`Recreate`). The `MASTER`-guarded bootstrap step (`DROP TRIGGER IF EXISTS`) is idempotent.

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
  `Recreate` (`phpFpm.updateStrategy`, chart < 0.7.0: `RollingUpdate`): all old pods stop before
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

### Upgrading from chart < 0.7.0

0.7.0 switched php-fpm to `Recreate` (`phpFpm.updateStrategy`; chart < 0.7.0 rendered no strategy
for it). Helm 4 applies server-side and only removes fields it owns. A Deployment
created without a strategy holds the API server's defaulted `rollingUpdate` (owned by no field
manager), so the upgrade fails with `spec.strategy.rollingUpdate: Forbidden: may not be specified
when strategy type is 'Recreate'`.

Since 0.7.1 the `strategy-fix` pre-upgrade hook handles it. It looks up the live Deployments and,
for each one whose strategy differs from the rendered one (type, or a leftover `rollingUpdate` next
to `Recreate`), runs a Job (own ServiceAccount and Role limited to `get`/`patch` on exactly those
Deployments, `cronjobs.image`, field manager `mailcow-strategy-fix`) with one container per
Deployment sending a strategic merge patch with `$retainKeys`. The patch is idempotent and leaves
the pod template alone, so nothing rolls out. Nothing is rendered on install, on releases that are
already consistent, or for Deployments that do not exist yet. With `networkPolicy.egress.enabled`
the hook brings its own NetworkPolicy to the API server (the live policies are still the previous
release's). Every `RollingUpdate` Deployment now renders `rollingUpdate` (`maxSurge` and
`maxUnavailable` 25%, the API server defaults), so Helm owns it and a later switch to `Recreate`
drops it.

The hook needs `lookup`, i.e. a real `helm upgrade` (`helm template` and tools that render with it,
such as Argo CD, never run it). Without it, or with `--no-hooks`, patch php-fpm once by hand and
upgrade again; it is the only Deployment that changed to `Recreate` (repeat for any other Deployment
the error names):

```bash
kubectl -n mailcow patch deployment mailcow-php-fpm --type=strategic \
  -p '{"spec":{"strategy":{"$retainKeys":["type"],"type":"Recreate"}}}'
```

Also new in 0.7.0: the `cert-reload` CronJob is gone ([TLS](#tls)).

## Backup and restore

`backup.enabled: true` (off by default) renders the CronJob form of
`helper-scripts/backup_and_restore.sh`: the same data sets, archive names and archive paths, written
to a `backup` PVC. `scripts/restore.sh` restores them with `kubectl`. Large mailstores are better
served by volume snapshots ([below](#volume-snapshots-and-off-site-copies)); the CronJobs are a
self-contained baseline.

> **Back up `crypt`.** It holds dovecot's mail_crypt key pair. Every stored message is encrypted
> with it: a vmail backup without the matching `crypt` backup cannot be read by anyone. The
> archives therefore contain private keys: restrict access to the backup storage and encrypt it at
> rest.

### What is backed up

| `backup.components` | file in the backup directory | how | `backup_and_restore.sh` |
|---|---|---|---|
| `mysql` | `backup_mysql.sql.zst` (`.sql.gz` if the client image has no zstd) | `mariadb-dump --single-transaction --routines --triggers --events` of `mailcow.dbName` as `mailcow.dbUser`, through the `mysql` Service | `backup_mariadb.tar.zst`, mariabackup (physical) |
| `redis` | `backup_redis.tar.zst` (`/redis/dump.rdb`) | `redis-cli --rdb` through `redis-mailcow` (replication protocol) | `SAVE`, then the redis volume (same layout) |
| `crypt` | `backup_crypt.tar.zst` (`/crypt`) | tar of the crypt PVC, read-only | same |
| `vmail` | `backup_vmail.tar.zst` (`/vmail`) | tar of the vmail PVC, read-only | same |
| `rspamd` | `backup_rspamd.tar.zst` (`/rspamd`, `/rspamd_override`), `.<arch>` marker | tar of the rspamd PVC (`/var/lib/rspamd` + the UI password) | same (compose keeps the UI password in `data/conf`) |
| `postfix` | `backup_postfix.tar.zst` (`/postfix`) | tar of the queue PVC; skipped with `postfix.spoolPerPod` | same |
| `sogo` (off) | `backup_sogo.tar.zst` (`/sogo_backup`) | tar of `sogo-backup` (SOGo's own nightly per-user exports) | not included |
| - | `mailcow-helm.info` | release, chart, image tags, DBNAME/DBUSER; no secrets | copies `mailcow.conf` (with passwords) |

Archives are `tar --use-compress-program="zstd --rsyncable -T<backup.threads>" -Pcpf`, exactly the
script's call (absolute member paths), made with the same image (`ghcr.io/mailcow/backup`, Debian:
GNU tar, zstd, pigz; tag pinned by digest in `backup.image`). A compose `backup_and_restore.sh
restore` can read the vmail, crypt, redis, rspamd and postfix archives, and `restore.sh` reads a
compose backup directory (see [Migrating from compose](#migrating-from-compose)).

Not backed up, as in the script: `vmail-index` (dovecot rebuilds indexes), `clamd-db` (freshclam
downloads it), `postfix-tlspol` (a cache), and configuration. Compose keeps configuration in the git
checkout; here it is your values file and `extraFiles` (keep them in Git) plus the `shared` PVC
(`rspamd-custom` maps and the `global-sieve` filters edited in the UI): copy those subPaths if you
change them in the UI. The release Secret (`<release>-secrets` or `existingSecret`) is not backed up
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
    backup_rspamd.tar.zst  backup_postfix.tar.zst  .x86_64  mailcow-helm.info
```

One CronJob per group: `<fullname>-backup-{mysql,redis,mail,rspamd,postfix,sogo}` (`mail` = crypt,
then vmail). The volume groups must run on the node of their owner's ReadWriteOnce volume (required
podAffinity to dovecot, rspamd, postfix or sogo) and those owners may sit on different nodes, so one
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
for g in mysql redis mail rspamd postfix; do
  kubectl -n mailcow create job --from=cronjob/mailcow-backup-$g mailcow-backup-$g-$m
done
kubectl -n mailcow get jobs -l app.kubernetes.io/component=backup
```

### Scheduling and storage

- `backup.persistence.accessMode: ReadWriteOnce` (default): all backup Jobs must mount the volume on
  one node, so each of them also requires the dovecot pod's node. rspamd and postfix (and sogo with
  `components.sogo`) must then run there too, or their Jobs stay Pending until
  `activeDeadlineSeconds` and fail. That holds on single-node clusters; with
  `persistence.shared.accessMode: ReadWriteOnce` rspamd is already pinned there (postfix too with
  `acme.enabled`). NOTES.txt lists the components that are not.
- Multi-node: `backup.persistence.accessMode: ReadWriteMany`, or `backup.persistence.existingClaim`
  on RWX storage (NFS, CephFS, EFS, ...; set `accessMode` to what it is). Each volume group then only
  follows its owner (when the owner's volume is ReadWriteOnce).
- The Jobs run as root with every capability dropped except `DAC_READ_SEARCH` (read mailboxes of any
  owner), read-only root filesystem, no service account token. They write as root: an NFS export
  needs `no_root_squash`, or replace `backup.securityContext` / `backup.podSecurityContext`.
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

`scripts/restore.sh` needs `kubectl` access to the namespace (pods, pods/exec, deployments/statefulsets
scale, PVCs, Secrets read; Secrets patch for a compose MariaDB restore). It prints the kubectl
context and server it will use and asks you to type the namespace (or `--yes`).

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

1. Starts `<fullname>-restore-inspect` (backup PVC read-only) to list the backup and the node's
   architecture.
2. Scales watchdog and the writers of the selected components to 0 and waits for their pods to go:
   `vmail`/`crypt` dovecot; `redis` redis; `rspamd` rspamd; `postfix` postfix; `sogo` sogo; `mysql`
   php-fpm, sogo, dovecot, postfix, acme (+ mysql for a physical restore).
3. Starts `<fullname>-restore`, which mounts the backup PVC read-only and each target PVC at the
   archive's path (`/vmail`, `/crypt`, `/redis`, `/rspamd` + `/rspamd_override`, `/postfix`,
   `/sogo_backup`), and a `db` container from the mysql client image. It schedules wherever the
   volumes allow (their owners are stopped); with node-local storage on several nodes it may not fit
   anywhere, and the script shows the scheduling events.
4. Extracts the archives over the volumes (`tar --numeric-owner -Pxpf`; nothing is deleted first,
   as in the script) and pipes `backup_mysql.sql.*` into `mariadb` through the `mysql` Service (the
   bundled or the external database). rspamd data from another CPU architecture is skipped (the
   script's check).
5. Deletes the pod and scales everything back to its previous replica count, also after a failure
   (the volumes may then be partially restored: rerun the restore). Optionally runs
   `doveadm force-resync -A '*'` (`--resync`, or asked).

Not handled by the script: Redis of `externalRedis` (load `dump.rdb` with the provider's tools) and
`postfix.spoolPerPod` queues (extract `backup_postfix.tar.zst` into one spool PVC with a pod like
the restore pod, while that postfix pod is scaled down; or let the old queue go).

Disaster recovery into a new cluster:

1. Recreate the Secret from your export (and `existingSecret: <name>`) or let the chart generate a
   new one; install the chart with the same values and `backup.enabled: true`.
2. Make the backups visible: `backup.persistence.existingClaim` on the restored NFS export, or copy
   a backup directory into the new backup PVC (e.g. `kubectl cp` into a pod that mounts it).
3. `restore.sh --backup <dir>` (all components), then log in, check a few mailboxes and open an
   older message (proves the crypt keys match).

#### Migrating from compose

`restore.sh` restores a directory written by `backup_and_restore.sh backup all`: vmail, crypt,
redis, rspamd and postfix archives are identical. The MariaDB part is a physical
`backup_mariadb.tar.zst`: with the bundled database the script stops mysql and its clients, empties
the mysql PVC, extracts it (`chown 999:999`) and, if the passwords in the directory's `mailcow.conf`
differ from the release Secret, offers to set `DBPASS`/`DBROOT` in the Secret (the restored data
directory carries the compose users). Set `mailcow.dbName`/`mailcow.dbUser` to the compose values
first, and keep the MariaDB major version (`mysql.image`) the same. It cannot go into an external
database (load a `mariadb-dump` there instead).

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
| `DOCKERAPIHOST` | php-fpm, dovecot, acme, watchdog | `dockerapi` (the UI uses that literal name, so the Service is called exactly `dockerapi`) |
| `SOGOHOST`, `PHPFPMHOST`, `RSPAMDHOST` | nginx | `sogo-mailcow`, `php-fpm-mailcow`, `rspamd-mailcow` |
| `NGINXHOST` | acme | `nginx` |
| `WAIT_TCP=y` | nginx, acme, postfix-tlspol | wait for dependencies with TCP connects instead of `ping` |
| `TLSPOL_DNS` | postfix-tlspol | `<unbound.clusterIP>:53` |
| `MAILCOW_NETWORKS` | rspamd, postfix, php-fpm | `mailcow.networks` |
| `SOGO_TRUSTED_NETS` | dovecot, php-fpm | `mailcow.sogoTrustedNets` (empty = `mailcow.networks`) |
| `DOVECOT_TRUSTED_NETS`, `RSPAMD_TRUSTED_NETS` | rspamd | `mailcow.dovecotTrustedNets` / `rspamdTrustedNets` (empty = `mailcow.networks`); unset, rspamd waits forever for `dig dovecot` |
| `SOGO_SSO_PASS`, `DOVECOT_MASTER_USER/PASS` | dovecot (+ seed initContainers of sogo, php-fpm) | release Secret (stable SOGo SSO, sieve.creds, cron.creds; sogo/php-fpm derive the same files, see [Storage](#storage)) |
| `SOGO_ENCRYPTION_KEY` | sogo | release Secret (alphanumeric) |
| `DOCKERAPI_BACKEND=kubernetes`, `COMPOSE_PROJECT_NAME`, `K8S_POD_SELECTOR` | dockerapi | pods matched by `app.kubernetes.io/name=mailcow,app.kubernetes.io/instance=<release>` in the ServiceAccount's namespace |

Comma-separated CIDR lists, IPv6 without brackets (`10.244.0.0/16,fd00:10:244::/56`).

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

With `externalTrafficPolicy: Cluster` kube-proxy SNATs incoming connections to a node address, and
some CNI setups masquerade to an address inside the pod CIDR (a node's bridge/gateway IP). An outside client
then appears to postfix as a member of `MAILCOW_NETWORKS`: **open relay**, DKIM-signed spoofing. So:

- `mail.proxyProtocol: true` (default): the load balancer passes the real address in a PROXY header to
  the PROXY listeners; the Service may then use `Cluster`.
- `mail.proxyProtocol: false`: the chart sets `externalTrafficPolicy: Local` (only nodes running the pod
  answer, the source address stays intact). Do not override it with `Cluster`; NOTES.txt warns if you do.

PROXY headers are trusted by source: dovecot only from `mail.proxyTrustedNetworks`
(`haproxy_trusted_networks`; must cover the LB, node or SNAT addresses the connections come from),
while postfix's PROXY listeners (10025/10465/10587, like in compose) accept a PROXY header from
**anyone** who can connect. Anything able to reach them can claim any client address, including one
in `MAILCOW_NETWORKS`. Limit who can reach them with `networkPolicy.publicMailFrom`.

### SOGo

`mailcow.sogoTrustedNets` defaults to `mailcow.networks` (every pod in the cluster), and NOTES.txt
warns about it. If your CNI can assign the sogo pod addresses from a dedicated range (e.g. a Calico
IPPool selected by namespace/pod annotation), set `mailcow.sogoTrustedNets` to that range.

### NetworkPolicy

Requires a CNI that enforces NetworkPolicy (Calico, Cilium, ...); otherwise the
objects are ignored silently.

- Always: dockerapi :443 only from php-fpm, watchdog, acme and dovecot pods. dockerapi is an
  unauthenticated API that runs commands in every mailcow container.
- Always: rspamd's controller relay :11335 only from php-fpm, dovecot, postfix and watchdog pods.
  It forwards to the controller's unix socket, which rspamd trusts like localhost: no password,
  full controller access (learn, fuzzy add/delete, settings, maps, history). The same policy opens
  rspamd's other ports (11333, 11334, 9900, 11445) to release pods with `networkPolicy.enabled`, and
  to anyone without it (a policy selecting the pod would block them otherwise). No other rule
  mentions 11335. Without an enforcing CNI every pod in the cluster can reach 11335; so can traffic
  from the node itself (kubelet, hostNetwork pods), which most CNIs never filter.
- `networkPolicy.enabled` (default `true`, in both mail modes; only `false` turns it off, the old
  `""` auto mode now counts as on): every port of mysql, redis (unless external), memcached, clamd, olefy,
  php-fpm, sogo, postfix-tlspol, unbound, postfix and dovecot (rspamd: every port but 11335) only from pods of this release;
  postfix/dovecot client ports (PROXY listeners, or the plain ports without PROXY protocol) from
  `networkPolicy.publicMailFrom`; nginx http/https from anywhere. Without it, any pod in the cluster
  can relay through postfix, since it connects from the pod CIDR.
- `networkPolicy.publicMailFrom` empty (default): the client ports allow `0.0.0.0/0` except every
  IPv4 entry of `mailcow.networks`, and `::/0` except every IPv6 entry (bare addresses become /32 or
  /128). Pods of this release still reach every port through the pod selector. Every other source
  inside the pod CIDR is one mailcow trusts (relay without auth), so it must not reach the client
  ports:
  - Calico applies `ipBlock` to pod addresses, so `except` blocks other pods;
  - Cilium never matches pods with CIDR rules, so other pods are blocked either way;
  - ingress traffic SNAT'd into the pod CIDR (e.g. flannel's `cni0`/`flannel.1` address with
    `externalTrafficPolicy: Cluster`) is blocked too. Without PROXY protocol that traffic would
    otherwise be an open relay, so blocking is the safe outcome. With PROXY protocol on such a CNI,
    clients that reach the pod through another node are blocked: set
    `mail.service.externalTrafficPolicy: Local`, or set `publicMailFrom` to the source range you
    accept.

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

plus, for dockerapi, the CronJob runner and the TLS bootstrap and strategy-fix hook Jobs only, the Kubernetes API server:
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

### Namespace

Install mailcow into a namespace of its own. RBAC cannot be scoped to labels: dockerapi's Role allows
exec into and deletion of **every** pod in the namespace, and the CronJob runner can exec into every
pod too.

## Brute-force protection (no fail2ban)

compose's netfilter container (fail2ban-style bans written to the host's iptables/nftables) is not
part of the chart, and chart 0.3.0 removed the opt-in DaemonSet:

- it needs a privileged (or NET_ADMIN/NET_RAW) hostNetwork pod on every node that rewrites the
  node's firewall, next to the rules kube-proxy and the CNI own;
- eBPF dataplanes (Cilium, Calico eBPF) and IPVS forward Service traffic before or outside the
  iptables chains it inserts into, so a ban may be bypassed;
- behind PROXY protocol the TCP source on the node is the load balancer: banning the address mailcow
  logs does nothing, banning the TCP source blocks all mail;
- the load balancer, cloud firewall or ingress in front of the cluster can drop traffic before it
  reaches any node.

Values that still set `netfilter:` (or `networkPolicy.nodeCIDRs`) render nothing and print a NOTES
warning.

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
  not the load balancer. Without PROXY protocol they rely on `externalTrafficPolicy: Local`; with
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

## Limitations (0.1)

- dovecot and rspamd run a single replica; postfix replicas each have their own queue (UI queue view
  shows one pod), php-fpm restarts with `Recreate` (short UI/login gap on upgrades), see
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
  be prepared by hand (user, grants, `event_scheduler`, time zone tables); Redis is plain TCP only
  and must listen on 6379 when given by DNS name ([External database / Redis](#external-database--redis)).
- The rspamd socket relay listens dual-stack when the pod has IPv6, IPv4-only otherwise; IPv6-only
  and dual-stack clusters work. Other IPv6 caveats (nginx `mailcow.enableIpv6`, watchdog's IPv4-only
  checks) are unchanged.

## Development

- `helm/mailcow/scripts/check-tags.sh [--fix]`: chart image tags must equal `docker-compose.yml`.
- `ci/*-values.yaml`: kind (NodePorts 30080/30443/30025/30465/30587/30143/30993/32190, RWO shared,
  self-signed TLS, clamd skipped), cert-manager + Ingress, HA (RWX, LB + PROXY,
  watchdog, NetworkPolicy), acme + extraFiles + watchdog (postfix limits off, NetworkPolicy off), NetworkPolicy without PROXY protocol,
  external MySQL/Redis by DNS name (ExternalName, DBPORT 3307) and by IPv4/IPv6 address (EndpointSlices, Redis 6379 → 6380),
  egress policies on a dual-stack cluster with an in-cluster external database in `extraTo`,
  scaling (nginx HPA, sogo/php-fpm 2 replicas, postfix 2 with a queue per pod, watchdog without the
  queue mount, 60 s TLS reload checks; layer it on kind-values.yaml for the local kind cluster).
  kind and cert-manager: NetworkPolicy on with the default `publicMailFrom`; cert-manager has the
  ofelia CronJobs off (no CronJob runner at all).
  backup: the defaults (ReadWriteOnce backup PVC, every group incl. sogo, retention by age and count;
  layer it on kind-values.yaml) and a multi-node variant (RWX existingClaim and mail volumes, external
  database and Redis, newer client image, postfix queue per pod = not backed up).
  `check-tags.sh` skips the compose services the chart does not ship (ofelia, netfilter) and checks
  `backup.image` against `DEBIAN_DOCKER_IMAGE` of `helper-scripts/backup_and_restore.sh`.
- `scripts/restore.sh`: restore a backup directory ([Backup and restore](#restore)); `KUBECTL` selects the binary.
