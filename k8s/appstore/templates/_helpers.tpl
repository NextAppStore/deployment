{{/*
Common labels applied to every resource.
*/}}
{{- define "appstore.labels" -}}
app.kubernetes.io/part-of: appstore
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels for a given component name (e.g. "backend", "postgres").
Pass the component name as the second element of a (dict "name" "<name>" "root" $) tuple,
or just use: {{ include "appstore.selectorLabels" "backend" }}
*/}}
{{- define "appstore.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/instance: appstore
{{- end -}}

{{/*
Full image reference: <registry>/<repository>:<tag>
*/}}
{{- define "appstore.image" -}}
{{- printf "%s/%s:%s" .registry .repository .tag -}}
{{- end -}}
