$ErrorActionPreference = 'SilentlyContinue'
$ksDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'keystore'

# 删除多余的旧签名文件（新的 deepseek.keystore 需保留）
$old = Join-Path $ksDir 'deepseek_app.keystore'
if (Test-Path -LiteralPath $old) {
    Remove-Item -LiteralPath $old -Force
    Write-Output "DEL old: deepseek_app.keystore"
}

Write-Output "== 剩余 keystore =="
Get-ChildItem -LiteralPath $ksDir -File | ForEach-Object { Write-Output "$($_.Name) $($_.Length) bytes" }
