#requires -Version 5.1
# po0fw - po0 防火墙自动加白 (Windows)
# 用法: powershell -File po0fw.ps1 -Tokens "pgnfw_xxx,pgnfw_yyy@0"
param(
    [string]$Tokens = $env:PO0FW_TOKENS,
    [string]$ApiBase = $env:PO0FW_API,
    [switch]$Status
)

function Write-Po0fwLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[po0fw $ts] $Message"
}

function Read-Po0fwConfTokens {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $collected = New-Object System.Collections.Generic.List[string]
    foreach ($rawLine in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^(?:export\s+)?PO0FW_TOKENS\s*=\s*(.*)$') {
            $val = $Matches[1].Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            if ($val) { return $val.Trim() }
            continue
        }
        if ($line.StartsWith("pgnfw_")) {
            $collected.Add($line)
        }
    }
    return ($collected -join ",")
}

function Test-SameC24 {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    if ($A -eq $B) { return $true }
    if (-not $A.EndsWith("/24") -and -not $B.EndsWith("/24")) { return $false }
    $pa = ($A -replace '/24$', '').Split('.')
    $pb = ($B -replace '/24$', '').Split('.')
    return ($pa.Count -eq 4 -and $pb.Count -eq 4 -and $pa[0] -eq $pb[0] -and $pa[1] -eq $pb[1] -and $pa[2] -eq $pb[2])
}

function Invoke-Po0fwApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $statusCode = 0
        $bodyText = ""
        $netErr = $null

        try {
            $reqParams = @{
                Method = $Method
                Uri = $Uri
                TimeoutSec = 20
                UseBasicParsing = $true
            }
            $resp = Invoke-WebRequest @reqParams
            $statusCode = [int]$resp.StatusCode
            $bodyText = [string]$resp.Content
        } catch {
            $ex = $_.Exception
            if ($ex -and $ex.Response) {
                try {
                    $statusCode = [int]$ex.Response.StatusCode
                } catch {
                    $statusCode = 0
                }
                try {
                    $stream = $ex.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Close()
                    }
                } catch {}
            } else {
                $netErr = $ex.Message
                if (-not $netErr) { $netErr = [string]$_ }
            }
        }

        $parsed = $null
        if ($bodyText) {
            try {
                $parsed = ConvertFrom-Json -InputObject $bodyText -ErrorAction Stop
            } catch {
                $parsed = $null
            }
        }

        $retryable = $false
        if ($netErr) {
            $retryable = $true
        } elseif ($statusCode -ge 500 -or $statusCode -eq 429 -or $statusCode -eq 0) {
            $retryable = $true
        } elseif (($statusCode -lt 200 -or $statusCode -ge 300) -and $statusCode -ne 403 -and $null -eq $parsed) {
            $retryable = $true
        }

        if (-not $retryable) {
            return [PSCustomObject]@{
                StatusCode = $statusCode
                Body = $bodyText
                Data = $parsed
                NetError = $null
                RetriesExhausted = $false
            }
        }

        if ($attempt -ge $MaxAttempts) {
            $errMsg = if ($netErr) { "${netErr}（已重试 $MaxAttempts 次）" } else { $null }
            return [PSCustomObject]@{
                StatusCode = $statusCode
                Body = $bodyText
                Data = $parsed
                NetError = $errMsg
                RetriesExhausted = $true
            }
        }

        Start-Sleep -Seconds ($attempt * 2)
    }
}

if (-not $ApiBase) {
    $ApiBase = "https://124.221.69.228/api/firewall"
}
$ApiBase = $ApiBase.TrimEnd('/')

$confPath = Join-Path $env:ProgramData "po0fw\po0fw.conf"
if (-not $Tokens -and (Test-Path -LiteralPath $confPath)) {
    $Tokens = Read-Po0fwConfTokens -Path $confPath
}
if (-not $Tokens) {
    Write-Error "未配置 token。用 -Tokens 参数或写入 $confPath"
    exit 1
}

# 官方端点为 IP 证书（SAN=IP），强制启用 TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072

$rawEntries = $Tokens -split '[,，|;、\s]+' | Where-Object { $_ -ne "" }
if (-not $rawEntries -or $rawEntries.Count -eq 0) {
    Write-Error "未解析到有效 token。请检查 -Tokens 参数或 $confPath"
    exit 1
}

$fail = $false
$idx = 0
foreach ($rawEntry in $rawEntries) {
    $entry = $rawEntry.Trim()
    if (-not $entry) { continue }
    $idx++

    $slot = $null
    $tok = $entry
    $hasAt = $entry.Contains('@')
    if ($hasAt) {
        $parts = $entry.Split('@', 2)
        $tok = $parts[0]
        $slot = $parts[1]
    }
    $short = $tok.Substring(0, [Math]::Min(12, $tok.Length))

    if ($tok -notmatch '^pgnfw_[A-Za-z0-9_-]+$') {
        Write-Po0fwLog "#$idx $short… ❌ 无效 token 格式（应为 pgnfw_xxx）"
        $fail = $true
        continue
    }
    if ($hasAt) {
        if ($slot -notmatch '^\d+$') {
            Write-Po0fwLog "#$idx $short… ❌ 无效槽位号 '@$slot'（须为非负整数，如 @0）"
            $fail = $true
            continue
        }
        $slot = [string]([int]$slot)
    }

    if ($Status) {
        # 只读端点：GET <base>/<token>（不带 /add）。
        $r = Invoke-Po0fwApi -Method "GET" -Uri "$ApiBase/$tok"
    } else {
        $url = "$ApiBase/$tok/add"
        if ($null -ne $slot -and $slot -ne "") { $url += "?slot=$slot" }
        $r = Invoke-Po0fwApi -Method "POST" -Uri $url
    }

    $verb = if ($Status) { "查询失败" } else { "请求失败" }
    $retryNote = if ($r.RetriesExhausted) { "（已重试 3 次）" } else { "" }

    if ($r.NetError) {
        Write-Po0fwLog "#$idx $short… ❌ ${verb}: $($r.NetError)"
        $fail = $true
        continue
    }
    if (-not $Status -and $r.StatusCode -eq 403) {
        Write-Po0fwLog "#$idx $short… ❌ 槽位冲突：本机 IP 已在其它槽位，请先去控制台删除旧槽位"
        $fail = $true
        continue
    }
    if ($r.StatusCode -ge 400) {
        $errDetail = if ($r.Data -and $r.Data.message) {
            $r.Data.message
        } elseif ($r.Data -and $r.Data.error) {
            $r.Data.error
        } elseif ($r.Body -and $r.Body.Trim()) {
            $r.Body.Trim()
        } else {
            "无响应体"
        }
        Write-Po0fwLog "#$idx $short… ❌ ${verb} (HTTP $($r.StatusCode)): ${errDetail}${retryNote}"
        $fail = $true
        continue
    }
    if ($null -eq $r.Data -or $null -eq $r.Data.PSObject.Properties["whitelist"]) {
        $rawBody = if ($r.Body -and $r.Body.Trim()) { $r.Body.Trim() } else { "无响应体" }
        Write-Po0fwLog "#$idx $short… ❌ ${verb}: 响应异常 ${rawBody}${retryNote}"
        $fail = $true
        continue
    }

    $res = $r.Data
    $cur = [string]$res.currentIp
    $whitelist = @()
    if ($null -ne $res.whitelist) { $whitelist = @($res.whitelist) }
    $inList = $false
    $matchedSlot = $null
    foreach ($item in $whitelist) {
        $itemIp = if ($item -is [string]) { $item } else { [string]$item.ip }
        if (Test-SameC24 -A $itemIp -B $cur) {
            $inList = $true
            if (-not ($item -is [string]) -and $null -ne $item.slot) {
                $matchedSlot = [string]$item.slot
            }
            break
        }
    }

    if ($Status) {
        $limit = if ($res.limit) { $res.limit } else { 5 }
        $currentDisplay = if ($cur) { $cur } else { '未知' }
        Write-Po0fwLog "#$idx $short… 当前出口 $currentDisplay"
        if ($res.enabled -eq $false) {
            Write-Po0fwLog "#$idx $short… ⚠️  防火墙未启用"
            $fail = $true
            continue
        }
        $n = 0
        foreach ($e in $whitelist) {
            $eIp = if ($e -is [string]) { $e } else { [string]$e.ip }
            $eSlot = if ($e -is [string]) { $null } else { $e.slot }
            $mark = if (Test-SameC24 -A $eIp -B $cur) { '->' } else { '  ' }
            $kind = if ($null -eq $eSlot) {
                '(普通，参与 FIFO 淘汰)'
            } else {
                "(固定槽位 $eSlot，不淘汰)"
            }
            Write-Po0fwLog "    $mark $eIp  $kind"
            $n++
        }
        if ($n -eq 0) { Write-Po0fwLog "    (白名单为空)" }
        Write-Po0fwLog "    共 $n/$limit 个网段占用"
        if ($inList) {
            Write-Po0fwLog "#$idx $short… ✅ 当前出口已在白名单"
        } else {
            Write-Po0fwLog "#$idx $short… ⚠️  当前出口不在白名单（status 不会自动加白，需要时请跑不带 -Status 的命令）"
            $fail = $true
        }
        continue
    }

    if ($res.enabled -eq $false) {
        Write-Po0fwLog "#$idx $short… ⚠️  防火墙未启用"
        $fail = $true
        continue
    }

    if ($inList) {
        if ($null -ne $slot -and $slot -ne "" -and $matchedSlot -ne $slot) {
            $actual = if ($null -ne $matchedSlot) { $matchedSlot } else { "null" }
            Write-Po0fwLog "#$idx $short… ⚠️  出口 $cur 已在白名单，但固定槽位 @$slot 未生效 (实际=$actual)"
            $fail = $true
        } elseif ($null -ne $matchedSlot -and $matchedSlot -ne "") {
            Write-Po0fwLog "#$idx $short… ✅ 出口 $cur 已在白名单 (槽位 $matchedSlot)"
        } else {
            Write-Po0fwLog "#$idx $short… ✅ 出口 $cur 已在白名单"
        }
    } else {
        Write-Po0fwLog "#$idx $short… ❌ 加白未生效 (currentIp=$cur)"
        $fail = $true
    }
}
if ($fail) { exit 1 }
