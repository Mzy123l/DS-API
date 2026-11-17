$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $PSScriptRoot

# 1. 调试截图
Get-ChildItem -LiteralPath $base -Filter 'shot_*.png' -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    Write-Output "DEL shot: $($_.Name)"
}

# 2. 临时日志/残留
foreach ($f in 'mock.err','mock.log','ui.xml') {
    $p = Join-Path $base $f
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        Write-Output "DEL tmp: $f"
    }
}

# 3. IDEA / 编辑器缓存
$idea = Join-Path $base '.idea'
if (Test-Path -LiteralPath $idea) {
    Remove-Item -LiteralPath $idea -Recurse -Force
    Write-Output "DEL dir: .idea"
}

Write-Output "DONE. 剩余 shot: $((Get-ChildItem -LiteralPath $base -Filter 'shot_*.png' -File).Count)"
