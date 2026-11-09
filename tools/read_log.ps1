param([string]$Port = '', [string]$Log = (Join-Path $PSScriptRoot '..\logs\glove80-debug.log'), [double]$Minutes = 120)
# Reads the debug firmware's log from the Glove80's USB serial port and prefixes each line
# with the PC's clock. Without -Port it finds the keyboard's port itself and reopens it
# after a replug or reboot. Stops after -Minutes or when tools\read_log.stop appears.
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
$stop = Join-Path $PSScriptRoot 'read_log.stop'
Remove-Item $stop -ErrorAction SilentlyContinue
$end = (Get-Date).AddMinutes($Minutes)
function Out([string]$s) { $l = "$(Get-Date -Format HH:mm:ss.fff)  $s"; $l; Add-Content -Path $Log -Value $l -Encoding utf8 }
function Find-Port {
    if ($Port) { return $Port }
    $dev = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\VID_16C0&PID_27DB%'" |
        Where-Object { $_.Name -match '\((COM\d+)\)' } | Select-Object -First 1
    if ($dev -and $dev.Name -match '\((COM\d+)\)') { return $Matches[1] }
    return $null
}
$announced = $false
while ((Get-Date) -lt $end -and -not (Test-Path $stop)) {
    $name = Find-Port
    if (-not $name) {
        if (-not $announced) { Out 'waiting for the keyboard''s USB serial port'; $announced = $true }
        Start-Sleep -Milliseconds 500; continue
    }
    $sp = New-Object System.IO.Ports.SerialPort $name, 115200
    $sp.DtrEnable = $true; $sp.RtsEnable = $true; $sp.ReadTimeout = 500; $sp.NewLine = "`n"
    try { $sp.Open() } catch { Start-Sleep -Milliseconds 500; continue }
    Out "reading $name"; $announced = $false
    try {
        while ((Get-Date) -lt $end -and -not (Test-Path $stop)) {
            try { $line = $sp.ReadLine() } catch [System.TimeoutException] { continue }
            $line = ($line -replace '\x1b\[[0-9;]*m', '').TrimEnd("`r")
            if ($line) { Out $line }
        }
    } catch { Out "port closed: $($_.Exception.Message)" }
    finally { try { $sp.Close() } catch {} }
}
Out 'log reader stopped'
