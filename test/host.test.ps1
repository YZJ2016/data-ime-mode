# ime-host.ps1 の変換モード計算だけを単体で確認する。
# 実ソースから関数定義を AST で取り出し、Win32 呼び出しはスタブに差し替える。
# IME には一切触らない。
#
#   powershell -ExecutionPolicy Bypass -File test\host.test.ps1

param([string]$Source)

$ErrorActionPreference = 'Stop'

$src = if ($Source) { $Source } else { Join-Path $PSScriptRoot '..\host\ime-host.ps1' }
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $src), [ref]$null, [ref]$null)

$fn = $ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Set-ConversionBits'
}, $true)
if ($fn.Count -ne 1) { throw "Set-ConversionBits が見つかりません (見つかった数: $($fn.Count))" }

# 依存をスタブ化してから、実物の関数定義を読み込む。
$script:written = $null
function Invoke-ImeControl($imeWnd, $cmd, $value) {
    switch ($cmd) {
        1 { return $script:conv }
        2 {
            $script:written = $value
            if ($script:writeTimeout) { return $null }
            if (!$script:ignoreWrite -and !$script:openPending) { $script:conv = $value }
            return 0
        }
        5 {
            if ($script:openPending) {
                $script:openPending--
                if (!$script:openPending) { $script:open = 1 }
            }
            return $script:open
        }
        6 {
            if ($script:delayOpen -and $value -eq 1) { $script:openPending = 2 }
            else { $script:open = $value }
            return 0
        }
    }
}
function Write-DebugLog($msg) { }
$CONV_MASK = 0x000B
$IMC_GETCONVERSIONMODE = 1
$IMC_SETCONVERSIONMODE = 2
$IMC_GETOPENSTATUS = 5
$IMC_SETOPENSTATUS = 6

Invoke-Expression $fn[0].Extent.Text

$results = @()

function Show($v) {
    if ($null -eq $v) { return '書き込みなし' }
    return ('0x{0:X4}' -f [int]$v)
}

function Check([string]$name, [int]$current, [int]$value, [bool]$exact, $expectWrite) {
    $script:written = $null
    Set-ConversionBits ([IntPtr]::Zero) $current $value $exact | Out-Null
    $actual = $script:written
    $ok = if ($null -eq $expectWrite) { $null -eq $actual } else { $actual -eq $expectWrite }
    $script:results += [pscustomobject]@{
        Name     = $name
        Ok       = $ok
        Expected = (Show $expectWrite)
        Actual   = (Show $actual)
    }
}

# --- 適用: 自分の 3 ビットだけ書き換え、ROMAN などは現在値から引き継ぐ -------

Check ' 適用 ひらがな: 既にひらがな (ROMAN 有) なら書かない' 0x0019 0x0009 $false $null
Check ' 適用 全角カナ: ROMAN を保ったまま KATAKANA を立てる'   0x0019 0x000B $false 0x001B
Check ' 適用 半角カナ: ROMAN を保ったまま FULLSHAPE を落とす'  0x0019 0x0003 $false 0x0013
Check ' 適用 全角カナ: ROMAN が無ければ付けない'               0x0009 0x000B $false 0x000B

# --- 復帰: 捕獲した値をそのまま書き戻す -------------------------------------
#
# ここをマスクに通すと、適用中に非マスクビットが変わっていた場合に取り違える。
# 実際にログで観測した壊れ方: convRaw=0x0019 を要求したのに 0x0009 が書かれ、
# ROMAN が落ちてローマ字入力からかな入力へ勝手に切り替わっていた。

Check '*復帰 ROMAN を含む値を欠けずに書き戻す'      0x0003 0x0019 $true 0x0019
Check '*復帰 現在値と同じなら書かない'              0x0019 0x0019 $true $null
Check '*復帰 変換モード無し (0x0000) へ戻せる'      0x0009 0x0000 $true 0x0000
Check '*復帰 非マスクビットのみ異なる場合も書き直す' 0x0009 0x0019 $true 0x0019

# Run the real request handler against an IME that may acknowledge and ignore a write.
$handler = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $args[0].Name -eq 'Invoke-ImeRequest'
}, $true)
$flags = $ast.Find({
    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $args[0].Left.Extent.Text -eq '$CONV_BITS'
}, $true)
$IME_CMODE_NATIVE = 1
$IME_CMODE_KATAKANA = 2
$IME_CMODE_FULLSHAPE = 8
Invoke-Expression $flags.Extent.Text
Invoke-Expression $handler.Extent.Text
function Resolve-ImeWnd($hwnd) { return @{ target = [IntPtr]42; ime = [IntPtr]43 } }

function Check-Request($name, $mode, $ignore, $timeout, $ok, $expectedConv, $expectedError) {
    $script:open = 1
    $script:conv = 0x19
    $script:ignoreWrite = $ignore
    $script:writeTimeout = $timeout
    $script:lastChange = $null
    $r = Invoke-ImeRequest @{ cmd = 'set'; hwnd = 42; open = 1; conv = $mode }
    $actual = "$($r.ok) / $($script:conv) / $($r.error)"
    $expected = "$ok / $expectedConv / $expectedError"
    $script:results += [pscustomobject]@{
        Name = $name; Ok = ($actual -eq $expected -and $r.previousConv -eq 0x19)
        Expected = $expected; Actual = $actual
    }
}
Check-Request 'full alphanumeric retains ROMAN flag' 'full-alphanumeric' $false $false $true 0x18 ''
Check-Request 'half alphanumeric clears NATIVE and FULLSHAPE' 'half-alphanumeric' $false $false $true 0x10 ''
Check-Request 'accepted but ignored write fails readback' 'full-alphanumeric' $true $false $false 0x19 'IME did not apply the requested state'
Check-Request 'write timeout is propagated' 'full-alphanumeric' $false $true $false 0x19 'setting IME conversion mode timed out'

$script:open = 0
$script:conv = 0x19
$script:delayOpen = $true
$script:ignoreWrite = $false
$script:writeTimeout = $false
$script:lastChange = $null
$r = Invoke-ImeRequest @{ cmd = 'set'; hwnd = 42; open = 1; conv = 'full-katakana' }
$results += [pscustomobject]@{
    Name = 'waits for Japanese IME to open before setting katakana'
    Ok = ($r.ok -and $script:conv -eq 0x1B)
    Expected = 'IME open and full katakana'
    Actual = "$($r.ok) / $($script:conv) / $($r.error)"
}

# Exercise the browser request path with recorded layout and mode operations.
foreach ($functionName in 'Restore-BrowserMode', 'Restore-BrowserLayout', 'Confirm-BrowserImeMode', 'Invoke-BrowserImeRequest') {
    $definition = $ast.Find({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $args[0].Name -eq $functionName
    }, $true)
    Invoke-Expression $definition.Extent.Text
}
$zh = [IntPtr]0x08040804
$ja = [IntPtr]0x04110411
function Get-BrowserWindow($req, $foreground) { return @{ hwnd = [IntPtr]42; pid = 123 } }
function Get-WindowLayout($hwnd) { return $script:layout }
function Test-JapaneseLayout($layout) { return $layout -eq $ja }
function Get-JapaneseLayout { return $ja }
function Set-WindowLayout($hwnd, $layout) {
    $script:actions += "layout:$($layout.ToInt64())"
    if ($script:rejectLayout) { return $false }
    $script:layout = $layout
    return $true
}
function Invoke-ImeRequest($req) {
    if ($req.cmd -eq 'get') { return @{ ok = $true; open = 1; conv = 11 } }
    $script:actions += "mode:$($script:layout.ToInt64()):$($req.conv)"
    if ($req.restore) { $script:lastChange = $null }
    else {
        $script:lastChange = @{ hwnd = [IntPtr]42; pid = 123; layout = $req.inputLayout;
            open = 0; conv = 0x19 }
    }
    return @{ ok = $true; hwnd = 42; previous = 0; previousConv = 0x19;
        expectedOpen = 1; expectedConv = 11; conversionMask = 11 }
}
function Check-BrowserRequest($name, $actual, $expected) {
    $script:results += [pscustomobject]@{
        Name = $name; Ok = ($actual -eq $expected); Expected = $expected; Actual = $actual
    }
}
$apply = @{ cmd = 'set'; browser = 'chrome'; hwnd = 42; open = 1; conv = 'full-katakana' }
$restore = @{ cmd = 'set'; browser = 'chrome'; hwnd = 42; restore = $true }
$script:layout = $ja
$script:actions = @()
$script:lastChange = $null
$script:layoutChange = $null
Invoke-BrowserImeRequest $apply | Out-Null
Check-BrowserRequest 'Japanese layout is already active: only switch mode' ($script:actions -join ',') "mode:$($ja.ToInt64()):full-katakana"

$script:layout = $zh
$script:actions = @()
$script:lastChange = $null
Invoke-BrowserImeRequest $apply | Out-Null
Invoke-BrowserImeRequest $restore | Out-Null
Check-BrowserRequest 'select Japanese first; restore Japanese mode, then original language' (
    $script:actions -join ','
) "layout:$($ja.ToInt64()),mode:$($ja.ToInt64()):full-katakana,mode:$($ja.ToInt64()):,layout:$($zh.ToInt64())"

$script:actions = @()
$script:rejectLayout = $true
$r = Invoke-BrowserImeRequest $apply
Check-BrowserRequest 'rejected layout request does not write a conversion mode' (
    "$($r.ok) / $($script:actions -join ',')"
) "False / layout:$($ja.ToInt64())"
$script:rejectLayout = $false
Invoke-BrowserImeRequest $restore | Out-Null

$script:actions = @()
Invoke-BrowserImeRequest $apply | Out-Null
$script:layout = [IntPtr]0x04090409
Invoke-BrowserImeRequest $restore | Out-Null
Check-BrowserRequest 'leaving a field preserves a later manual input-language selection' (
    $script:layout.ToInt64()
) 0x04090409

# After a layout handoff the initial readback can still reflect the old
# IME context; simulate the new context starting in direct input.
$script:modeWrites = 0
$script:layout = $zh
$script:layoutChange = $null
$script:lastChange = $null
function Invoke-ImeRequest($req) {
    if ($req.cmd -eq 'get') {
        if ($script:modeWrites -eq 1 -or $script:alwaysDirect) {
            return @{ ok = $true; open = 0; conv = 9 }
        }
        return @{ ok = $true; open = 1; conv = 11 }
    }
    $script:modeWrites++
    return @{ ok = $true; hwnd = 42; previous = 0; previousConv = 9;
        expectedOpen = 1; expectedConv = 11; conversionMask = 11 }
}
$verifiedMode = Invoke-BrowserImeRequest $apply
Check-BrowserRequest 'layout handoff reapplies katakana if the next context opens in direct input' (
    "$($verifiedMode.ok) / $script:modeWrites"
) 'True / 2'

$script:alwaysDirect = $true
$script:modeWrites = 0
$script:layout = $zh
$script:layoutChange = $null
$verifiedMode = Invoke-BrowserImeRequest $apply
Check-BrowserRequest 'a persistent reset does not report success or retry forever' (
    "$($verifiedMode.ok) / $script:modeWrites / $($verifiedMode.restorePending)"
) 'False / 2 / True'

$bad = 0
foreach ($r in $results) {
    if ($r.Ok) {
        Write-Host ('PASS  ' + $r.Name)
    } else {
        $bad++
        Write-Host ('FAIL  ' + $r.Name) -ForegroundColor Red
        Write-Host ('        期待: ' + $r.Expected)
        Write-Host ('        実際: ' + $r.Actual)
    }
}
Write-Host ''
Write-Host ("{0}/{1} passed" -f ($results.Count - $bad), $results.Count)
if ($bad) { exit 1 }
