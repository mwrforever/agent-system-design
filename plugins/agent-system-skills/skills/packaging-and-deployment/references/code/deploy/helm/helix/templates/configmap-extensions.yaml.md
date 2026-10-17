# `deploy/helm/helix/templates/configmap-extensions.yaml`

> 逐字复制的真实源码（11 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "helix.fullname" . }}-extensions
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
data:
  extensions_config.json: |
{{ .Values.extensionsConfig | default "" | indent 4 }}
```
