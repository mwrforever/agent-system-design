# `deploy/helm/helix/templates/redis-service.yaml`

> 逐字复制的真实源码（20 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if .Values.redis.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "helix.redisFullname" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: redis
spec:
  type: ClusterIP
  ports:
    - name: tcp-redis
      port: 6379
      targetPort: tcp-redis
  selector:
    {{- include "helix.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: redis
{{- end -}}
```
