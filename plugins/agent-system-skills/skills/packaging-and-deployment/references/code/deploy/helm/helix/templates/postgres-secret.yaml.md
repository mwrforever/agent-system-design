# `deploy/helm/helix/templates/postgres-secret.yaml`

> 逐字复制的真实源码（44 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
{{- /*
  Postgres Secret — holds DATABASE_URL (key `database-url`) and, in bundled
  mode, the postgres superuser password (key `postgres-password`).

  Created when the chart owns the credentials:
    • bundled mode  (postgresql.enabled=true)                         → generates password, builds DSN
    • external mode with postgresql.external.databaseUrl set          → wraps the DSN verbatim
  NOT created when the user manages the Secret themselves:
    • postgresql.external.existingSecret OR postgresql.existingSecret → referenced only
*/ -}}
{{- $userSecret := or .Values.postgresql.external.existingSecret .Values.postgresql.existingSecret -}}
{{- $wrapExternal := and (not .Values.postgresql.enabled) .Values.postgresql.external.databaseUrl -}}
{{- if and (not $userSecret) (or .Values.postgresql.enabled $wrapExternal) -}}
{{- $password := "" -}}
{{- $dsn := "" -}}
{{- if .Values.postgresql.enabled -}}
{{- /* bundled: password persists across upgrades via lookup */ -}}
{{- $prev := lookup "v1" "Secret" (include "helix.namespace" .) (include "helix.databaseUrlSecret" .) -}}
{{- if $prev -}}
{{- $password = index $prev.data "postgres-password" | default "" | b64dec -}}
{{- end -}}
{{- if not $password -}}{{- $password = randAlphaNum 32 -}}{{- end -}}
{{- $dsn = printf "postgresql://%s:%s@%s:5432/%s" .Values.postgresql.auth.username (include "helix.urlEscape" $password) (include "helix.postgresFullname" .) .Values.postgresql.auth.database -}}
{{- else -}}
{{- /* external: user-supplied DSN, verbatim */ -}}
{{- $dsn = .Values.postgresql.external.databaseUrl -}}
{{- end -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "helix.databaseUrlSecret" . }}
  namespace: {{ include "helix.namespace" . }}
  labels:
    {{- include "helix.labels" . | nindent 4 }}
    app.kubernetes.io/component: postgres
type: Opaque
stringData:
  database-url: {{ $dsn | quote }}
  {{- if .Values.postgresql.enabled }}
  # Superuser password for the bundled postgres StatefulSet (POSTGRES_PASSWORD).
  postgres-password: {{ $password | quote }}
  {{- end }}
{{- end -}}
```
