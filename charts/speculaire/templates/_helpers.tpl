{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "speculaire.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "speculaire.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Name of a DaemonSet: `.component` (agent or reflector) after the fullname,
cut so that both names stay distinct within 63 characters.
*/}}
{{- define "speculaire.componentName" -}}
{{- printf "%s-%s" (include "speculaire.fullname" .root | trunc 53 | trimSuffix "-") .component }}
{{- end }}

{{/*
Chart label value.
*/}}
{{- define "speculaire.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key. Each DaemonSet
adds app.kubernetes.io/component.
*/}}
{{- define "speculaire.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "speculaire.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "speculaire.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "speculaire.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "speculaire.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "speculaire.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "speculaire.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Tag empty: appVersion, pinned by the digest recorded in the
artifacthub.io/images annotation of Chart.yaml (only when image.repository is
the one the annotation names). Tag set: that tag, plus image.digest if given;
the chart digest never applies to a user-chosen tag.
*/}}
{{- define "speculaire.image" -}}
{{- $repo := .Values.image.repository }}
{{- if .Values.image.tag }}
{{- if .Values.image.digest }}
{{- printf "%s:%s@%s" $repo .Values.image.tag .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo .Values.image.tag }}
{{- end }}
{{- else }}
{{- $images := fromYamlArray (index .Chart.Annotations "artifacthub.io/images" | default "") }}
{{- if not $images }}
{{- fail "Chart.yaml: annotation artifacthub.io/images is missing, it holds the pinned image digest" }}
{{- end }}
{{- $ref := splitList "@" (first $images).image }}
{{- if and (eq (len $ref) 2) (hasPrefix (printf "%s:" $repo) (first $ref)) }}
{{- printf "%s:%s@%s" $repo .Chart.AppVersion (last $ref) }}
{{- else }}
{{- printf "%s:%s" $repo .Chart.AppVersion }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Image of the reflector DaemonSet: reflector.image.tag (and digest) on
image.repository, or the agents' image when the tag is empty. Upgrading the
reflectors first (a protocol bump) sets this tag alone.
*/}}
{{- define "speculaire.reflectorImage" -}}
{{- with .Values.reflector.image }}
{{- if .tag }}
{{- if .digest }}
{{- printf "%s:%s@%s" $.Values.image.repository .tag .digest }}
{{- else }}
{{- printf "%s:%s" $.Values.image.repository .tag }}
{{- end }}
{{- else }}
{{- include "speculaire.image" $ }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Node directories and files the pods mount, each at its node path so that the
agent's default paths hold (packaging/config.toml in spnngl/speculaire).
Directories, never sockets: a runtime restart makes a new socket, and a socket
mount keeps the dead inode. /var/lib/kubelet/pki is a directory too: the
kubelet repoints its kubelet-client-current.pem symlink on rotation. Of the
cluster PKI only ca.crt: on a control-plane node the directory holds the CA
and etcd keys. Returns a YAML list of {name, path, type, readOnly}.
*/}}
{{- define "speculaire.hostPaths" -}}
{{- $paths := list
  (dict "name" "nri" "path" "/var/run/nri" "type" "DirectoryOrCreate" "readOnly" true)
  (dict "name" "kubelet-pki" "path" "/var/lib/kubelet/pki" "type" "Directory" "readOnly" true)
  (dict "name" "cluster-ca" "path" "/etc/kubernetes/pki/ca.crt" "type" "File" "readOnly" true)
  (dict "name" "state" "path" "/var/lib/speculaire" "type" "DirectoryOrCreate" "readOnly" false)
  (dict "name" "run" "path" "/run/speculaire" "type" "DirectoryOrCreate" "readOnly" false) }}
{{- if eq .Values.runtime "containerd" }}
{{- $paths = concat $paths (list
  (dict "name" "runtime-socket" "path" "/run/containerd" "type" "Directory" "readOnly" true)
  (dict "name" "runtime-config" "path" "/etc/containerd" "type" "Directory" "readOnly" true)
  (dict "name" "runtime-hosts" "path" "/etc/containerd/certs.d" "type" "DirectoryOrCreate" "readOnly" false)
  (dict "name" "runtime-content" "path" "/var/lib/containerd/io.containerd.content.v1.content" "type" "Directory" "readOnly" true)) }}
{{- else }}
{{- $paths = concat $paths (list
  (dict "name" "runtime-socket" "path" "/var/run/crio" "type" "Directory" "readOnly" true)
  (dict "name" "runtime-config" "path" "/etc/containers" "type" "Directory" "readOnly" true)
  (dict "name" "runtime-registries" "path" "/etc/containers/registries.conf.d" "type" "DirectoryOrCreate" "readOnly" false)
  (dict "name" "runtime-certs" "path" "/etc/containers/certs.d" "type" "DirectoryOrCreate" "readOnly" false)
  (dict "name" "runtime-images" "path" "/var/lib/containers/storage/overlay-images" "type" "Directory" "readOnly" true)) }}
{{- end }}
{{- if eq .Values.config.source "host" }}
{{- $paths = append $paths (dict "name" "config" "path" "/etc/speculaire" "type" "Directory" "readOnly" true) }}
{{- end }}
{{- if .Values.hostTrustStore.enabled }}
{{- range $i, $path := .Values.hostTrustStore.paths }}
{{- $paths = append $paths (dict "name" (printf "trust-store-%d" $i) "path" $path "type" "DirectoryOrCreate" "readOnly" true) }}
{{- end }}
{{- end }}
{{- toYaml $paths }}
{{- end }}

{{/*
The agent config (config.toml) parsed, so the guards can read it.
*/}}
{{- define "speculaire.parsedConfig" -}}
{{- toJson (fromToml .Values.config.toml) }}
{{- end }}

{{/*
Settings the schema cannot express. Included by daemonset.yaml, which is
always rendered.
*/}}
{{- define "speculaire.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.reflector.image.digest (not .Values.reflector.image.tag) }}
{{- fail "reflector.image.digest requires reflector.image.tag: without a tag the reflectors run the agents' image" }}
{{- end }}
{{- if and (eq .Values.updateStrategy.type "RollingUpdate") (has (toString .Values.updateStrategy.rollingUpdate.maxUnavailable) (list "0" "0%")) }}
{{- fail "updateStrategy.rollingUpdate.maxUnavailable must not be 0: a DaemonSet cannot surge, so no node would ever be updated" }}
{{- end }}
{{- if eq .Values.config.source "host" }}
{{- if or .Values.config.toml .Values.config.policy .Values.config.trustedRoot }}
{{- fail "config.source host reads /etc/speculaire from each node: leave config.toml, config.policy and config.trustedRoot empty, or set config.source to configMap" }}
{{- end }}
{{- else }}
{{- $config := include "speculaire.parsedConfig" . | fromJson }}
{{- if hasKey $config "Error" }}
{{- fail (printf "config.toml is not valid TOML: %s" $config.Error) }}
{{- end }}
{{- if hasKey $config "role" }}
{{- fail "config.toml must not set role: the chart sets role = \"reflector\" on the reflector DaemonSet and leaves the agents at the default" }}
{{- end }}
{{- $trustedRoot := dig "verify" "trusted_root" "" $config }}
{{- if and .Values.config.trustedRoot (ne $trustedRoot "/etc/speculaire/trusted_root.json") }}
{{- fail "config.trustedRoot needs verify.trusted_root = \"/etc/speculaire/trusted_root.json\" in config.toml: the agent pins only the root its config names" }}
{{- end }}
{{- if and (not .Values.config.trustedRoot) (eq $trustedRoot "/etc/speculaire/trusted_root.json") }}
{{- fail "config.toml sets verify.trusted_root = \"/etc/speculaire/trusted_root.json\": set config.trustedRoot, the file the ConfigMap would hold there" }}
{{- end }}
{{- end }}
{{- end }}
