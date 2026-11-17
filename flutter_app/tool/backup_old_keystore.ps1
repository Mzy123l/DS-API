$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ksDir = Join-Path $root 'keystore'
$backupDir = Join-Path $env:TEMP 'ds_api_keystore_backup'

if (-not (Test-Path -LiteralPath $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

foreach ($f in 'deepseek.keystore', 'deepseek_app.keystore') {
    $src = Join-Path $ksDir $f
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $backupDir $f
        Copy-Item -LiteralPath $src -Destination $dst -Force
        # 备份后用临时文件的方式，原文件稍后由删除脚本删除
        Write-Output "BACKUP: $f -> $dst"
    }
}

# 记录原签名信息（脱敏）
$props = Join-Path $root 'flutter_app\android\keystore.properties'
if (Test-Path -LiteralPath $props) {
    Copy-Item -LiteralPath $props -Destination (Join-Path $backupDir 'keystore.properties.bak') -Force
    Write-Output "BACKUP: keystore.properties"
}
Write-Output "BACKUP_DIR: $backupDir"
