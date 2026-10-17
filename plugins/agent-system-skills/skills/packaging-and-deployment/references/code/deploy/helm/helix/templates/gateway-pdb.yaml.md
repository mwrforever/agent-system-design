# `deploy/helm/helix/templates/gateway-pdb.yaml`

> 逐字复制的真实源码（25 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- /*
  PodDisruptionBudget for the gateway. Rendered only for a multi-instance
  gateway (gateway.replicas > 1, or gateway.multiInstance: true for
  deployments scaled with kubectl/HPA): with a single replica a budget of 1
  would block every node drain, and with several it keeps at least one Pod
  serving (and renewing its run leases) while nodes are drained.
*/ -}}
{{- $pdb := .Values.gateway.podDisruptionBudget | default dict -}}
{{- if and $pdb.enabled (eq (include "helix.gatewayMultiInstance" .) "true") }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "helix.fullname" . }}-gateway
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: gateway
spec:
  minAvailable: {{ include "helix.pdbMinAvailable" (dict "value" $pdb.minAvailable "key" "gateway.podDisruptionBudget.minAvailable") }}
  selector:
    matchLabels:
      {{- include "helix.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: gateway
{{- end }}
```
