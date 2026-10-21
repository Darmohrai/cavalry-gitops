{{/* Chart name */}}
{{- define "cavalry.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified name built from the release name */}}
{{- define "cavalry.fullname" -}}
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

{{/* chart-name-version label value */}}
{{- define "cavalry.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Selector labels (immutable subset) */}}
{{- define "cavalry.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cavalry.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Common label set */}}
{{- define "cavalry.labels" -}}
helm.sh/chart: {{ include "cavalry.chart" . }}
{{ include "cavalry.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Name of the Secret with credentials: existingSecret (created by hand) or the one rendered by the chart */}}
{{- define "cavalry.secretName" -}}
{{- .Values.existingSecret | default (printf "%s-secret" (include "cavalry.fullname" .)) }}
{{- end }}
