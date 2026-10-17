# `backend/packages/harness/helix/agents/memory/backends/helixmem/helixmem/core/message_patterns/correction.yaml`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
# Correction signal patterns for detect_correction (message_processing).
#
# Each list entry is either:
#   - a string                       -> compiled with no flags
#   - a mapping {pattern, flags}     -> flags is a list of names: "ignorecase"
#
# In single-quoted strings backslashes are literal (regex \b stays \b); double
# '' for a literal single quote. Default content mirrors the pre-externalization
# hardcoded _CORRECTION_PATTERNS (en+zh) so zero-config behavior is unchanged.
# Add languages / business phrases here without touching code.

- pattern: '\bthat(?:''s| is) (?:wrong|incorrect)\b'
  flags: [ignorecase]
- pattern: '\byou misunderstood\b'
  flags: [ignorecase]
- pattern: '\btry again\b'
  flags: [ignorecase]
- pattern: '\bredo\b'
  flags: [ignorecase]
- '不对'
- '你理解错了'
- '你理解有误'
- '重试'
- '重新来'
- '换一种'
- '改用'
```
