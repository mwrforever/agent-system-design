# `agents/memory/backends/helixmem/pkg/core/message_patterns/goal.yaml`

> 逐字复制的真实源码（28 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Goal signal patterns for detect_signals (message_processing).
#
# Detects that the user stated an objective / intent / plan -- a high-value
# "what to remember" signal. Matched via ``search`` over the last 6 human
# turns. Keep these narrow to avoid false positives.
#
# Each list entry is either:
#   - a string                       -> compiled with no flags
#   - a mapping {pattern, flags}     -> flags is a list of names: "ignorecase"
#
# In single-quoted strings backslashes are literal (regex \b stays \b); double
# '' for a literal single quote (apostrophe).

- pattern: '\bI (?:plan to|want to|am going to|aim to|intend to)\b'
  flags: [ignorecase]
- pattern: '\bmy goal is\b'
  flags: [ignorecase]
- pattern: '\bI.m going to\b'
  flags: [ignorecase]
- pattern: '\bnext I.ll\b'
  flags: [ignorecase]
- '我的目标是'
- '我打算'
- '我准备'
- '接下来我要'
- '接下来我打算'
- '我想做'
```
