---
name: im-channels
description: 设计生产级 agent 平台的 IM 渠道对接--Channel/ChannelManager/MessageBus 三层抽象 + 钉钉出站长连接（dingtalk-stream，非 webhook）完整对接 + AI Card 流式 patch / sampleMarkdown 回退 + access token 缓存刷新 + 内部 token + owner 头透传 + 单活跃 owner 迁移 + 各 IM 差异（飞书 patch card / telegram 原地 edit / slack-discord wait / github fire-and-forget / 微信/企微）。给出完整真实代码与在端到端链路 ①入站-IM + ⑧渲染-IM 的位置。当你要对接 IM 平台、选出站长连接还是 webhook、做流式卡片渲染、排查 IM 串用户或 token 限流时调用本 skill。
---

## 何时用

- 对接任一 IM 平台（钉钉/飞书/Slack/Telegram/Discord/微信/企微/GitHub）把外部消息桥接进 agent run
- 在"出站长连接"（WebSocket/long-poll）与"入站 webhook"之间做选型，或要讲清为何钉钉/飞书/Slack/Telegram 都选了出站长连接
- 写一个新 channel adapter：复用 `Channel` 基类 + 注册到 `ChannelService` + 经 `MessageBus` 与 `ChannelManager` 解耦
- 做流式渲染：钉钉 AI Card 流式 patch（`PUT /v1.0/card/streaming`）与 sampleMarkdown 回退的取舍，或飞书 patch card / Telegram 原地 edit 的节流策略
- 排查 IM 侧"串用户"（owner 头没透传、per-user 目录落错桶）、access token 限流（没缓存每条消息都换 token）、卡片流失败无回退
- 理解"单活跃 owner 迁移"：同一外部身份被新 owner 绑定时旧 owner 连接如何被吊销
- 处理多实例部署下同一 channel 的连接抢占、provider 重投去重、thread 创建竞争

> 本 skill 是 IM 维度的深度；它如何汇入 ②认证 与 ③–⑧ 后段见脊柱 [[e2e-request-lifecycle]]。

## 设计方案（为什么这么设计）

### 核心定位：在端到端链路 ①入站-IM + ⑧渲染-IM 两跳

本 skill 同时 owns 端到端链路的两个端点：

- **①入站-IM**：IM 平台消息 -> channel adapter -> `MessageBus.publish_inbound` -> `ChannelManager._dispatch_loop` 取出 -> `client.runs.wait/stream` 调 Gateway。这条路径与 Web 前端、定时任务在 ②认证处汇合（IM 走内部 token + owner 头），此后 ③–⑧ 完全一致。
- **⑧渲染-IM**：agent 产出 -> `ChannelManager` 把响应/流式 chunk 经 `MessageBus.publish_outbound` -> channel 的 `send` 回写平台。钉钉用 AI Card 流式 patch 原地更新同一张卡片；飞书 patch card；Telegram 原地 edit；Slack/Discord wait（等终态再发）；GitHub fire-and-forget（agent 自己用 `gh` 发）。

### 为何用出站长连接而非 webhook

七家 IM 平台里，六家（钉钉/飞书/Slack/Telegram/Discord/微信/企微）都用**出站长连接**或 long-poll，唯独 GitHub 用 webhook。这不是随意的，而是三股力量共同决定的：

1. **无需公网 IP / 无需暴露端口**。出站长连接是 agent 侧主动向平台发起 WebSocket（钉钉 `dingtalk-stream`、飞书 `lark-oapi` ws、Slack Socket Mode、Discord gateway、企微 `wss://openws.work.weixin.qq.com`）或 long-poll（Telegram getUpdates、微信 iLink getupdates），平台把消息**推回这条已建立的连接**。部署方不需要公网入口、不需要配反向代理、不需要在防火墙开端口。这对"私有部署、内网运行"的 agent 平台是决定性的--大多数自托管用户没有稳定公网 IP。
2. **安全面收敛**。webhook 要求平台能**主动访问**你的端点，意味着你要暴露一个公网 URL 并校验签名（HMAC）。出站长连接把"谁能连谁"翻转：agent 侧持凭证主动连平台，平台在这条已认证连接上推消息，**不存在被公网扫描的入站端点**。凭证（client_secret/bot_token）只存在 agent 侧，不经 URL 暴露。GitHub 例外是因为它本就是代码托管平台，webhook 是其原生模型，且签名校验（`GITHUB_WEBHOOK_SECRET`）足够成熟。
3. **reconnect 由 SDK 兜底**。出站长连接的 SDK（`dingtalk-stream`、`lark-oapi`、`slack_sdk.socket_mode`、`python-telegram-bot`、`discord.py`、`wecom-aibot-python-sdk`）内置断线重连。agent 侧不需要自己实现重连状态机，只需在 `start()` 里起一个 daemon 线程跑 `client.start_forever()`，SDK 负责心跳、重连、消息去重。

**代价与取舍**：出站长连接要求 agent 进程常驻（不能是 serverless 冷启动），且每个 channel 占一个常驻线程/连接。但 agent 平台本就是常驻服务（Gateway + worker），这个代价可接受。webhook 仅在"平台原生只支持 webhook"（GitHub）或"需要承受高突发吞吐且不愿常驻连接"时才选。

### Channel / ChannelManager / MessageBus 三层抽象（为何这样切）

三层职责严格分离，使"加一个新 IM 平台"变成只写一个 `Channel` 子类：

| 层 | 职责 | 不做什么 |
|---|---|---|
| `Channel`（基类 + 各平台子类） | 连接平台（长连接/long-poll）、解析入站消息为 `InboundMessage`、`send` 出站消息回平台、平台特有的渲染（卡片/edit/反应） | 不调 agent、不创建 thread、不碰 run config |
| `MessageBus`（异步 pub/sub） | 入站走 `asyncio.Queue`（channel -> manager），出站走回调列表（manager -> channel） | 不做业务逻辑，纯解耦管道 |
| `ChannelManager`（dispatcher） | 从 bus 取入站 -> 创建/复用 thread -> 解析 run 参数 -> 调 `client.runs.wait/stream` -> 提取响应 -> 发出站 | 不直接连 IM 平台 |

**关键解耦点**：channel 跑在**独立线程**（SDK 要求自己的事件循环），manager 跑在**主事件循环**。两者靠 `MessageBus` 的 `asyncio.Queue` 跨线程通信：channel 用 `asyncio.run_coroutine_threadsafe(bus.publish_inbound(msg), main_loop)` 把消息从 SDK 线程扔回主循环。这让 SDK 的线程模型（钉钉/飞书/Slack 各不同）与 manager 的 asyncio 模型互不干扰。

`ChannelManager._get_client()` 用 `langgraph_sdk.get_client` 连本机 Gateway，并带**内部认证头 + CSRF 头**（manager 自身是个受信内部调用者）。每个 IM 消息再叠一个 **owner 头**标明所属用户（见下文）。

### 钉钉 AI Card 流式 patch vs sampleMarkdown 回退

钉钉有两种出站渲染模式，由 `card_template_id` 配置开关：

- **AI Card 模式**（`card_template_id` 非空）：入站时先 `async_create_and_deliver_card` 建一张"运行中"卡片，拿到 `out_track_id`；此后每个流式 chunk 经 `async_streaming(card_instance_id, content_key="content", content_value=..., finished=is_finalize)` 调钉钉 `PUT /v1.0/card/streaming` **原地 patch 同一张卡片**。用户看到的是卡片内容实时增长，体验近似前端 SSE。终态 chunk `finished=True` 结束流。
- **sampleMarkdown 模式**（无 `card_template_id`，或卡片流失败回退）：`_send_p2p_message` / `_send_group_message` 调 `robot/oToMessages/batchSend` 或 `robot/groupMessages/send`，`msgKey="sampleMarkdown"`，一次性发完整 markdown。无流式效果，但稳定。

**回退策略**（关键不变量）：卡片流 patch 失败时，**仅最终消息**回退 sampleMarkdown--非最终 chunk 失败直接吞掉（`return`），因为中间 chunk 回退成独立消息会刷屏。代码里是 `if msg.is_final: await self._send_markdown_fallback(...)`。这保证用户终归能看到完整结果，即使卡片流中途断了。

**sampleMarkdown 的渲染局限**：钉钉 sampleMarkdown 不支持管道表格、围栏代码块、水平线。`_adapt_markdown_for_dingtalk` 把围栏代码块转引用块、行内代码转粗体、表格转键值对引用、水平线转长横线，使输出在钉钉里可读。

### access token 缓存刷新（double-check lock + 提前量）

钉钉机器人 API（`robot/oToMessages`、`robot/groupMessages`、`files/upload`）需要 `x-acs-dingtalk-access-token`，由 `oauth2/accessToken` 用 `appKey`+`appSecret` 换取，TTL 通常 7200s。**不缓存则每条消息换一次 token**，钉钉对该接口限流，高并发下直接 429。

解法是**带提前量的 double-check lock**：

```python
async def _get_access_token(self) -> str:
    if self._cached_token and time.monotonic() < self._token_expires_at:  # 快路径：无锁检查
        return self._cached_token
    async with self._token_lock:                                           # 慢路径：加锁
        if self._cached_token and time.monotonic() < self._token_expires_at:  # 二次检查（可能已被等锁者刷新）
            return self._cached_token
        # ... 换 token ...
        self._token_expires_at = time.monotonic() + expires_in - _TOKEN_REFRESH_MARGIN_SECONDS  # 提前 300s 过期
```

- **double-check**：快路径无锁读，命中则零开销返回；未命中才加锁，锁内再查一次（抢锁期间前一个持有者可能已刷新），避免 N 个并发请求同时换 token。
- **提前量 `_TOKEN_REFRESH_MARGIN_SECONDS = 300`**：过期时间设为 `expires_in - 300s`，留 5 分钟缓冲。防止"token 在过期边缘被缓存，发到钉钉时刚好过期"的竞态。

### 内部 token + owner 头透传（IM 消息如何落到正确用户）

IM channel 是**受信内部调用者**，调 Gateway 时不走浏览器 cookie 路径，而是带 `X-Helix-Internal-Token`（进程内共享密钥）。但仅此不够--所有 IM 消息都用同一个内部 token，Gateway 无法区分"这是钉钉用户 A 的消息还是飞书用户 B 的"。故额外透传 **owner 头** `X-Helix-Owner-User-Id`：

```python
def _owner_headers(msg: InboundMessage) -> dict[str, str] | None:
    owner_user_id = _effective_owner_user_id(msg)     # 优先 channel connection 绑定的 owner，否则 auth-disabled 兜底
    if not owner_user_id:
        return None
    return create_internal_auth_headers(owner_user_id=owner_user_id)  # 内部 token + owner 头
```

owner 头经 `AuthMiddleware` 的 `get_internal_user` 落到 `user_context` contextvar，使 ③–⑧ 的 per-user 目录（uploads/workspace/outputs/memory/agents）落到**真实 channel 用户**而非 `"default"`。owner 头**仅在内部 token 校验通过后生效**--浏览器调用者塞的 owner 头被 `get_trusted_internal_owner_user_id` 无视（见 [[auth]]）。

**两级身份分离**（关键不变量，源码注释强调）：
- `_owner_headers(msg)`：发 HTTP 给 Gateway 用，传**原始** owner id（不 sanitize、无平台回退），Gateway 侧 `make_safe_user_id` 规范化。
- `_channel_storage_user_id(msg)`：进程内文件系统用，**sanitize 后**的 id（`get_paths().prepare_user_dir_for_raw_id`），并带平台 user_id 回退。这两者必须分开，否则未绑定的 auth-enabled channel 会 run 在 `safe(msg.user_id)` 但文件落到 `get_effective_user_id()`（dispatcher task 的未设 contextvar -> `"default"`），uploads 落 `users/default/...` 而 agent 读 `users/{safe_platform_user_id}/...`，文件对不上。

### 单活跃 owner 迁移语义

channel connection（"哪个外部身份绑了哪个平台账号"）持久化在 `ChannelConnectionRepository`。**同一外部身份**（`provider + external_account_id + workspace_id`）同一时刻只能有一个**活跃 owner**。当新 owner 绑定同一身份时，`upsert_connection` 在 commit 前**先吊销旧 owner 的活跃行**：

```python
async def _revoke_other_active_owners(session):
    if status != "connected":
        return
    # 查同 provider+external_account_id+workspace_id 但不同 owner 且未 revoked 的行
    transferred_ids = [r.id for r in query(... owner_user_id != owner_user_id, status != "revoked")]
    if not transferred_ids:
        return
    # 吊销连接 + 删除其凭证
    update(... status="revoked" where id in transferred_ids)
    delete(ChannelCredentialRow where connection_id in transferred_ids)
```

- **在 flush 前 revoke**：先吊销旧 owner 的活跃行，再 flush 自己的 `connected` 行，使**部分唯一索引**（"活跃身份唯一"）在 commit 时满足。若顺序反了，两条 `connected` 行会撞唯一索引 `IntegrityError`。
- **IntegrityError 重试**：并发 writer 可能先一步 commit 同一身份，`_UPSERT_MAX_ATTEMPTS = 3` 次重试，每次 rollback 后重读已可见状态、revoke 新 commit 的 owner、再写自己的行。
- **结果语义**：用户 A 绑定的钉钉账号，被用户 B 重新绑定后，A 的连接立即变 `revoked`、凭证被删，此后该外部身份的消息归属 B。`_get_bound_identity_rejection` 在 run 创建前**重读** connection 校验，不信任入站消息自带的 `connection_id`/`owner_user_id` 字段（防伪造）。

### 各 IM 差异矩阵

七家平台在"入站连接 / 流式渲染 / thread 映射 / 绑定方式"上各有取舍：

| 平台 | 入站连接 | 流式渲染 | thread 映射（topic_id） | 绑定方式 |
|---|---|---|---|---|
| 钉钉 | `dingtalk-stream` WebSocket（出站长连接） | AI Card 流式 patch + sampleMarkdown 回退 | P2P: `None`（单用户单 thread）；群: `msg_id`（每条新 topic） | `/connect <code>` |
| 飞书 | `lark-oapi` WebSocket（出站长连接） | patch card（`im.v1.message.patch` 原地更新）+ OK/DONE 表情反应 | P2P: `None`；群: `root_id`/`parent_id`（回复链） | `/connect <code>` |
| Slack | Socket Mode WebSocket（出站长连接） | wait（`chat_postMessage` 终态发，eyes/✅/❌ 反应） | `thread_ts`（Slack 原生 thread） | `/connect <code>` |
| Telegram | long-poll `getUpdates`（出站拉取） | 原地 `edit_message_text`（节流 + rate-limit 降级） | P2P: `None`；群: `reply_to` msg id | `/start <token>` 深链 |
| Discord | `discord.py` gateway WebSocket（出站长连接） | wait（`channel.send` 终态发，typing 指示 + ✅ 反应） | `thread_ts`（Discord 原生 thread，mention 触发创建） | `/connect <code>` |
| 微信 | iLink long-poll `getupdates`（出站拉取） | wait（`sendmessage` 终态发） | `None`（单用户单 thread） | `/connect <code>` |
| 企微 | `wecom-aibot-python-sdk` WebSocket（出站长连接） | `reply_stream`（WS 流式，原地更新） | `user_id`（单用户单 thread） | `/connect <code>` |
| GitHub | **webhook**（`POST /api/webhooks/github`，HMAC 签名） | **fire-and-forget**（agent 用 `gh` CLI 自己发，`send` 仅 log） | `preferred_thread_id`（repo+number 确定性） | agent `config.yaml` ownership |

**三个维度上的关键差异**：

1. **流式 vs wait**：支持流式的平台（钉钉 AI Card / 飞书 patch / Telegram edit / 企微 reply_stream）让用户看到中间产出；不支持的平台（Slack/Discord/微信）等终态一次性发。差异源于平台 API 是否提供"原地更新已有消息"能力。
2. **fire-and-forget（GitHub 独有）**：`ChannelRunPolicy.fire_and_forget=True` 时 manager 用 `runs.create`（立即返回 pending）而非 `runs.wait`（保持 HTTP 流开到 run 结束）。因为 GitHub agent 自己在沙箱里用 `gh` 发评论，manager 不需要 ferry 最终响应回去，且自主长 run 超 5 分钟会触发 SDK 300s `httpx.ReadTimeout`。
3. **非交互通道 disable_clarification**：`ChannelRunPolicy.is_interactive=False`（GitHub）设 `run_context["disable_clarification"]=True`，使 `ClarificationMiddleware` 不 `Command(goto=END)` 中断（webhook 无法同步等用户回复）。这与调度任务的 `non_interactive` 剥离互补：调度在**建图**剥离 `ask_clarification` 工具，GitHub webhook 在**中间件**让它不中断。

### 关键不变量

1. **出站长连接优先**：除 GitHub（原生 webhook）外，所有 IM 用出站长连接/long-poll，不暴露公网入站端点。
2. **Channel/Manager/Bus 三层解耦**：channel 跑 SDK 线程，manager 跑主循环，靠 `MessageBus` 的 `asyncio.Queue` + `run_coroutine_threadsafe` 跨线程通信。
3. **owner 头两级分离**：`_owner_headers` 传原始 id 给 HTTP，`_channel_storage_user_id` 传 sanitize 后 id 给文件系统；两者不可混用。
4. **AI Card patch 失败仅终态回退**：非最终 chunk 失败吞掉，最终 chunk 失败回退 sampleMarkdown。
5. **access token double-check + 提前量**：快路径无锁、慢路径二次检查、`expires_in - 300s` 过期。
6. **单活跃 owner**：`upsert_connection` flush 前 revoke 旧 owner，部分唯一索引 commit 时满足；IntegrityError 重试。
7. **入站去重 fail-closed**：无 workspace/team/guild 标识时不去重（宁可重复处理也不跨工作区合并）。
8. **bound identity 重读校验**：manager 是 run 创建安全边界，不信任入站消息自带的 identity 字段，重读 connection repo 校验。

### 在端到端链路中的位置

本 skill owns [[e2e-request-lifecycle]] 的 **①入站-IM** 与 **⑧渲染-IM** 两跳：

- **①入站-IM**：IM 平台消息 -> channel adapter（出站长连接回调）-> `MessageBus.publish_inbound` -> `ChannelManager._dispatch_loop` -> `_handle_chat` -> `client.runs.wait/stream`（带内部 token + owner 头）-> 在 ②认证处与 Web/调度路径汇合（IM 走内部 token + owner 头 -> `user_context`）。
- **⑧渲染-IM**：agent 产出 -> `ChannelManager` 经 `MessageBus.publish_outbound` -> channel `send` -> 钉钉 AI Card 流式 patch / 飞书 patch card / Telegram 原地 edit / Slack-Discord wait / GitHub fire-and-forget。

owner 头与内部 token 的认证细节见 [[auth]]；run 生命周期与 `runs.wait/stream` 见 [[gateway-runs-and-sse]]；per-user 目录隔离见 [[multi-user-isolation]]；`ask_clarification` 中断与 `disable_clarification`/`non_interactive` 剥离见 [[system-prompt-template]] 与 [[scheduled-tasks]]。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `channels/channels/base.py` | `Channel` 抽象基类：`start`/`stop`/`send` 抽象 + `_on_outbound` 出站回调 + `_send_with_retry` 重试 + `_pending_connect_code` 绑定码 + `receive_file` 钩子 | [channel-abstraction.md](./references/code/channel-abstraction.md) §1 |
| `channels/channels/message_bus.py` | `InboundMessage`/`OutboundMessage`/`ResolvedAttachment` 数据类 + `MessageBus`（入站 `asyncio.Queue` / 出站回调列表） | [channel-abstraction.md](./references/code/channel-abstraction.md) §2 |
| `channels/channels/store.py` | `ChannelStore`：JSON 文件持久化 IM 会话 -> thread 映射（原子写） | [channel-abstraction.md](./references/code/channel-abstraction.md) §3 |
| `channels/channels/run_policy.py` | `ChannelRunPolicy` + `CHANNEL_RUN_POLICY` 注册表（fire_and_forget / is_interactive / requires_bound_identity） | [channel-abstraction.md](./references/code/channel-abstraction.md) §4 |
| `channels/channels/connection_identity.py` | `attach_connection_identity`：给入站消息贴 connection_id/owner_user_id | [channel-abstraction.md](./references/code/channel-abstraction.md) §5 |
| `core/helix/persistence/channel_connections/sql.py` | `ChannelConnectionRepository.upsert_connection` + `_revoke_other_active_owners`（单活跃 owner 迁移） | [channel-abstraction.md](./references/code/channel-abstraction.md) §6 |
| `channels/channels/manager.py` | `ChannelManager`：dispatch/chat/streaming/command + owner 头透传 + 入站去重 + bound identity 校验 + thread 创建竞争锁 | [channel-abstraction.md](./references/code/channel-abstraction.md) §7（§7.2 owner 头 / §7.7 _handle_chat / §7.8 流式） |
| `channels/channels/service.py` | `ChannelService`：生命周期 + 懒加载注册表 + 就绪轮询 + 单例 | [channel-abstraction.md](./references/code/channel-abstraction.md) §8 |
| `channels/channels/dingtalk.py` | `DingTalkChannel`（重头）：dingtalk-stream 出站长连接回调 + AI Card 流式 patch + sampleMarkdown 回退 + access token 缓存 | [dingtalk.md](./references/code/dingtalk.md) §1-6 |
| `channels/channels/{feishu,slack,telegram,discord,wechat,wecom,github}.py` | 各平台 adapter（差异见 im-differences.md） | [im-differences.md](./references/code/im-differences.md) §1-7 |
| `gateway/gateway/internal_auth.py` | `create_internal_auth_headers`（内部 token + owner 头，见 [[auth]]） | 见 [[auth]] |

### 入口伪代码（完整源码见 references/code/）

```python
# 伪代码：入站调度主流程（完整源码见 channel-abstraction.md §7.4 _dispatch_loop / §7.7 _handle_chat）
async def _dispatch_loop(self):
    while self._running:
        msg = await asyncio.wait_for(self.bus.get_inbound(), timeout=1.0)
        if self._is_duplicate_inbound(msg): continue      # provider 重投去重（fail-closed：无 workspace 标识不去重）
        asyncio.create_task(self._handle_message(msg))

async def _handle_chat(self, msg, *, bound_identity_checked=False):
    # bound identity 校验：run 创建安全边界，重读 connection repo，不信任入站 identity 字段
    if not bound_identity_checked and await self._get_bound_identity_rejection(msg): return
    thread_id, _ = await self._get_or_create_thread(client, msg)   # per-conversation 锁防重复创建
    assistant_id, run_config, run_context = self._resolve_run_params(msg, thread_id)
    policy = await self._apply_channel_policy(msg, run_context)    # fire_and_forget / disable_clarification
    headers = _owner_headers(msg)              # 内部 token + owner 头（_channel_storage_user_id 给 FS，两级分离）
    if policy and policy.fire_and_forget:
        await client.runs.create(thread_id, assistant_id, headers=headers, ...)   # GitHub：立即返回 pending
    elif self._channel_supports_streaming(msg.channel_name):
        await self._handle_streaming_chat(...)                    # 钉钉 AI Card / 飞书 patch / Telegram edit / 企微 stream
    else:
        result = await client.runs.wait(thread_id, assistant_id, headers=headers, ...)  # multitask reject -> thread busy
        await self.bus.publish_outbound(OutboundMessage(...))     # -> channel.send -> 平台

# 伪代码：钉钉出站（AI Card 流式 patch + sampleMarkdown 回退，完整源码见 dingtalk.md §2/§4/§5）
async def send(self, msg, *, _max_retries=3):
    out_track_id = self._card_track_ids.get(source_key)
    if self._card_template_id and not out_track_id and not msg.is_final: return   # 建卡失败跳过非终态 chunk
    if out_track_id:
        try: await self._stream_update_card(out_track_id, msg.text, is_finalize=msg.is_final)  # PUT /v1.0/card/streaming
        except Exception:
            if msg.is_final: await self._send_markdown_fallback(...)   # 仅终态回退（非终态吞掉防刷屏）
        return
    await self._send_with_retry(send_markdown, max_retries=_max_retries)   # 非卡片：sampleMarkdown 带重试

# 伪代码：SDK 回调线程 -> 主循环 MessageBus（完整源码见 dingtalk.md §3）
def _on_chatbot_message(self, message):
    inbound = self._make_inbound(chat_id=..., user_id=sender_staff_id, text=...,
                                 topic_id=msg_id if group else None)
    asyncio.run_coroutine_threadsafe(self._prepare_inbound(chat_id, inbound), self._main_loop)  # 跨线程扔回主循环
```

### 模块索引

- **Channel 抽象层**（base + message_bus + store + run_policy + connection_identity + manager + service + 单活跃 owner 迁移，§1-8）：[references/code/channel-abstraction.md](./references/code/channel-abstraction.md)
- **钉钉完整源码**（dingtalk-stream 出站长连接回调 + AI Card 创建/流式 patch + sampleMarkdown 回退 + access token 缓存 + markdown 适配 + media 上传 + `/connect` 绑定 + P2P/群路由，§1-6）：[references/code/dingtalk.md](./references/code/dingtalk.md)
- **各 IM 差异片段**（飞书 patch card / Slack Socket Mode wait / Telegram 原地 edit / Discord thread+typing / 微信 iLink long-poll / 企微 WS reply_stream / GitHub webhook fire-and-forget，§1-7）：[references/code/im-differences.md](./references/code/im-differences.md)

## 反模式与陷阱

- ❌ **webhook 暴露公网** -> 除 GitHub 外所有 IM 都不该用 webhook。后果：需要公网 IP/端口、暴露入站端点被扫描、签名校验失败即丢消息、serverless 冷启动接不上。修复：用出站长连接（钉钉 dingtalk-stream / 飞书 lark ws / Slack Socket Mode / Discord gateway / 企微 ws），SDK 自带重连，agent 侧零公网暴露。
- ❌ **access token 不缓存致限流** -> 每条消息调 `oauth2/accessToken` 换 token，钉钉该接口限流，高并发 429。或缓存了但不加锁，N 个并发请求同时换 token 互相覆盖。修复：double-check lock（快路径无锁读、慢路径加锁二次检查）+ 提前量（`expires_in - 300s` 过期）。
- ❌ **AI Card patch 失败无回退** -> 卡片流中途断了，用户看到半截"运行中"卡片永远不更新。或所有 chunk 失败都回退 sampleMarkdown，导致刷屏 N 条独立消息。修复：仅**最终消息**回退 sampleMarkdown；非最终 chunk 失败吞掉（下一个 chunk 或终态会补上）。
- ❌ **owner 头缺失致串用户** -> IM channel 调 Gateway 不带 `X-Helix-Owner-User-Id`，所有 IM 消息的 per-user 目录落到 `"default"` 桶，不同用户互相看到对方的 uploads/memory。修复：`_owner_headers(msg)` 透传绑定 owner；`_channel_storage_user_id` 给文件系统用 sanitize 后 id。两者分离：HTTP 传原始 id，FS 用 safe id。
- ❌ **owner 头与 storage id 混用** -> 用 `_owner_headers` 的原始 id 直接做文件路径，或用 `_channel_storage_user_id` 的 safe id 做 HTTP 头。后果：前者路径穿越/跨用户冒充（原始 id 含 `/`/`..`）；后者 Gateway 侧重复 sanitize 或 id 不一致。修复：严格分离--HTTP 走原始 id（Gateway 规范化），FS 走 safe id（本地规范化）。
- ❌ **多实例同 channel 抢连接** -> 两个进程都跑 dingtalk-stream，SDK 各自建一条 WebSocket，平台只认最后注册的，旧连接被踢且消息随机丢。修复：channel 连接是单实例资源；多实例部署需用 lease/leader election 保证同一 channel 同一时刻只有一个实例连，或把 channel 抽成独立 worker。
- ❌ **SDK 线程直接操作主循环资源** -> dingtalk-stream/lark-oapi 回调跑在 SDK 自己的线程/事件循环，直接 `await bus.publish_inbound()` 会跑错循环或线程不安全。修复：`asyncio.run_coroutine_threadsafe(coro, self._main_loop)` 把协程扔回主循环，配 `add_done_callback(self._log_future_error)` 兜底异常。
- ❌ **入站去重跨工作区合并** -> 用 `(channel, chat_id, message_id)` 去重，但 Slack channel id 不跨 workspace 全局唯一，两个 workspace 的同 channel id 消息被误去重丢一条。修复：去重 key 含 `workspace_id`（team_id/guild_id/aibotid），无 workspace 标识时 fail-closed 不去重（宁可重复也不合并）。
- ❌ **thread 创建竞争致孤儿** -> 两条消息几乎同时到达同一 chat，都查不到 thread，都创建一个，第二个覆盖第一个的 store 映射，Gateway 侧孤儿一个 thread。修复：per-conversation `asyncio.Lock`（`_thread_create_locks`），锁内二次查 store，只有第一个创建；用完即删锁保持 registry 有界。
- ❌ **lark-oapi 与 uvloop 冲突** -> `lark.ws.Client.start()` 在主线程 uvloop 上调 `loop.run_until_complete()`，而 uvloop 已在跑，抛 `RuntimeError`。修复：把 ws client 放独立线程，新建普通 asyncio loop，patch SDK 模块级 `lark_oapi.ws.client.loop = loop` 再 start。
- ❌ **Telegram 流式 edit 触发 rate-limit 不降级** -> 群聊 20 msg/min 限制下仍 1 msg/s edit，被 429 后整条流卡死。修复：群聊 `STREAM_EDIT_GROUP_MIN_INTERVAL_SECONDS=3.0`（私聊 1.0）；rate-limit（`retry_after`）时静默丢这次 edit，终态消息保底送达。
- ❌ **fire-and-forget 通道用 runs.wait** -> GitHub agent 自主长 run 超 5 分钟，SDK `httpx.ReadTimeout`（300s）触发，manager 误判"内部错误"发一条假错误评论。修复：`ChannelRunPolicy.fire_and_forget=True` 改用 `runs.create`（立即返回 pending），`ConflictError` 仍同步抛（保留 busy-thread 路径）。
- ❌ **单活跃 owner 迁移顺序错** -> 先 flush 自己的 `connected` 行再 revoke 旧 owner，撞部分唯一索引 `IntegrityError`，或 revoke 失败但自己已 commit，两 owner 同时活跃。修复：`_revoke_other_active_owners` 在 flush **之前**执行；`IntegrityError` rollback 重试（重读已可见状态）。
- ❌ **bound identity 信任入站字段** -> 直接用 `msg.connection_id`/`msg.owner_user_id` 创建 run，攻击者伪造这两个字段即冒充任意 owner。修复：manager 是 run 创建安全边界，`_get_bound_identity_rejection` **重读** connection repo（`find_connection_by_external_identity`）校验，不匹配则拒绝并只保留服务端 connection 字段做出站路由。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `_TOKEN_REFRESH_MARGIN_SECONDS` | dingtalk.py | access token 提前过期量（默认 300s）；过小有边缘过期风险，过大则换 token 更频繁 |
| `_max_retries`（send） | base.py `_send_with_retry` | 出站重试次数（默认 3），指数退避 `2**attempt` |
| `STREAM_UPDATE_MIN_INTERVAL_SECONDS` | manager.py | 流式出站最小间隔（默认 1.0s），防 IM 平台限流 |
| `STREAM_UPDATE_MIN_CHARS` | manager.py | 流式出站累计字符阈值（默认 60），达阈值立即 flush |
| `STREAM_EDIT_MIN_INTERVAL_SECONDS` / `STREAM_EDIT_GROUP_MIN_INTERVAL_SECONDS` | telegram.py | Telegram edit 节流（私聊 1.0s / 群聊 3.0s，群聊 20 msg/min 限制） |
| `INBOUND_DEDUPE_TTL_SECONDS` / `INBOUND_DEDUPE_MAX_ENTRIES` | manager.py | 入站去重 TTL（默认 600s）/ 最大条目（默认 4096） |
| `max_concurrency` | ChannelManager | 并发处理入站消息的信号量上限（默认 5） |
| `_UPSERT_MAX_ATTEMPTS` | channel_connections/sql.py | 单活跃 owner 迁移的 IntegrityError 重试次数（默认 3） |
| `card_template_id` | dingtalk config | 非空启用 AI Card 流式 patch；空则纯 sampleMarkdown |
| `FEISHU_INBOUND_BATCH_WINDOW_SECONDS` | feishu.py | 飞书连续文件消息合并窗口（默认 0.75s） |
| `HELIX_CHANNELS_LANGGRAPH_URL` / `HELIX_CHANNELS_GATEWAY_URL` | service.py env | channel 连 Gateway 的 URL 覆盖 |
| `ChannelRunPolicy.fire_and_forget` / `is_interactive` / `requires_bound_identity` | run_policy.py | 每通道 run 策略（GitHub: fire_and_forget=True, is_interactive=False, requires_bound_identity=False） |

### 关键日志串

- `[Manager] received inbound: channel=..., chat_id=..., type=..., text_len=..., files=...` - ①入站消息到达 dispatcher
- `[Manager] duplicate inbound ignored: channel=..., chat_id=..., message_id=...` - 入站去重命中（provider 重投）
- `[Manager] invoking runs.wait(thread_id=..., text_len=...)` / `runs.stream(...)` / `runs.create(...) [fire_and_forget]` - 调 Gateway run 的三种路径
- `[Manager] thread busy (concurrent run rejected): thread_id=...` - multitask reject 命中
- `[DingTalk] AI card created: outTrackId=...` - 钉钉 AI 卡片建卡成功
- `[DingTalk] card stream failed, falling back to sampleMarkdown` - 卡片流失败回退
- `[DingTalk] AI card running reply sent for chat=...` - "运行中"卡片占位发出
- `[Bus] inbound enqueued: channel=..., queue_size=...` - MessageBus 入队
- `[Manager] rejecting unbound channel message: channel=..., chat_id=...` - bound identity 校验失败
- `[Manager] threads.create raced on preferred_thread_id=...; reusing the deterministic id` - GitHub thread 创建竞争恢复
- `WeCom WebSocket disconnected...; SDK will attempt to reconnect` - 企微断线（SDK 自重连）
- `[Telegram] stream edit rate-limited in chat=..., dropping update` - Telegram edit 限流降级

### 自测方向

- **出站回调 -> run 链路**：mock 一个 `InboundMessage` 发到 bus，断言 manager 起了 run、Gateway 收到带内部 token + owner 头的 `runs.wait` 调用、响应经 bus 回到 channel 的 `send`。
- **AI Card patch 回退**：mock `_stream_update_card` 抛异常，断言非最终 chunk 不回退（直接 return）、最终 chunk 回退 `_send_markdown_fallback`、`_card_track_ids`/`_card_repliers` 被清理。
- **access token 缓存**：连续调 `_get_access_token` 两次，断言只换一次 token（httpx post 只调一次）；mock token 即将过期，断言提前刷新；并发 10 个 `_get_access_token`，断言只换一次（double-check lock）。
- **owner 隔离**：两条不同 owner 的 IM 消息，断言 `_owner_headers` 返回不同 owner 头、`_channel_storage_user_id` 返回不同 safe id、文件落到不同 `users/{id}/` 桶；无 owner 头的内部调用落 `"default"`。
- **owner 头门控**：浏览器调用者（仅 cookie）塞 owner 头，断言被 `get_trusted_internal_owner_user_id` 无视（见 [[auth]]）。
- **单活跃 owner 迁移**：owner A 绑定钉钉身份 X，再让 owner B 绑定同一 X，断言 A 的 connection 变 `revoked`、A 的 credential 被删、B 的 connection `connected`；此后 X 的消息归属 B。
- **入站去重 fail-closed**：无 workspace_id 的消息，断言不去重（`_inbound_dedupe_key` 返回 None）；有 workspace_id 的重投，断言第二次被去重。
- **thread 创建竞争**：并发两条同 chat 消息，断言只创建一个 thread（`_thread_create_locks` 串行化）。
- **多 IM 差异**：分别 mock 钉钉/飞书/Telegram/Slack/Discord/GitHub 的入站，断言各自的流式路径（AI Card / patch card / edit / wait / fire-and-forget）与 thread 映射（topic_id）正确。
- **fire-and-forget**：GitHub channel 消息，断言用 `runs.create`（非 `runs.wait`）、`ConflictError` 仍同步抛 busy。
- **跨线程通信**：mock SDK 回调线程调 `_on_chatbot_message`，断言 `run_coroutine_threadsafe` 把 `publish_inbound` 扔回主循环执行。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整源码：[references/code/dingtalk.md](./references/code/dingtalk.md)、[references/code/channel-abstraction.md](./references/code/channel-abstraction.md)、[references/code/im-differences.md](./references/code/im-differences.md)
- 端到端链路（本 skill 处于 ①入站-IM + ⑧渲染-IM 跳）：[[e2e-request-lifecycle]]
- 内部 token + owner 头（`X-Helix-Internal-Token` / `X-Helix-Owner-User-Id` / `create_internal_auth_headers`）：[[auth]]
- run 生命周期与 `runs.wait/stream`（`RunManager` / `run_agent` worker）：[[gateway-runs-and-sse]]
- per-user 目录隔离（owner 头 -> `user_context` -> 文件桶）：[[multi-user-isolation]]
- `ask_clarification` 中断与 `disable_clarification` / `non_interactive` 剥离：[[system-prompt-template]]、[[scheduled-tasks]]
- 长任务取消与 `multitask_strategy`（thread busy / reject）：[[long-running-and-cancellation]]
- 配置与热重载（`channels.<name>` 配置 + 运行时 overlay）：[[config-and-hot-reload]]
