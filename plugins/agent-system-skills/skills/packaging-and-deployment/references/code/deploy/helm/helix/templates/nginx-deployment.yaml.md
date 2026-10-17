# `deploy/helm/helix/templates/nginx-deployment.yaml`

> 逐字复制的真实源码（86 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "helix.fullname" . }}-nginx
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: nginx
spec:
  replicas: {{ .Values.nginx.replicas }}
  selector:
    matchLabels:
      {{- include "helix.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: nginx
  template:
    metadata:
      labels:
        {{- include "helix.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: nginx
      annotations:
        # Roll pods when the nginx ConfigMap changes (subPath mount).
        checksum/nginx: {{ include "helix.nginxChecksum" . }}
    spec:
      securityContext:
        # Non-root: nginx:alpine ships a `nginx` user (uid 101). /etc/nginx and
        # /var/cache/nginx are root-owned, so the command writes the rendered
        # config to /tmp and we mount an emptyDir on the cache dir (below).
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: {{ include "helix.nginxImage" . }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          ports:
            - name: http
              containerPort: 2026
          # Strip the IPv6 listen line when IPv6 is unavailable (mirrors compose).
          # Writes the config to /tmp (1777, writable by uid 101) instead of
          # /etc/nginx (root-owned), then loads it with `nginx -c`.
          command: ["sh", "-c"]
          args:
            - >-
              cp /etc/nginx/nginx.conf.template /tmp/nginx.conf &&
              test -e /proc/net/if_inet6 || sed -i '/^[[:space:]]*listen[[:space:]]\+\[::\]:2026[[:space:]]/d' /tmp/nginx.conf &&
              nginx -c /tmp/nginx.conf -g 'daemon off;'
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /nginx-health
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
          {{- with .Values.nginx.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/nginx.conf.template
              subPath: nginx.conf
              readOnly: true
            # nginx creates client_body/proxy temp dirs under /var/cache/nginx
            # at startup; the dir is root-owned, so mount an emptyDir (writable
            # by fsGroup 101). The pid already lives at /tmp/nginx.pid (config).
            - name: nginx-cache
              mountPath: /var/cache/nginx
      volumes:
        - name: nginx-config
          configMap:
            name: {{ include "helix.fullname" . }}-nginx
        - name: nginx-cache
          emptyDir: {}
```
