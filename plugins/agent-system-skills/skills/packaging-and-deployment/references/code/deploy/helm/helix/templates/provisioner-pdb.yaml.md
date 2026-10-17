# `deploy/helm/helix/templates/provisioner-pdb.yaml`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- /*
  PodDisruptionBudget for the sandbox provisioner. Rendered only while the
  provisioner is enabled and runs more than one replica: with a single
  replica a budget of 1 would block every node drain, and with several it
  keeps at least one Pod answering the gateway's sandbox create/discover
  calls while nodes are drained. Unlike the gateway there is no multiInstance
  override, because nothing else in the chart renders differently per
  provisioner replica count; scaling with kubectl alone leaves it unbudgeted.
*/ -}}
{{- $pdb := .Values.provisioner.podDisruptionBudget | default dict -}}
{{- if and .Values.provisioner.enabled $pdb.enabled (gt (int .Values.provisioner.replicas) 1) }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "helix.fullname" . }}-provisioner
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: provisioner
spec:
  minAvailable: {{ include "helix.pdbMinAvailable" (dict "value" $pdb.minAvailable "key" "provisioner.podDisruptionBudget.minAvailable") }}
  selector:
    matchLabels:
      {{- include "helix.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: provisioner
{{- end }}
```
