# `agents/memory/backends/helixmem/pkg/core/message_patterns/preference.yaml`

> 逐字复制的真实源码（30 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Preference signal patterns for detect_signals (message_processing).
#
# Detects that the user stated a preference / dislike -- a high-value "what to
# remember" signal. Matched via ``search`` over the last 6 human turns. Keep
# these narrow to avoid false positives; extend here without touching code.
#
# Each list entry is either:
#   - a string                       -> compiled with no flags
#   - a mapping {pattern, flags}     -> flags is a list of names: "ignorecase"
#
# In single-quoted strings backslashes are literal (regex \b stays \b); double
# '' for a literal single quote (apostrophe).

- pattern: '\bI (?:really )?(?:prefer|like|love|enjoy|favor)\b'
  flags: [ignorecase]
- pattern: '\bI (?:really )?(?:hate|dislike|don.t like|cannot stand)\b'
  flags: [ignorecase]
- pattern: '\bmy favorite\b'
  flags: [ignorecase]
- pattern: '\bI.d rather\b'
  flags: [ignorecase]
- '我喜欢'
- '我偏好'
- '我更喜欢'
- '我偏爱'
- '我讨厌'
- '我不喜欢'
- '我钟爱'
- '我最喜欢'
```
