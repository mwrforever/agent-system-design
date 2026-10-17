# `deploy/helm/helix/templates/frontend-deployment.yaml`

> 逐字复制的真实源码（76 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "helix.fullname" . }}-frontend
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  replicas: {{ .Values.frontend.replicas }}
  selector:
    matchLabels:
      {{- include "helix.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: frontend
  template:
    metadata:
      labels:
        {{- include "helix.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: frontend
    spec:
      {{- include "helix.imagePullSecrets" . | nindent 6 }}
      securityContext:
        # Non-root: node:22-alpine ships a `node` user (uid 1000). fsGroup 1000
        # is harmless here (no PVC) but keeps the pod spec uniform.
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: frontend
          image: {{ include "helix.frontendImage" . }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          workingDir: /app/frontend
          args: ["pnpm", "start"]
          ports:
            - name: http
              containerPort: 3000
          env:
            - name: NODE_ENV
              value: production
            - name: HELIX_INTERNAL_GATEWAY_BASE_URL
              value: http://gateway:8001
            - name: BETTER_AUTH_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ include "helix.appSecret" . }}
                  key: BETTER_AUTH_SECRET
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 30
            periodSeconds: 20
          {{- with .Values.frontend.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            # Next.js writes runtime cache to .next/cache; the dir is root-owned
            # in the prod image, so mount an emptyDir to make it writable by 1000.
            - name: next-cache
              mountPath: /app/frontend/.next/cache
      volumes:
        - name: next-cache
          emptyDir: {}
```
