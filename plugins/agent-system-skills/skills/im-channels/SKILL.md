---
name: im-channels
description: IM 渠道接入体系：Channel(ABC) 抽象（start/stop/send + 可选流式/文件/主动通知）、MessageBus 确认式入队（InboundReservation 防丢）、ChannelManager worker 池（去重→绑定身份→线程查找→忙线 followup 合并→经内部令牌 HTTP 回环调 Gateway）、ChannelStore 线程绑定 + Postgres 去重存储、leader 租约多实例仲裁、run_policy/allowed_users/能力静态表、十个平台实现（飞书卡片/Slack/Discord/Telegram/钉钉/企微/微信 QR/ QQ 自实现 ws/GitHub webhook/Buzz Nostr）。当要把 agent 接进任何 IM、排查"消息丢/重复/线程串/机器人不回"时使用。
---

# IM 渠道体系

## 何时用

- 把 agent 接入 IM（新增平台或理解既有十平台之一）
- 渠道消息可靠性（去重、确认式消费、忙线合并）
- 多实例部署下渠道 leadership / 线程绑定
- GitHub issue/评论触发的 agent（webhook 型渠道）

## 设计方案（为什么这么设计）

### 1. 渠道是纯适配器

`Channel(ABC)`（base.py:102）：抽象 `start/stop/send`，可选 `send_file` / `send_notification(_for_owner)`（主动推送，能力表声明）/ `supports_streaming`。**平台 SDK 的全部怪癖被锁在渠道类内**；管理器只面对 InboundMessage/OutboundMessage。私有事件循环的渠道（飞书 ws 回调）经 tracked future 桥接回 Gateway 主循环。

### 2. 总线：确认式入队

`MessageBus`（message_bus.py:182）：`publish_inbound/reserve_inbound/get_inbound/publish_outbound/subscribe_outbound`。入站消息先**预订（reservation）**再处理，处理成功才确认——worker 崩溃消息回队不丢。`InboundMessage` 统一字段（channel_name/chat_id/user_id/text/topic_id/connection_id/owner_user_id/files/metadata），附件经 `ResolvedAttachment` 延迟解析。

### 3. 管理器：固定并发 worker 池 + 全链防线

`ChannelManager`（manager.py，3790 行）`_worker_loop` → `_handle_message`：
1. **去重**（dedupe_store：内存/Postgres，多 worker 共享）
2. **绑定身份校验**（allowed_users 白名单 + connection_identity）
3. **线程查找/创建**（ChannelStore：`channel:chat[:topic]` → thread_id）
4. **命令分派**（/agent /model /goal /help、@mention 剥离、connect code、斜杠技能）
5. **忙线合并**：线程已有活跃 run 时 followup 进缓冲，run 结束统一合并续跑（`_buffer_followup`/`_watch_run_and_drain_followups`）——避免每条群消息抢一个 run
6. **发起 run**：`langgraph_sdk.get_client(url=内部网关, headers={internal token + csrf})` **HTTP 回环**调 Gateway——渠道与 Web 走完全相同的 run 路径（scheduler 决定 when，渠道决定 where）
7. `_apply_channel_policy`（ChannelRunPolicy：渠道特化的并发/许可）

### 4. 多实例：leader 租约

`ChannelLeadership`（leadership.py）：租约续期（RenewOutcome）仲裁同一渠道多副本只有一个消费；租约存储与去重存储均支持 Postgres（多实例硬要求）。

### 5. 能力静态表

`capabilities.py`：`proactive_notifications`/`proactive_group_notifications` 按**渠道名**查表——调度器只读表不 import 渠道类（通知投递不拉起整个渠道栈）。

### 6. 十平台差异速览

| 渠道 | 流式 | 特殊机制 |
|---|---|---|
| feishu（2018 行） | ✗ | ws 私有 loop、卡片交互（按钮）、lark broker 进程 |
| slack / discord / qq | ✗/✗/✗ | qq 自实现 ws gateway |
| telegram / dingtalk / wecom / buzz | ✓ | buzz 走 Nostr 协议 + seen events 去重 |
| wechat（1875 行） | ✗ | 加密媒体上传、QR 登录 |
| github（115 行，最薄） | ✗ | 无长连接：webhook dispatcher 投递到 bus；**run-context 通道扣留 update_agent**（见 [[agent-graph-factory]]） |

## 实现索引

`references/code/backend/app/channels/`（42 文件 23190 行，整目录）+ 关联：

| 关键文件 | 行数 | 职责 |
|---|---|---|
| `channels/base.py` / `message_bus.py` / `manager.py` | 530/375/3790 | 抽象/总线/管理器 |
| `channels/service.py` + `_CHANNEL_REGISTRY` | 1118 | 渠道注册与启停 |
| `channels/store.py` / `dedupe_store.py` / `runtime_config_store.py` / `leadership.py` | 400/309/218/225 | 绑定/去重/运行时配置/租约 |
| `channels/{run_policy,allowed_users,commands,capabilities,notification_groups,connection_identity,inbound_files,sandbox_files}.py` | — | 策略/白名单/命令/能力表 |
| `channels/{feishu,slack,discord,telegram,dingtalk,wechat,wecom,qq,github,buzz}.py` | 2018/786/1247/1308/1325/1875/818/611/115/1756 | 十平台 |
| `channels/{feishu_card_interaction,wechat_qr_login,buzz_nostr,buzz_seen_events}.py` | 247/225/201/385 | 平台配套 |
| `backend/app/github/`（dispatcher/app_auth/triggers/registry/run_policy/identity/prompts） | 490+229+208+148+149+91+222 | webhook 事件驱动 |
| `backend/app/gateway/routers/{channels,channel_connections,github_webhooks,integrations}.py` | 63/850/387/423 | 渠道管理 API |
| `helix/integrations/lark_broker.py` | 549 | lark CLI 本地 broker（deny 子命令/原子写） |

## 反模式与陷阱

- ❌ 渠道直连运行时（不经 Gateway HTTP） → 绕过信任边界与统一 run 语义；回环 + 内部令牌。
- ❌ 入队即消费无确认 → 崩溃丢消息；reservation 确认式。
- ❌ 忙线时每消息起 run → run 风暴 + 乱序；followup 缓冲合并。
- ❌ 去重只做内存 → 多 worker 重复消费；Postgres 共享。
- ❌ 调度器 import 渠道类发通知 → 拉起全渠道栈；能力静态表。
- ❌ webhook 型渠道暴露自变更工具 → 外部评论者永久改 agent（见扣留机制）。

## 落地参考

**自测方向**：同消息重投只跑一次；worker 中途崩溃消息回队；忙线 followup 合并成一次续跑；leader 失联后备副本接管；github 评论者触发的 run 工具集不含 update_agent。

**调试**：ChannelManager 分派日志、去重命中、followup 缓冲日志。

## 进一步阅读

- [[e2e-request-lifecycle]]（渠道是 run 的一种发起方）、[[scheduled-tasks]]（通知投递消费能力表）
- [[auth]]（内部令牌）、[[gateway-runs-and-sse]]（被回环调用的面）
