# `deploy/helm/helix/templates/NOTES.txt`

> 逐字复制的真实源码（152 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```
Helix has been deployed.

  namespace: {{ include "helix.namespace" . }}

{{- if not .Values.image.registry }}

  ⚠️  WARNING: `image.registry` is empty. The gateway/frontend/provisioner
  images won't resolve. Set `image.registry` in your values and build+push the
  three images (see the chart README's "Build & push images" section).
{{- end }}

Get the status:

  kubectl -n {{ include "helix.namespace" . }} get pods

Quick port-forward to nginx (bypasses Ingress):

  kubectl -n {{ include "helix.namespace" . }} port-forward svc/nginx 2026:2026
  # then open http://localhost:2026

{{- if .Values.ingress.enabled }}

Ingress is enabled for host {{ .Values.ingress.host }}. Ensure your Ingress
controller is installed and DNS/hosts maps the host to the controller.
{{- if not .Values.ingress.tls.enabled }}
TLS is disabled — enable `ingress.tls` and provide a secret (or cert-manager)
for HTTPS.
{{- end }}
{{- end }}

Provisioner / sandbox notes:

  • The provisioner ServiceAccount has a namespaced Role (get, list, watch,
    create, delete on Pods + Services incl. pods/log, in this namespace) and a
    narrow ClusterRole (namespace get + create, cluster-wide). These verbs
    apply to *all* Pods in the namespace, not just sandbox Pods - scoping to
    sandbox Pods is deferred hardening (see README "Not yet enforced").
  • Sandbox Pods are created in namespace {{ include "helix.namespace" . }}.
  • PVC mode is enabled: sandbox Pods mount the `{{ include "helix.homePVC" . }}`
    PVC for per-thread user-data.

  • Sandbox reachability: per-sandbox Services are type
    `{{ .Values.provisioner.sandboxServiceType | default "ClusterIP" }}`.
{{- if eq (default "ClusterIP" .Values.provisioner.sandboxServiceType) "NodePort" }}
    The provisioner returns `http://{NODE_HOST}:{NodePort}` to the gateway.
    NODE_HOST defaults to the provisioner pod's node IP via the downward API; a
    NodePort is exposed on every node, so `<node-IP>:<NodePort>` routes from the
    gateway on most clusters. If your CNI or network policy blocks pod->node-IP
    traffic, set `provisioner.nodeHost` to an address the gateway can reach:

      kubectl get nodes -o wide

      provisioner:
        nodeHost: <node-InternalIP-or-ExternalIP>

    ⚠️  NodePort binds the code-execution sandbox on every node's interfaces,
    including externally-reachable ones. Prefer `ClusterIP` (the default) when
    the gateway runs in-cluster.
{{- else }}
    The provisioner returns a cluster-DNS URL
    (`http://sandbox-<id>-svc.{{ include "helix.namespace" . }}.svc.cluster.local:{{ .Values.provisioner.sandboxPort }}`)
    so the gateway reaches its sandbox inside the cluster - no node IP, no
    external port, no exposure on node interfaces.
{{- end }}

  • On multi-node clusters you additionally need
    `persistence.home.accessMode: ReadWriteMany` (e.g. NFS) so sandbox Pods on
    other nodes can mount the shared user-data PVC.
  • Memory data stays on that PVC; HelixMem's rebuildable SQLite search index
    is Pod-local (`memory.backend_config.retrieval_index_path`, an emptyDir at
    /var/lib/helix/memory-index). Keep that config line when you override
    `config`, or gateway Pods share one SQLite WAL file over the network.

Generated secrets (persisted across upgrades):

  • BETTER_AUTH_SECRET, HELIX_INTERNAL_AUTH_TOKEN, AUTH_JWT_SECRET (the
    session-cookie signing key shared by every gateway Pod),
    PROVISIONER_API_KEY (the key the gateway presents to the sandbox
    provisioner, which answers 401 to every /api/* request without it) and
    HELIX_CREDENTIALS_KEY (the at-rest key for stored credentials; back it
    up, losing it makes them unreadable) are stored in the Secret
    `{{ include "helix.appSecret" . }}`.

Database ({{ if .Values.postgresql.enabled }}bundled postgres{{ else }}external postgres{{ end }}):

{{- if .Values.postgresql.enabled }}
  • A postgres StatefulSet (`{{ include "helix.postgresFullname" . }}`)
    is deployed in this namespace. The gateway connects via the in-cluster
    Service `{{ include "helix.postgresFullname" . }}:5432`.
  • DATABASE_URL is in Secret `{{ include "helix.databaseUrlSecret" . }}`
    (key `database-url`); the auto-generated password is in key
    `postgres-password`. Both persist across upgrades.
  • Schema is bootstrapped automatically on gateway startup (alembic
    create_all + stamp head). No manual migration step needed.
  • To run real HA, disable this (`postgresql.enabled: false`) and point at a
    managed DB via `postgresql.external`.
{{- else }}
  • The gateway reads DATABASE_URL from Secret
    `{{ include "helix.databaseUrlSecret" . }}` (key `database-url`).
    Ensure that Secret exists and contains your managed-postgres DSN.
{{- end }}

Redis stream bridge ({{ if .Values.redis.enabled }}bundled redis{{ else if (include "helix.redisConfigured" .) }}external redis{{ else }}none{{ end }}):

{{- if .Values.redis.enabled }}
  • A redis StatefulSet (`{{ include "helix.redisFullname" . }}`) is deployed
    in this namespace. The gateway connects via the in-cluster Service
    `{{ include "helix.redisFullname" . }}:6379`.
  • HELIX_STREAM_BRIDGE_REDIS_URL is in Secret
    `{{ include "helix.redisUrlSecret" . }}` (key `redis-url`).
  • Per-run SSE events are stored in Redis Streams so a client connected to any
    gateway pod receives live events; reconnect resumes from Last-Event-ID.
  • To use a managed Redis, disable this (`redis.enabled: false`) and point at it
    via `redis.external`.
{{- else if (include "helix.redisConfigured" .) }}
  • The gateway reads HELIX_STREAM_BRIDGE_REDIS_URL from Secret
    `{{ include "helix.redisUrlSecret" . }}` (key `redis-url`). Ensure that
    Secret exists and contains your managed-Redis URL.
{{- else }}
  • No redis configured — the gateway falls back to the in-process memory stream
    bridge. This is single-pod only: cross-pod SSE delivery and reconnect will
    not work with `gateway.replicas > 1`.
{{- end }}

{{- if or .Values.secrets .Values.existingSecret }}

Provider/channel keys are in Secret `{{ include "helix.providerSecret" . }}`
and injected into the gateway via envFrom. Reference them from config.yaml as
$VAR.
{{- else }}

  ⚠️  No provider secrets configured. Add at least one model under `config`
    (e.g. an OpenAI model with `api_key: $OPENAI_API_KEY`) and supply the key
    under `secrets` in your values, or the agent will have no LLM to call.
{{- end }}

Agent tools: the chart enables the sandbox tools (ls, read_file, glob, grep,
write_file, str_replace, bash - run inside the AIO sandbox) and web tools
(web_search, web_fetch, image_search - no API key) by default. Add or swap
tools under `config` -> `tools:` (see config.example.yaml); the web tools need
outbound internet from the gateway pod.

Pod security:
  • All pods run non-root: gateway/frontend/provisioner uid 1000, nginx uid 101,
    postgres uid 999. All Linux capabilities are dropped and privilege escalation
    is disabled on every container.
  • ConfigMap changes roll pods automatically (checksum annotations on the
    gateway and nginx pod templates).
  • See README's "Security" section for the full posture and the deferred
    hardening items (readOnlyRootFilesystem, provisioner RBAC narrowing,
    startupProbe).
```
