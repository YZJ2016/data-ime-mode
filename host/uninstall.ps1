param([ValidatePattern('^[a-z0-9_]+(\.[a-z0-9_]+)*$')][string]$HostName = 'io.github.fukunagajiro.data_ime_mode')

$ErrorActionPreference = 'Stop'

$keys = @(
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$HostName"
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"
)
foreach ($key in $keys) {
    if (Test-Path $key) {
        Remove-Item -LiteralPath $key -Force
        Write-Host "レジストリキーを削除しました: $key"
    } else {
        Write-Host "レジストリキーは見つかりませんでした: $key"
    }
}

$manPath = Join-Path $PSScriptRoot "$HostName.json"
if (Test-Path $manPath) {
    Remove-Item -LiteralPath $manPath -Force
    Write-Host "マニフェストを削除しました: $manPath"
}
