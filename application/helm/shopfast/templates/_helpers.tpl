{{/* Chart name, overridable. */}}
{{- define "shopfast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified release name. */}}
{{- define "shopfast.fullname" -}}
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

{{- define "shopfast.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "shopfast.labels" -}}
helm.sh/chart: {{ include "shopfast.chart" . }}
{{ include "shopfast.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: shopfast-delivery-platform
shopfast.io/strategy: {{ .Values.deploymentStrategy }}
{{- end -}}

{{- define "shopfast.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shopfast.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "shopfast.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "shopfast.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Validate the strategy switch. This is the guard that makes the three modes
mutually exclusive: an unrecognised value stops the render instead of silently
producing no workload at all.
*/}}
{{- define "shopfast.validateStrategy" -}}
{{- $valid := list "standard" "bluegreen" "canary" -}}
{{- if not (has .Values.deploymentStrategy $valid) -}}
{{- fail (printf "deploymentStrategy must be one of %s, got %q" (join ", " $valid) .Values.deploymentStrategy) -}}
{{- end -}}
{{- end -}}

{{/* True when the workload must be an Argo Rollout rather than a Deployment. */}}
{{- define "shopfast.usesRollout" -}}
{{- if has .Values.deploymentStrategy (list "bluegreen" "canary") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Fully pinned image reference. Refuses to render without an explicit repository
and tag, so a chart can never fall back to :latest and deploy unknown bytes.
*/}}
{{- define "shopfast.image" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository must be set (the GitOps values supply the ECR repository URL)" -}}
{{- end -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag must be set to an immutable git SHA (never 'latest')" -}}
{{- end -}}
{{- if eq .Values.image.tag "latest" -}}
{{- fail "image.tag 'latest' is forbidden: use the immutable git SHA" -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{/* Pod annotations, including the vmagent scrape contract. */}}
{{- define "shopfast.podAnnotations" -}}
{{- if .Values.metrics.enabled }}
prometheus.io/scrape: "true"
prometheus.io/path: {{ .Values.metrics.path | quote }}
prometheus.io/port: {{ .Values.metrics.port | quote }}
{{- end }}
{{- end -}}

{{/*
The shared pod template. Both the Deployment and the Rollout embed exactly
this spec, so the two paths can never drift apart.
*/}}
{{- define "shopfast.podSpec" -}}
metadata:
  labels:
    {{- include "shopfast.selectorLabels" . | nindent 4 }}
    shopfast.io/release-color: {{ .Values.release.color | quote }}
  annotations:
    {{- include "shopfast.podAnnotations" . | nindent 4 }}
spec:
  serviceAccountName: {{ include "shopfast.serviceAccountName" . }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  terminationGracePeriodSeconds: 45
  containers:
    - name: shopfast
      image: {{ include "shopfast.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      securityContext:
        {{- toYaml .Values.containerSecurityContext | nindent 8 }}
      ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}
          protocol: TCP
      env:
        - name: SHOPFAST_RELEASE_COLOR
          value: {{ .Values.release.color | quote }}
        - name: SHOPFAST_VERSION
          value: {{ .Values.image.tag | quote }}
        {{- with .Values.env }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path }}
          port: http
        initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path }}
          port: http
        initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        # readOnlyRootFilesystem is on, so the JVM needs writable scratch space.
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
