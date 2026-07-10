# references/code/boundary-and-ci-test.md — CI 边界测试（AST import 防火墙）

> 自定路径：`tests/test_core_boundary.py`
> 真实职责：遍历 Core 框架包（`core/helix/`）下所有 `.py`，解析每条 import 语句，命中 `gateway.` / `channels.` / `scheduler.` 前缀即判 violation。CI 每条 PR 跑，红即阻断合并。
>
> 设计要点：用 AST（`ast.walk`）而非 regex 解析 import，可覆盖多行 import 与 `import a.b as c` 别名；`SyntaxError` 文件兜底返回空列表，不因单文件语法错误中断全量扫描。

## 完整源码

```python
"""Boundary check: core framework layer must not import from app layer.

The ``helix`` package (``core/helix/``) is a standalone, publishable agent
framework. It must never depend on the app layer (``gateway`` / ``channels`` /
``scheduler``).

This test scans all Python files in the core package and fails if any
``from gateway.`` / ``from channels.`` / ``from scheduler.`` or equivalent
``import`` statement is found.
"""

import ast
from pathlib import Path

CORE_ROOT = Path(__file__).parent.parent / "core" / "helix"

BANNED_PREFIXES = ("gateway.", "channels.", "scheduler.")


def _collect_imports(filepath: Path) -> list[tuple[int, str]]:
    """Return (line_number, module_path) for every import in *filepath*."""
    source = filepath.read_text(encoding="utf-8")
    try:
        tree = ast.parse(source, filename=str(filepath))
    except SyntaxError:
        return []

    results: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                results.append((node.lineno, alias.name))
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                results.append((node.lineno, node.module))
    return results


def test_core_does_not_import_app():
    violations: list[str] = []

    for py_file in sorted(CORE_ROOT.rglob("*.py")):
        for lineno, module in _collect_imports(py_file):
            if any(module == prefix.rstrip(".") or module.startswith(prefix) for prefix in BANNED_PREFIXES):
                rel = py_file.relative_to(CORE_ROOT.parent.parent.parent)
                violations.append(f"  {rel}:{lineno}  imports {module}")

    assert not violations, "Core layer must not import from app layer:\n" + "\n".join(violations)
```

## 关键实现细节

- **`CORE_ROOT` 定位**：`Path(__file__).parent.parent / "core" / "helix"`——测试文件位于 `tests/`，向上一级到仓库根，再进 `core/helix/`。整个 Core 包通过 `rglob("*.py")` 全量扫描，无白名单。
- **`BANNED_PREFIXES` 三前缀**：`gateway.` / `channels.` / `scheduler.`——对应应用层三个独立子包。匹配规则用 `module == prefix.rstrip(".")`（精确匹配顶层包名 `gateway`）或 `module.startswith(prefix)`（匹配子模块 `gateway.gateway.deps`），双保险。
- **AST 而非 regex**：`ast.Import` 捕获 `import a.b.c` 与 `import a.b as c`（`alias.name` 是完整点分路径）；`ast.ImportFrom` 捕获 `from a.b import c`（`node.module` 是 `a.b`）。regex 容易漏多行 import 或被字符串字面量误伤。
- **`SyntaxError` 兜底**：返回空列表而非抛错——单文件语法错误不应让边界测试失真（语法错误由编译/lint 阶段抓）。
- **失败信息可定位**：每条 violation 含 `相对路径:行号  imports 模块名`，直接跳到出错点。
- **TUI 绝对 import 联动**：`core/helix/tui/cli.py` 必须用 `from helix.tui.app import run_tui`（绝对），不能用 `from .app import run_tui`（相对）——后者会被 `ast.ImportFrom` 记录 `node.module = "app"`，虽不命中 `gateway.` 等前缀，但若未来 BANNED_PREFIXES 收紧到包含 `app.`，相对 import 即误伤。绝对 import 让模块名字面是 `helix.tui.app`，干净。
