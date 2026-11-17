$ErrorActionPreference = 'Stop'
Write-Host "PowerShell: $($PSVersionTable.PSVersion)  Windows: $([Environment]::OSVersion.Version)"
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
} catch {
    Write-Host "FAIL: Windows media API is not available: $($_.Exception.Message)"
    Write-Host "Windows N/KN editions need the Media Feature Pack."
    exit 1
}
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
function Wait-WinRT($operation, $type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation))
    if (-not $task.Wait(4000)) { throw 'timeout' }
    return $task.Result
}
$manager = Wait-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$sessions = @($manager.GetSessions())
Write-Host "Media sessions: $($sessions.Count)"
foreach ($s in $sessions) {
    $p = Wait-WinRT ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    Write-Host ("  app={0} | status={1} | title={2} | artist={3}" -f $s.SourceAppUserModelId, $s.GetPlaybackInfo().PlaybackStatus, $p.Title, $p.Artist)
}
if ($sessions.Count -eq 0) { Write-Host "No player publishes its track to Windows. The island cannot see it." }
