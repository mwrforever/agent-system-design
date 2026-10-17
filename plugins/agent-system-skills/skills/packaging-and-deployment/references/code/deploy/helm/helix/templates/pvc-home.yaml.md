# `deploy/helm/helix/templates/pvc-home.yaml`

> 逐字复制的真实源码（19 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if .Values.persistence.home.enabled -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "helix.homePVC" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
spec:
  accessModes:
    - {{ .Values.persistence.home.accessMode | quote }}
  resources:
    requests:
      storage: {{ .Values.persistence.home.size | quote }}
  {{- with .Values.persistence.home.storageClass }}
  storageClassName: {{ . | quote }}
  {{- end }}
{{- end -}}
```
