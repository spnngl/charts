{{/*
A DaemonSet of `.component` (agent or reflector), on the nodes that
component runs on. With `.hook`, the pre-delete hook's twin
(uninstall-hook.yaml): its init container runs `unconfigure` instead of
`configure`, and its container sleeps until the hook is deleted.
*/}}
{{- define "speculaire.daemonSet" -}}
{{- $root := .root }}
{{- $component := .component }}
{{- $hook := .hook }}
{{- $hostPaths := include "speculaire.hostPaths" $root | fromYamlArray }}
{{- $configMap := eq $root.Values.config.source "configMap" }}
{{- $volumeMounts := list }}
{{- if $configMap }}
{{- $volumeMounts = append $volumeMounts (dict "mountPath" "/etc/speculaire" "name" "config" "readOnly" true) }}
{{- end }}
{{- range $hostPaths }}
{{- $mount := dict "mountPath" .path "name" .name "readOnly" .readOnly }}
{{- /* A read-only hostPath is read-only below too: /run/containerd holds every container's rootfs and shm mounts. */}}
{{- if .readOnly }}
{{- $_ := set $mount "recursiveReadOnly" "IfPossible" }}
{{- end }}
{{- $volumeMounts = append $volumeMounts $mount }}
{{- end }}
{{- $volumeMounts = concat $volumeMounts $root.Values.extraVolumeMounts }}
{{- $reflector := eq $component "reflector" }}
{{- $config := ternary "/etc/speculaire/reflector.toml" "/etc/speculaire/config.toml" (and $reflector $configMap) }}
{{- $image := ternary (include "speculaire.reflectorImage" $root) (include "speculaire.image" $root) $reflector }}
{{- $name := include "speculaire.componentName" (dict "root" $root "component" $component) }}
{{- $labelComponent := $component }}
{{- if $hook }}
{{- $name = printf "%s-unconfigure" $name }}
{{- $labelComponent = printf "unconfigure-%s" $component }}
{{- end }}
{{- $labels := merge (dict "app.kubernetes.io/component" $labelComponent) (include "speculaire.labels" $root | fromYaml) }}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  annotations:
    {{- if $hook }}
    helm.sh/hook: pre-delete
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
    helm.sh/hook-weight: "0"
    {{- end }}
    ignore-check.kube-linter.io/dnsconfig-options: "With hostNetwork and dnsPolicy ClusterFirst the kubelet gives the pod the node's resolver: the agent, which CoreDNS pulls through, must not depend on cluster DNS."
    ignore-check.kube-linter.io/host-network: "The agent serves the node's runtime: its mirror listens on the node's loopback and its peer API on the node's address."
    {{- if $hook }}
    ignore-check.kube-linter.io/no-liveness-probe: "The container only sleeps until Helm deletes the hook."
    ignore-check.kube-linter.io/no-readiness-probe: "The container only sleeps: ready once unconfigure has succeeded."
    {{- end }}
    {{- if ne $root.Values.updateStrategy.type "RollingUpdate" }}
    ignore-check.kube-linter.io/no-rolling-update-strategy: "updateStrategy.type is a user choice."
    {{- end }}
    ignore-check.kube-linter.io/non-isolated-pod: "A host-network pod is not subject to NetworkPolicy."
    ignore-check.kube-linter.io/run-as-non-root: "The agent writes the runtime's root-owned registry config and connects to the root-only runtime and NRI sockets."
    ignore-check.kube-linter.io/sensitive-host-mounts: "The agent reads the runtime config, the kubelet client certificate and the cluster CA, each its own read-only mount; it writes only the runtime's registry directories."
    ignore-check.kube-linter.io/writable-host-mount: "configure writes the mirror entry into the runtime's registry directories; the agent keeps its state in /var/lib/speculaire and /run/speculaire."
  labels:
    {{- toYaml $labels | nindent 4 }}
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
spec:
  selector:
    matchLabels:
      {{- toYaml (merge (dict "app.kubernetes.io/component" $labelComponent) (include "speculaire.selectorLabels" $root | fromYaml)) | nindent 6 }}
  template:
    metadata:
      annotations:
        {{- toYaml (merge (dict $root.Values.gate.tolerateAnnotation "true") (deepCopy $root.Values.podAnnotations)) | nindent 8 }}
      labels:
        {{- toYaml (merge (deepCopy $labels) (deepCopy $root.Values.podLabels)) | nindent 8 }}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: {{ $root.Values.reflector.nodeLabel }}
                    operator: {{ ternary "Exists" "DoesNotExist" $reflector }}
                  - key: speculaire.spnngl.github.io/disabled
                    operator: DoesNotExist
      automountServiceAccountToken: false
      containers:
        {{- if $hook }}
        - args:
            - sleep
          image: {{ $image | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          name: sleep
          resources:
            {{- toYaml $root.Values.resources | nindent 12 }}
          securityContext:
            {{- toYaml $root.Values.securityContext | nindent 12 }}
        {{- else }}
        - args:
            - agent
            - --config
            - {{ $config }}
          image: {{ $image | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          livenessProbe:
            {{- toYaml $root.Values.livenessProbe | nindent 12 }}
          name: {{ $component }}
          ports:
            - containerPort: 7482
              name: metrics
              protocol: TCP
          readinessProbe:
            {{- toYaml $root.Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml $root.Values.resources | nindent 12 }}
          securityContext:
            {{- toYaml $root.Values.securityContext | nindent 12 }}
          startupProbe:
            {{- toYaml $root.Values.startupProbe | nindent 12 }}
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            {{- toYaml $volumeMounts | nindent 12 }}
        {{- end }}
      dnsPolicy: ClusterFirst
      enableServiceLinks: false
      hostNetwork: true
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      initContainers:
        - args:
            - {{ ternary "unconfigure" "configure" $hook }}
            - --config
            - {{ $config }}
          image: {{ $image | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          name: {{ ternary "unconfigure" "configure" $hook }}
          resources:
            {{- toYaml $root.Values.resources | nindent 12 }}
          securityContext:
            {{- toYaml $root.Values.securityContext | nindent 12 }}
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            {{- toYaml $volumeMounts | nindent 12 }}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      restartPolicy: Always
      securityContext:
        {{- toYaml $root.Values.podSecurityContext | nindent 8 }}
      serviceAccountName: {{ include "speculaire.serviceAccountName" $root }}
      terminationGracePeriodSeconds: {{ $root.Values.terminationGracePeriodSeconds }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumes:
        {{- if $configMap }}
        - configMap:
            name: {{ include "speculaire.fullname" $root }}
          name: config
        {{- end }}
        {{- range $hostPaths }}
        - hostPath:
            path: {{ .path }}
            type: {{ .type }}
          name: {{ .name }}
        {{- end }}
        {{- with $root.Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  updateStrategy:
    {{- if eq $root.Values.updateStrategy.type "RollingUpdate" }}
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: {{ $root.Values.updateStrategy.rollingUpdate.maxUnavailable }}
    type: RollingUpdate
    {{- else }}
    type: {{ $root.Values.updateStrategy.type }}
    {{- end }}
{{- end }}
