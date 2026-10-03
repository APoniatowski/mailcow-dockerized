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
  value: "3306"
{{- end -}}

{{- define "mailcow.networks" -}}
{{- .Values.mailcow.networks -}}
{{- end -}}

{{- define "mailcow.sogoTrustedNets" -}}
{{- default .Values.mailcow.networks .Values.mailcow.sogoTrustedNets -}}
{{- end -}}

{{/* rspamd DOVECOT_TRUSTED_NETS / RSPAMD_TRUSTED_NETS: always set, unset makes rspamd loop on `dig dovecot` */}}
{{- define "mailcow.dovecotTrustedNets" -}}
{{- default .Values.mailcow.networks .Values.mailcow.dovecotTrustedNets -}}
{{- end -}}

{{- define "mailcow.rspamdTrustedNets" -}}
{{- default .Values.mailcow.networks .Values.mailcow.rspamdTrustedNets -}}
{{- end -}}

{{/* FQDN of a release Service: include "mailcow.svcFqdn" (list . "postfix") */}}
{{- define "mailcow.svcFqdn" -}}
{{- $root := index . 0 -}}
{{- printf "%s.%s.svc.%s" (index . 1) $root.Release.Namespace $root.Values.clusterDomain -}}
{{- end -}}

{{/* "true" when the NetworkPolicies are rendered (networkPolicy.enabled; empty = mail.proxyProtocol) */}}
{{- define "mailcow.networkPolicy" -}}
{{- $e := toString .Values.networkPolicy.enabled -}}
{{- if eq $e "true" -}}true
{{- else if and (ne $e "false") .Values.mail.proxyProtocol -}}true
{{- end -}}
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

{{/* ---------- volumes ---------- */}}
{{- define "mailcow.claimName" -}}
{{- $root := index . 0 -}}{{- $key := index . 1 -}}{{- $suffix := index . 2 -}}
{{- $p := index $root.Values.persistence $key -}}
{{- default (printf "%s-%s" (include "mailcow.fullname" $root) $suffix) $p.existingClaim -}}
{{- end -}}

{{- define "mailcow.sharedClaim" -}}
{{- include "mailcow.claimName" (list . "shared" "shared") -}}
{{- end -}}

{{/* seed emptyDir + extraFiles ConfigMap + chart ConfigMap (+ shared PVC) */}}
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
  ssl       true: prepare /etc/ssl/mail (Secret mode) or wait for the acme cert (acme mode)
  appends   list of dicts {key, dst}: append k8s-conf ConfigMap key to /seed/<dst>
  script    extra shell appended at the end */}}
{{- define "mailcow.seedInit" -}}
{{- $root := .root -}}
{{- $slices := .slices | default list -}}
{{- $shared := .shared | default list -}}
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
      {{- range $path, $_ := $root.Values.extraFiles }}
      {{- $hit := false }}
      {{- range $slices }}{{ if or (eq . $path) (hasPrefix (printf "%s/" .) $path) }}{{ $hit = true }}{{ end }}{{ end }}
      {{- if $hit }}
      mkdir -p "/seed/{{ dir $path }}" && cp -L "/extra/{{ $path }}" "/seed/{{ $path }}"
      {{- if hasPrefix "hooks/" $path }}
      chmod 755 "/seed/{{ $path }}"
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
      {{- range $path, $_ := $root.Values.extraFiles }}
      {{- if hasPrefix (printf "%s/" $s.src) $path }}
      {{- $rel := trimPrefix (printf "%s/" $s.src) $path }}
      mkdir -p "/shared/{{ $s.dir }}/{{ dir $rel }}" && cp -L "/extra/{{ $path }}" "/shared/{{ $s.dir }}/{{ $rel }}"
      {{- end }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- range .touch }}
      mkdir -p "/shared/{{ dir . }}" && touch "/shared/{{ . }}"
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
  volumeMounts:
    - name: seed
      mountPath: /seed
    - name: k8s-conf
      mountPath: /k8s
    {{- if $root.Values.extraFiles }}
    - name: extra-files
      mountPath: /extra
    {{- end }}
    {{- if or $shared .touch (and .ssl $root.Values.acme.enabled) .sharedMount }}
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

{{/* ---------- probes ---------- */}}
{{/* include "mailcow.tcpProbes" (dict "port" 143 "startup" 60) ; startup = failureThreshold * 10s */}}
{{- define "mailcow.tcpProbes" -}}
startupProbe:
  tcpSocket:
    port: {{ .port }}
  periodSeconds: 10
  failureThreshold: {{ .startup | default 60 }}
readinessProbe:
  tcpSocket:
    port: {{ .port }}
  periodSeconds: 10
  failureThreshold: 3
livenessProbe:
  tcpSocket:
    port: {{ .port }}
  periodSeconds: 20
  timeoutSeconds: 5
  failureThreshold: 6
{{- end -}}
