<#
  读取本机 flutter_app/.env.local 里的服务器配置，打包 release APK。

  用法：
    powershell -File tool/build_release.ps1                 # 只出包
    powershell -File tool/build_release.ps1 -Install        # 出包并 adb 覆盖安装（不启动 App）
    powershell -File tool/build_release.ps1 -Abi armeabi-v7a
#>
param(
    [switch]$Install,
    [string]$Abi = 'arm64-v8a'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root '.env.local'
if (-not (Test-Path $envFile)) {
    throw "缺少 $envFile（记录服务器地址/口令/证书指纹，已被 gitignore）"
}

if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'C:\Program Files\Android\openjdk\jdk-21.0.8' }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\sdk" }
# FLUTTER_ROOT 未设置时从 PATH 里找 flutter；两者都没有才报错
if (-not $env:FLUTTER_ROOT) {
    $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCmd) { $env:FLUTTER_ROOT = Split-Path -Parent (Split-Path -Parent $flutterCmd.Source) }
}
if ($env:FLUTTER_ROOT) { $env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH" }

# 解析 .env.local（KEY=VALUE，# 开头是注释）
$config = @{}
foreach ($line in Get-Content $envFile) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $index = $trimmed.IndexOf('=')
    if ($index -lt 1) { continue }
    $config[$trimmed.Substring(0, $index).Trim()] = $trimmed.Substring($index + 1).Trim()
}

$defines = @()
$injected = @()
foreach ($key in 'DS_SERVER_BASE_URL', 'DS_SERVER_TOKEN', 'DS_SERVER_CERT_SHA256') {
    if ($config.ContainsKey($key) -and $config[$key] -ne '') {
        $defines += "--dart-define=$key=$($config[$key])"
        $injected += $key
    }
}
# 只打印注入了哪些配置，不打印值：服务器口令属于敏感信息
Write-Host "注入配置：$($injected -join '  ')"

Push-Location $root
try {
    & flutter build apk --release --split-per-abi @defines
    if ($LASTEXITCODE -ne 0) { throw '构建失败' }
} finally {
    Pop-Location
}

$apk = Join-Path $root "build\app\outputs\flutter-apk\app-$Abi-release.apk"
Write-Host "APK: $apk"

if ($Install) {
    $adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
    & $adb install -r $apk
    if ($LASTEXITCODE -ne 0) {
        throw '安装失败（设备未连接或安装被拒），APK 已生成在: ' + $apk
    }
    Write-Host '已覆盖安装（没有启动 App）'
}
