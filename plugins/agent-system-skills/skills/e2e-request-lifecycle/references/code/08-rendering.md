# ⑧ 渲染完整源码

> 本文件是脊柱 `SKILL.md` 第⑧跳"渲染"的深度展开。脊柱只给入口片段；此处给前端三路乐观合并（`mergeMessages`）+ 钉钉 AI Card 流式 patch（`PUT /v1.0/card/streaming`）+ sampleMarkdown 回退的真实源码片段。
>
> 代码已按插件匿名化规则映射到自定结构（`frontend.*` / `channels.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[frontend-streaming-protocol]]`（SSE schema + useStream 消费）、`[[frontend-app-design]]`（Next.js 渲染层 + 设计系统）、`[[im-channels]]`（钉钉/飞书/Telegram 渲染差异）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `frontend/src/core/threads/hooks.ts` | 前端三路乐观合并：`mergeMessages`（历史 + 实时流 + 乐观消息） |
| `channels/channels/dingtalk.py` | 钉钉 AI Card 流式 patch + sampleMarkdown 回退 |

---

## 1. `frontend/src/core/threads/hooks.ts` - 三路乐观合并

> 前端把 `useStream` 收到的 `values`/`messages-tuple`/`custom` 事件，与历史、乐观消息**三路合并**（`mergeMessages`），再 markdown 渲染。重叠是 historyMessages 的连续后缀（最新历史 == 最旧线程消息）。

```typescript
// frontend/src/core/threads/hooks.ts - 三路乐观合并（历史 + 实时流 + 乐观消息）
export function mergeMessages(historyMessages: Message[], threadMessages: Message[], optimisticMessages: Message[]): Message[] {
  const threadMessageIds = new Set(
    threadMessages.filter(m => !isHiddenFromUIMessage(m)).map(messageIdentity).filter(isNonEmptyString));
  // 重叠是 historyMessages 的连续后缀（最新历史 == 最旧线程）：从尾扫描，命中即缩 cutoff
  let cutoff = historyMessages.length;
  for (let i = historyMessages.length - 1; i >= 0; i--) {
    const id = messageIdentity(historyMessages[i]);
    if (id && threadMessageIds.has(id)) cutoff = i; else break;
  }
  return dedupeMessagesByIdentity([
    ...historyMessages.slice(0, cutoff), ...threadMessages, ...optimisticMessages,
  ]);
}
// mergedMessages 由聊天 UI（components/workspace/messages/）经 markdown 渲染器呈现；
// useStream 收到的 messages-tuple 增量由 SDK 按 message id 拼接成完整消息
```

> 注：`isHiddenFromUIMessage` 过滤对用户不可见的消息（如 `<system-reminder>` 注入的 SystemMessage、`helix_tool_meta` 元数据消息）。`messageIdentity` 用消息 id 做去重 key。从尾扫描找重叠后缀--historyMessages 的最新部分可能与 threadMessages 的最旧部分重叠（断线重连续传时），找到 cutoff 后切掉重叠段再拼接。`dedupeMessagesByIdentity` 兜底去重。

---

## 2. `channels/channels/dingtalk.py` - AI Card 流式 patch + sampleMarkdown 回退

> IM 侧钉钉用 **AI Card 流式 patch**（`PUT /v1.0/card/streaming`）原地更新同一张卡片，失败回退 `sampleMarkdown`（仅最终消息值得回退）。先发"运行中"卡片占位，再流式 patch 内容。

```python
# channels/channels/dingtalk.py - AI Card 流式 patch + sampleMarkdown 回退
async def send(self, msg: OutboundMessage, *, _max_retries: int = 3) -> None:
    out_track_id = self._card_track_ids.get(self._make_card_source_key_from_outbound(msg))
    if out_track_id:
        try:
            await self._stream_update_card(out_track_id, msg.text, is_finalize=msg.is_final)
        except Exception:
            if msg.is_final:   # 卡片流失败 -> 回退 sampleMarkdown（仅最终消息值得回退）
                await self._send_markdown_fallback(robot_code, conversation_type,
                                                   sender_staff_id, conversation_id, msg.text)
        return
    await self._send_with_retry(send_markdown, max_retries=_max_retries)   # 无卡片模式：直接 sampleMarkdown

async def _stream_update_card(self, out_track_id: str, content: str, *, is_finalize=False, is_error=False):
    replier = self._card_repliers.get(out_track_id)
    await replier.async_streaming(card_instance_id=out_track_id, content_key="content",
        content_value=content, append=False, finished=is_finalize, failed=is_error)   # 钉钉 PUT /v1.0/card/streaming
```

> 注：`out_track_id` 是钉钉卡片的实例标识，`_card_track_ids` 按 outbound 消息源 key 映射到卡片 id，使同一轮对话的多次流式更新打到同一张卡片。`append=False` 每次全量替换内容（而非追加），`finished=is_finalize` 标记流结束。卡片流失败时仅最终消息回退 sampleMarkdown--中间流式消息回退会刷屏，不值得。`_send_with_retry` 是无卡片模式的直发路径（带重试）。

---

## 关键不变量与测试锚点

1. **三路合并**：历史（持久化）+ 实时流（SSE 增量）+ 乐观消息（用户发送即显示），经 `mergeMessages` 去重拼接。
2. **重叠后缀切除**：historyMessages 的连续后缀 == threadMessages 的前缀（断线重连续传），从尾扫描找 cutoff 切掉重叠段。
3. **隐藏消息过滤**：`isHiddenFromUIMessage` 过滤 `<system-reminder>`/`helix_tool_meta` 等非用户可见消息。
4. **AI Card 流式 patch**：同一轮对话多次更新打到同一张卡片（`out_track_id` 映射），`append=False` 全量替换。
5. **回退策略**：卡片流失败仅最终消息回退 sampleMarkdown（中间消息不回退避免刷屏）。
6. **messages-tuple 拼接**：SDK 按 message id 把 `messages-tuple` 增量拼接成完整消息，前端不手动拼。

> 关联：`[[frontend-streaming-protocol]]`（SSE schema + useStream 消费细节）、`[[frontend-app-design]]`（Next.js 渲染层 + 设计系统 + markdown 渲染器）、`[[im-channels]]`（钉钉/飞书/Telegram 渲染差异 + AI Card 协议）。
