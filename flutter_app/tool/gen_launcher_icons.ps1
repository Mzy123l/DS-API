$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$base = Split-Path -Parent $PSScriptRoot
$src = Join-Path $base 'assets\icon_official.png'
$resDir = Join-Path $base 'android\app\src\main\res'

# 各密度尺寸（px）
$sizes = @{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}

$sourceImg = [System.Drawing.Image]::FromFile($src)
Write-Output "源图标: $($sourceImg.Width)x$($sourceImg.Height)"

foreach ($entry in $sizes.GetEnumerator()) {
    $dir = Join-Path $resDir $entry.Key
    $size = $entry.Value
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($sourceImg, 0, 0, $size, $size)
    $g.Dispose()
    $out = Join-Path $dir 'ic_launcher.png'
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "GEN $($entry.Key)/ic_launcher.png ($size->$size)"
}

$sourceImg.Dispose()
Write-Output 'DONE. 图标已按官方鲸鱼图标生成。'
