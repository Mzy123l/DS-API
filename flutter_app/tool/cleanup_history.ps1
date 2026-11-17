$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# 废弃的 QML/C++ 历史工程目录（已改用 Flutter，保留 flutter_app）
$dirs = @('android', 'build', 'qml', 'src', 'tests', 'tools')
foreach ($d in $dirs) {
    $p = Join-Path $root $d
    if (Test-Path -LiteralPath $p) {
        # 校验：目标必须位于项目根目录内
        $full = [System.IO.Path]::GetFullPath($p)
        $rootFull = [System.IO.Path]::GetFullPath($root)
        if (-not $full.StartsWith($rootFull)) {
            Write-Output "SKIP(out-of-root): $full"
            continue
        }
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Output "DEL dir: $d"
    }
}

# 废弃的 QML/C++ 单文件
foreach ($f in 'CMakeLists.txt', 'Main.qml', 'BUILD.md') {
    $p = Join-Path $root $f
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        Write-Output "DEL file: $f"
    }
}

# 旧 APK 产物
foreach ($f in 'DeepSeekApp-release.apk', 'DS-API-release.apk', 'DS-API-x86_64-release.apk') {
    $p = Join-Path $root $f
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        Write-Output "DEL apk: $f"
    }
}

Write-Output 'DONE'
