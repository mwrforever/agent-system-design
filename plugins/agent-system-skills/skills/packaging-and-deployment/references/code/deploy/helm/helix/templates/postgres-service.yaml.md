# `deploy/helm/helix/templates/postgres-service.yaml`

> 逐字复制的真实源码（20 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if .Values.postgresql.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "helix.postgresFullname" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
spec:
  type: ClusterIP
  ports:
    - name: tcp-postgres
      port: 5432
      targetPort: tcp-postgres
  selector:
    {{- include "helix.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
{{- end -}}
```
