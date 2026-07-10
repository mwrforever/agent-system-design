# 各 IM 平台差异片段对照（飞书/Slack/Telegram/Discord/微信/企微/GitHub）

> 本文件给出七家 IM 平台 adapter 的**关键差异片段**：入站连接方式、`send` 出站渲染策略、流式处理、thread 映射、绑定方式。每个平台只摘取最能体现差异的部分；完整 adapter 源码归真实仓库的 `channels/channels/<platform>.py`。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `channels.channels.*` / `gateway.gateway.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 差异速查表

| 平台 | 入站连接 | 流式渲染 | thread 映射 | 绑定方式 | 关键 SDK |
|---|---|---|---|---|---|
| 钉钉 | `dingtalk-stream` WebSocket | AI Card patch + sampleMarkdown 回退 | P2P: None；群: msg_id | `/connect <code>` | `dingtalk-stream` |
| 飞书 | `lark-oapi` WebSocket | patch card + OK/DONE 反应 | P2P: None；群: root_id/parent_id | `/connect <code>` | `lark-oapi` |
| Slack | Socket Mode WebSocket | wait + eyes/✅/❌ 反应 | thread_ts（原生 thread） | `/connect <code>` | `slack_sdk` |
| Telegram | long-poll getUpdates | 原地 edit_message_text（节流） | P2P: None；群: reply_to | `/start <token>` 深链 | `python-telegram-bot` |
| Discord | `discord.py` gateway WebSocket | wait + typing + ✅ 反应 | thread_ts（mention 创建 thread） | `/connect <code>` | `discord.py` |
| 微信 | iLink long-poll getupdates | wait（sendmessage 终态发） | None（单用户单 thread） | `/connect <code>` | httpx 直连 |
| 企微 | `wecom-aibot-python-sdk` WebSocket | reply_stream（WS 流式） | user_id（单用户单 thread） | `/connect <code>` | `wecom-aibot-python-sdk` |
| GitHub | **webhook**（HMAC 签名） | **fire-and-forget**（agent 用 gh CLI） | preferred_thread_id（repo+number） | agent config.yaml | httpx/webhook |

---

## 1. 飞书：patch card 流式 + OK/DONE 表情反应

飞书用 `lark-oapi` 的 WebSocket 长连接接消息。流式渲染靠 `im.v1.message.patch` **原地更新已有 card 消息**，配 OK（收到）/DONE（完成）表情反应。

### 1.1 send（patch card 原地更新 + 终态反应）

```python
# channels/channels/feishu.py
class FeishuChannel(Channel):
    """飞书/Lark IM channel using the ``lark-oapi`` WebSocket client.

    消息流：
        1. 用户发消息 -> bot 加 "OK" emoji 反应
        2. bot 回一张 card："Working on it......"
        3. agent 处理消息返回结果
        4. bot 用结果 patch（原地更新）那张 card
        5. bot 给原消息加 "DONE" emoji 反应
    """

    @property
    def supports_streaming(self) -> bool:
        return True     # 飞书支持 patch card 流式

    async def _send_card_message(self, msg: OutboundMessage) -> None:
        """Send or update the Feishu card tied to the current request.

        有 source_message_id（即 msg.thread_ts）时走 in-thread 回复：
        - 已有 running card -> patch 原地更新（流式 chunk）
        - patch 失败且是终态 -> 回退 _reply_card 新建一张
        - 无 running card 且非终态 -> 起 _create_running_card 任务
        - 无 running card 且终态 -> _reply_card 直接发终态
        """
        source_message_id = msg.thread_ts
        if source_message_id:
            running_card_id = self._running_card_ids.get(source_message_id)
            awaited_running_card_task = False

            if not running_card_id:
                running_card_task = self._running_card_tasks.get(source_message_id)
                if running_card_task:
                    awaited_running_card_task = True
                    running_card_id = await running_card_task

            if running_card_id:
                try:
                    await self._update_card(running_card_id, msg.text)    # im.v1.message.patch 原地更新
                except Exception:
                    if not msg.is_final:
                        raise       # 非终态 patch 失败：抛错触发重试
                    # 终态 patch 失败：回退 _reply_card 新建一张
                    logger.exception("[Feishu] failed to patch running card %s, falling back to final reply", running_card_id)
                    fallback_card_id = await self._reply_card(source_message_id, msg.text)
                    self._remember_thread_mapping(msg, source_message_id, fallback_card_id)
                    self._remember_pending_clarification(msg, fallback_card_id)
                else:
                    self._remember_thread_mapping(msg, source_message_id, running_card_id)
                    self._remember_pending_clarification(msg, running_card_id)
                    logger.info("[Feishu] running card updated: source=%s card=%s", source_message_id, running_card_id)
            elif msg.is_final:
                final_card_id = await self._reply_card(source_message_id, msg.text)
                self._remember_thread_mapping(msg, source_message_id, final_card_id)
                self._remember_pending_clarification(msg, final_card_id)
            else:
                created_card_id = await self._ensure_running_card(source_message_id, msg.text)
                self._remember_thread_mapping(msg, source_message_id, created_card_id)

            if msg.is_final:
                self._running_card_ids.pop(source_message_id, None)
                await self._add_reaction(source_message_id, "DONE")     # 终态加 DONE 反应
            return

        await self._create_card(msg.chat_id, msg.text)

    async def _update_card(self, message_id: str, text: str) -> None:
        """Patch an existing card message in place (im.v1.message.patch)."""
        if not self._api_client or not self._PatchMessageRequest:
            return
        content = self._build_card_content(text)
        request = self._PatchMessageRequest.builder().message_id(message_id).request_body(
            self._PatchMessageRequestBody.builder().content(content).build()).build()
        await asyncio.to_thread(self._api_client.im.v1.message.patch, request)

    @staticmethod
    def _build_card_content(text: str) -> str:
        """Build a Feishu interactive card with markdown content.

        飞书 interactive card 原生渲染 markdown（headers/bold/code/lists/links）。
        """
        card = {
            "config": {"wide_screen_mode": True, "update_multi": True},   # update_multi: True 允许多次 patch
            "elements": [{"tag": "markdown", "content": text}],
        }
        return json.dumps(card)
```

### 1.2 入站：lark ws 线程 + uvloop 冲突规避

```python
    def _run_ws(self, app_id: str, app_secret: str, domain: str) -> None:
        """在独立线程跑 lark ws client（配新事件循环，规避 uvloop 冲突）。

        lark-oapi SDK 在 import 时缓存模块级 event loop（lark_oapi.ws.client.loop）。
        当 uvicorn 用 uvloop 时，那个 loop 是主线程的 uvloop--已在运行，
        Client.start() 里的 loop.run_until_complete() 会抛 RuntimeError。
        解法：本线程建一个普通 asyncio loop，patch SDK 模块级引用再 start。
        """
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            import lark_oapi as lark
            import lark_oapi.ws.client as _ws_client_mod

            # 替换 SDK 模块级 loop，使 Client.start() 用本线程的（未运行的）loop
            _ws_client_mod.loop = loop

            event_handler = self._build_event_handler(lark)
            ws_client = lark.ws.Client(
                app_id=app_id,
                app_secret=app_secret,
                event_handler=event_handler,
                log_level=lark.LogLevel.INFO,
                domain=domain,
            )
            ws_client.start()
        except Exception:
            if self._running:
                logger.exception("Feishu WebSocket error")
            self._running = False

    async def _prepare_inbound(self, msg_id: str, inbound, *, source_message_ids=None) -> None:
        """入站侧效果：加 OK 反应 + 起 running card，不阻塞 dispatch。"""
        inbound = await self._attach_connection_identity(inbound)
        reaction_message_ids = source_message_ids or [msg_id]
        for reaction_message_id in reaction_message_ids:
            reaction_task = asyncio.create_task(self._add_reaction(reaction_message_id, "OK"))
            self._track_background_task(reaction_task, name="add_reaction", msg_id=reaction_message_id)
        self._ensure_running_card_started(msg_id)      # 异步起 running card（不阻塞 publish_inbound）
        await self.bus.publish_inbound(inbound)
```

> **飞书关键差异**：`update_multi: True` 允许同一张 card 被多次 patch（流式前提）；P2P 用 `topic_id=None`（单 thread），群用 `root_id`/`parent_id`（回复链）；连续文件消息有 0.75s 批合并窗口（`FEISHU_INBOUND_BATCH_WINDOW_SECONDS`）。

---

## 2. Slack：Socket Mode + wait（eyes/✅/❌ 反应）

Slack 用 Socket Mode（WebSocket），不支持原地流式更新，故 `send` 等终态一次性 `chat_postMessage`，配 eyes（收到）/✅（完成）/❌（失败）表情反应。

```python
# channels/channels/slack.py
class SlackChannel(Channel):
    """Slack IM channel using Socket Mode (WebSocket, no public IP).

    Configuration keys:
        - ``bot_token``: Slack Bot User OAuth Token (xoxb-...).
        - ``app_token``: Slack App-Level Token (xapp-...) for Socket Mode.
        - ``allowed_users``: (optional) List of allowed Slack user IDs.
    """

    async def start(self) -> None:
        # ...
        from slack_sdk import WebClient
        from slack_sdk.socket_mode import SocketModeClient

        bot_token = self.config.get("bot_token", "")
        app_token = self.config.get("app_token", "")

        if self.config.get("event_delivery") == "http":
            logger.error("Slack HTTP Events mode is not supported by this channel adapter; use Socket Mode with app_token")
            return

        if not bot_token or not app_token:
            logger.error("Slack channel requires bot_token and app_token")
            return

        await self._initialize_operator_web_client(str(bot_token))
        self._socket_client = SocketModeClient(app_token=app_token, web_client=self._web_client)
        self._loop = asyncio.get_event_loop()

        self._socket_client.socket_mode_request_listeners.append(self._on_socket_event)

        self._running = True
        self.bus.subscribe_outbound(self._on_outbound)

        # Socket Mode 在后台线程跑（executor）
        asyncio.get_event_loop().run_in_executor(None, self._socket_client.connect)

    async def send(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
        """Slack send：chat_postMessage（终态发）+ 完成反应。

        Slack 不支持原地流式更新，故等终态一次性发。
        markdown 转 mrkdwn（Slack 专用格式）。
        """
        web_client = await self._get_web_client_for_message(msg)
        if not web_client:
            return

        kwargs: dict[str, Any] = {
            "channel": msg.chat_id,
            "text": _slack_md_converter.convert(msg.text),   # markdown -> Slack mrkdwn
        }
        if msg.thread_ts:
            kwargs["thread_ts"] = msg.thread_ts       # Slack 原生 thread

        async def post_message() -> None:
            await asyncio.to_thread(web_client.chat_postMessage, **kwargs)
            # 给 thread 根消息加完成反应
            if msg.thread_ts:
                await asyncio.to_thread(self._add_reaction_with_client, web_client,
                                        msg.chat_id, msg.thread_ts, "white_check_mark")

        try:
            await self._send_with_retry(post_message, max_retries=_max_retries, log_prefix="[Slack]")
        except Exception:
            # 失败反应
            if msg.thread_ts:
                try:
                    await asyncio.to_thread(self._add_reaction_with_client, web_client,
                                            msg.chat_id, msg.thread_ts, "x")
                except Exception:
                    pass
            raise

    def _on_socket_event(self, client, req) -> None:
        """Socket Mode 事件回调：先 ACK，再处理 message/app_mention。"""
        try:
            response = self._SocketModeResponse(envelope_id=req.envelope_id)
            client.send_socket_mode_response(response)     # 先 ACK

            event = req.payload.get("event", {})
            etype = event.get("type", "")
            if etype in ("message", "app_mention"):
                self._handle_message_event(
                    event,
                    team_id=req.payload.get("team_id") or req.payload.get("team") or event.get("team"),
                )
        except Exception:
            logger.exception("Error processing Slack event")

    def _handle_message_event(self, event: dict, *, team_id: str | None = None) -> None:
        # 忽略 bot 消息
        if event.get("bot_id") or event.get("subtype"):
            return
        # ...
        if self._loop and self._loop.is_running():
            # eyes 反应（收到）+ "Working on it..." 回复（fire-and-forget 从 SDK 线程）
            self._add_reaction(channel_id, event.get("ts", thread_ts), "eyes")
            self._send_running_reply(channel_id, thread_ts)
            asyncio.run_coroutine_threadsafe(self._publish_inbound_with_connection(inbound, team_id=team_id), self._loop)
```

> **Slack 关键差异**：Socket Mode（app_token 驱动）；不支持原地流式，靠反应（eyes/✅/❌）反馈状态；`thread_ts` 是 Slack 原生 thread（非线程则用消息自身 ts 做 topic）；`team_id` 做 workspace 维度（去重 key 含它）；per-connection `WebClient` 缓存（OAuth 安装的 bot 各自带 token）。

---

## 3. Telegram：long-poll + 原地 edit_message_text（节流 + rate-limit 降级）

Telegram 用 long-poll（`getUpdates`），支持 `edit_message_text` 原地编辑已发消息，故流式靠 edit。但 Telegram 有严格 rate-limit（群 20 msg/min），必须节流 + 限流降级。

```python
# channels/channels/telegram.py
class TelegramChannel(Channel):
    """Telegram bot channel using long-polling.

    Configuration keys:
        - ``bot_token``: Telegram Bot API token (from @BotFather).
        - ``allowed_users``: (optional) List of allowed Telegram user IDs.
    """

    STREAM_EDIT_MIN_INTERVAL_SECONDS = 1.0
    # 群（负 chat_id）被 Telegram 限 20 msg/min，流式 edit 必须远低于私聊 1 msg/s
    STREAM_EDIT_GROUP_MIN_INTERVAL_SECONDS = 3.0
    MAX_TRACKED_STREAM_MESSAGES = 256     # 防流式消息追踪泄漏（final 没到的兜底）

    @property
    def supports_streaming(self) -> bool:
        return True

    async def send(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
        """Telegram send：非终态 edit 原地更新，终态 finalize（edit + 溢出分条）。"""
        try:
            chat_id = int(msg.chat_id)
        except (ValueError, TypeError):
            logger.error("Invalid Telegram chat_id: %s", msg.chat_id)
            return

        key = self._stream_key(msg.chat_id, msg.thread_ts)

        if not msg.is_final:
            await self._send_stream_update(chat_id, key, msg.text,
                                           reply_to=self._parse_message_id(msg.thread_ts))
            return

        state = self._stream_messages.pop(key, None)
        if state is not None:
            await self._finalize_stream_message(chat_id, msg.chat_id, state, msg.text)
            return

        await self._send_new_message(chat_id, msg.chat_id, msg.text, _max_retries=_max_retries)

    async def _send_stream_update(self, chat_id: int, key: str, text: str, reply_to: int | None = None) -> None:
        """Edit the in-flight streamed message with accumulated text.

        节流：私聊 1s / 群 3s 间隔；rate-limit（retry_after）时静默丢这次 edit。
        manager 总会在之后发终态消息，保证完整文本送达。
        """
        if not text:
            return

        display = text
        if len(display) > TELEGRAM_MAX_MESSAGE_LENGTH:
            display = display[: TELEGRAM_MAX_MESSAGE_LENGTH - 1] + "…"

        bot = self._application.bot
        state = self._stream_messages.get(key)

        send_kwargs: dict[str, Any] = {"chat_id": chat_id, "text": display}
        if reply_to:
            send_kwargs["reply_to_message_id"] = reply_to

        if state is None:
            # 首次：发新消息并注册为流式目标
            try:
                sent = await bot.send_message(**send_kwargs)
            except Exception:
                logger.exception("[Telegram] failed to start stream message in chat=%s", chat_id)
                return
            self._register_stream_message(key, message_id=sent.message_id, last_text=display, last_edit_at=_monotonic())
            return

        now = _monotonic()
        # 群聊用更长的节流间隔（Telegram 群 20 msg/min 限制）
        min_interval = STREAM_EDIT_GROUP_MIN_INTERVAL_SECONDS if chat_id < 0 else STREAM_EDIT_MIN_INTERVAL_SECONDS
        if now - state["last_edit_at"] < min_interval:
            return      # 节流：间隔不够，跳过这次 edit
        if display == state["last_text"]:
            return      # 内容没变，跳过

        try:
            await bot.edit_message_text(chat_id=chat_id, message_id=state["message_id"], text=display)
        except Exception as exc:
            if self._is_not_modified(exc):
                state["last_text"] = display
                return      # "message is not modified"：内容相同，静默
            if self._is_retry_after(exc):
                logger.debug("[Telegram] stream edit rate-limited in chat=%s, dropping update", chat_id)
                return      # rate-limit：静默丢这次 edit，终态会保底
            logger.warning("[Telegram] stream edit failed in chat=%s, sending new message: %s", chat_id, exc)
            # edit 失败（非限流）：fallback 发新消息并更新追踪
            try:
                sent = await bot.send_message(**send_kwargs)
            except Exception:
                logger.exception("[Telegram] failed to send fallback stream message in chat=%s", chat_id)
                return
            state["message_id"] = sent.message_id

        state["last_edit_at"] = _monotonic()
        state["last_text"] = display

    async def _finalize_stream_message(self, chat_id: int, chat_key: str, state: dict[str, Any], text: str) -> None:
        """终态：edit 流式消息成最终文本，溢出部分分条发新消息。"""
        bot = self._application.bot
        chunks = self._split_message(text or "")

        edited = True
        if chunks[0] != state["last_text"]:
            edited = await self._edit_final_chunk(bot, chat_id, state["message_id"], chunks[0])

        if edited:
            self._last_bot_message[chat_key] = state["message_id"]
        else:
            # edit 失败（如消息被删）：第一条分块用新消息发
            await self._send_new_message(chat_id, chat_key, chunks[0])

        for chunk in chunks[1:]:
            await self._send_new_message(chat_id, chat_key, chunk)
```

> **Telegram 关键差异**：long-poll（非 WebSocket）；原地 `edit_message_text` 流式，但群/私聊节流间隔不同（群 3s / 私聊 1s）；rate-limit（`retry_after`）静默降级，终态保底；`/start <token>` 深链绑定（非 `/connect`）；P2P `topic_id=None`（单 thread），群用 `reply_to` msg id。

---

## 4. Discord：gateway WebSocket + wait + typing 指示 + thread 创建

Discord 用 `discord.py` 的 gateway WebSocket。`mention_only` 模式下首次 @ 触发创建 Discord thread，此后该 thread 内的消息继续会话。typing 指示器表示"正在处理"。

```python
# channels/channels/discord.py
class DiscordChannel(Channel):
    """Discord bot channel.

    Configuration keys:
        - ``bot_token``: Discord Bot token.
        - ``allowed_guilds``: (optional) List of allowed Discord guild IDs.
        - ``mention_only``: (optional) If true, only respond when mentioned.
        - ``thread_mode``: (optional) If true, group a channel conversation into a thread.
    """

    _DISCORD_MAX_MESSAGE_LEN = 2000

    async def send(self, msg: OutboundMessage) -> None:
        """Discord send：先停 typing，再 split 成 ≤2000 字符的 chunk 发。

        Discord 不支持原地流式更新，故等终态发（wait）。
        长文本按换行/长度 split 成多条消息（Discord 单条上限 2000）。
        """
        # 发响应前先停 typing 指示器
        stop_future = asyncio.run_coroutine_threadsafe(self._stop_typing(msg.chat_id, msg.thread_ts), self._discord_loop)
        await asyncio.wrap_future(stop_future)

        target = await self._resolve_target(msg)     # 解析 channel/thread 对象
        if target is None:
            logger.error("[Discord] target not found for chat_id=%s thread_ts=%s", msg.chat_id, msg.thread_ts)
            return

        text = msg.text or ""
        for chunk in self._split_text(text):         # 按 ≤2000 split
            send_future = asyncio.run_coroutine_threadsafe(target.send(chunk), self._discord_loop)
            await asyncio.wrap_future(send_future)

    async def _start_typing(self, channel, chat_id: str, thread_ts: str | None = None) -> None:
        """周期性发 typing 指示（每 10s 一次），直到响应发出。"""
        target_id = thread_ts or chat_id
        if target_id in self._typing_tasks:
            return

        async def _typing_loop():
            try:
                while True:
                    try:
                        await channel.trigger_typing()
                    except Exception:
                        pass
                    await asyncio.sleep(10)
            except asyncio.CancelledError:
                pass

        task = asyncio.create_task(_typing_loop())
        self._typing_tasks[target_id] = task

    async def _on_message(self, message) -> None:
        """Discord on_message：mention_only 门控 + thread 创建/路由。"""
        # ...
        # mention_only + fresh @ -> 创建新 thread（替换已有 thread）
        if self._mention_only and has_mention:
            thread_obj = await self._create_thread(message)
            if thread_obj is not None:
                target_thread_id = str(thread_obj.id)
                self._record_thread_mapping(channel_id, target_thread_id)   # 同步更新内存（不等持久化）
                await asyncio.to_thread(self._persist_thread_mappings)       # offload 持久化
                thread_id = target_thread_id
                chat_id = channel_id
                typing_target = thread_obj
            # ...
        # ...
        # 起 typing 指示 + 发 inbound
        if typing_target:
            asyncio.create_task(self._start_typing(typing_target, chat_id, thread_id))
        self._publish(inbound)
        asyncio.create_task(self._add_reaction(message))     # ✅ 反应（收到）

    async def _create_thread(self, message):
        """为消息创建 Discord thread（仅 TextChannel/NewsChannel 支持）。"""
        # ...
        thread_name = f"helix-{message.author.display_name}-{message.id}"[:100]
        return await message.create_thread(name=thread_name)
```

> **Discord 关键差异**：`discord.py` gateway WebSocket；`mention_only` 模式 @ 触发创建 thread（thread 内继续会话）；typing 指示器（每 10s）；单条消息 2000 字符上限 split；独立 JSON 文件存 channel->thread 映射（`discord_threads.json`，与 `ChannelStore` 分离）；`_record_thread_mapping` 同步更新内存、`_persist_thread_mappings` offload 持久化（防 follow-up 消息误判孤儿）。

---

## 5. 微信：iLink long-poll + wait + AES 加密文件

微信（iLink 桥）用 long-poll `getupdates`，无流式（终态发）。文件收发走 CDN + AES-128-ECB 加密。首次可用 QR 码登录绑定。

```python
# channels/channels/wechat.py
class WechatChannel(Channel):
    """WeChat iLink bot channel using long-polling.

    Configuration keys:
        - ``bot_token``: iLink bot token.
        - ``qrcode_login_enabled``: (optional) Allow first-time QR bootstrap.
        - ``base_url``: (optional) iLink API base URL.
        - ``polling_timeout``: (optional) Long-poll timeout. Default: 35.
    """

    async def _poll_loop(self) -> None:
        """long-poll 主循环：getupdates -> 处理消息 -> 存游标。"""
        while self._running:
            try:
                if not await self._ensure_authenticated():
                    await asyncio.sleep(self._retry_delay)
                    continue

                data = await self._request_json(
                    "/ilink/bot/getupdates",
                    {"get_updates_buf": self._get_updates_buf, "base_info": self._base_info()},
                    timeout=max(self._current_longpoll_timeout_seconds() + 5.0, 10.0),
                )

                ret = data.get("ret", 0)
                if ret not in (0, None):
                    errcode = data.get("errcode")
                    if errcode == -14:
                        # bot token 过期：清状态，需重新扫码或更新 token
                        self._bot_token = ""
                        self._get_updates_buf = ""
                        await asyncio.to_thread(self._save_state)
                        logger.error("[WeChat] bot token expired; scan again or update bot_token and restart the channel")
                        self._running = False
                        break
                    # ...

                self._update_longpoll_timeout(data)     # 服从服务端 long-poll 超时建议
                next_buf = data.get("get_updates_buf")
                if isinstance(next_buf, str) and next_buf != self._get_updates_buf:
                    self._get_updates_buf = next_buf
                    await asyncio.to_thread(self._save_state)    # 持久化游标

                for raw_message in data.get("msgs", []):
                    await self._handle_update(raw_message)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("[WeChat] polling loop failed")
                await asyncio.sleep(self._retry_delay)

    async def send(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
        """微信 send：sendmessage 终态发（无流式），需 context_token 路由。"""
        text = msg.text.strip()
        if not text:
            return

        if not self._bot_token and not await self._ensure_authenticated():
            logger.warning("[WeChat] unable to authenticate before sending chat=%s", msg.chat_id)
            return

        context_token = self._resolve_context_token(msg)     # 从 metadata/缓存解析 context_token
        if not context_token:
            logger.warning("[WeChat] missing context_token for chat=%s, dropping outbound message", msg.chat_id)
            return

        await self._send_text_message(
            chat_id=msg.chat_id, context_token=context_token, text=text,
            client_id_prefix="helix", max_retries=_max_retries,
        )

    async def _send_image_attachment(self, msg: OutboundMessage, attachment: ResolvedAttachment) -> bool:
        """微信图片发送：AES-128-ECB 加密 -> CDN 上传 -> 发送 image_item。

        微信 iLink 的文件传输走 CDN + 对称加密：明文用随机 AES key 加密后上传 CDN，
        下载方用同一 AES key 解密。AES key 经 base64(hex) 编码随消息发送。
        """
        # ...
        aes_key = secrets.token_bytes(16)
        filekey = _safe_media_filename("wechat-upload", attachment.actual_path.suffix or ".bin", message_id=msg.thread_id)
        upload_request = self._build_upload_request(
            filekey=filekey, media_type=UploadMediaType.IMAGE, to_user_id=msg.chat_id,
            plaintext=plaintext, aes_key=aes_key, no_need_thumb=True,
        )
        # ...
        encrypted = _encrypt_aes_128_ecb(plaintext, aes_key)     # AES-128-ECB + PKCS7 padding
        download_param = await self._upload_cdn_bytes(upload_full_url, encrypted, content_type=attachment.mime_type, method="POST")
        # ...
```

> **微信关键差异**：iLink long-poll（非 WebSocket）；无流式（终态发）；`context_token` 做会话路由（从入站消息缓存）；文件走 CDN + AES-128-ECB 加密；bot token 过期（errcode -14）需重新扫码；QR 码登录 bootstrap（`qrcode_login_enabled`）；`topic_id=None`（单用户单 thread）；state_dir 持久化游标 + auth（0600 原子写）。

---

## 6. 企微：wecom-aibot-python-sdk WebSocket + reply_stream 流式

企微用 `wecom-aibot-python-sdk` 的 WebSocket。流式靠 `reply_stream`（WS 帧流式更新），与钉钉 AI Card 类似但走 WS 而非 HTTP patch。

```python
# channels/channels/wecom.py
class WeComChannel(Channel):
    def __init__(self, bus: MessageBus, config: dict[str, Any]) -> None:
        super().__init__(name="wecom", bus=bus, config=config)
        self._bot_id: str | None = None
        self._bot_secret: str | None = None
        self._ws_client = None
        self._ws_task: asyncio.Task | None = None
        self._ws_frames: dict[str, dict[str, Any]] = {}       # msg_id -> frame（reply_stream 用）
        self._ws_stream_ids: dict[str, str] = {}              # msg_id -> stream_id
        self._working_message = "Working on it..."

    @property
    def supports_streaming(self) -> bool:
        return True

    async def start(self) -> None:
        # ...
        from aibot import WSClient, WSClientOptions
        self._ws_client = WSClient(WSClientOptions(bot_id=self._bot_id, secret=self._bot_secret, logger=logger))
        self._ws_client.on("message.text", self._on_ws_text)
        self._ws_client.on("message.mixed", self._on_ws_mixed)
        self._ws_client.on("message.image", self._on_ws_image)
        self._ws_client.on("message.file", self._on_ws_file)
        self._ws_client.on("error", self._on_ws_error)
        self._ws_client.on("disconnected", self._on_ws_disconnected)
        self._ws_task = asyncio.create_task(self._ws_client.connect())    # WS 连接（SDK 自重连）
        # ...

    def _on_ws_disconnected(self, *args: Any) -> None:
        """断线告警（SDK 会自动重连）。"""
        detail = f" ({args[0]})" if args else ""
        logger.warning("WeCom WebSocket disconnected%s; SDK will attempt to reconnect", detail)

    async def _send_ws(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
        """企微 send：有 frame -> reply_stream 流式更新；无 frame -> send_message markdown。"""
        if not self._ws_client:
            return
        try:
            from aibot import generate_req_id
        except Exception:
            generate_req_id = None

        if msg.thread_ts and msg.thread_ts in self._ws_frames:
            frame = self._ws_frames[msg.thread_ts]
            stream_id = self._ws_stream_ids.get(msg.thread_ts)
            if not stream_id and generate_req_id:
                stream_id = generate_req_id("stream")
                self._ws_stream_ids[msg.thread_ts] = stream_id
            if not stream_id:
                return

            # reply_stream：WS 流式更新同一消息（finished=is_final 控制终态）
            await self._send_with_retry(
                lambda: self._ws_client.reply_stream(frame, stream_id, msg.text, bool(msg.is_final)),
                max_retries=_max_retries, log_prefix="[WeCom]", operation_name="stream send",
            )
            return

        # 无 frame（如主动发消息）：markdown 一次性发
        body = {"msgtype": "markdown", "markdown": {"content": msg.text}}
        await self._send_with_retry(
            lambda: self._ws_client.send_message(msg.chat_id, body),
            max_retries=_max_retries, log_prefix="[WeCom]",
        )

    async def _on_outbound(self, msg: OutboundMessage) -> None:
        """企微覆盖 _on_outbound：终态时清理 ws frame/stream_id 上下文。"""
        if msg.channel_name != self.name:
            return
        try:
            await self.send(msg)
        except Exception:
            logger.exception("Failed to send outbound message on channel %s", self.name)
            if msg.is_final:
                self._clear_ws_context(msg.thread_ts)
            return
        for attachment in msg.attachments:
            # ...
        if msg.is_final:
            self._clear_ws_context(msg.thread_ts)     # 终态清理 frame + stream_id

    async def _publish_ws_inbound(self, frame, text, *, files=None) -> None:
        """入站：生成 stream_id -> reply_stream 发 'Working on it...' -> publish_inbound。"""
        # ...
        stream_id = generate_req_id("stream")
        self._ws_frames[msg_id] = frame               # 缓存 frame 供出站 reply_stream 用
        self._ws_stream_ids[msg_id] = stream_id

        try:
            await self._ws_client.reply_stream(frame, stream_id, self._working_message, False)
        except Exception:
            pass

        inbound = await self._attach_connection_identity(inbound)
        await self.bus.publish_inbound(inbound)

    async def send_file(self, msg: OutboundMessage, attachment: ResolvedAttachment) -> bool:
        """企微文件上传：WS 分块上传（init -> chunks -> finish -> reply media_id）。"""
        if not msg.is_final:
            return True       # 仅终态发文件
        # ...
        # WS 分块上传：aibot_upload_media_init -> aibot_upload_media_chunk * N -> aibot_upload_media_finish
        chunk_size = 512 * 1024
        total_chunks = (size + chunk_size - 1) // chunk_size
        # ...
        init_ack = await self._send_ws_upload_command(init_req_id, init_body, "aibot_upload_media_init")
        upload_id = (init_ack.get("body") or {}).get("upload_id")
        # ...
        for idx in range(total_chunks):
            data = f.read(chunk_size)
            chunk_body = {"upload_id": upload_id, "chunk_index": int(idx), "base64_data": base64.b64encode(data).decode("utf-8")}
            await self._send_ws_upload_command(chunk_req_id, chunk_body, "aibot_upload_media_chunk")
        # ...
        finish_ack = await self._send_ws_upload_command(finish_req_id, {"upload_id": upload_id}, "aibot_upload_media_finish")
        media_id = (finish_ack.get("body") or {}).get("media_id")
```

> **企微关键差异**：`wecom-aibot-python-sdk` WebSocket；`reply_stream` 流式（WS 帧更新，非 HTTP patch）；文件走 WS 分块上传（init/chunk/finish 三段式）；`aibotid` 做 workspace 维度；`topic_id=user_id`（单用户单 thread）；终态清理 `_ws_frames`/`_ws_stream_ids` 上下文；SDK 版本要求 `wecom-aibot-python-sdk==0.1.6`+（暴露 `send_reply` 媒体上传 API）。

---

## 7. GitHub：webhook（HMAC 签名）+ fire-and-forget（agent 用 gh CLI）

GitHub 是**唯一用 webhook 的平台**（代码托管平台原生模型）。`send` 是 log-only（agent 自己在沙箱里用 `gh` CLI 发评论），`ChannelRunPolicy.fire_and_forget=True` 使 manager 用 `runs.create` 不等 run 结束。

```python
# channels/channels/github.py
"""GitHub channel - webhook-driven IM channel for PR/issue comments.

Unlike other IM channels (Feishu, Slack, Telegram) which long-poll or use
WebSockets, GitHub delivers messages via HTTP push webhooks. This channel
therefore has a no-op ``start``/``stop`` - inbound messages arrive through
``POST /api/webhooks/github`` and are published to the bus by the webhook
route handler.

**The channel does not auto-post the agent's final response.** Each GitHub
agent (coder, reviewer, ...) has the `gh` CLI in its sandbox and is expected to
decide for itself what - if anything - to post on the issue or PR, and to use
``gh issue comment`` / ``gh pr comment`` / ``gh pr create`` during the run.
The agent's final assistant message is logged at INFO for visibility in
``gateway.log`` but is **not** sent to GitHub.

Why log-only rather than auto-post:

- Two agents can bind the same event (e.g. coder + reviewer on a mention).
  If both auto-posted their final messages, the user would see two replies
  for every mention even when only one had useful work to do.
- The agent often wants to post *intermediate* updates (an issue comment
  linking the PR, a separate comment on a new sub-issue, ...) - the
  auto-post-the-final-message contract didn't model that.
- The dispatcher's per-agent ``_is_self_event`` gate already prevents the
  comments the LLM posts via ``gh`` from looping the webhook back into a
  new run for the same agent.
"""

from channels.base import Channel
from channels.message_bus import MessageBus, OutboundMessage


class GitHubChannel(Channel):
    """Webhook-driven GitHub channel.

    Inbound: ``POST /api/webhooks/github`` publishes ``InboundMessage`` to
    the bus. Outbound: ``send`` is log-only - agents post to GitHub themselves
    via the ``gh`` CLI in their sandbox.

    Configuration keys (in ``config.yaml`` under ``channels.github``):
        - ``enabled`` (bool): set to ``true`` to activate.
        - ``default_mention_login`` (str, optional): bot handle used by
          ``require_mention`` when the agent binding does not set one.
          Falls back to ``"helix-bot"``.
    """

    async def start(self) -> None:
        """Register the outbound callback.

        GitHub is push-based (webhooks), so no long-poll or socket
        listener is needed. We only register for outbound replies so the
        agent's final message gets logged.
        """
        if self._running:
            return
        self.bus.subscribe_outbound(self._on_outbound)
        self._running = True
        logger.info("GitHubChannel started (webhook-driven, no polling)")

    async def stop(self) -> None:
        """Unregister the outbound callback."""
        if not self._running:
            return
        self.bus.unsubscribe_outbound(self._on_outbound)
        self._running = False
        logger.info("GitHubChannel stopped")

    async def send(self, msg: OutboundMessage) -> None:
        """Log the agent's final message - do NOT post it to GitHub.

        GitHub agents post to issues/PRs themselves via ``gh`` mid-run; the
        final assistant message is logged for ``gateway.log`` visibility but
        is not delivered to the platform.
        """
        gh = msg.metadata.get("github", {}) if isinstance(msg.metadata, dict) else {}
        if not isinstance(gh, dict):
            gh = {}

        repo = gh.get("repo") or msg.chat_id
        number = gh.get("number")

        body = msg.text or ""

        logger.info(
            "[GitHubChannel] final message from agent for %s#%s (text_len=%d) - not posted; agents use `gh` directly",
            repo,
            number,
            len(body),
        )
        # 镜像 body 到 DEBUG，使运维能关联而不刷屏 INFO；截断保日志行有界
        if body:
            logger.debug("[GitHubChannel] final body (truncated to 2000 chars): %s", body[:2000])
```

### 7.1 GitHub 的 ChannelRunPolicy（fire_and_forget + 非交互 + 无 bound identity）

```python
# gateway/gateway/github/run_policy.py（GitHub 注册其 ChannelRunPolicy）
# GitHub 是 webhook 通道：fire_and_forget + 非交互 + 不需要 bound identity
CHANNEL_RUN_POLICY["github"] = ChannelRunPolicy(
    is_interactive=False,               # webhook 无法同步等用户回复 -> disable_clarification
    default_recursion_limit=250,        # 自主长 run 需更高 recursion budget
    credentials_provider=github_credentials_provider,   # mint GitHub installation token（>1h TTL）
    requires_bound_identity=False,      # HMAC 在 webhook 路由校验，无 /connect 握手
    fire_and_forget=True,               # agent 自己用 gh 发，manager 用 runs.create 不等
)
```

> **GitHub 关键差异**：**唯一用 webhook 的平台**（HMAC 签名校验在 `/api/webhooks/github` 路由）；`send` log-only（agent 用 `gh` CLI 自己发评论）；`fire_and_forget=True` -> `runs.create`（非 `runs.wait`，避免 300s timeout）；`is_interactive=False` -> `disable_clarification`（webhook 无同步回复）；`requires_bound_identity=False`（HMAC 校验，无 `/connect` 握手）；`preferred_thread_id` 确定性映射（repo+number -> 同一 LangGraph thread）；两个 agent 可绑同一事件（coder + reviewer），靠 `_is_self_event` 防 `gh` 评论回流。

---

## 差异矩阵总结

| 维度 | 钉钉 | 飞书 | Slack | Telegram | Discord | 微信 | 企微 | GitHub |
|---|---|---|---|---|---|---|---|---|
| **入站** | WS(stream) | WS(lark) | WS(socket mode) | long-poll | WS(gateway) | long-poll | WS(aibot) | webhook |
| **流式** | AI Card patch | patch card | wait | edit_text | wait | wait | reply_stream | fire-forget |
| **回退** | sampleMarkdown | reply_card | - | send_new | - | - | send_message | log-only |
| **反应** | - | OK/DONE | eyes/✅/❌ | - | ✅ | - | - | - |
| **thread** | msg_id(群) | root_id | thread_ts | reply_to | thread_ts | None | user_id | preferred_id |
| **绑定** | /connect | /connect | /connect | /start | /connect | /connect | /connect | config.yaml |
| **token** | oauth2+缓存 | SDK 自管 | SDK 自管 | SDK 自管 | SDK 自管 | bot_token | SDK 自管 | installation |

> **共性**（所有平台共享 `Channel` 基类 + `MessageBus` + `ChannelManager`）：
>
> - 入站都包装为 `InboundMessage` -> `MessageBus.publish_inbound` -> `_dispatch_loop`。
> - 出站都经 `MessageBus.publish_outbound` -> channel 的 `_on_outbound` -> `send`。
> - owner 头透传（`_owner_headers`）+ 文件桶身份（`_channel_storage_user_id`）全在 manager 层，channel 不碰。
> - bound identity 校验、thread 创建竞争锁、入站去重全在 manager 层。
> - `/connect <code>` 绑定流程（Telegram 例外用 `/start <token>` 深链）都走 `attach_connection_identity` + `upsert_connection`（单活跃 owner 迁移）。
