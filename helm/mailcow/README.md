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

Before installing, check these cluster-specific values:

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
| mysql, redis | StatefulSet (1 replica, PVC). Clients use TCP (`DBHOST=mysql`) |
| dovecot, postfix | StatefulSet (1 replica) |
| rspamd | Deployment, `hostname: rspamd` (worker-proxy binds `rspamd:9900`) |
| php-fpm, sogo, nginx, clamd, olefy, memcached, postfix-tlspol | Deployment |
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
socket, so its users effectively need one node. `global-sieve/{before,after}` (global filters, edited
in the UI) start as the repo's `data/conf/dovecot/global_sieve_*` (or `extraFiles` with those paths)
and are only re-seeded while missing or empty. Data PVCs and
the generated Secret are kept on `helm uninstall` (`persistence.keep`).

### TLS

`/etc/ssl/mail` in postfix, dovecot, nginx (and watchdog), first match wins:

1. `acme.enabled`: mailcow ACME client writes to the shared `ssl` dir (snake-oil seeded first).
2. `tls.certManager.enabled`: Certificate (`issuerRef`) → Secret `<fullname>-tls`.
3. `tls.existingSecret`.
4. otherwise a pre-install hook Job creates a self-signed snake-oil Secret once (like `generate_config.sh`).

For 2–4 the Secret is mounted as a whole volume at `/etc/ssl/mail-tls` (`cert.pem`/`key.pem`)
and `/etc/ssl/mail` holds `dhparams.pem` (files image) plus symlinks, so renewed certificates appear
in the pods without a restart (kubelet syncs Secret volumes within a minute or two). The daemons
only read certificates when they (re)load, so the CronJob `cert-reload` (`tls.reload.enabled`,
default on; schedule `tls.reload.schedule`, default `17 3 * * *`) runs `postfix reload`,
`doveadm reload` and `nginx -s reload` in the three pods through the CronJob runner. The three steps
run independently; the Job fails if any of them fails. All three reloads are graceful: open
connections finish on the old processes, new ones get the new certificate.

cert-manager renews at 2/3 of the certificate lifetime by default (30 days before expiry for
90-day Let's Encrypt certificates; `tls.certManager.renewBefore` overrides it), so a daily reload
means the new certificate is in use at most about a day after renewal, long before the old one
expires. With `acme.enabled` the job is not rendered: the acme container reloads/restarts the
daemons through dockerapi itself.

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
the target container. Override with `cronjobs.jobs.<name>.{enabled,schedule}`. The chart's own
`cert-reload` job ([TLS](#tls)) uses the same runner and ServiceAccount, and renders even with
`cronjobs.enabled: false`.

## Environment contract

Every variable below is opt-in in the images: compose leaves it empty and keeps its old behaviour.
The chart sets them; images at the tags pinned in `docker-compose.yml` support all of them.

| variable | set on | value |
|---|---|---|
| `DBHOST`, `DBPORT` | php-fpm, sogo, dovecot, postfix, acme, watchdog | `mysql`, `3306` (TCP instead of the unix socket) |
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
| `SOGO_SSO_PASS`, `DOVECOT_MASTER_USER/PASS` | dovecot | release Secret (stable SOGo SSO, sieve.creds, cron.creds) |
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
- `networkPolicy.enabled` (default `true`, in both mail modes; only `false` turns it off, the old
  `""` auto mode now counts as on): every port of mysql, redis, memcached, clamd, olefy, rspamd,
  php-fpm, sogo, postfix-tlspol, unbound, postfix and dovecot only from pods of this release;
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
- Ingress only: DNS to unbound, unbound's queries to kube-dns and the forwarders, and the CronJob
  runner's API server calls are egress and unaffected. Kubelet probes come from the node, which
  NetworkPolicy does not block.

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

- dovecot/postfix single replica; rspamd/php-fpm/dovecot/postfix share a node through rspamd.sock.
- No fail2ban (netfilter); see [Brute-force protection](#brute-force-protection-no-fail2ban).
- `redis` `net.core.somaxconn` is an unsafe sysctl (`redis.sysctls`, off by default); compose
  ulimits for dovecot have no pod equivalent (runtime defaults are higher).
- NetworkPolicy covers ingress only; egress is unrestricted.
- No external database support yet (php-fpm waits for the mysql pod via dockerapi).

## Development

- `helm/mailcow/scripts/check-tags.sh [--fix]`: chart image tags must equal `docker-compose.yml`.
- `ci/*-values.yaml`: kind (NodePorts 30080/30443/30025/30465/30587/30143/30993/32190, RWO shared,
  self-signed TLS, clamd skipped), cert-manager + Ingress, HA (RWX, LB + PROXY,
  watchdog, NetworkPolicy), acme + extraFiles (postfix limits off, NetworkPolicy off), NetworkPolicy without PROXY protocol.
  kind and cert-manager: NetworkPolicy on with the default `publicMailFrom`; cert-manager renders
  `cert-reload` with the ofelia CronJobs off.
  `check-tags.sh` skips the compose services the chart does not ship (ofelia, netfilter).
