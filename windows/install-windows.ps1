#requires -Version 5.1
# po0fw Windows one-click installer (run from an elevated PowerShell)
# Usage: powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Tokens "pgnfw_xxx"
param(
    [Parameter(Mandatory = $true)][string]$Tokens,
    [string]$RawBase = "https://raw.githubusercontent.com/w0ven/po0fw/main",
    [switch]$SkipInitialRun
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072

$dir = Join-Path $env:ProgramData "po0fw"
$mainScript = Join-Path $dir "po0fw.ps1"
$launcherScript = Join-Path $dir "po0fw-hidden.vbs"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Install-Po0fwFile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $local = Join-Path $PSScriptRoot $Name
    if (Test-Path $local) {
        Copy-Item -LiteralPath $local -Destination $Destination -Force
        return
    }

    $download = "$Destination.download"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/windows/$Name" -OutFile $download
        if (-not (Test-Path $download) -or (Get-Item $download).Length -eq 0) {
            throw "Downloaded file is empty: $Name"
        }
        Move-Item -LiteralPath $download -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-Utf8Bom {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom) { return }

    # Windows PowerShell 5.1 treats UTF-8 files without a BOM as the system ANSI
    # code page. Re-save downloaded/local PowerShell source with a BOM before it
    # is parsed, otherwise Chinese text and emoji can corrupt string boundaries.
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [IO.File]::WriteAllText($Path, $text, $utf8Bom)
}

function Assert-PowerShellSyntax {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokensFound = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokensFound,
        [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join "; "
        throw "Downloaded PowerShell script failed syntax validation: $details"
    }
}

Write-Host "[1/3] Installing files -> $dir"
Install-Po0fwFile -Name "po0fw.ps1" -Destination $mainScript
Install-Po0fwFile -Name "po0fw-hidden.vbs" -Destination $launcherScript
ConvertTo-Utf8Bom -Path $mainScript
Assert-PowerShellSyntax -Path $mainScript

Write-Host "[2/3] Writing configuration"
Set-Content -LiteralPath (Join-Path $dir "po0fw.conf") -Value $Tokens -Encoding UTF8

Write-Host "[3/3] Registering the silent scheduled task (10 minutes + network change)"
# Use splatting instead of PowerShell backtick continuations. A backtick stops
# working when copied text gains trailing whitespace, which made -Argument run
# as a separate command and left the scheduled-task Action null.
$actionParameters = @{
    Execute = "wscript.exe"
    Argument = ('"{0}" //B //Nologo' -f $launcherScript)
}
$action = New-ScheduledTaskAction @actionParameters

$triggerParameters = @{
    Once = $true
    At = Get-Date
    RepetitionInterval = New-TimeSpan -Minutes 10
}
$timerTrigger = New-ScheduledTaskTrigger @triggerParameters

$eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$networkTrigger = New-CimInstance -CimClass $eventClass -ClientOnly
$networkTrigger.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
$networkTrigger.Enabled = $true

$settingsParameters = @{
    AllowStartIfOnBatteries = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable = $true
    ExecutionTimeLimit = New-TimeSpan -Minutes 5
    Hidden = $true
}
$settings = New-ScheduledTaskSettingsSet @settingsParameters

$registrationParameters = @{
    TaskName = "po0fw"
    Action = $action
    Trigger = @($timerTrigger, $networkTrigger)
    Settings = $settings
    RunLevel = "Limited"
    Force = $true
}
Register-ScheduledTask @registrationParameters | Out-Null

if (-not $SkipInitialRun) {
    Write-Host "Installation completed. Running once now:"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript
} else {
    Write-Host "Installation completed. Initial run skipped."
}

Write-Host ""
Write-Host ('View whitelist status: powershell.exe -File "{0}" -Status' -f $mainScript)
