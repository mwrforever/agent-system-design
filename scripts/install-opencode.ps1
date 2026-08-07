# opencode 全局安装脚本（Windows PowerShell）
#
# 作用：把本仓库的 agent-system-skills 技能集注册到 opencode 全局配置
#       ~/.config/opencode/opencode.json 的 skills.paths 中（幂等，可重复执行）。
# 用法：在仓库根目录执行  .\scripts\install-opencode.ps1
# 说明：修改配置后需要重启 opencode 才会生效。

$ErrorActionPreference = "Stop"

# 脚本位于 <repo>/scripts/ 下，技能目录为 <repo>/plugins/agent-system-skills/skills
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$skillsPath = (Resolve-Path (Join-Path $repoRoot "plugins\agent-system-skills\skills")).Path

if (-not (Test-Path -LiteralPath $skillsPath)) {
    Write-Error "未找到技能目录：$skillsPath"
    exit 1
}

# opencode 全局配置路径（支持 OPENCODE_CONFIG 环境变量覆盖）
$configDir = "$env:USERPROFILE\.config\opencode"
$configPath = Join-Path $configDir "opencode.json"
if ($env:OPENCODE_CONFIG) {
    $configPath = $env:OPENCODE_CONFIG
    $configDir = Split-Path -Parent $configPath
}

New-Item -ItemType Directory -Path $configDir -Force | Out-Null

# 读取或初始化配置（文件不存在时以空对象起步；兼容 PS5.1 的 PSCustomObject 写法）
$config = [pscustomobject]@{}
if (Test-Path -LiteralPath $configPath) {
    $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    if ($raw.Trim()) {
        $config = $raw | ConvertFrom-Json
    }
}

# 确保 skills.paths 节点存在（PSCustomObject 需要显式 Add-Member）
if (-not $config.PSObject.Properties['skills']) {
    $config | Add-Member -NotePropertyName skills -NotePropertyValue ([pscustomobject]@{ paths = @() })
}
if (-not $config.skills.PSObject.Properties['paths']) {
    $config.skills | Add-Member -NotePropertyName paths -NotePropertyValue @()
}

# 合并 skills.paths（幂等去重；Windows 路径统一转小写比较）
$paths = @($config.skills.paths)
$alreadyRegistered = $paths | Where-Object { $_.ToLowerInvariant() -eq $skillsPath.ToLowerInvariant() }
if (-not $alreadyRegistered) {
    $paths += $skillsPath
    $config.skills.paths = $paths
}

# UTF-8 无 BOM 写回（保持 $schema 提示；键名用单引号避免 PowerShell 变量插值）
if (-not $config.'$schema') {
    $config | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://opencode.ai/config.json"
}
$json = $config | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "已注册技能目录：$skillsPath"
Write-Host "写入配置：$configPath"
Write-Host "请退出并重启 opencode 使配置生效。"
