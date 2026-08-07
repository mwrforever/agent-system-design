#!/usr/bin/env bash
# opencode 全局安装脚本（bash / macOS / Linux）
#
# 作用：把本仓库的 agent-system-skills 技能集注册到 opencode 全局配置
#       ~/.config/opencode/opencode.json 的 skills.paths 中（幂等，可重复执行）。
# 用法：在仓库根目录执行  ./scripts/install-opencode.sh
# 说明：修改配置后需要重启 opencode 才会生效。

set -euo pipefail

# 脚本位于 <repo>/scripts/ 下，技能目录为 <repo>/plugins/agent-system-skills/skills
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_PATH="$REPO_ROOT/plugins/agent-system-skills/skills"

if [ ! -d "$SKILLS_PATH" ]; then
    echo "错误：未找到技能目录：$SKILLS_PATH" >&2
    exit 1
fi

# opencode 全局配置路径（支持 OPENCODE_CONFIG 环境变量覆盖）
CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
mkdir -p "$(dirname "$CONFIG_PATH")"

# 读取或初始化配置（文件不存在时以空对象起步）
if [ -s "$CONFIG_PATH" ]; then
    CONFIG="$(cat "$CONFIG_PATH")"
else
    CONFIG='{}'
fi

# 用 python3 做 JSON 合并（幂等去重，UTF-8 无 BOM 写回）
python3 - "$CONFIG_PATH" "$SKILLS_PATH" <<'PY'
import json
import sys

config_path, skills_path = sys.argv[1], sys.argv[2]

with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

skills = config.setdefault("skills", {})
paths = skills.setdefault("paths", [])
if not any(p.rstrip("/") == skills_path.rstrip("/") for p in paths):
    paths.append(skills_path)
config.setdefault("$schema", "https://opencode.ai/config.json")

with open(config_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "已注册技能目录：$SKILLS_PATH"
echo "写入配置：$CONFIG_PATH"
echo "请退出并重启 opencode 使配置生效。"
