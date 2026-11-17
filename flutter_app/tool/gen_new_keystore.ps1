$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = 'C:\Program Files\Android\openjdk\jdk-21.0.8'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

$ksDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'keystore'
$ks = Join-Path $ksDir 'deepseek.keystore'
$alias = 'deepseek'
# 密码从环境变量读取，避免明文入库（见 AGENTS.md 安全习惯）
$pass = $env:DSAPI_KEYSTORE_PASS
if (-not $pass) {
    throw '请先设置环境变量 DSAPI_KEYSTORE_PASS（keystore 密码）再运行'
}

# 删除旧 keystore
if (Test-Path -LiteralPath $ks) {
    Remove-Item -LiteralPath $ks -Force
    Write-Output "DEL old keystore: $ks"
}

# 生成新 keystore（RSA 2048，有效期 10000 天）
& keytool -genkeypair `
    -alias $alias `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -keystore $ks `
    -storepass $pass `
    -keypass $pass `
    -dname "CN=DeepSeek App, OU=Developer, O=DeepSeek, L=Hangzhou, ST=Zhejiang, C=CN" `
    -noprompt 2>&1 | ForEach-Object { Write-Output $_ }

if (Test-Path -LiteralPath $ks) {
    Write-Output "NEW keystore created: $ks ($((Get-Item $ks).Length) bytes)"
} else {
    Write-Output "FAILED: keystore not created"
}
