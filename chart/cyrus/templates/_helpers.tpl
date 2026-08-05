{{/*
Chart name
*/}}
{{- define "cyrus.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname
*/}}
{{- define "cyrus.fullname" -}}
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
Common labels
*/}}
{{- define "cyrus.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "cyrus.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.cyrus.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cyrus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cyrus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "cyrus.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cyrus.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. The tag defaults to the chart version rather than appVersion:
appVersion tracks the cyrus-ai npm release, which the image does not contain.
*/}}
{{- define "cyrus.image" -}}
{{- $tag := .Values.image.tag | default (printf "v%s" .Chart.Version) -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/*
Base URL of the LLM gateway. Defaults to the bundled subchart's Service, whose
name is `<release>-litellm:4000` (Helm sets the subchart's .Chart.Name to the
dependency alias, and litellm.fullname is release-chart).
*/}}
{{- define "cyrus.gatewayUrl" -}}
{{- if .Values.llm.gateway.baseUrl -}}
{{- .Values.llm.gateway.baseUrl -}}
{{- else if .Values.litellm.enabled -}}
{{- printf "http://%s-litellm:4000" .Release.Name -}}
{{- else -}}
{{- fail "llm.mode is 'gateway' but neither llm.gateway.baseUrl nor litellm.enabled is set" -}}
{{- end -}}
{{- end }}

{{/*
Space-separated name=url pairs consumed by entrypoint.sh
*/}}
{{- define "cyrus.repoList" -}}
{{- $pairs := list -}}
{{- range $name, $url := .Values.repositories -}}
{{- $pairs = append $pairs (printf "%s=%s" $name $url) -}}
{{- end -}}
{{- join " " $pairs -}}
{{- end }}
