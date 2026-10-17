# `deploy/helm/helix/templates/nginx-service.yaml`

> 逐字复制的真实源码（24 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  type: {{ .Values.nginx.service.type | default "ClusterIP" }}
  {{- if and (eq (default "ClusterIP" .Values.nginx.service.type) "LoadBalancer") .Values.nginx.service.loadBalancerIP }}
  loadBalancerIP: {{ .Values.nginx.service.loadBalancerIP | quote }}
  {{- end }}
  ports:
    - name: http
      port: {{ .Values.nginx.service.port | default 2026 }}
      targetPort: http
      {{- if and (eq (default "ClusterIP" .Values.nginx.service.type) "NodePort") .Values.nginx.service.nodePort }}
      nodePort: {{ .Values.nginx.service.nodePort }}
      {{- end }}
  selector:
    {{- include "helix.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
```
