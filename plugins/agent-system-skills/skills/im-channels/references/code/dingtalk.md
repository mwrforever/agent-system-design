# 完整源码：DingTalkChannel（钉钉出站长连接 + AI Card 流式 patch + sampleMarkdown 回退 + token 缓存）

> 本文件给出钉钉 channel 的**完整实现**：`dingtalk-stream` 出站长连接回调、AI Card 创建与流式 patch、sampleMarkdown 回退、access token 缓存刷新（double-check lock + 提前量）、markdown 适配、media 上传、`/connect` 绑定、P2P/群路由。
>
> SKILL.md「完整真实代码实现」段给了 `send`/`_stream_update_card`/`_get_access_token`/`_on_chatbot_message` 入口片段与索引；此处补全完整源码与所有边界处理。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `channels.channels.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 1. 模块头与辅助函数

```python
# channels/channels/dingtalk.py
"""DingTalk channel implementation."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
import time
from pathlib import Path
from typing import Any

import httpx

from channels.base import Channel
from channels.commands import is_known_channel_command
from channels.connection_identity import attach_connection_identity
from channels.message_bus import InboundMessage, InboundMessageType, MessageBus, OutboundMessage, ResolvedAttachment

logger = logging.getLogger(__name__)

DINGTALK_API_BASE = "https://api.dingtalk.com"

# access token 提前过期量：留 5 分钟缓冲，防"token 在过期边缘被缓存，发到钉钉时刚好过期"
_TOKEN_REFRESH_MARGIN_SECONDS = 300

_CONVERSATION_TYPE_P2P = "1"
_CONVERSATION_TYPE_GROUP = "2"

_MAX_UPLOAD_SIZE_BYTES = 20 * 1024 * 1024


def _normalize_conversation_type(raw: Any) -> str:
    """Normalize ``conversationType`` to ``"1"`` (P2P) or ``"2"`` (group).

    Stream payloads may send int or string values.
    """
    if raw is None:
        return _CONVERSATION_TYPE_P2P
    s = str(raw).strip()
    if s == _CONVERSATION_TYPE_GROUP:
        return _CONVERSATION_TYPE_GROUP
    return _CONVERSATION_TYPE_P2P


def _normalize_allowed_users(allowed_users: Any) -> set[str]:
    if allowed_users is None:
        return set()
    if isinstance(allowed_users, str):
        values = [allowed_users]
    elif isinstance(allowed_users, (list, tuple, set)):
        values = allowed_users
    else:
        logger.warning(
            "DingTalk allowed_users should be a list of user IDs; treating %s as one string value",
            type(allowed_users).__name__,
        )
        values = [allowed_users]
    return {str(uid) for uid in values if str(uid)}


def _is_dingtalk_command(text: str) -> bool:
    return is_known_channel_command(text)


def _extract_text_from_rich_text(rich_text_list: list) -> str:
    parts: list[str] = []
    for item in rich_text_list:
        if isinstance(item, dict) and "text" in item:
            parts.append(item["text"])
    return " ".join(parts)


# 钉钉 sampleMarkdown 渲染局限：不支持围栏代码块、行内代码、管道表格、水平线
# 以下正则与函数把这些 markdown 元素转成 sampleMarkdown 能渲染的形式
_FENCED_CODE_BLOCK_RE = re.compile(r"```(\w*)\n(.*?)```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
_HORIZONTAL_RULE_RE = re.compile(r"^-{3,}$", re.MULTILINE)
_TABLE_SEPARATOR_RE = re.compile(r"^\|[-:| ]+\|$", re.MULTILINE)


def _convert_markdown_table(text: str) -> str:
    # DingTalk sampleMarkdown does not render pipe-delimited tables.
    lines = text.split("\n")
    result: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Detect table: header row followed by separator row
        if i + 1 < len(lines) and line.strip().startswith("|") and _TABLE_SEPARATOR_RE.match(lines[i + 1].strip()):
            headers = [h.strip() for h in line.strip().strip("|").split("|")]
            i += 2  # skip header + separator
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                for h, c in zip(headers, cells):
                    result.append(f"> **{h}**: {c}")
                result.append("")
                i += 1
        else:
            result.append(line)
            i += 1
    return "\n".join(result)


def _adapt_markdown_for_dingtalk(text: str) -> str:
    """Adapt markdown for DingTalk's limited sampleMarkdown renderer."""

    def _code_block_to_quote(match: re.Match) -> str:
        lang = match.group(1)
        code = match.group(2).rstrip("\n")
        prefix = f"> **{lang}**\n" if lang else ""
        quoted_lines = "\n".join(f"> {line}" for line in code.split("\n"))
        return f"{prefix}{quoted_lines}\n"

    text = _FENCED_CODE_BLOCK_RE.sub(_code_block_to_quote, text)
    text = _INLINE_CODE_RE.sub(r"**\1**", text)
    text = _convert_markdown_table(text)
    text = _HORIZONTAL_RULE_RE.sub("───────────", text)
    return text
```

---

## 2. DingTalkChannel 主体（生命周期 + 路由 + send + 回退）

```python
class DingTalkChannel(Channel):
    """DingTalk IM channel using Stream Push (WebSocket, no public IP needed)."""

    def __init__(self, bus: MessageBus, config: dict[str, Any]) -> None:
        super().__init__(name="dingtalk", bus=bus, config=config)
        self._thread: threading.Thread | None = None
        self._main_loop: asyncio.AbstractEventLoop | None = None
        self._client_id: str = ""
        self._client_secret: str = ""
        self._allowed_users: set[str] = _normalize_allowed_users(config.get("allowed_users"))
        # access token 缓存：_cached_token + _token_expires_at + _token_lock（double-check lock）
        self._cached_token: str = ""
        self._token_expires_at: float = 0.0
        self._token_lock = asyncio.Lock()
        self._card_template_id: str = config.get("card_template_id", "")
        # AI Card 流式 patch 的追踪状态：source_key -> out_track_id（卡片实例 id）
        self._card_track_ids: dict[str, str] = {}
        self._dingtalk_client: Any = None
        self._stream_client: Any = None
        self._incoming_messages: dict[str, Any] = {}
        self._incoming_messages_lock = threading.Lock()
        # out_track_id -> AICardReplier 实例（流式 patch 用）
        self._card_repliers: dict[str, Any] = {}

    @property
    def supports_streaming(self) -> bool:
        # 仅当配了 card_template_id 才走 AI Card 流式 patch；否则纯 sampleMarkdown（无流式）
        return bool(self._card_template_id)

    async def start(self) -> None:
        if self._running:
            return

        try:
            import dingtalk_stream  # noqa: F401
        except ImportError:
            logger.error("dingtalk-stream is not installed. Install it with: uv add dingtalk-stream")
            return

        client_id = self.config.get("client_id", "")
        client_secret = self.config.get("client_secret", "")

        if not client_id or not client_secret:
            logger.error("DingTalk channel requires client_id and client_secret")
            return

        self._client_id = client_id
        self._client_secret = client_secret
        self._main_loop = asyncio.get_running_loop()

        if self._card_template_id:
            logger.info("[DingTalk] AI Card mode enabled (template=%s)", self._card_template_id)

        self._running = True
        self.bus.subscribe_outbound(self._on_outbound)

        # dingtalk-stream 跑在独立 daemon 线程（SDK 自带重连）
        self._thread = threading.Thread(
            target=self._run_stream,
            args=(client_id, client_secret),
            daemon=True,
        )
        self._thread.start()
        logger.info("DingTalk channel started")

    async def stop(self) -> None:
        self._running = False
        self.bus.unsubscribe_outbound(self._on_outbound)

        stream_client = self._stream_client
        if stream_client is not None:
            try:
                if hasattr(stream_client, "disconnect"):
                    stream_client.disconnect()
            except Exception:
                logger.debug("[DingTalk] error disconnecting stream client", exc_info=True)

        self._dingtalk_client = None
        self._stream_client = None
        with self._incoming_messages_lock:
            self._incoming_messages.clear()
        self._card_repliers.clear()
        self._card_track_ids.clear()
        if self._thread:
            self._thread.join(timeout=5)
            self._thread = None
        logger.info("DingTalk channel stopped")

    def _resolve_routing(self, msg: OutboundMessage) -> tuple[str, str, str]:
        """Return (conversation_type, sender_staff_id, conversation_id).

        Uses msg.chat_id as the primary routing key; metadata as fallback.
        """
        conversation_type = _normalize_conversation_type(msg.metadata.get("conversation_type"))
        sender_staff_id = msg.metadata.get("sender_staff_id", "")
        conversation_id = msg.metadata.get("conversation_id", "")
        if conversation_type == _CONVERSATION_TYPE_GROUP:
            conversation_id = msg.chat_id or conversation_id
        else:
            sender_staff_id = msg.chat_id or sender_staff_id
        return conversation_type, sender_staff_id, conversation_id

    async def send(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
        conversation_type, sender_staff_id, conversation_id = self._resolve_routing(msg)
        robot_code = self._client_id

        # Card mode: stream update to existing AI card
        source_key = self._make_card_source_key_from_outbound(msg)
        out_track_id = self._card_track_ids.get(source_key)

        # ``card_template_id`` enables ``runs.stream`` (non-final + final outbounds).
        # If card creation failed, skip non-final chunks to avoid duplicate messages.
        if self._card_template_id and not out_track_id and not msg.is_final:
            return

        if out_track_id:
            try:
                await self._stream_update_card(
                    out_track_id,
                    msg.text,
                    is_finalize=msg.is_final,
                )
            except Exception:
                logger.warning("[DingTalk] card stream failed, falling back to sampleMarkdown")
                if msg.is_final:
                    # 仅最终消息回退 sampleMarkdown（非最终 chunk 回退会刷屏）
                    self._card_track_ids.pop(source_key, None)
                    self._card_repliers.pop(out_track_id, None)
                    await self._send_markdown_fallback(robot_code, conversation_type, sender_staff_id, conversation_id, msg.text)
                    return
            if msg.is_final:
                self._card_track_ids.pop(source_key, None)
                self._card_repliers.pop(out_track_id, None)
            return

        async def send_markdown() -> None:
            if conversation_type == _CONVERSATION_TYPE_GROUP:
                await self._send_group_message(robot_code, conversation_id, msg.text, at_user_ids=[sender_staff_id] if sender_staff_id else None)
            else:
                await self._send_p2p_message(robot_code, sender_staff_id, msg.text)

        # Non-card mode: send sampleMarkdown with retry
        await self._send_with_retry(
            send_markdown,
            max_retries=_max_retries,
            log_prefix="[DingTalk]",
        )
        return

    async def _send_markdown_fallback(
        self,
        robot_code: str,
        conversation_type: str,
        sender_staff_id: str,
        conversation_id: str,
        text: str,
    ) -> None:
        try:
            if conversation_type == _CONVERSATION_TYPE_GROUP:
                await self._send_group_message(robot_code, conversation_id, text)
            else:
                await self._send_p2p_message(robot_code, sender_staff_id, text)
        except Exception:
            logger.exception("[DingTalk] markdown fallback also failed")
            raise

    async def send_file(self, msg: OutboundMessage, attachment: ResolvedAttachment) -> bool:
        if attachment.size > _MAX_UPLOAD_SIZE_BYTES:
            logger.warning("[DingTalk] file too large (%d bytes), skipping: %s", attachment.size, attachment.filename)
            return False

        conversation_type, sender_staff_id, conversation_id = self._resolve_routing(msg)
        robot_code = self._client_id

        try:
            media_id = await self._upload_media(attachment.actual_path, "image" if attachment.is_image else "file")
            if not media_id:
                return False

            if attachment.is_image:
                msg_key = "sampleImageMsg"
                msg_param = json.dumps({"photoURL": media_id})
            else:
                msg_key = "sampleFile"
                msg_param = json.dumps(
                    {
                        "fileUrl": media_id,
                        "fileName": attachment.filename,
                        "fileSize": str(attachment.size),
                    }
                )

            token = await self._get_access_token()
            async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
                if conversation_type == _CONVERSATION_TYPE_GROUP:
                    response = await client.post(
                        f"{DINGTALK_API_BASE}/v1.0/robot/groupMessages/send",
                        headers=self._api_headers(token),
                        json={
                            "msgKey": msg_key,
                            "msgParam": msg_param,
                            "robotCode": robot_code,
                            "openConversationId": conversation_id,
                        },
                    )
                else:
                    response = await client.post(
                        f"{DINGTALK_API_BASE}/v1.0/robot/oToMessages/batchSend",
                        headers=self._api_headers(token),
                        json={
                            "msgKey": msg_key,
                            "msgParam": msg_param,
                            "robotCode": robot_code,
                            "userIds": [sender_staff_id],
                        },
                    )
                response.raise_for_status()

            logger.info("[DingTalk] file sent: %s", attachment.filename)
            return True
        except (httpx.HTTPError, OSError, ValueError, TypeError, AttributeError):
            logger.exception("[DingTalk] failed to send file: %s", attachment.filename)
            return False
```

---

## 3. 出站长连接回调（SDK 线程 -> 主循环 MessageBus）

```python
    # -- stream client (runs in dedicated thread) --------------------------

    def _run_stream(self, client_id: str, client_secret: str) -> None:
        """dingtalk-stream 客户端在独立线程跑（SDK 自带心跳与重连）。"""
        try:
            import dingtalk_stream

            credential = dingtalk_stream.Credential(client_id, client_secret)
            client = dingtalk_stream.DingTalkStreamClient(credential)
            self._stream_client = client
            client.register_callback_handler(
                dingtalk_stream.chatbot.ChatbotMessage.TOPIC,
                _DingTalkMessageHandler(self),
            )
            client.start_forever()       # 阻塞：SDK 维持 WebSocket、收消息、回调 handler
        except Exception:
            if self._running:
                logger.exception("DingTalk Stream Push error")
        finally:
            self._stream_client = None

    def _on_chatbot_message(self, message: Any) -> None:
        """SDK 回调线程里解析入站消息，跨线程扔回主事件循环 -> MessageBus。"""
        if not self._running:
            return
        try:
            sender_staff_id = message.sender_staff_id or ""
            conversation_type = _normalize_conversation_type(message.conversation_type)
            conversation_id = message.conversation_id or ""
            msg_id = message.message_id or ""
            sender_nick = message.sender_nick or ""

            text = self._extract_text(message)
            if not text:
                logger.info("[DingTalk] empty text, ignoring message")
                return

            connect_code = self._pending_connect_code(text)
            if connect_code:
                # /connect <code> 绑定命令：在 allowed_users 门控之前处理，
                # 使浏览器发起的绑定能引导一个 bot 尚未见过、未授权的外部身份
                if self._main_loop and self._main_loop.is_running():
                    fut = asyncio.run_coroutine_threadsafe(
                        self._bind_connection_from_connect_code(
                            conversation_type=conversation_type,
                            sender_staff_id=sender_staff_id,
                            sender_nick=sender_nick,
                            conversation_id=conversation_id,
                            code=connect_code,
                        ),
                        self._main_loop,
                    )
                    fut.add_done_callback(lambda f, mid=msg_id: self._log_future_error(f, "bind_connection", mid))
                else:
                    logger.warning("[DingTalk] main loop not running, cannot bind channel connection")
                return

            if self._allowed_users and sender_staff_id not in self._allowed_users:
                logger.debug("[DingTalk] ignoring message from non-allowed user: %s", sender_staff_id)
                return

            # 只记元数据（长度，非内容），使消息文本永不进 INFO 日志；
            # 且在 allowed_users 门控之后才记，被拦的发送者根本不记
            logger.info(
                "[DingTalk] parsed message: conv_type=%s, msg_id=%s, sender=%s(%s), text_len=%d",
                conversation_type,
                msg_id,
                sender_staff_id,
                sender_nick,
                len(text or ""),
            )

            if _is_dingtalk_command(text):
                msg_type = InboundMessageType.COMMAND
            else:
                msg_type = InboundMessageType.CHAT

            # P2P: topic_id=None（单用户单 thread，类似 Telegram 私聊）
            # Group: topic_id=msg_id（每条新消息开新 topic，类似飞书）
            topic_id: str | None = msg_id if conversation_type == _CONVERSATION_TYPE_GROUP else None

            # 群用 conversation_id 做 chat_id，P2P 用 sender_staff_id 做 chat_id
            chat_id = conversation_id if conversation_type == _CONVERSATION_TYPE_GROUP else sender_staff_id

            inbound = self._make_inbound(
                chat_id=chat_id,
                user_id=sender_staff_id,
                text=text,
                msg_type=msg_type,
                thread_ts=msg_id,
                metadata={
                    "conversation_type": conversation_type,
                    "conversation_id": conversation_id,
                    "sender_staff_id": sender_staff_id,
                    "sender_nick": sender_nick,
                    "message_id": msg_id,
                },
            )
            inbound.topic_id = topic_id

            if self._card_template_id:
                # AI Card 模式：缓存原始 chatbot_message，建卡时要用
                source_key = self._make_card_source_key(inbound)
                with self._incoming_messages_lock:
                    self._incoming_messages[source_key] = message

            if self._main_loop and self._main_loop.is_running():
                logger.info("[DingTalk] publishing inbound message to bus (type=%s, msg_id=%s)", msg_type.value, msg_id)
                # SDK 回调跑在独立线程，跨线程把入站消息扔回主事件循环
                fut = asyncio.run_coroutine_threadsafe(
                    self._prepare_inbound(chat_id, inbound),
                    self._main_loop,
                )
                fut.add_done_callback(lambda f, mid=msg_id: self._log_future_error(f, "prepare_inbound", mid))
            else:
                logger.warning("[DingTalk] main loop not running, cannot publish inbound message")
        except Exception:
            logger.exception("[DingTalk] error processing chatbot message")

    @staticmethod
    def _extract_text(message: Any) -> str:
        msg_type = message.message_type
        if msg_type == "text" and message.text:
            return message.text.content.strip()
        if msg_type == "richText" and message.rich_text_content:
            return _extract_text_from_rich_text(message.rich_text_content.rich_text_list).strip()
        return ""

    async def _prepare_inbound(self, chat_id: str, inbound: InboundMessage) -> None:
        """主循环里执行：贴 connection 身份 -> 发"运行中"卡片 -> 入队给 manager。

        "运行中"卡片必须在 publish_inbound 之前发完，使 AI card 追踪在 manager
        发出流式出站之前已注册。
        """
        inbound = await self._attach_connection_identity(inbound)
        await self._send_running_reply(chat_id, inbound)   # 先发"运行中"卡片占位
        await self.bus.publish_inbound(inbound)

    @staticmethod
    def _connection_workspace_id(conversation_type: str, conversation_id: str) -> str | None:
        if conversation_type == _CONVERSATION_TYPE_GROUP and conversation_id:
            return conversation_id
        return None

    async def _attach_connection_identity(self, inbound: InboundMessage) -> InboundMessage:
        conversation_type = str(inbound.metadata.get("conversation_type") or _CONVERSATION_TYPE_P2P)
        conversation_id = str(inbound.metadata.get("conversation_id") or "")
        return await attach_connection_identity(
            inbound,
            repo=self._connection_repo,
            provider="dingtalk",
            workspace_id=self._connection_workspace_id(conversation_type, conversation_id),
            fallback_without_workspace=True,
        )

    async def _bind_connection_from_connect_code(
        self,
        *,
        conversation_type: str,
        sender_staff_id: str,
        sender_nick: str,
        conversation_id: str,
        code: str,
    ) -> bool:
        if self._connection_repo is None or not code:
            return False

        state = await self._connection_repo.consume_oauth_state(provider="dingtalk", state=code)
        if state is None:
            await self._send_connection_reply(
                conversation_type,
                sender_staff_id,
                conversation_id,
                "DingTalk connection code is invalid or expired.",
            )
            return True

        if not sender_staff_id:
            await self._send_connection_reply(
                conversation_type,
                sender_staff_id,
                conversation_id,
                "DingTalk connection could not be completed from this message.",
            )
            return True

        # upsert_connection 会触发单活跃 owner 迁移：若该外部身份已被别的 owner 绑定，
        # 旧 owner 的连接被吊销、凭证被删（见 channel-abstraction.md §6）
        await self._connection_repo.upsert_connection(
            owner_user_id=state["owner_user_id"],
            provider="dingtalk",
            external_account_id=sender_staff_id,
            external_account_name=sender_nick or None,
            workspace_id=self._connection_workspace_id(conversation_type, conversation_id),
            metadata={
                "conversation_type": conversation_type,
                "conversation_id": conversation_id,
            },
            status="connected",
        )
        await self._send_connection_reply(
            conversation_type,
            sender_staff_id,
            conversation_id,
            "DingTalk connected to Helix.",
        )
        return True

    async def _send_connection_reply(
        self,
        conversation_type: str,
        sender_staff_id: str,
        conversation_id: str,
        text: str,
    ) -> None:
        robot_code = self._client_id
        if conversation_type == _CONVERSATION_TYPE_GROUP:
            if conversation_id:
                await self._send_text_message_to_group(robot_code, conversation_id, text)
            return
        if sender_staff_id:
            await self._send_text_message_to_user(robot_code, sender_staff_id, text)

    async def _send_running_reply(self, chat_id: str, inbound: InboundMessage) -> None:
        """发"运行中"占位：AI Card 模式建卡并追踪 out_track_id，否则发 sampleText。"""
        conversation_type = inbound.metadata.get("conversation_type", _CONVERSATION_TYPE_P2P)
        sender_staff_id = inbound.metadata.get("sender_staff_id", "")
        conversation_id = inbound.metadata.get("conversation_id", "")
        text = "⏳ Working on it..."

        try:
            if self._card_template_id:
                source_key = self._make_card_source_key(inbound)
                with self._incoming_messages_lock:
                    chatbot_message = self._incoming_messages.pop(source_key, None)
                out_track_id = await self._create_and_deliver_card(
                    text,
                    chatbot_message=chatbot_message,
                )
                if out_track_id:
                    self._card_track_ids[source_key] = out_track_id
                    logger.info("[DingTalk] AI card running reply sent for chat=%s", chat_id)
                    return

            robot_code = self._client_id
            if conversation_type == _CONVERSATION_TYPE_GROUP:
                await self._send_text_message_to_group(robot_code, conversation_id, text)
            else:
                await self._send_text_message_to_user(robot_code, sender_staff_id, text)
            logger.info("[DingTalk] 'Working on it...' reply sent for chat=%s", chat_id)
        except Exception:
            logger.exception("[DingTalk] failed to send running reply for chat=%s", chat_id)
```

---

## 4. 钉钉 API helpers（access token 缓存 + 文本/Markdown 消息）

```python
    # -- DingTalk API helpers ----------------------------------------------

    async def _get_access_token(self) -> str:
        """带提前量的 double-check lock 缓存钉钉 access token。

        快路径：无锁检查缓存且未过期 -> 直接返回。
        慢路径：加锁后二次检查（抢锁期间前一个持有者可能已刷新）-> 换 token -> 缓存 + 提前量过期。
        """
        if self._cached_token and time.monotonic() < self._token_expires_at:
            return self._cached_token
        async with self._token_lock:
            if self._cached_token and time.monotonic() < self._token_expires_at:
                return self._cached_token
            async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
                response = await client.post(
                    f"{DINGTALK_API_BASE}/v1.0/oauth2/accessToken",
                    json={"appKey": self._client_id, "appSecret": self._client_secret},  # DingTalk API field names
                )
                response.raise_for_status()
                data = response.json()

                if not isinstance(data, dict):
                    raise ValueError(f"DingTalk access token response must be a JSON object, got {type(data).__name__}")

                access_token = data.get("accessToken")
                if not isinstance(access_token, str) or not access_token.strip():
                    raise ValueError("DingTalk access token response did not contain a usable accessToken")

                raw_expires_in = data.get("expireIn", 7200)
                try:
                    expires_in = int(raw_expires_in)
                except (TypeError, ValueError):
                    logger.warning("[DingTalk] invalid expireIn value %r, using default 7200s", raw_expires_in)
                    expires_in = 7200

                self._cached_token = access_token.strip()
                # 提前 300s 过期，防"token 在过期边缘被缓存，发到钉钉时刚好过期"
                self._token_expires_at = time.monotonic() + expires_in - _TOKEN_REFRESH_MARGIN_SECONDS
                return self._cached_token

    @staticmethod
    def _api_headers(token: str) -> dict[str, str]:
        return {
            "x-acs-dingtalk-access-token": token,
            "Content-Type": "application/json",
        }

    async def _send_text_message_to_user(self, robot_code: str, user_id: str, text: str) -> None:
        token = await self._get_access_token()
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            response = await client.post(
                f"{DINGTALK_API_BASE}/v1.0/robot/oToMessages/batchSend",
                headers=self._api_headers(token),
                json={
                    "msgKey": "sampleText",
                    "msgParam": json.dumps({"content": text}),
                    "robotCode": robot_code,
                    "userIds": [user_id],
                },
            )
            response.raise_for_status()

    async def _send_text_message_to_group(self, robot_code: str, conversation_id: str, text: str) -> None:
        token = await self._get_access_token()
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            response = await client.post(
                f"{DINGTALK_API_BASE}/v1.0/robot/groupMessages/send",
                headers=self._api_headers(token),
                json={
                    "msgKey": "sampleText",
                    "msgParam": json.dumps({"content": text}),
                    "robotCode": robot_code,
                    "openConversationId": conversation_id,
                },
            )
            response.raise_for_status()

    async def _send_p2p_message(self, robot_code: str, user_id: str, text: str) -> None:
        # sampleMarkdown：先适配钉钉渲染局限（围栏代码块/表格/水平线），再发
        text = _adapt_markdown_for_dingtalk(text)
        token = await self._get_access_token()
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            response = await client.post(
                f"{DINGTALK_API_BASE}/v1.0/robot/oToMessages/batchSend",
                headers=self._api_headers(token),
                json={
                    "msgKey": "sampleMarkdown",
                    "msgParam": json.dumps({"title": "Helix", "text": text}),
                    "robotCode": robot_code,
                    "userIds": [user_id],
                },
            )
            response.raise_for_status()
            data = response.json()
            if data.get("processQueryKey"):
                logger.info("[DingTalk] P2P message sent to user=%s", user_id)
            else:
                logger.warning("[DingTalk] P2P send response: %s", data)

    async def _send_group_message(
        self,
        robot_code: str,
        conversation_id: str,
        text: str,
        *,
        at_user_ids: list[str] | None = None,  # noqa: ARG002
    ) -> None:
        # at_user_ids accepted for call-site compatibility but not passed to the API
        # (sampleMarkdown does not support @mentions).
        text = _adapt_markdown_for_dingtalk(text)
        token = await self._get_access_token()

        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            response = await client.post(
                f"{DINGTALK_API_BASE}/v1.0/robot/groupMessages/send",
                headers=self._api_headers(token),
                json={
                    "msgKey": "sampleMarkdown",
                    "msgParam": json.dumps({"title": "Helix", "text": text}),
                    "robotCode": robot_code,
                    "openConversationId": conversation_id,
                },
            )
            response.raise_for_status()
            data = response.json()
            if data.get("processQueryKey"):
                logger.info("[DingTalk] group message sent to conversation=%s", conversation_id)
            else:
                logger.warning("[DingTalk] group send response: %s", data)
```

---

## 5. AI Card 流式 patch helpers（建卡 + 原地 patch + source_key 关联）

```python
    # -- AI Card streaming helpers -------------------------------------------

    def _make_card_source_key(self, inbound: InboundMessage) -> str:
        """入站消息的卡片关联 key：会话类型 + 发送者 + 会话 id + 消息 id。"""
        m = inbound.metadata
        return f"{m.get('conversation_type', '')}:{m.get('sender_staff_id', '')}:{m.get('conversation_id', '')}:{m.get('message_id', '')}"

    def _make_card_source_key_from_outbound(self, msg: OutboundMessage) -> str:
        """出站消息的卡片关联 key：与入站 key 对齐，靠 message_id 或 thread_ts 关联。"""
        m = msg.metadata
        correlation_id = m.get("message_id") or msg.thread_ts or ""
        return f"{m.get('conversation_type', '')}:{m.get('sender_staff_id', '')}:{m.get('conversation_id', '')}:{correlation_id}"

    async def _create_and_deliver_card(
        self,
        initial_text: str,
        *,
        chatbot_message: Any = None,
    ) -> str | None:
        """建 AI 卡片并投递，返回 out_track_id（卡片实例 id）。"""
        if self._dingtalk_client is None or chatbot_message is None:
            logger.warning("[DingTalk] SDK client or chatbot_message unavailable, skipping AI card")
            return None

        try:
            from dingtalk_stream.card_replier import AICardReplier
        except ImportError:
            logger.warning("[DingTalk] dingtalk-stream card_replier not available")
            return None

        try:
            replier = AICardReplier(self._dingtalk_client, chatbot_message)
            card_instance_id = await replier.async_create_and_deliver_card(
                card_template_id=self._card_template_id,
                card_data={"content": initial_text},
            )
            if not card_instance_id:
                return None

            self._card_repliers[card_instance_id] = replier
            logger.info("[DingTalk] AI card created: outTrackId=%s", card_instance_id)
            return card_instance_id
        except Exception:
            logger.exception("[DingTalk] failed to create AI card")
            return None

    async def _stream_update_card(
        self,
        out_track_id: str,
        content: str,
        *,
        is_finalize: bool = False,
        is_error: bool = False,
    ) -> None:
        """钉钉 PUT /v1.0/card/streaming：原地 patch 同一张 AI 卡片。

        append=False：每次用最新完整内容覆盖（manager 侧已累加好）。
        finished=is_finalize：终态 chunk 结束流。
        failed=is_error：错误态。
        """
        replier = self._card_repliers.get(out_track_id)
        if not replier:
            raise RuntimeError(f"No AICardReplier found for track ID {out_track_id}")

        await replier.async_streaming(
            card_instance_id=out_track_id,
            content_key="content",
            content_value=content,
            append=False,
            finished=is_finalize,
            failed=is_error,
        )

    # -- media upload --------------------------------------------------------

    async def _upload_media(self, file_path: str | Path, media_type: str) -> str | None:
        try:
            file_bytes = await asyncio.to_thread(Path(file_path).read_bytes)
            token = await self._get_access_token()
            async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
                response = await client.post(
                    f"{DINGTALK_API_BASE}/v1.0/files/upload",
                    headers={"x-acs-dingtalk-access-token": token},
                    files={"file": ("upload", file_bytes)},
                    data={"type": media_type},
                )
                response.raise_for_status()
                try:
                    payload = response.json()
                except json.JSONDecodeError:
                    logger.exception("[DingTalk] failed to decode upload response JSON: %s", file_path)
                    return None
                if not isinstance(payload, dict):
                    logger.warning("[DingTalk] unexpected upload response type %s for %s", type(payload).__name__, file_path)
                    return None
                return payload.get("mediaId")
        except (httpx.HTTPError, OSError):
            logger.exception("[DingTalk] failed to upload media: %s", file_path)
            return None
```

---

## 6. _DingTalkMessageHandler（注册到 dingtalk-stream 的回调处理器）

```python
class _DingTalkMessageHandler:
    """Callback handler registered with dingtalk-stream."""

    def __init__(self, channel: DingTalkChannel) -> None:
        self._channel = channel

    def pre_start(self) -> None:
        """SDK 启动前回调：把 dingtalk_client 注入 channel（建卡要用）。"""
        if hasattr(self, "dingtalk_client") and self.dingtalk_client is not None:
            self._channel._dingtalk_client = self.dingtalk_client

    async def raw_process(self, callback_message: Any) -> Any:
        """SDK 原始回调入口：调 process 后构造 AckMessage 回 ACK。"""
        import dingtalk_stream
        from dingtalk_stream.frames import Headers

        code, message = await self.process(callback_message)
        ack_message = dingtalk_stream.AckMessage()
        ack_message.code = code
        ack_message.headers.message_id = callback_message.headers.message_id
        ack_message.headers.content_type = Headers.CONTENT_TYPE_APPLICATION_JSON
        ack_message.data = {"response": message}
        return ack_message

    async def process(self, callback: Any) -> tuple[int, str]:
        """解析 ChatbotMessage，转交 channel 处理，返回 ACK 状态。"""
        import dingtalk_stream

        incoming_message = dingtalk_stream.ChatbotMessage.from_dict(callback.data)
        self._channel._on_chatbot_message(incoming_message)
        return dingtalk_stream.AckMessage.STATUS_OK, "OK"
```

> **设计要点回顾**：
>
> - **出站长连接**：`_run_stream` 在 daemon 线程跑 `dingtalk_stream.DingTalkStreamClient.start_forever()`，SDK 维持 WebSocket、收消息、回调 `_DingTalkMessageHandler.process`。agent 侧零公网暴露。
> - **跨线程通信**：`_on_chatbot_message` 跑在 SDK 线程，用 `asyncio.run_coroutine_threadsafe(self._prepare_inbound(...), self._main_loop)` 把消息扔回主事件循环。
> - **AI Card 流式 patch**：`_send_running_reply` 建卡拿 `out_track_id` -> `send` 用 `_stream_update_card` 原地 patch -> 终态清理。失败仅终态回退 sampleMarkdown。
> - **token 缓存**：`_get_access_token` double-check lock + 提前 300s 过期，避免每条消息换 token 触发限流。
> - **P2P/群路由**：`_resolve_routing` 按 `conversation_type` 决定用 `sender_staff_id`（P2P）还是 `conversation_id`（群）做路由主键。
> - **`/connect` 绑定**：在 `allowed_users` 门控**之前**处理，使浏览器发起的绑定能引导未授权身份；`upsert_connection` 触发单活跃 owner 迁移。
