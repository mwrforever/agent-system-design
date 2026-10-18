# `agents/memory/backends/helixmem/pkg/core/message_patterns/identity.yaml`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Identity signal patterns for detect_signals (message_processing).
#
# Detects that the user stated something about who they are (role, profession,
# background) -- a high-value "what to remember" signal. Matched via ``search``
# over the last 6 human turns. Keep these narrow to avoid false positives.
#
# Each list entry is either:
#   - a string                       -> compiled with no flags
#   - a mapping {pattern, flags}     -> flags is a list of names: "ignorecase"
#
# In single-quoted strings backslashes are literal (regex \b stays \b); double
# '' for a literal single quote (apostrophe).

- pattern: '\bI am (?:a |an )?[a-z][a-z -]{2,}\b'
  flags: [ignorecase]
- pattern: '\bI work as\b'
  flags: [ignorecase]
- pattern: '\bI.m (?:a |an )?[a-z][a-z -]{2,}\b'
  flags: [ignorecase]
- pattern: '\bmy job is\b'
  flags: [ignorecase]
- '我是'
- '我的职业是'
- '我的工作是'
- '我担任'
- '我是一名'
```
