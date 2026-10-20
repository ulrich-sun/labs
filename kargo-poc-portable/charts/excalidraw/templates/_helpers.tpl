{{- define "excalidraw.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "excalidraw.labels" -}}
app.kubernetes.io/name: {{ include "excalidraw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: kargo
{{- end -}}

{{- define "excalidraw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "excalidraw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Référence d'image : repo:tag, ou repo:tag@digest si un digest est fourni */}}
{{- define "excalidraw.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
