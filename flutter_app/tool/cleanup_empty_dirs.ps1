$ErrorActionPreference = 'SilentlyContinue'
$oldKotlin = Join-Path (Split-Path -Parent $PSScriptRoot) 'android\app\src\main\kotlin\com\deepseek\deepseek_app'
if (Test-Path -LiteralPath $oldKotlin) {
    Remove-Item -LiteralPath $oldKotlin -Recurse -Force
    Write-Output "DEL empty dir: $oldKotlin"
}
Write-Output 'DONE'
