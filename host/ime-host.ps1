#requires -Version 5.1
# Native Messaging host for the data-ime-mode extension.
# Speaks Chromium's stdio protocol (4-byte native-order length prefix + UTF-8 JSON)
# and drives the IME open state / conversion mode of a target window via WM_IME_CONTROL.

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class ImeNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("imm32.dll")]  public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);
    [DllImport("imm32.dll")] public static extern bool ImmIsIME(IntPtr layout);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(
        IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    // 診断用: 書き込み先が本当に Edge なのかを記録するため。
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(
        IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@

$WM_INPUTLANGCHANGEREQUEST = 0x0050
$WM_IME_CONTROL        = 0x0283
$IMC_GETCONVERSIONMODE = 0x0001
$IMC_SETCONVERSIONMODE = 0x0002
$IMC_GETOPENSTATUS     = 0x0005
$IMC_SETOPENSTATUS     = 0x0006
$SMTO_ABORTIFHUNG      = 0x0002
$SEND_TIMEOUT_MS       = 200

$IME_CMODE_NATIVE    = 0x0001
$IME_CMODE_KATAKANA  = 0x0002
$IME_CMODE_FULLSHAPE = 0x0008

# Only these three bits are ours. ROMAN (ローマ字入力/かな入力) and everything
# else belongs to the user's own IME configuration and must survive untouched.
$CONV_MASK = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA -bor $IME_CMODE_FULLSHAPE

$CONV_BITS = @{
    'full-alphanumeric' = $IME_CMODE_FULLSHAPE
    'half-alphanumeric' = 0
    'hiragana'      = $IME_CMODE_NATIVE -bor $IME_CMODE_FULLSHAPE                          # 0x09
    'full-katakana' = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA -bor $IME_CMODE_FULLSHAPE  # 0x0B
    'half-katakana' = $IME_CMODE_NATIVE -bor $IME_CMODE_KATAKANA                            # 0x03
}

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

# 診断ログ。host\debug.on を置くと有効になる。プロセスを起動するのは Edge なので
# 環境変数では切り替えられない。stdout はプロトコル専用なので必ずファイルへ書く。
$script:logPath = $null
if (Test-Path (Join-Path $PSScriptRoot 'debug.on')) {
    $script:logPath = Join-Path $PSScriptRoot 'debug.log'
}

function Write-DebugLog([string]$msg) {
    if ($null -eq $script:logPath) { return }
    try {
        [IO.File]::AppendAllText(
            $script:logPath,
            ('{0:HH:mm:ss.fff}  {1}{2}' -f (Get-Date), $msg, [Environment]::NewLine),
            [Text.Encoding]::UTF8)
    } catch { }
}

Write-DebugLog '--- host 起動 ---'

# 診断専用。ウィンドウがどのアプリのものかを人間が読める形にする。
# 「Edge に書いたつもりが別アプリだった」を一目で分かるようにするため。
function Get-WindowLabel([IntPtr]$hWnd) {
    if ($hWnd -eq [IntPtr]::Zero) { return '(なし)' }
    try {
        $pid32 = 0
        [void][ImeNative]::GetWindowThreadProcessId($hWnd, [ref]$pid32)
        $name = try { (Get-Process -Id $pid32 -ErrorAction Stop).ProcessName } catch { "pid $pid32" }
        $sb = New-Object Text.StringBuilder 256
        [void][ImeNative]::GetWindowTextW($hWnd, $sb, $sb.Capacity)
        $title = $sb.ToString()
        if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '…' }
        return "$name `"$title`""
    } catch { return '(取得失敗)' }
}

# Safety net: whatever we last changed, put it back when the port dies.
$script:lastChange = $null
$script:layoutChange = $null

function Read-Exactly([int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stdin.Read($buf, $off, $count - $off)
        if ($n -le 0) { return $null }   # EOF - browser closed the port
        $off += $n
    }
    return $buf
}

function Read-Message {
    $lenBuf = Read-Exactly 4
    if ($null -eq $lenBuf) { return $null }
    $len = [BitConverter]::ToInt32($lenBuf, 0)
    if ($len -le 0 -or $len -gt 1048576) { return $null }
    $body = Read-Exactly $len
    if ($null -eq $body) { return $null }
    return [Text.Encoding]::UTF8.GetString($body)
}

function Write-Message([string]$json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stdout.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# hwnd 0 means "whatever window is in the foreground right now".
function Resolve-ImeWnd([int64]$hwnd) {
    $target = if ($hwnd -eq 0) { [ImeNative]::GetForegroundWindow() } else { [IntPtr]$hwnd }
    if ($target -eq [IntPtr]::Zero) { return @{ target = [IntPtr]::Zero; ime = [IntPtr]::Zero } }
    return @{ target = $target; ime = [ImeNative]::ImmGetDefaultIMEWnd($target) }
}

function Invoke-ImeControl([IntPtr]$imeWnd, [int]$cmd, [int]$value) {
    $result = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = [ImeNative]::SendMessageTimeout(
        $imeWnd, $WM_IME_CONTROL, [IntPtr]$cmd, [IntPtr]$value,
        $SMTO_ABORTIFHUNG, $SEND_TIMEOUT_MS, [ref]$result)
    $sw.Stop()
    if ($ok -eq [IntPtr]::Zero) {   # timed out or window is hung
        Write-DebugLog ('    IMC 0x{0:X2} <- 0x{1:X4}  失敗/タイムアウト ({2}ms, 上限 {3}ms)' `
            -f $cmd, $value, $sw.ElapsedMilliseconds, $SEND_TIMEOUT_MS)
        return $null
    }
    Write-DebugLog ('    IMC 0x{0:X2} <- 0x{1:X4}  => 0x{2:X4} ({3}ms)' `
        -f $cmd, $value, [int]$result, $sw.ElapsedMilliseconds)
    return [int]$result
}

# 変換モードの書き込みは 2 種類あり、扱いが違う。
#
#   モード適用 ($exact = $false)
#     自分の 3 ビットだけを書き換え、非マスクビット（ROMAN = ローマ字入力 /
#     かな入力の別など）は現在値から引き継ぐ。ユーザー自身の設定を壊さないため。
#
#   状態の復帰 ($exact = $true)
#     捕獲した値をそのまま書き戻す。マスクに通してはいけない。適用中に非マスク
#     ビットが変わっていると、現在値側から引き継いだ値で上書きしてしまい、
#     ROMAN が落ちてローマ字入力からかな入力へ勝手に切り替わる。
function Set-ConversionBits([IntPtr]$imeWnd, [int]$current, [int]$value, [bool]$exact = $false) {
    $target = if ($exact) {
        $value
    } else {
        ($current -band (-bnot $CONV_MASK)) -bor ($value -band $CONV_MASK)
    }
    $kind = if ($exact) { '復帰' } else { '適用' }
    if ($target -eq $current) {
        Write-DebugLog ('    conv({0}): current=0x{1:X4} 要求=0x{2:X4} target=0x{3:X4} → 同値のため書き込みスキップ' `
            -f $kind, $current, $value, $target)
        return $true
    }
    Write-DebugLog ('    conv({0}): current=0x{1:X4} 要求=0x{2:X4} target=0x{3:X4}' -f $kind, $current, $value, $target)
    return $null -ne (Invoke-ImeControl $imeWnd $IMC_SETCONVERSIONMODE $target)
}

function Invoke-ImeRequest($req) {
    $cmd = [string]$req.cmd

    if ($cmd -eq 'ping') { return @{ ok = $true } }

    # ログ無効時に ConvertTo-Json / Get-Process を走らせないよう、引数の組み立てごと囲う。
    $logging = $null -ne $script:logPath
    if ($logging) { Write-DebugLog ('req  ' + ($req | ConvertTo-Json -Compress)) }

    $hwndIn = 0
    if ($null -ne $req.hwnd) { $hwndIn = [int64]$req.hwnd }
    $w = Resolve-ImeWnd $hwndIn

    $targetPid = [uint32]0
    if ($req.browser -or $req.pid) {
        [void][ImeNative]::GetWindowThreadProcessId($w.target, [ref]$targetPid)
        $process = if ($targetPid) { Get-Process -Id $targetPid -ErrorAction SilentlyContinue }
        if (!$process -or ($req.pid -and $targetPid -ne $req.pid) -or
            ($req.browser -and $process.ProcessName -ne $req.browser) -or
            ($cmd -eq 'set' -and !$req.restore -and $w.target -ne [ImeNative]::GetForegroundWindow())) {
            return @{ ok = $false; error = 'target window changed' }
        }
    }
    if ($req.inputLayout -and (Get-WindowLayout $w.target) -ne $req.inputLayout) {
        return @{ ok = $false; error = 'input language changed before applying IME mode' }
    }
    if ($w.ime -eq [IntPtr]::Zero) {
        Write-DebugLog '  IME ウィンドウを取得できず'
        return @{ ok = $false; error = 'no IME window for target' }
    }
    if ($logging) {
        # hwnd 0 はフォアグラウンドに解決される。ここが Edge でなければ、
        # 別アプリの IME を書き換えていることになる。
        Write-DebugLog ('  target hwnd=0x{0:X} ime=0x{1:X} (要求 hwnd={2}) → {3}' -f
            [int64]$w.target, [int64]$w.ime, $hwndIn, (Get-WindowLabel $w.target))
    }

    $curOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
    if ($null -eq $curOpen) { return @{ ok = $false; error = 'IMC_GETOPENSTATUS timed out' } }
    $curConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
    if ($null -eq $curConv) { return @{ ok = $false; error = 'IMC_GETCONVERSIONMODE timed out' } }

    if ($cmd -eq 'get') {
        return @{ ok = $true; hwnd = [int64]$w.target; open = $curOpen; conv = $curConv }
    }

    if ($cmd -ne 'set') { return @{ ok = $false; error = "unknown cmd: $cmd" } }

    $open = [int]$req.open

    # Resolve the requested conversion mode: a symbolic name from the extension
    # (apply), or a raw value when restoring a state we captured earlier.
    # どちらで来たかで書き方が変わるので取り違えないこと。
    $convValue = $null
    $convExact = $false
    if ($null -ne $req.conv) {
        $name = [string]$req.conv
        if (-not $CONV_BITS.ContainsKey($name)) {
            return @{ ok = $false; error = "unknown conv: $name" }
        }
        $convValue = [int]$CONV_BITS[$name]
    } elseif ($null -ne $req.convRaw) {
        $convValue = [int]$req.convRaw
        $convExact = !$req.held
    }

    $result = @{ ok = $false; hwnd = [int64]$w.target; pid = $targetPid;
        previous = $curOpen; previousConv = $curConv }
    if (!$req.restore -and $null -eq $script:lastChange) {
        $script:lastChange = @{
            hwnd = $w.target; pid = $targetPid; browser = $req.browser
            layout = $req.inputLayout; open = $curOpen; conv = $curConv
        }
    }

    $mask = if ($convExact) { -1 } else { $CONV_MASK }
    $needsConversion = $null -ne $convValue
    $writeConversion = $needsConversion -and (($curConv -band $mask) -ne ($convValue -band $mask) -or $open -ne $curOpen)
    $workingOpen = $curOpen
    if (($open -eq 1 -or $writeConversion) -and $workingOpen -ne 1) {
        if ($null -eq (Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS 1)) {
            $result.error = 'setting IME open timed out'
            return $result
        }
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            if ($attempt -gt 0) { Start-Sleep -Milliseconds 25 }
            $workingOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
            if ($workingOpen -eq 1) { break }
        }
        if ($workingOpen -ne 1) {
            $result.error = 'IME did not open'
            return $result
        }
    }
    if ($writeConversion) {
        $workingConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
        if ($null -eq $workingConv -or !(Set-ConversionBits $w.ime $workingConv $convValue $convExact)) {
            $result.error = 'setting IME conversion mode timed out'
            return $result
        }
    }
    if ($workingOpen -ne $open -and $null -eq (Invoke-ImeControl $w.ime $IMC_SETOPENSTATUS $open)) {
        $result.error = 'setting IME open status timed out'
        return $result
    }

    # An accepted window message is not proof that the IME applied the change.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 25 }
        $actualOpen = Invoke-ImeControl $w.ime $IMC_GETOPENSTATUS 0
        $actualConv = Invoke-ImeControl $w.ime $IMC_GETCONVERSIONMODE 0
        if ($actualOpen -eq $open -and $null -ne $actualConv -and
            (!$needsConversion -or ($actualConv -band $mask) -eq ($convValue -band $mask))) {
            if ($req.inputLayout -and (Get-WindowLayout $w.target) -ne $req.inputLayout) {
                $result.error = 'input language changed while applying IME mode'
                return $result
            }
            $result.ok = $true
            $result.expectedOpen = $open
            $result.expectedConv = $convValue
            $result.conversionMask = $mask
            if ($req.restore) { $script:lastChange = $null }
            return $result
        }
    }
    $result.error = 'IME did not apply the requested state'
    return $result
}

function Get-WindowLayout([IntPtr]$target) {
    $processId = [uint32]0
    $thread = [ImeNative]::GetWindowThreadProcessId($target, [ref]$processId)
    if (!$thread) { return [IntPtr]::Zero }
    return [ImeNative]::GetKeyboardLayout($thread)
}

function Test-JapaneseLayout([IntPtr]$layout) {
    return ($layout.ToInt64() -band 0xFFFF) -eq 0x0411 -and [ImeNative]::ImmIsIME($layout)
}

function Get-JapaneseLayout {
    $count = [ImeNative]::GetKeyboardLayoutList(0, $null)
    if ($count -gt 0) {
        $layouts = New-Object IntPtr[] $count
        $copied = [ImeNative]::GetKeyboardLayoutList($count, $layouts)
        for ($i = 0; $i -lt $copied; $i++) {
            if (Test-JapaneseLayout $layouts[$i]) { return $layouts[$i] }
        }
    }
    return [IntPtr]::Zero
}

function Set-WindowLayout([IntPtr]$target, [IntPtr]$layout) {
    if ((Get-WindowLayout $target) -eq $layout) { return $true }
    if (![ImeNative]::PostMessage($target, $WM_INPUTLANGCHANGEREQUEST, [IntPtr]::Zero, $layout)) {
        return $false
    }
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        Start-Sleep -Milliseconds 25
        if ((Get-WindowLayout $target) -eq $layout) { return $true }
    }
    return $false
}

function Get-BrowserWindow($req, [bool]$requireForeground) {
    $target = if ($req.hwnd) { [IntPtr][int64]$req.hwnd } else { [ImeNative]::GetForegroundWindow() }
    $processId = [uint32]0
    [void][ImeNative]::GetWindowThreadProcessId($target, [ref]$processId)
    $process = if ($processId) { Get-Process -Id $processId -ErrorAction SilentlyContinue }
    if (!$process -or $process.ProcessName -ne $req.browser -or
        ($req.pid -and $req.pid -ne $processId) -or
        ($requireForeground -and $target -ne [ImeNative]::GetForegroundWindow())) { return $null }
    return @{ hwnd = $target; pid = $processId }
}

function Restore-BrowserMode($target, [string]$browser) {
    $savedMode = $script:lastChange
    if (!$savedMode) { return @{ ok = $true } }
    if ($target.hwnd -ne $savedMode.hwnd -or $target.pid -ne $savedMode.pid) {
        $script:lastChange = $null
        return @{ ok = $false; error = 'target window changed' }
    }
    if ($savedMode.layout -ne (Get-WindowLayout $target.hwnd)) {
        $script:lastChange = $null
        return @{ ok = $true }
    }
    return (Invoke-ImeRequest @{
        cmd = 'set'; hwnd = [int64]$target.hwnd; pid = $target.pid; browser = $browser
        open = $savedMode.open; convRaw = $savedMode.conv; inputLayout = $savedMode.layout; restore = $true
    })
}

function Restore-BrowserLayout($req) {
    $savedLayout = $script:layoutChange
    $target = Get-BrowserWindow $req $false
    if (!$target -or $target.hwnd -ne $savedLayout.hwnd -or $target.pid -ne $savedLayout.pid) {
        $script:layoutChange = $null
        $script:lastChange = $null
        return @{ ok = $false; error = 'target window changed' }
    }

    # If the user picked a different input language, leave that choice in place.
    $active = Get-WindowLayout $target.hwnd
    if ($active -ne $savedLayout.applied) {
        $script:layoutChange = $null
        $script:lastChange = $null
        return @{ ok = $true }
    }

    $modeResult = Restore-BrowserMode $target $req.browser
    if (!(Set-WindowLayout $target.hwnd $savedLayout.original)) {
        return @{ ok = $false; error = 'original input language was not restored' }
    }
    $script:layoutChange = $null
    $script:lastChange = $null
    if (!$modeResult.ok) { $modeResult.restored = $true }
    return $modeResult
}

function Confirm-BrowserImeMode($apply, $result) {
    if (!$result.ok -or $apply.open -ne 1) { return $result }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        # The browser's text input context can change after the first successful read.
        Start-Sleep -Milliseconds 100
        if (!(Get-BrowserWindow $apply $true)) {
            $result.ok = $false
            $result.error = 'target window changed after applying IME mode'
            return $result
        }
        $actual = Invoke-ImeRequest @{
            cmd = 'get'; hwnd = $apply.hwnd; pid = $apply.pid; browser = $apply.browser
            inputLayout = $apply.inputLayout
        }
        if ($actual.ok -and $actual.open -eq $result.expectedOpen -and
            ($null -eq $result.expectedConv -or
                ($actual.conv -band $result.conversionMask) -eq ($result.expectedConv -band $result.conversionMask))) {
            return $result
        }
        if ($attempt -eq 0) {
            Write-DebugLog '  IME context changed after the first readback; applying the field mode again'
            $retry = Invoke-ImeRequest $apply
            if (!$retry.ok) {
                $result.ok = $false
                $result.error = $retry.error
                return $result
            }
        }
    }
    $result.ok = $false
    $result.error = 'IME did not retain the requested state'
    return $result
}

function Invoke-BrowserImeRequest($req) {
    if (!$req.browser -or $req.cmd -ne 'set') { return (Invoke-ImeRequest $req) }
    if ($req.restore) {
        if ($null -ne $script:layoutChange) { return (Restore-BrowserLayout $req) }
        if (!$script:lastChange) { return @{ ok = $true } }
        $target = Get-BrowserWindow $req $false
        if (!$target) {
            $script:lastChange = $null
            return @{ ok = $false; error = 'target window changed' }
        }
        return (Restore-BrowserMode $target $req.browser)
    }

    $target = Get-BrowserWindow $req $true
    if (!$target) { return @{ ok = $false; error = 'target window changed' } }
    $apply = @{
        cmd = 'set'; hwnd = [int64]$target.hwnd; pid = $target.pid; browser = $req.browser
        open = $req.open; conv = $req.conv; convRaw = $req.convRaw; held = $req.held
    }

    $current = Get-WindowLayout $target.hwnd
    if ($current -eq [IntPtr]::Zero) { return @{ ok = $false; error = 'cannot read active input language' } }
    $apply.inputLayout = $current
    if ($script:layoutChange -and $current -ne $script:layoutChange.applied) {
        # The user changed input language while the field was focused.
        $script:layoutChange = $null
        $script:lastChange = $null
    } elseif ($script:lastChange -and $current -ne $script:lastChange.layout) {
        $script:lastChange = $null
    }
    if (($req.open -ne 1 -and !$req.japanese) -or (Test-JapaneseLayout $current)) {
        $result = Invoke-ImeRequest $apply
        if ($req.open -eq 1 -and $result.previous -eq 0) {
            return (Confirm-BrowserImeMode $apply $result)
        }
        return $result
    }

    $japanese = Get-JapaneseLayout
    if ($japanese -eq [IntPtr]::Zero) {
        return @{ ok = $false; error = 'no installed Japanese IME layout found' }
    }

    # An inactive field may have changed the previous IME before entering this field.
    $previous = Restore-BrowserMode $target $req.browser
    if (!$previous.ok) { return $previous }

    if (!(Get-BrowserWindow $apply $true)) { return @{ ok = $false; error = 'target window changed' } }
    $script:layoutChange = @{
        hwnd = $target.hwnd; pid = $target.pid; browser = $req.browser
        original = $current; applied = $japanese
    }
    Write-DebugLog ('  input layout: 0x{0:X} -> 0x{1:X}' -f $current.ToInt64(), $japanese.ToInt64())
    if (!(Set-WindowLayout $target.hwnd $japanese)) {
        return @{ ok = $false; error = 'browser did not activate the Japanese IME layout';
            hwnd = [int64]$target.hwnd; pid = $target.pid; restorePending = $true }
    }

    # Re-resolve the IME window after the language change.
    $apply.inputLayout = $japanese
    $result = Confirm-BrowserImeMode $apply (Invoke-ImeRequest $apply)
    if (!$result.ok) {
        $result.hwnd = [int64]$target.hwnd
        $result.pid = $target.pid
        $result.restorePending = $true
    }
    return $result
}

try {
    while ($true) {
        $raw = Read-Message
        if ($null -eq $raw) { break }

        $id = $null
        try {
            $req = $raw | ConvertFrom-Json
            $id = $req.id
            $resp = Invoke-BrowserImeRequest $req
        } catch {
            $resp = @{ ok = $false; error = "$_" }
        }
        $resp['id'] = $id
        Write-Message ($resp | ConvertTo-Json -Compress)
    }
}
finally {
    # Port died (service worker evicted, extension disabled, browser closed).
    # Never strand the user with the IME in a state they did not choose.
    if ($null -ne $script:layoutChange) {
        $saved = $script:layoutChange
        Restore-BrowserLayout @{ hwnd = [int64]$saved.hwnd; pid = $saved.pid; browser = $saved.browser } | Out-Null
    } elseif ($script:lastChange.browser) {
        $saved = $script:lastChange
        Invoke-BrowserImeRequest @{ cmd = 'set'; hwnd = [int64]$saved.hwnd; pid = $saved.pid;
            browser = $saved.browser; restore = $true } | Out-Null
    } elseif ($null -ne $script:lastChange) {
        Invoke-ImeRequest @{ cmd = 'set'; hwnd = [int64]$script:lastChange.hwnd;
            pid = $script:lastChange.pid; open = $script:lastChange.open;
            convRaw = $script:lastChange.conv; restore = $true } | Out-Null
    }
}
