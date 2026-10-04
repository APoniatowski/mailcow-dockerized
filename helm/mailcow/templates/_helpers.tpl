{{/* ---------- names ---------- */}}
{{- define "mailcow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mailcow.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mailcow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ---------- labels ----------
Naming contract (dockerapi kubernetes backend): component = compose service minus "-mailcow".
Usage: include "mailcow.labels" (dict "root" . "component" "dovecot") */}}
{{- define "mailcow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailcow.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "mailcow.labels" -}}
helm.sh/chart: {{ include "mailcow.chart" .root }}
{{ include "mailcow.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: mailcow
{{- end -}}

{{- define "mailcow.commonLabels" -}}
helm.sh/chart: {{ include "mailcow.chart" . }}
app.kubernetes.io/name: {{ include "mailcow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mailcow
{{- end -}}

{{/* ---------- secrets / tls ---------- */}}
{{- define "mailcow.secretName" -}}
{{- default (printf "%s-secrets" .Release.Name) .Values.existingSecret -}}
{{- end -}}

{{- define "mailcow.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "mailcow.fullname" .)) .Values.tls.existingSecret -}}
{{- end -}}

{{/* true when the self-signed bootstrap Job provides the TLS Secret */}}
{{- define "mailcow.tlsSelfSigned" -}}
{{- if and (not .Values.acme.enabled) (not .Values.tls.certManager.enabled) (not .Values.tls.existingSecret) -}}true{{- end -}}
{{- end -}}

{{/* env var from the release Secret: include "mailcow.secretEnv" (list $ "ENV_NAME" "KEY") */}}
{{- define "mailcow.secretEnv" -}}
{{- $root := index . 0 -}}
- name: {{ index . 1 }}
  valueFrom:
    secretKeyRef:
      name: {{ include "mailcow.secretName" $root }}
      key: {{ index . 2 }}
{{- end -}}

{{/* ---------- images ---------- */}}
{{- define "mailcow.image" -}}
{{- printf "%s:%s" .repository (toString .tag) -}}
{{- end -}}

{{- define "mailcow.filesImage" -}}
{{- printf "%s:%s" .Values.files.image.repository (default .Chart.AppVersion .Values.files.image.tag) -}}
{{- end -}}

{{- define "mailcow.yn" -}}
{{- if . -}}y{{- else -}}n{{- end -}}
{{- end -}}

{{/* ---------- common env blocks ---------- */}}
{{- define "mailcow.env.tz" -}}
- name: TZ
  value: {{ .Values.mailcow.tz | quote }}
{{- end -}}

{{- define "mailcow.env.redis" -}}
- name: REDIS_SLAVEOF_IP
  value: {{ .Values.mailcow.redisSlaveofIp | quote }}
- name: REDIS_SLAVEOF_PORT
  value: {{ .Values.mailcow.redisSlaveofPort | quote }}
{{ include "mailcow.secretEnv" (list . "REDISPASS" "REDISPASS") }}
{{- end -}}

{{/* DBHOST/DBPORT: MySQL over TCP (unset = unix socket like compose) */}}
{{- define "mailcow.env.db" -}}
- name: DBNAME
  value: {{ .Values.mailcow.dbName | quote }}
- name: DBUSER
  value: {{ .Values.mailcow.dbUser | quote }}
{{ include "mailcow.secretEnv" (list . "DBPASS" "DBPASS") }}
- name: DBHOST
  value: mysql
- name: DBPORT
  value: {{ include "mailcow.dbPort" . | quote }}
{{- end -}}

{{/* ---------- trusted networks ----------
Validated, normalized network list (JSON array). Entries: IPv4/IPv6 address or CIDR, IPv6 without
brackets; /0 and anything else fail (the images drop such entries with only a warning).
Input: comma separated string or list. include "mailcow.netList" (list "mailcow.networks" $value) | fromJsonArray */}}
{{- define "mailcow.netList" -}}
{{- $what := index . 0 -}}
{{- $in := index . 1 -}}
{{- if not (kindIs "slice" $in) -}}{{- $in = splitList "," (toString $in) -}}{{- end -}}
{{- $out := list -}}
{{- range $in -}}
{{- $n := trim (toString .) -}}
{{- if $n -}}
{{- $v4 := regexMatch `^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$` $n -}}
{{- $v6 := and (contains ":" $n) (regexMatch `^[0-9A-Fa-f:.]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$` $n) -}}
{{- if not (or $v4 $v6) -}}
{{- fail (printf "%s: %q is not an IP address or CIDR (comma separated list, IPv6 without brackets, no spaces inside an entry)" $what $n) -}}
{{- end -}}
{{- if hasSuffix "/0" $n -}}
{{- fail (printf "%s: %q trusts every address; list the real ranges" $what $n) -}}
{{- end -}}
{{- $out = append $out $n -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/* MAILCOW_NETWORKS, comma separated without spaces (dovecot's /source_env.sh breaks on spaces) */}}
{{- define "mailcow.networks" -}}
{{- $l := include "mailcow.netList" (list "mailcow.networks" .Values.mailcow.networks) | fromJsonArray -}}
{{- if not $l -}}{{- fail "mailcow.networks is required: the cluster pod CIDR(s), e.g. 10.244.0.0/16" -}}{{- end -}}
{{- join "," $l -}}
{{- end -}}

{{/* list value or mailcow.networks when empty. include "mailcow.netsOrNetworks" (list . "sogoTrustedNets") */}}
{{- define "mailcow.netsOrNetworks" -}}
{{- $root := index . 0 -}}{{- $key := index . 1 -}}
{{- $l := include "mailcow.netList" (list (printf "mailcow.%s" $key) (index $root.Values.mailcow $key)) | fromJsonArray -}}
{{- if $l -}}{{- join "," $l -}}{{- else -}}{{- include "mailcow.networks" $root -}}{{- end -}}
{{- end -}}

{{- define "mailcow.sogoTrustedNets" -}}
{{- include "mailcow.netsOrNetworks" (list . "sogoTrustedNets") -}}
{{- end -}}

{{/* rspamd DOVECOT_TRUSTED_NETS / RSPAMD_TRUSTED_NETS: always set, unset makes rspamd loop on `dig dovecot` */}}
{{- define "mailcow.dovecotTrustedNets" -}}
{{- include "mailcow.netsOrNetworks" (list . "dovecotTrustedNets") -}}
{{- end -}}

{{- define "mailcow.rspamdTrustedNets" -}}
{{- include "mailcow.netsOrNetworks" (list . "rspamdTrustedNets") -}}
{{- end -}}

{{/* mail.proxyTrustedNetworks (JSON array): required with mail.proxyProtocol, [] without */}}
{{- define "mailcow.proxyTrustedNetworks" -}}
{{- if .Values.mail.proxyProtocol -}}
{{- $l := include "mailcow.netList" (list "mail.proxyTrustedNetworks" .Values.mail.proxyTrustedNetworks) | fromJsonArray -}}
{{- if not $l -}}
{{- fail `mail.proxyProtocol is true, so mail.proxyTrustedNetworks is required: the source addresses the PROXY-protocol connections reach the postfix/dovecot pods from, and nothing wider. postfix's PROXY listeners trust any PROXY header, so whoever can connect from these ranges can claim any client address (including one in mailcow.networks = open relay). Use the load balancer's own addresses (IP-target LBs such as AWS NLB ip mode: its subnet/private IPs), or the node addresses when the LB targets node ports with externalTrafficPolicy Cluster (then firewall the node ports so only the LB reaches them). Never the pod CIDR. Set mail.proxyProtocol=false when nothing in front sends PROXY headers. README "Security".` -}}
{{- end -}}
{{- toJson $l -}}
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{/* NetworkPolicy ipBlock peers for a JSON array of addresses/CIDRs (bare addresses become /32 or /128) */}}
{{- define "mailcow.ipBlocks" -}}
{{- range . }}
- ipBlock:
    cidr: {{ ternary . (printf "%s/%s" . (ternary "128" "32" (contains ":" .))) (contains "/" .) }}
{{- end }}
{{- end -}}

{{/* FQDN of a release Service: include "mailcow.svcFqdn" (list . "postfix") */}}
{{- define "mailcow.svcFqdn" -}}
{{- $root := index . 0 -}}
{{- printf "%s.%s.svc.%s" (index . 1) $root.Release.Namespace $root.Values.clusterDomain -}}
{{- end -}}

{{/* "true" when the release-wide ingress NetworkPolicies are rendered (networkPolicy.enabled) */}}
{{- define "mailcow.networkPolicy" -}}
{{- if .Values.networkPolicy.enabled -}}true{{- end -}}
{{- end -}}

{{/* ipBlock peers 0.0.0.0/0 and ::/0, each except the given CIDRs of its family (bare addresses
become /32 or /128). include "mailcow.allExcept" (list "10.244.0.0/16" "fd00::/56") */}}
{{- define "mailcow.allExcept" -}}
{{- $v4 := list -}}{{- $v6 := list -}}
{{- range . -}}
{{- $n := trim . -}}
{{- if $n -}}
{{- if contains ":" $n -}}{{- $v6 = append $v6 (ternary $n (printf "%s/128" $n) (contains "/" $n)) -}}
{{- else -}}{{- $v4 = append $v4 (ternary $n (printf "%s/32" $n) (contains "/" $n)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
- ipBlock:
    cidr: 0.0.0.0/0
    {{- with $v4 }}
    except:
      {{- toYaml . | nindent 6 }}
    {{- end }}
- ipBlock:
    cidr: ::/0
    {{- with $v6 }}
    except:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end -}}

{{/* NetworkPolicy peers for the public mail ports: networkPolicy.publicMailFrom, or everything
except mailcow.networks (in-cluster pods from the pod CIDR would be trusted as internal) */}}
{{- define "mailcow.publicMailPeers" -}}
{{- if .Values.networkPolicy.publicMailFrom -}}
{{- toYaml .Values.networkPolicy.publicMailFrom -}}
{{- else -}}
{{- include "mailcow.allExcept" (splitList "," (include "mailcow.networks" .)) -}}
{{- end -}}
{{- end -}}

{{/* egress "internet" exceptions: networkPolicy.egress.clusterCIDRs, or mailcow.networks + serviceCIDR */}}
{{- define "mailcow.egressClusterCIDRs" -}}
{{- $e := .Values.networkPolicy.egress -}}
{{- $in := $e.clusterCIDRs | default (concat (splitList "," (include "mailcow.networks" .)) (splitList "," (toString $e.serviceCIDR))) -}}
{{- /* the API server often sits on a node/VPC address outside the cluster CIDRs: keep it out of the
       internet rule so only the pods in <fullname>-egress-apiserver can reach it */ -}}
{{- $in = concat $in ($e.apiServerCIDRs | default list) -}}
{{- $out := list -}}
{{- range $in -}}{{- if trim (toString .) -}}{{- $out = append $out (trim (toString .)) -}}{{- end -}}{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/* ---------- external database / Redis ----------
"IPv4" / "IPv6" for an address literal (brackets stripped), "" for a DNS name */}}
{{- define "mailcow.ipFamily" -}}
{{- $h := . | trimPrefix "[" | trimSuffix "]" -}}
{{- if regexMatch `^[0-9]{1,3}(\.[0-9]{1,3}){3}$` $h -}}IPv4
{{- else if and (contains ":" $h) (regexMatch `^[0-9A-Fa-f:.]+$` $h) -}}IPv6
{{- end -}}
{{- end -}}

{{/* DBPORT: the external port for the ExternalName/EndpointSlice aliases; 3306 for the bundled server and
the ProxySQL TLS proxy (externalDatabase.tls) */}}
{{- define "mailcow.dbPort" -}}
{{- if and .Values.externalDatabase.enabled (not (include "mailcow.dbTls" .)) -}}{{- int .Values.externalDatabase.port -}}{{- else -}}3306{{- end -}}
{{- end -}}

{{/* "true" when the external database is reached through the ProxySQL TLS proxy <fullname>-db-tls */}}
{{- define "mailcow.dbTls" -}}
{{- if .Values.externalDatabase.tls.enabled -}}
{{- if not .Values.externalDatabase.enabled -}}{{- fail "externalDatabase.tls.enabled needs externalDatabase.enabled (TLS to the bundled mysql StatefulSet is not supported)" -}}{{- end -}}
true
{{- end -}}
{{- end -}}

{{/* "true" when the external Redis is reached through the TLS relay <fullname>-redis-tls */}}
{{- define "mailcow.redisTls" -}}
{{- if .Values.externalRedis.tls.enabled -}}
{{- if not .Values.externalRedis.enabled -}}{{- fail "externalRedis.tls.enabled needs externalRedis.enabled (TLS to the bundled redis StatefulSet is not supported)" -}}{{- end -}}
true
{{- end -}}
{{- end -}}

{{/* external host:port validation shared by the aliases and the TLS proxies; returns the address
family ("IPv4", "IPv6", "" = DNS name). include "mailcow.externalHost" (dict "what" "externalRedis" "host" .host "port" .port) */}}
{{- define "mailcow.externalHost" -}}
{{- $host := trim (toString .host) -}}
{{- if not $host -}}{{- fail (printf "%s.enabled needs %s.host (DNS name or IP address)" .what .what) -}}{{- end -}}
{{- $port := int .port -}}
{{- if or (lt $port 1) (gt $port 65535) -}}{{- fail (printf "%s.port must be 1-65535" .what) -}}{{- end -}}
{{- $family := include "mailcow.ipFamily" $host -}}
{{- if and (not $family) (not (regexMatch `^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\.?$` (lower $host))) -}}
{{- fail (printf "%s.host %q is neither an IP address nor a valid DNS name" .what $host) -}}
{{- end -}}
{{- $family -}}
{{- end -}}

{{/* TLS proxy pods (redis-tls, db-tls): plain listener for release pods only, always rendered while the
proxy exists: it lends its client certificate (if any) to whoever connects.
include "mailcow.tlsProxyPolicy" (dict "root" . "component" "redis-tls" "port" 6379) */}}
{{- define "mailcow.tlsProxyPolicy" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "mailcow.fullname" .root }}-{{ .component }}
  labels:
    {{- include "mailcow.labels" (dict "root" .root "component" .component) | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "mailcow.selectorLabels" (dict "root" .root "component" .component) | nindent 6 }}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        {{- include "mailcow.releasePeer" .root | nindent 8 }}
      ports:
        - port: {{ .port }}
          protocol: TCP
{{- end -}}

{{/* Secret volume with the given keys, mode 0444 (the proxies run as mailcow.helperUid, Secret files are
root-owned; only the proxy container mounts it). include "mailcow.keysVolume" (dict "name" "ca" "secret" "x" "keys" (list "ca.crt")) */}}
{{- define "mailcow.keysVolume" -}}
- name: {{ .name }}
  secret:
    secretName: {{ .secret }}
    defaultMode: 0444
    items:
      {{- range .keys }}
      - key: {{ . }}
        path: {{ . }}
      {{- end }}
{{- end -}}

{{/* Services `<alias>` and `<component>-mailcow` for an external endpoint, instead of the selector Services.
DNS name: ExternalName (CNAME, no port mapping: clients connect to `port`).
IP literal: selector-less Service on `svcPort` + EndpointSlice -> host:`port`.
include "mailcow.externalServices" (dict "root" $ "component" "mysql" "alias" "mysql" "what" "externalDatabase"
  "host" "db.example.org" "port" 3306 "svcPort" 3306 "portName" "mysql") */}}
{{- define "mailcow.externalServices" -}}
{{- $root := .root -}}
{{- $what := .what -}}
{{- $host := trim (toString .host) -}}
{{- $port := int .port -}}
{{- $family := include "mailcow.externalHost" (dict "what" $what "host" $host "port" $port) -}}
{{- $ip := $host | trimPrefix "[" | trimSuffix "]" -}}
{{- $dns := lower $host -}}
{{- if and (not $family) (ne $port (int .svcPort)) -}}
{{- fail (printf "%s.port %d: with a DNS host the Services are ExternalName aliases, which cannot remap ports, and mailcow components connect to %d. Use %d, or an IP address as host (the EndpointSlice then maps %d to %d)" $what $port (int .svcPort) (int .svcPort) (int .svcPort) $port) -}}
{{- end -}}
{{- range $name := list .alias (printf "%s-mailcow" .component) }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    {{- include "mailcow.labels" (dict "root" $root "component" $.component) | nindent 4 }}
    mailcow.email/external: "true"
spec:
  {{- if $family }}
  type: ClusterIP
  ipFamilyPolicy: SingleStack
  ipFamilies: [{{ $family }}]
  ports:
    - name: {{ $.portName }}
      port: {{ int $.svcPort }}
      targetPort: {{ $port }}
      protocol: TCP
  {{- else }}
  type: ExternalName
  externalName: {{ $dns }}
  ports:
    - name: {{ $.portName }}
      port: {{ $port }}
      protocol: TCP
  {{- end }}
{{- if $family }}
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: {{ $name }}-external
  labels:
    {{- include "mailcow.labels" (dict "root" $root "component" $.component) | nindent 4 }}
    mailcow.email/external: "true"
    kubernetes.io/service-name: {{ $name }}
    endpointslice.kubernetes.io/managed-by: {{ $root.Release.Service | lower }}
addressType: {{ $family }}
endpoints:
  - addresses:
      - {{ $ip | quote }}
    conditions:
      ready: true
ports:
  - name: {{ $.portName }}
    port: {{ $port }}
    protocol: TCP
{{- end }}
{{- end }}
{{- end -}}

{{/* NetworkPolicy peer: every pod of this release (same namespace) */}}
{{- define "mailcow.releasePeer" -}}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ include "mailcow.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* ---------- pod scaffolding ---------- */}}
{{/* dnsConfig for pods that used `dns: ${IPV4_NETWORK}.254` in compose */}}
{{- define "mailcow.dnsUnbound" -}}
dnsPolicy: None
dnsConfig:
  nameservers:
    - {{ .Values.unbound.clusterIP }}
  searches:
    - {{ printf "%s.svc.%s" .Release.Namespace .Values.clusterDomain }}
    - {{ printf "svc.%s" .Values.clusterDomain }}
    - {{ .Values.clusterDomain }}
  options:
    - name: ndots
      value: "5"
{{- end -}}

{{- define "mailcow.sharedColocate" -}}
{{- if eq .Values.persistence.shared.accessMode "ReadWriteOnce" -}}true{{- end -}}
{{- end -}}

{{/* pod-level scheduling + pull secrets. include "mailcow.podCommon" (dict "root" . "shared" true) */}}
{{- define "mailcow.podCommon" -}}
{{- $root := .root -}}
{{- with $root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.podDefaults.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.podDefaults.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if and .shared (include "mailcow.sharedColocate" $root) }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/instance: {{ $root.Release.Name }}
            mailcow.email/shared-volume: "true"
{{- end }}
{{- end -}}

{{/* extra pod labels for pods that mount the shared PVC */}}
{{- define "mailcow.sharedLabel" -}}
mailcow.email/shared-volume: "true"
{{- end -}}

{{- define "mailcow.podAnnotations" -}}
checksum/k8s-conf: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum | trunc 16 }}
{{- with .Values.podDefaults.annotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* pod template `annotations:` block with podDefaults.annotations only (pods that read no chart ConfigMap),
nothing when empty. include "mailcow.podDefaultAnnotations" . | nindent 6 (at metadata level) */}}
{{- define "mailcow.podDefaultAnnotations" -}}
{{- with .Values.podDefaults.annotations -}}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{/* ClusterIP of the cluster DNS Service: clusterDNS, or (empty) kube-system/kube-dns looked up at
install/upgrade time; 10.96.0.10 (kubeadm/kind) when the lookup finds nothing (helm template) */}}
{{- define "mailcow.clusterDNS" -}}
{{- if .Values.clusterDNS -}}
{{- .Values.clusterDNS -}}
{{- else -}}
{{- $svc := lookup "v1" "Service" "kube-system" "kube-dns" | default dict -}}
{{- $ip := dig "spec" "clusterIP" "" $svc -}}
{{- if and $ip (ne $ip "None") -}}{{- $ip -}}{{- else -}}10.96.0.10{{- end -}}
{{- end -}}
{{- end -}}

{{/* SOGo custom logo / script files: [file in data/conf/sogo, path under WebServerResources] (JSON) */}}
{{- define "mailcow.sogoLogos" -}}
{{- toJson (list (list "custom-favicon.ico" "img/sogo.ico") (list "custom-shortlogo.svg" "img/sogo-compact.svg") (list "custom-fulllogo.svg" "img/sogo-full.svg") (list "custom-fulllogo.png" "img/sogo-logo.png") (list "custom-theme.js" "js/theme.js") (list "custom-sogo.js" "js/custom-sogo.js")) -}}
{{- end -}}

{{/* ---------- volumes ---------- */}}
{{- define "mailcow.claimName" -}}
{{- $root := index . 0 -}}{{- $key := index . 1 -}}{{- $suffix := index . 2 -}}
{{- $p := index $root.Values.persistence $key -}}
{{- default (printf "%s-%s" (include "mailcow.fullname" $root) $suffix) $p.existingClaim -}}
{{- end -}}

{{- define "mailcow.sharedClaim" -}}
{{- include "mailcow.claimName" (list . "shared" "shared") -}}
{{- end -}}

{{/* extraFiles + extraSecretFiles: JSON {data/-relative path: file in the seed initContainer}.
extraSecretFiles win over extraFiles for the same path. Paths are validated so they can be single-quoted
in shell. include "mailcow.extraFileMap" . | fromJson */}}
{{- define "mailcow.extraFileMap" -}}
{{- $m := dict -}}
{{- range $src := list (list "extraFiles" "/extra") (list "extraSecretFiles" "/extra-secret") -}}
{{- range $path, $v := index $.Values (index $src 0) -}}
{{- if or (not (regexMatch `^[A-Za-z0-9_@+-][A-Za-z0-9._@+/-]*$` $path)) (regexMatch `(^|/)\.\.?(/|$)` $path) (hasSuffix "/" $path) -}}
{{- fail (printf "%s: %q must be a file path relative to data/ (letters, digits, . _ - @ + /, no . or .. segments)" (index $src 0) $path) -}}
{{- end -}}
{{- if and (eq (index $src 0) "extraSecretFiles") (or (not (kindIs "map" $v)) (not $v.secretName) (not $v.key)) -}}
{{- fail (printf "extraSecretFiles.%s needs {secretName: <Secret in the release namespace>, key: <key in it>}" $path) -}}
{{- end -}}
{{- $_ := set $m $path (printf "%s/%s" (index $src 1) $path) -}}
{{- end -}}
{{- end -}}
{{- toJson $m -}}
{{- end -}}

{{/* seed emptyDir + extraFiles ConfigMap + extraSecretFiles Secrets + chart ConfigMap (+ shared PVC) */}}
{{- define "mailcow.seedVolumes" -}}
{{- $root := .root -}}
- name: seed
  emptyDir: {}
- name: k8s-conf
  configMap:
    name: {{ include "mailcow.fullname" $root }}-k8s
{{- if $root.Values.extraFiles }}
- name: extra-files
  configMap:
    name: {{ include "mailcow.fullname" $root }}-extra-files
    items:
      {{- range $path, $_ := $root.Values.extraFiles }}
      - key: {{ printf "f-%s" (sha256sum $path | trunc 16) }}
        path: {{ $path }}
      {{- end }}
{{- end }}
{{- if $root.Values.extraSecretFiles }}
- name: extra-secret-files
  projected:
    defaultMode: 0444
    sources:
      {{- range $path, $s := $root.Values.extraSecretFiles }}
      - secret:
          name: {{ $s.secretName }}
          items:
            - key: {{ $s.key }}
              path: {{ $path }}
      {{- end }}
{{- end }}
{{- if .shared }}
- name: shared
  persistentVolumeClaim:
    claimName: {{ include "mailcow.sharedClaim" $root }}
{{- end }}
{{- end -}}

{{/* /etc/ssl/mail volumes for postfix/dovecot/nginx/watchdog */}}
{{- define "mailcow.tlsVolumes" -}}
{{- if not .Values.acme.enabled }}
- name: ssl
  emptyDir: {}
- name: tls-secret
  secret:
    secretName: {{ include "mailcow.tlsSecretName" . }}
    defaultMode: 0400
    items:
      - key: tls.crt
        path: cert.pem
      - key: tls.key
        path: key.pem
{{- end }}
{{- end -}}

{{/* /etc/ssl/mail mounts. Secret mode: an emptyDir with dhparams.pem (files image) and
symlinks cert.pem/key.pem -> /etc/ssl/mail-tls/*, where the Secret is mounted as a whole
volume (not subPath), so renewed certificates show up without a pod restart. */}}
{{- define "mailcow.tlsMounts" -}}
{{- if .Values.acme.enabled }}
- name: shared
  subPath: ssl
  mountPath: /etc/ssl/mail
  readOnly: true
{{- else }}
- name: ssl
  mountPath: /etc/ssl/mail
  readOnly: true
- name: tls-secret
  mountPath: /etc/ssl/mail-tls
  readOnly: true
{{- end }}
{{- end -}}

{{/* ---------- seed initContainer ----------
Copies the pod's slice of data/ (paths relative to data/) from the files image into the `seed`
emptyDir at the same relative path, then extraFiles on top. Main containers mount
`seed` with subPath = the compose bind source minus ./data/, mirroring compose mounts exactly.
Args (dict):
  root      chart root
  slices    list of data/-relative paths copied into /seed
  shared    list of dicts {dir, src (data/-relative, optional), clobber (bool)} seeded into the shared PVC
  touch     list of shared-relative files that must exist (single-file subPath mounts)
  files     list of dicts {src (data/-relative), dst (shared-relative)}: copy the default only while
            dst is missing or empty, so UI edits survive restarts (single-file subPath mounts)
  ssl       true: prepare /etc/ssl/mail (Secret mode) or wait for the acme cert (acme mode)
  appends   list of dicts {key, dst}: append k8s-conf ConfigMap key to /seed/<dst>
  env       env entries (YAML string) for the script
  script    extra shell appended at the end */}}
{{- define "mailcow.seedInit" -}}
{{- $root := .root -}}
{{- $slices := .slices | default list -}}
{{- $shared := .shared | default list -}}
{{- $extra := include "mailcow.extraFileMap" $root | fromJson -}}
- name: seed
  image: {{ include "mailcow.filesImage" $root }}
  imagePullPolicy: {{ $root.Values.files.image.pullPolicy }}
  command: ["/bin/sh", "-ec"]
  args:
    - |
      seed() {
        if [ -d "/mailcow/data/$1" ]; then mkdir -p "/seed/$1"; cp -a "/mailcow/data/$1/." "/seed/$1/"
        elif [ -e "/mailcow/data/$1" ]; then mkdir -p "/seed/$(dirname "$1")"; cp -a "/mailcow/data/$1" "/seed/$1"
        else echo "warning: data/$1 not in files image, creating empty dir"; mkdir -p "/seed/$1"; fi
      }
      {{- range $slices }}
      seed {{ . | quote }}
      {{- end }}
      {{- range $path, $file := $extra }}
      {{- $hit := false }}
      {{- range $slices }}{{ if or (eq . $path) (hasPrefix (printf "%s/" .) $path) }}{{ $hit = true }}{{ end }}{{ end }}
      {{- if $hit }}
      mkdir -p {{ printf "/seed/%s" (dir $path) | squote }} && cp -L {{ $file | squote }} {{ printf "/seed/%s" $path | squote }}
      {{- if hasPrefix "hooks/" $path }}
      chmod 755 {{ printf "/seed/%s" $path | squote }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- range .appends }}
      grep -qs "added by the mailcow Helm chart" "/seed/{{ .dst }}" || cat "/k8s/{{ .key }}" >> "/seed/{{ .dst }}"
      {{- end }}
      {{- range $shared }}
      mkdir -p "/shared/{{ .dir }}"
      {{- if .src }}
      cp -a{{ if not .clobber }}n{{ end }} "/mailcow/data/{{ .src }}/." "/shared/{{ .dir }}/"
      {{- $s := . }}
      {{- range $path, $file := $extra }}
      {{- if hasPrefix (printf "%s/" $s.src) $path }}
      {{- $rel := trimPrefix (printf "%s/" $s.src) $path }}
      mkdir -p {{ printf "/shared/%s/%s" $s.dir (dir $rel) | squote }} && cp -L {{ $file | squote }} {{ printf "/shared/%s/%s" $s.dir $rel | squote }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- range .touch }}
      mkdir -p "/shared/{{ dir . }}" && touch "/shared/{{ . }}"
      {{- end }}
      {{- if .files }}
      seedfile() {
        d="/shared/$2"; t="$d.tmp.$(hostname)"
        [ -s "$d" ] && return 0
        mkdir -p "$(dirname "$d")"
        [ -e "$1" ] || { touch "$d"; return 0; }
        if [ ! -e "$d" ]; then
          cp "$1" "$t" && { ln "$t" "$d" 2>/dev/null || mv -n "$t" "$d"; }; rm -f "$t"
        fi
        [ -s "$d" ] || cat "$1" > "$d"
      }
      {{- range .files }}
      seedfile {{ get $extra .src | default (printf "/mailcow/data/%s" .src) | squote }} {{ .dst | squote }}
      {{- end }}
      {{- end }}
      {{- if .ssl }}
      {{- if $root.Values.acme.enabled }}
      until [ -s /shared/ssl/cert.pem ] && [ -s /shared/ssl/key.pem ]; do echo "waiting for acme to seed /shared/ssl"; sleep 2; done
      {{- else }}
      cp /mailcow/data/assets/ssl-example/dhparams.pem /ssl/dhparams.pem
      ln -sfn /etc/ssl/mail-tls/cert.pem /ssl/cert.pem
      ln -sfn /etc/ssl/mail-tls/key.pem /ssl/key.pem
      {{- end }}
      {{- end }}
      {{- with .script }}
      {{- . | nindent 6 }}
      {{- end }}
  {{- with .env }}
  env:
    {{- . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: seed
      mountPath: /seed
    - name: k8s-conf
      mountPath: /k8s
    {{- if $root.Values.extraFiles }}
    - name: extra-files
      mountPath: /extra
    {{- end }}
    {{- if $root.Values.extraSecretFiles }}
    - name: extra-secret-files
      mountPath: /extra-secret
      readOnly: true
    {{- end }}
    {{- if or $shared .touch .files (and .ssl $root.Values.acme.enabled) .sharedMount }}
    - name: shared
      mountPath: /shared
    {{- end }}
    {{- if and .ssl (not $root.Values.acme.enabled) }}
    - name: ssl
      mountPath: /ssl
    {{- end }}
    {{- range .extraMounts }}
    - {{ toYaml . | nindent 6 | trim }}
    {{- end }}
  resources:
    requests: {cpu: 10m, memory: 16Mi}
{{- end -}}

{{/* hooks mount (compose ./data/hooks/<svc>:/hooks) */}}
{{- define "mailcow.hooksMount" -}}
- name: seed
  subPath: hooks/{{ . }}
  mountPath: /hooks
{{- end -}}

{{/* ---------- SOGo credential files ----------
dovecot's entrypoint writes sieve.creds, cron.creds (into /etc/sogo) and sogo-sso.pass (into
/etc/phpfpm) on every start, from DOVECOT_MASTER_USER/PASS and SOGO_SSO_PASS. The sogo and php-fpm
pods derive the same bytes from the same Secret keys in their seed initContainer (same unquoted
echo / echo -n as the entrypoint), so nothing is shared with the dovecot pod. */}}
{{- define "mailcow.sogoCredsEnv" -}}
{{ include "mailcow.secretEnv" (list . "DOVECOT_MASTER_USER" "DOVECOT_MASTER_USER") }}
{{ include "mailcow.secretEnv" (list . "DOVECOT_MASTER_PASS" "DOVECOT_MASTER_PASS") }}
{{ include "mailcow.secretEnv" (list . "SOGO_SSO_PASS" "SOGO_SSO_PASS") }}
{{ include "mailcow.secretEnv" (list . "SOGO_ENCRYPTION_KEY" "SOGO_ENCRYPTION_KEY") }}
{{- end -}}

{{/* charset of SOGO_SSO_PASS (dovecot exits otherwise), shared by the sogo and php-fpm seed scripts */}}
{{- define "mailcow.sogoSsoCheck" -}}
case "${SOGO_SSO_PASS}" in
  ""|*[!A-Za-z0-9]*) echo "SOGO_SSO_PASS in Secret {{ include "mailcow.secretName" . }} must be non-empty and alphanumeric only ([A-Za-z0-9]); dovecot refuses to start otherwise"; exit 1 ;;
esac
{{- end -}}

{{/* /seed/conf/sogo/{sieve.creds,cron.creds} (sogo pod) */}}
{{- define "mailcow.sogoCredsScript" -}}
if [ -z "${DOVECOT_MASTER_USER}" ] || [ -z "${DOVECOT_MASTER_PASS}" ]; then
  echo "DOVECOT_MASTER_USER and DOVECOT_MASTER_PASS must be set in Secret {{ include "mailcow.secretName" . }}"; exit 1
fi
{{ include "mailcow.sogoSsoCheck" . }}
case "${SOGO_ENCRYPTION_KEY}" in
  ""|*[!A-Za-z0-9_-]*) echo "SOGO_ENCRYPTION_KEY in Secret {{ include "mailcow.secretName" . }} must be non-empty and use only [A-Za-z0-9_-]; sogo refuses to start otherwise"; exit 1 ;;
esac
mkdir -p /seed/conf/sogo
echo ${DOVECOT_MASTER_USER}@mailcow.local:${DOVECOT_MASTER_PASS} > /seed/conf/sogo/sieve.creds
echo -n ${DOVECOT_MASTER_USER}@mailcow.local:${SOGO_SSO_PASS} > /seed/conf/sogo/cron.creds
{{- end -}}

{{/* /seed/conf/phpfpm/sogo-sso/sogo-sso.pass (php-fpm pod, compose ./data/conf/phpfpm/sogo-sso) */}}
{{- define "mailcow.sogoSsoScript" -}}
{{ include "mailcow.sogoSsoCheck" . }}
mkdir -p /seed/conf/phpfpm/sogo-sso
echo -n ${SOGO_SSO_PASS} > /seed/conf/phpfpm/sogo-sso/sogo-sso.pass
{{- end -}}

{{/* ---------- rspamd controller socket relay ----------
rspamd's controller trusts its unix socket (worker-controller.inc). Instead of sharing the socket's
directory across pods, the rspamd pod exposes it on TCP 11335 with mutual TLS (socat sidecar
`rspamd-sock-relay`: only clients with a certificate from the relay CA get through; the NetworkPolicy
additionally limits 11335 to the socket's users) and every user pod gets a local
/var/lib/rspamd/rspamd.sock from a socat sidecar `rspamd-sock` connecting there with the client
certificate. Secret: <fullname>-rspamd-relay-tls (rspamd.yaml) or rspamd.socketRelay.tls.existingSecret,
keys ca.crt, tls.crt/tls.key (server), client.crt/client.key. */}}

{{/* uid/gid of the relay sidecars: used by no mailcow image (postfix 101, dovecot 401/402/5000,
sogo 999, nobody 65534 runs imapsync inside dovecot), so they share no uid with the processes they
can see in a shared process namespace */}}
{{- define "mailcow.helperUid" -}}10900{{- end -}}

{{- define "mailcow.relaySecurityContext" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ include "mailcow.helperUid" . }}
  runAsGroup: {{ include "mailcow.helperUid" . }}
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{- define "mailcow.rspamdRelayTlsSecret" -}}
{{- default (printf "%s-rspamd-relay-tls" (include "mailcow.fullname" .)) .Values.rspamd.socketRelay.tls.existingSecret -}}
{{- end -}}

{{/* relay TLS volume; side "server" (rspamd pod) or "client". Mode 0444: the relay runs as
mailcow.helperUid and Secret files are root-owned; only the relay container mounts it.
include "mailcow.rspamdRelayTlsVolume" (dict "root" . "side" "client") */}}
{{- define "mailcow.rspamdRelayTlsVolume" -}}
- name: rspamd-relay-tls
  secret:
    secretName: {{ include "mailcow.rspamdRelayTlsSecret" .root }}
    defaultMode: 0444
    items:
      - key: ca.crt
        path: ca.crt
      {{- if eq .side "server" }}
      - key: tls.crt
        path: tls.crt
      - key: tls.key
        path: tls.key
      {{- else }}
      - key: client.crt
        path: client.crt
      - key: client.key
        path: client.key
      {{- end }}
{{- end -}}

{{/* client side: native sidecar (initContainer, restartPolicy Always) + emptyDir `rspamd-sock`.
socat verifies the server certificate against the relay CA and the Service FQDN (in its SANs). */}}
{{- define "mailcow.rspamdSockSidecar" -}}
{{- $t := "/etc/rspamd-relay-tls" -}}
- name: rspamd-sock
  image: {{ include "mailcow.filesImage" . }}
  imagePullPolicy: {{ .Values.files.image.pullPolicy }}
  restartPolicy: Always
  command: ["socat"]
  args:
    # -d0: errors only (no per-connection OpenSSL CRL warning)
    - -d0
    - UNIX-LISTEN:/var/lib/rspamd/rspamd.sock,fork,mode=0666,unlink-early
    # resolved per connection (A and AAAA, tried in order); FQDN works with unbound-only pod DNS too
    - {{ printf "OPENSSL:%s:11335,cert=%s/client.crt,key=%s/client.key,cafile=%s/ca.crt,verify=1" (include "mailcow.svcFqdn" (list . "rspamd-mailcow")) $t $t $t }}
  {{- include "mailcow.relaySecurityContext" . | nindent 2 }}
  startupProbe:
    exec:
      command: ["test", "-S", "/var/lib/rspamd/rspamd.sock"]
    periodSeconds: 2
    failureThreshold: 30
  volumeMounts:
    - name: rspamd-sock
      mountPath: /var/lib/rspamd
    - name: rspamd-relay-tls
      mountPath: {{ $t }}
      readOnly: true
  resources:
    {{- toYaml .Values.rspamd.socketRelay.resources | nindent 4 }}
{{- end -}}

{{- define "mailcow.rspamdSockVolume" -}}
- name: rspamd-sock
  emptyDir: {}
{{ include "mailcow.rspamdRelayTlsVolume" (dict "root" . "side" "client") }}
{{- end -}}

{{/* ---------- probes ---------- */}}
{{/* include "mailcow.probes" (dict "handler" (dict "exec" (dict "command" (list ...))) "startup" 60 "ready" 20 "live" 30 "timeout" 5)
startup = failureThreshold * 10s; ready/live = periodSeconds (default 10/20); timeout for startup/readiness */}}
{{- define "mailcow.probes" -}}
{{- $h := toYaml .handler -}}
startupProbe:
  {{- $h | nindent 2 }}
  periodSeconds: 10
  {{- with .timeout }}
  timeoutSeconds: {{ . }}
  {{- end }}
  failureThreshold: {{ .startup | default 60 }}
readinessProbe:
  {{- $h | nindent 2 }}
  periodSeconds: {{ .ready | default 10 }}
  {{- with .timeout }}
  timeoutSeconds: {{ . }}
  {{- end }}
  failureThreshold: 3
livenessProbe:
  {{- $h | nindent 2 }}
  periodSeconds: {{ .live | default 20 }}
  timeoutSeconds: 5
  failureThreshold: 6
{{- end -}}

{{/* include "mailcow.tcpProbes" (dict "port" 143 "startup" 60) */}}
{{- define "mailcow.tcpProbes" -}}
{{- include "mailcow.probes" (dict "handler" (dict "tcpSocket" (dict "port" .port)) "startup" .startup) -}}
{{- end -}}

{{/* ---------- exec CronJobs ---------- */}}
{{/* include "mailcow.execCronJob" (dict "root" $ "job" "name" "schedule" "* * * * *" "target" "dovecot"
  "steps" (list (dict "name" "kubectl" "kind" "statefulset" "comp" "dovecot" "command" (list ...))))
One CronJob; every step is a container running `kubectl exec <kind>/<fullname>-<comp> -c <comp>-mailcow -- <command>`.
Containers run side by side and independently; the pod (and Job) fails if any of them fails. */}}
{{- define "mailcow.execCronJob" -}}
{{- $root := .root -}}
{{- $fullname := include "mailcow.fullname" $root -}}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ $fullname }}-{{ .job }}
  labels:
    {{- include "mailcow.labels" (dict "root" $root "component" "cron") | nindent 4 }}
    mailcow.email/cron-target: {{ .target }}
spec:
  schedule: {{ .schedule | quote }}
  timeZone: {{ $root.Values.mailcow.tz | quote }}
  # ofelia no-overlap
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 120
  successfulJobsHistoryLimit: {{ $root.Values.cronjobs.successfulJobsHistoryLimit }}
  failedJobsHistoryLimit: {{ $root.Values.cronjobs.failedJobsHistoryLimit }}
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: {{ $root.Values.cronjobs.ttlSecondsAfterFinished }}
      template:
        metadata:
          labels:
            {{- include "mailcow.selectorLabels" (dict "root" $root "component" "cron") | nindent 12 }}
            mailcow.email/cron-job: {{ .job }}
          {{- with include "mailcow.podDefaultAnnotations" $root }}
          {{- . | nindent 10 }}
          {{- end }}
        spec:
          serviceAccountName: {{ $fullname }}-cron
          automountServiceAccountToken: true
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
          {{- include "mailcow.podCommon" (dict "root" $root) | nindent 10 }}
          containers:
            {{- range .steps }}
            - name: {{ .name }}
              image: {{ include "mailcow.image" $root.Values.cronjobs.image }}
              imagePullPolicy: {{ $root.Values.cronjobs.image.pullPolicy }}
              args:
                - exec
                - {{ printf "%s/%s-%s" .kind $fullname .comp }}
                - -c
                - {{ printf "%s-mailcow" .comp }}
                - --
                {{- range .command }}
                - {{ . | quote }}
                {{- end }}
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: {cpu: 10m, memory: 32Mi}
            {{- end }}
{{- end -}}

{{/* ---------- Deployment update strategy ----------
spec.strategy of a Deployment. RollingUpdate always carries rollingUpdate (the API server defaults), so
Helm owns it: server-side apply only removes fields it owns, and a later switch to Recreate drops it.
include "mailcow.strategy" "Recreate" */}}
{{- define "mailcow.strategy" -}}
strategy:
{{- if eq . "Recreate" }}
  type: Recreate
{{- else if eq . "RollingUpdate" }}
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 25%
{{- else }}
{{- fail (printf "unknown Deployment strategy %q" .) }}
{{- end }}
{{- end -}}

{{/* NetworkPolicy egress rule to the Kubernetes API server (networkPolicy.egress) */}}
{{- define "mailcow.apiServerEgress" -}}
- to:
    {{- range .apiServerCIDRs }}
    - ipBlock:
        cidr: {{ ternary . (printf "%s/%s" . (ternary "128" "32" (contains ":" .))) (contains "/" .) }}
    {{- end }}
  ports:
    {{- range .apiServerPorts }}
    - port: {{ int . }}
      protocol: TCP
    {{- end }}
{{- end -}}

{{/* postfix StatefulSet name: <fullname>-postfix (single queue PVC) or <fullname>-postfix-spool
(postfix.spoolPerPod, volumeClaimTemplates). One name per mode: switching creates a new StatefulSet and
Helm deletes the old one, instead of changing the immutable volume spec in place. */}}
{{- define "mailcow.postfixName" -}}
{{- printf "%s-postfix%s" (include "mailcow.fullname" .) (ternary "-spool" "" (eq (toString .Values.postfix.spoolPerPod) "true")) -}}
{{- end -}}

{{/* ---------- scaling ----------
v = the component's values (replicas, optional autoscaling). "true" when the workload may run more
than one pod: replicas > 1 or an HPA. include "mailcow.multi" $v */}}
{{- define "mailcow.multi" -}}
{{- $a := .autoscaling | default dict -}}
{{- if or $a.enabled (gt (int .replicas) 1) -}}true{{- end -}}
{{- end -}}

{{/* spec.replicas, omitted when an HPA owns it. include "mailcow.replicas" (dict "v" $v "key" "nginx") */}}
{{- define "mailcow.replicas" -}}
{{- $a := .v.autoscaling | default dict -}}
{{- if lt (int .v.replicas) 0 -}}{{- fail (printf "%s.replicas must be >= 0" .key) -}}{{- end -}}
{{- if $a.enabled -}}
{{- if ne (int .v.replicas) 1 -}}
{{- fail (printf "%s: set either %s.replicas or %s.autoscaling.enabled (the HPA owns the replica count), not both" .key .key .key) -}}
{{- end -}}
{{- if or (lt (int $a.minReplicas) 1) (lt (int $a.maxReplicas) (int $a.minReplicas)) -}}
{{- fail (printf "%s.autoscaling: need 1 <= minReplicas <= maxReplicas" .key) -}}
{{- end -}}
{{- else -}}
replicas: {{ int .v.replicas }}
{{- end -}}
{{- end -}}

{{/* topologySpreadConstraints over nodes (soft). Only for replicated pods without a volume that pins
them to one node (RWO shared PVC affinity, sogo's RWO backup volume). include "mailcow.spread" (dict "root" . "component" "nginx") */}}
{{- define "mailcow.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "mailcow.selectorLabels" (dict "root" .root "component" .component) | nindent 8 }}
{{- end -}}

{{/* PodDisruptionBudget (maxUnavailable 1) when the workload is replicated; none for singletons.
include "mailcow.pdb" (dict "root" . "v" $v "component" "nginx") */}}
{{- define "mailcow.pdb" -}}
{{- if include "mailcow.multi" .v }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "mailcow.fullname" .root }}-{{ .component }}
  labels:
    {{- include "mailcow.labels" (dict "root" .root "component" .component) | nindent 4 }}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      {{- include "mailcow.selectorLabels" (dict "root" .root "component" .component) | nindent 6 }}
{{- end }}
{{- end -}}

{{/* HorizontalPodAutoscaler on CPU for a Deployment. include "mailcow.hpa" (dict "root" . "v" $v "component" "nginx") */}}
{{- define "mailcow.hpa" -}}
{{- $a := .v.autoscaling | default dict -}}
{{- if $a.enabled }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "mailcow.fullname" .root }}-{{ .component }}
  labels:
    {{- include "mailcow.labels" (dict "root" .root "component" .component) | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "mailcow.fullname" .root }}-{{ .component }}
  minReplicas: {{ int $a.minReplicas }}
  maxReplicas: {{ int $a.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ int $a.targetCPUUtilizationPercentage }}
{{- end }}
{{- end -}}

{{/* ---------- backups ---------- */}}
{{- define "mailcow.backupImage" -}}
{{- $i := .Values.backup.image -}}
{{- printf "%s:%s" $i.repository (toString $i.tag) -}}{{- with $i.digest -}}@{{ . }}{{- end -}}
{{- end -}}

{{/* env of every backup container; retention + info only for the group that runs mailcow.backupFinish.
include "mailcow.backupEnv" (dict "root" . "group" "mail" "first" true) */}}
{{- define "mailcow.backupEnv" -}}
{{- $root := .root -}}
{{- $b := $root.Values.backup -}}
- name: JOB_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['batch.kubernetes.io/job-name']
- name: BACKUP_GROUP
  value: {{ .group | quote }}
- name: THREADS
  value: {{ int $b.threads | quote }}
{{- if .first }}
- name: RETENTION_DAYS
  value: {{ int $b.retentionDays | quote }}
- name: KEEP
  value: {{ int $b.keep | quote }}
- name: BACKUP_INFO
  value: |
    # mailcow Helm chart backup. Not needed for a restore; the release Secret is NOT part of the backup.
    release={{ $root.Release.Name }}
    namespace={{ $root.Release.Namespace }}
    chart={{ include "mailcow.chart" $root }}
    app_version={{ $root.Chart.AppVersion }}
    hostname={{ $root.Values.mailcow.hostname }}
    dbname={{ $root.Values.mailcow.dbName }}
    dbuser={{ $root.Values.mailcow.dbUser }}
    external_database={{ $root.Values.externalDatabase.enabled }}
    external_redis={{ $root.Values.externalRedis.enabled }}
    mysql_image={{ include "mailcow.image" $root.Values.mysql.image }}
    redis_image={{ include "mailcow.image" $root.Values.redis.image }}
    dovecot_image={{ include "mailcow.image" $root.Values.dovecot.image }}
{{- end }}
{{- end -}}

{{/* bash: sets $dir = /backup/mailcow-YYYY-MM-DD-HH-MM-SS (UTC, mode 700, files 600). CronJob Jobs are named
<cronjob>-<scheduled time in minutes since the epoch>, so every group of one run picks the same
directory; any other Job name (kubectl create job --from=cronjob/...) uses the current time. */}}
{{- define "mailcow.backupPrelude" -}}
set -euo pipefail
# archives hold the mail_crypt private keys and the database: owner-only directories and files
umask 077
n="${JOB_NAME##*-}"
if [[ "${n}" =~ ^[0-9]{8,10}$ ]]; then stamp=$(date -u -d "@$(( n * 60 ))" +%Y-%m-%d-%H-%M-%S)
else stamp=$(date -u +%Y-%m-%d-%H-%M-%S); fi
dir="/backup/mailcow-${stamp}"
mkdir -p "${dir}"
chmod 700 "${dir}"
echo "backup ${BACKUP_GROUP} -> mailcow-${stamp}"
{{- end -}}

{{/* bash, first enabled group only: info file + retention (backup.retentionDays by the time in the
directory name, backup.keep newest directories). Never touches the current directory. */}}
{{- define "mailcow.backupFinish" -}}
printf '%s' "${BACKUP_INFO}" > "${dir}/mailcow-helm.info"
cd /backup
mapfile -t runs < <(find . -mindepth 1 -maxdepth 1 -type d -name 'mailcow-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' -printf '%f\n' | sort)
now=$(date -u +%s); i=0
for d in "${runs[@]}"; do
  i=$(( i + 1 ))
  [ "${d}" = "mailcow-${stamp}" ] && continue
  why=""
  if [ "${KEEP}" -gt 0 ] && [ $(( ${#runs[@]} - i )) -ge "${KEEP}" ]; then why="more than ${KEEP} backups"; fi
  if [ "${RETENTION_DAYS}" -gt 0 ]; then
    t=${d#mailcow-}
    t=$(date -u -d "${t:0:10} ${t:11:2}:${t:14:2}:${t:17:2}" +%s)
    if [ $(( now - t )) -gt $(( RETENTION_DAYS * 86400 )) ]; then why="older than ${RETENTION_DAYS} days"; fi
  fi
  if [ -n "${why}" ]; then echo "prune ${d} (${why})"; rm -rf -- "/backup/${d}"; fi
done
{{- end -}}

{{/* ---------- TLS reload sidecar ----------
"true" when nginx, postfix and dovecot get the `tls-reload` sidecar: certificate from a Secret
(cert-manager / existingSecret / self-signed) and tls.reload.enabled. With acme, the acme container
reloads the daemons through dockerapi. */}}
{{- define "mailcow.tlsReload" -}}
{{- if and .Values.tls.reload.enabled (not .Values.acme.enabled) -}}true{{- end -}}
{{- end -}}

{{/* Native sidecar (files image) that hashes the mounted TLS Secret every tls.reload.interval seconds and
sends SIGHUP to its own pod's master process when cert or key changed (nginx/postfix/dovecot HUP = graceful
reload, what `nginx -s reload`, `postfix reload` and `doveadm reload` send). Needs shareProcessNamespace.
The masters run as root: the sidecar runs as uid 0 to be allowed to signal them (same uid, no capability).
What it can do in the shared process namespace: list every process of the pod and read the world-readable
/proc/<pid>/{comm,cmdline,status}; signal uid-0 processes. It cannot read another process's environ, memory
or files through /proc/<pid>/root: with no capabilities its permitted set is not a superset of the root
daemons' (the kernel's ptrace access check), and other uids (relay 10900, postfix, dovecot, nobody) differ
from 0 without CAP_SYS_PTRACE. Acceptable: a fixed busybox loop from the chart, no input but the mounted
Secret, no network listener, read-only root filesystem, no privilege escalation. README "TLS".
include "mailcow.tlsReloadSidecar" (dict "root" . "comm" "master" "cmdline" "/usr/lib/postfix/sbin/master*") */}}
{{- define "mailcow.tlsReloadSidecar" -}}
{{- $root := .root -}}
{{- $r := $root.Values.tls.reload -}}
{{- if lt (int $r.interval) 10 -}}{{- fail "tls.reload.interval must be >= 10 (seconds)" -}}{{- end -}}
- name: tls-reload
  image: {{ include "mailcow.filesImage" $root }}
  imagePullPolicy: {{ $root.Values.files.image.pullPolicy }}
  restartPolicy: Always
  command: ["/bin/sh", "-c"]
  args:
    - |
      trap 'exit 0' TERM INT
      sum() { cat /etc/ssl/mail-tls/cert.pem /etc/ssl/mail-tls/key.pem 2>/dev/null | sha256sum | cut -d' ' -f1; }
      master() {
        for d in /proc/[0-9]*; do
          [ "$(cat "$d/comm" 2>/dev/null)" = "${RELOAD_COMM}" ] || continue
          case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in ${RELOAD_CMDLINE}) echo "${d#/proc/}"; return 0;; esac
        done
        return 1
      }
      last=$(sum)
      echo "watching /etc/ssl/mail-tls every ${RELOAD_INTERVAL}s, SIGHUP to ${RELOAD_COMM} on change"
      while :; do
        sleep "${RELOAD_INTERVAL}" & wait $!
        now=$(sum)
        [ "${now}" = "${last}" ] && continue
        if pid=$(master) && kill -HUP "${pid}"; then
          echo "certificate changed: SIGHUP to ${RELOAD_COMM} (pid ${pid})"
          last=${now}
        else
          echo "certificate changed but no ${RELOAD_COMM} master process found, retrying"
        fi
      done
  env:
    - name: RELOAD_INTERVAL
      value: {{ int $r.interval | quote }}
    - name: RELOAD_COMM
      value: {{ .comm | quote }}
    - name: RELOAD_CMDLINE
      value: {{ .cmdline | quote }}
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    runAsNonRoot: false
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
  volumeMounts:
    - name: tls-secret
      mountPath: /etc/ssl/mail-tls
      readOnly: true
  resources:
    {{- toYaml $r.resources | nindent 4 }}
{{- end -}}
