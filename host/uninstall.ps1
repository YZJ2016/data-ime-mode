param([ValidatePattern('^[a-z0-9_]+(\.[a-z0-9_]+)*$')][string]$HostName = 'data_ime_mode')

$ErrorActionPreference = 'Stop'

function Remove-HostRegistration([string]$name) {
    $manPath = Join-Path $PSScriptRoot "$name.json"
    $keys = @(
        "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$name"
        "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$name"
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            $registeredPath = (Get-ItemProperty -LiteralPath $key).'(default)'
            if ($registeredPath -ne $manPath) {
                Write-Host "別のフォルダの登録を保持しました: $key"
                continue
            }
            Remove-Item -LiteralPath $key -Force
            Write-Host "レジストリキーを削除しました: $key"
        } else {
            Write-Host "レジストリキーは見つかりませんでした: $key"
        }
    }

    if (Test-Path -LiteralPath $manPath) {
        Remove-Item -LiteralPath $manPath -Force
        Write-Host "マニフェストを削除しました: $manPath"
    }
}

Remove-HostRegistration $HostName
if (!$PSBoundParameters.ContainsKey('HostName')) {
    Remove-HostRegistration 'io.github.fukunagajiro.data_ime_mode'
}
