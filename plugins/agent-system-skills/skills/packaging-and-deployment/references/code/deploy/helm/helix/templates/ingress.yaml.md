# `deploy/helm/helix/templates/ingress.yaml`

> 逐字复制的真实源码（38 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "helix.fullname" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className | quote }}
  {{- end }}
  {{- if .Values.ingress.tls.enabled }}
  tls:
    - hosts:
        {{- $hosts := .Values.ingress.tls.hosts | default (list .Values.ingress.host) }}
        {{- toYaml $hosts | nindent 8 }}
      {{- if .Values.ingress.tls.secretName }}
      secretName: {{ .Values.ingress.tls.secretName | quote }}
      {{- end }}
  {{- end }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 2026
{{- end -}}
```
