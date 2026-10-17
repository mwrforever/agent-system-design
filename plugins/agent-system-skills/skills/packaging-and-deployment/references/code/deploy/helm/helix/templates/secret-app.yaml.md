# `deploy/helm/helix/templates/secret-app.yaml`

> 逐字复制的真实源码（47 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- if not .Values.existingAppSecret -}}
{{- $prev := lookup "v1" "Secret" (include "helix.namespace" .) (include "helix.appSecret" .) -}}
{{- $betterAuth := "" -}}
{{- $internalToken := "" -}}
{{- $jwtSecret := "" -}}
{{- $provisionerKey := "" -}}
{{- $credentialsKey := "" -}}
{{- if $prev -}}
{{- $betterAuth = index $prev.data "BETTER_AUTH_SECRET" | default "" | b64dec -}}
{{- $internalToken = index $prev.data "HELIX_INTERNAL_AUTH_TOKEN" | default "" | b64dec -}}
{{- $jwtSecret = index $prev.data "AUTH_JWT_SECRET" | default "" | b64dec -}}
{{- $provisionerKey = index $prev.data "PROVISIONER_API_KEY" | default "" | b64dec -}}
{{- $credentialsKey = index $prev.data "HELIX_CREDENTIALS_KEY" | default "" | b64dec -}}
{{- end -}}
{{- if not $betterAuth -}}{{- $betterAuth = randAlphaNum 48 | lower -}}{{- end -}}
{{- if not $internalToken -}}{{- $internalToken = randAlphaNum 40 -}}{{- end -}}
{{- /* Session-cookie signing key. Generated once and preserved across upgrades
       so sessions survive, and shared by every gateway Pod so a session signed
       on one replica validates on another. */ -}}
{{- if not $jwtSecret -}}{{- $jwtSecret = randAlphaNum 48 -}}{{- end -}}
{{- /* Shared gateway -> sandbox-provisioner key. The provisioner's
       verify_api_key middleware answers 401 to every /api/* request while
       PROVISIONER_API_KEY is empty or mismatched, so both Pods read this one
       value. Generated once and preserved across upgrades so a rollout never
       leaves the two sides on different keys. */ -}}
{{- if not $provisionerKey -}}{{- $provisionerKey = randAlphaNum 48 -}}{{- end -}}
{{- /* At-rest key for stored credentials (a Fernet key: urlsafe base64 of 32
       random bytes). randBytes emits standard base64, so translate its
       alphabet. Generated once and preserved across upgrades: a new key would
       make every credential the gateway Pods stored unreadable. */ -}}
{{- if not $credentialsKey -}}{{- $credentialsKey = randBytes 32 | replace "+" "-" | replace "/" "_" -}}{{- end -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "helix.appSecret" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
type: Opaque
stringData:
  BETTER_AUTH_SECRET: {{ $betterAuth | quote }}
  HELIX_INTERNAL_AUTH_TOKEN: {{ $internalToken | quote }}
  AUTH_JWT_SECRET: {{ $jwtSecret | quote }}
  PROVISIONER_API_KEY: {{ $provisionerKey | quote }}
  HELIX_CREDENTIALS_KEY: {{ $credentialsKey | quote }}
{{- end -}}
```
