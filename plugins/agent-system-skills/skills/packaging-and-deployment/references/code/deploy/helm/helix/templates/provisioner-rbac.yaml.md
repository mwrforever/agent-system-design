# `deploy/helm/helix/templates/provisioner-rbac.yaml`

> 逐字复制的真实源码（77 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if .Values.provisioner.enabled -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "helix.fullname" . }}-provisioner
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
---
# Namespaced permissions: manage sandbox Pods + Services in this namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "helix.fullname" . }}-provisioner
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
rules:
  # Verbs mirror docker/provisioner/app.py, which only calls get/create/delete
  # on pods and get/list/create/delete on services. update/patch, pods/exec,
  # and events were unused and dropped (least privilege). These verbs still
  # apply to *all* Pods in the namespace - scoping to sandbox Pods is deferred
  # (see README "Not yet enforced").
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "helix.fullname" . }}-provisioner
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
subjects:
  - kind: ServiceAccount
    name: {{ include "helix.fullname" . }}-provisioner
    namespace: {{ include "helix.namespace" . }}
roleRef:
  kind: Role
  name: {{ include "helix.fullname" . }}-provisioner
  apiGroup: rbac.authorization.k8s.io
---
# Cluster-scoped: read/create Namespaces so the provisioner can ensure the
# sandbox namespace exists (mirrors docker/provisioner/README.md:202-206).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "helix.fullname" . }}-provisioner-ns
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "helix.fullname" . }}-provisioner-ns
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
subjects:
  - kind: ServiceAccount
    name: {{ include "helix.fullname" . }}-provisioner
    namespace: {{ include "helix.namespace" . }}
roleRef:
  kind: ClusterRole
  name: {{ include "helix.fullname" . }}-provisioner-ns
  apiGroup: rbac.authorization.k8s.io
{{- end -}}
```
