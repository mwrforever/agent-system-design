---
name: model-provider-factory
description: 模型接入层：create_chat_model 工厂（档案解析→use 类路径反射→采样覆写→推理契约→api_base 归一）、ReasoningContract 统一推理策略（legacy 与 contract 双路径 thinking 设置，能力声明而非散落 if）、九家 provider 兼容层（Claude OAuth+prompt caching、Codex Responses API、vLLM 保留 reasoning、MindIE XML 工具解析、OpenAI/DeepSeek/MiniMax/MiMo/StepFun 流式修复）、CLI OAuth 凭据复用、模型级限速 RequestAdmission、受管模型路由（RedactedModelRoute）。当要多模型接入、适配非标 provider、统一 thinking/reasoning_effort 语义时使用。
---

# 模型工厂与 Provider

## 何时用

- 平台接入多家模型（OpenAI 兼容/Anthropic/自托管 vLLM/MindIE…）
- 统一 thinking / reasoning_effort 的配置语义
- 非标 provider 的流式/工具调用兼容补丁怎么写
- 复用 CLI 工具的 OAuth 凭据、模型级限速

## 设计方案（为什么这么设计）

### 1. 工厂：档案驱动 + 反射分发

`create_chat_model(name, thinking_enabled, *, app_config, attach_tracing=True, model_overrides)`（factory.py:526）：取模型档案（`config.yaml → models[]`）→ `resolve_class(model_config.use, BaseChatModel)` 按**类路径字符串**分发（同一工厂装所有 provider，见 [[tool-assembly-and-policy]] 的反射机制）→ 采样覆写合并 → 推理契约 → `api_base→base_url` 归一 → provider 特例（Codex 丢 max_tokens、映射 reasoning_effort）。

### 2. 推理契约：能力声明，不是 if 地雷阵

`reasoning.py`：`ReasoningContract`/`EffortContract` 声明每家 provider 的思考字段与档位；`resolve_reasoning_contract(model_config)` + `resolve_reasoning_request(contract, thinking_enabled, reasoning_effort)` 把统一的用户语义翻译到各家方言，legacy 路径兼容旧配置。前端 `core/models/reasoning.ts` 消费同一能力面（见 [[frontend-app-design]]）。

### 3. 九家 provider 兼容层（谁病治谁）

| Provider | 文件 | 治什么 |
|---|---|---|
| Claude | `claude_provider.py`（445） | OAuth Bearer + prompt caching |
| Codex | `openai_codex_provider.py`（530） | Responses API 工具面 |
| vLLM | `vllm_provider.py`（328） | 保留 reasoning 字段透传 |
| MindIE | `mindie_provider.py`（418） | XML 形态工具调用解析 |
| OpenAI/DeepSeek/MiniMax/MiMo/StepFun | `patched_*.py` | 各家流式分块/思考字段/finish_reason 修复 |

**补丁层只修 provider 缺陷，不实现业务**——业务语义全在工厂与契约。

### 4. 凭据、限速、受管路由

- `credential_loader.py`：`load_claude_code_credential` / `load_codex_cli_credential` 复用官方 CLI 的 OAuth 凭据（用户不必再配 key）
- `request_admission.py::RequestAdmission(BaseRateLimiter)`：模型级限速（防单模型打爆配额）
- `managed_models.py` + 网关 `routers/managed_models.py`：受管模型路由，对外 `RedactedModelRoute`（路由里的 key 永不回显）

### 5. tracing 纪律

图内建模型一律 `attach_tracing=False`（挂图根不变量，见 [[agent-graph-factory]] / [[observability-tracing]]）；工厂默认 True 仅供图外（标题/摘要由中间件自建并显式关闭）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/models/factory.py` | 721 | 工厂 |
| `references/code/backend/packages/harness/helix/models/reasoning.py` + `reasoning_capture.py` | 217+56 | 推理契约 |
| `references/code/backend/packages/harness/helix/models/{claude_provider,openai_codex_provider,vllm_provider,mindie_provider}.py` | 445/530/328/418 | 四家自研层 |
| `references/code/backend/packages/harness/helix/models/patched_{openai,deepseek,minimax,mimo,stepfun}.py` | 110/102/267/124/157 | 五家补丁 |
| `references/code/backend/packages/harness/helix/models/{credential_loader,request_admission,assistant_payload_replay}.py` | 269/120/118 | 凭据/限速/回放还原 |
| `references/code/backend/packages/harness/helix/config/{model_config,managed_models,managed_model_providers}.py` | 269/246/136 | 档案配置 |
| `references/code/backend/app/gateway/routers/{models,managed_models}.py` | 226/182 | 模型 API |

## 反模式与陷阱

- ❌ 每家 provider 写一套装配分支 → 工厂爆炸；档案 + use 反射。
- ❌ thinking 语义散落各 provider if → 无法审计；集中契约。
- ❌ 补丁层塞业务逻辑 → 不可复用；只修缺陷。
- ❌ 路由配置原样回显给前端 → key 泄漏；RedactedModelRoute。
- ❌ 图内建模忘了 attach_tracing=False → 双 span/双计费。

## 落地参考

**自测方向**：同一 `thinking_enabled=True` 在声明不支持的模型上自动降级（warning）；未知名降级默认不抛错；vLLM 思考字段往返不丢；Codex 映射 reasoning_effort；限速命中节流；凭据过期路径可刷新。

## 进一步阅读

- [[agent-graph-factory]]（建模调用点）、[[config-and-hot-reload]]（models 配置段）
- [[observability-tracing]]（attach_tracing 语义）
