param([string]$Dir = '', [int]$Version = 0, [switch]$Once)

$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = Join-Path $PSScriptRoot 'data' }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)
$statePath = Join-Path $Dir 'state.json'
$heartbeatPath = Join-Path $Dir 'heartbeat'
$commandPath = Join-Path $Dir 'cmd.txt'
$logPath = Join-Path $Dir 'bridge.log'

function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Log([string]$message) {
    try {
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 65536) {
            Remove-Item -LiteralPath $logPath -Force
        }
        $line = (Get-Date).ToString('HH:mm:ss') + ' [' + $PID + '] ' + $message + "`r`n"
        [IO.File]::AppendAllText($logPath, $line, $utf8)
    } catch {}
}

trap {
    Log ('fatal: ' + $_.Exception.Message)
    exit 1
}

$createdNew = $false
$mutexName = 'Local\nl_dynamic_island_bridge_v' + $Version
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Log 'another bridge is already running, exit'
    exit 0
}
Log ('start: bridge v' + $Version + ', PowerShell ' + $PSVersionTable.PSVersion + ', Windows ' + [Environment]::OSVersion.Version + ', dir ' + $Dir)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream]))
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRT($operation, $type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation))
    if (-not $task.Wait(4000)) { throw 'Windows media request timed out' }
    return $task.Result
}
Log 'windows media api loaded'

$audioOk = $true
try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr p);
    int UnregisterControlChangeNotify(IntPtr p);
    int GetChannelCount(out uint c);
    int SetMasterVolumeLevel(float level, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int GetMasterVolumeLevel(out float level);
    int GetMasterVolumeLevelScalar(out float level);
    int SetChannelVolumeLevel(uint ch, float level, ref Guid ctx);
    int SetChannelVolumeLevelScalar(uint ch, float level, ref Guid ctx);
    int GetChannelVolumeLevel(uint ch, out float level);
    int GetChannelVolumeLevelScalar(uint ch, out float level);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlMMDevice {
    int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int flow, int role, out INlMMDevice device);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class NlMMDeviceEnumerator { }

[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlAudioSessionManager2 {
    int GetAudioSessionControl(IntPtr guid, int flags, out IntPtr control);
    int GetSimpleAudioVolume(IntPtr guid, int flags, out IntPtr volume);
    int GetSessionEnumerator(out INlAudioSessionEnumerator enumerator);
}

[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlAudioSessionEnumerator {
    int GetCount(out int count);
    int GetSession(int index, out INlAudioSessionControl2 session);
}

[Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlAudioSessionControl2 {
    int GetState(out int state);
    int GetDisplayName(out IntPtr name);
    int SetDisplayName(IntPtr name, ref Guid ctx);
    int GetIconPath(out IntPtr path);
    int SetIconPath(IntPtr path, ref Guid ctx);
    int GetGroupingParam(out Guid param);
    int SetGroupingParam(ref Guid param, ref Guid ctx);
    int RegisterAudioSessionNotification(IntPtr client);
    int UnregisterAudioSessionNotification(IntPtr client);
    int GetSessionIdentifier(out IntPtr id);
    int GetSessionInstanceIdentifier(out IntPtr id);
    int GetProcessId(out uint pid);
}

[Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface INlSimpleAudioVolume {
    int SetMasterVolume(float level, ref Guid ctx);
    int GetMasterVolume(out float level);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

public static class NlAudio {
    public static string LastMatch = "";

    static INlMMDevice Device() {
        var enumerator = (INlMMDeviceEnumerator)new NlMMDeviceEnumerator();
        INlMMDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
        return device;
    }

    static string ProcessName(uint pid) {
        if (pid == 0) return "";
        try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return ""; }
    }

    static readonly string[] Ignored = { "svchost", "audiodg", "explorer", "System", "Idle", "dwm", "csrss", "RuntimeBroker", "ShellExperienceHost", "SearchHost", "StartMenuExperienceHost", "cs2" };

    static bool Matches(string hint, string name) {
        if (string.IsNullOrEmpty(hint) || string.IsNullOrEmpty(name)) return false;
        foreach (var bad in Ignored) if (string.Equals(bad, name, StringComparison.OrdinalIgnoreCase)) return false;
        if (string.Equals(hint, name + ".exe", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(hint, name, StringComparison.OrdinalIgnoreCase)) return true;
        return name.Length >= 4 && hint.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    static System.Collections.Generic.List<INlSimpleAudioVolume> Find(string hint) {
        var found = new System.Collections.Generic.List<INlSimpleAudioVolume>();
        Guid iid = typeof(INlAudioSessionManager2).GUID;
        object o;
        Marshal.ThrowExceptionForHR(Device().Activate(ref iid, 23, IntPtr.Zero, out o));
        var manager = (INlAudioSessionManager2)o;
        INlAudioSessionEnumerator sessions;
        Marshal.ThrowExceptionForHR(manager.GetSessionEnumerator(out sessions));
        int count;
        Marshal.ThrowExceptionForHR(sessions.GetCount(out count));
        string match = "";
        for (int i = 0; i < count; i++) {
            INlAudioSessionControl2 session;
            if (sessions.GetSession(i, out session) != 0 || session == null) continue;
            int state;
            if (session.GetState(out state) == 0 && state == 2) continue;
            uint pid;
            if (session.GetProcessId(out pid) != 0) continue;
            string name = ProcessName(pid);
            if (!Matches(hint, name)) continue;
            found.Add((INlSimpleAudioVolume)session);
            match = name + " (pid " + pid + ")";
        }
        LastMatch = match;
        return found;
    }

    public static float GetAppVolume(string hint) {
        var list = Find(hint);
        if (list.Count == 0) return -1f;
        float v;
        Marshal.ThrowExceptionForHR(list[0].GetMasterVolume(out v));
        return v;
    }

    public static bool GetAppMute(string hint) {
        var list = Find(hint);
        if (list.Count == 0) return false;
        bool m;
        Marshal.ThrowExceptionForHR(list[0].GetMute(out m));
        return m;
    }

    public static int SetAppVolume(string hint, float v) {
        var list = Find(hint);
        Guid g = Guid.Empty;
        foreach (var s in list) s.SetMasterVolume(Math.Max(0f, Math.Min(1f, v)), ref g);
        return list.Count;
    }

    public static int ToggleAppMute(string hint) {
        var list = Find(hint);
        if (list.Count == 0) return 0;
        bool m;
        list[0].GetMute(out m);
        Guid g = Guid.Empty;
        foreach (var s in list) s.SetMute(!m, ref g);
        return list.Count;
    }
}
'@
    Log 'audio session api loaded'
} catch {
    $audioOk = $false
    Log ('volume api unavailable: ' + $_.Exception.Message)
}

$manager = Wait-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
Log 'media session manager ready'
$lastSessions = $null
$lastError = ''
$lastAudio = ''
$quit = $false

function Log-Sessions {
    $all = @($manager.GetSessions())
    $summary = if ($all.Count -eq 0) { 'none' } else {
        ($all | ForEach-Object { [string]$_.SourceAppUserModelId + ' (' + $_.GetPlaybackInfo().PlaybackStatus + ')' }) -join ', '
    }
    if ($summary -ne $script:lastSessions) {
        $script:lastSessions = $summary
        Log ('windows media sessions: ' + $summary)
    }
}

function Get-Session {
    $session = $manager.GetCurrentSession()
    if (-not $session -or $session.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') {
        foreach ($candidate in @($manager.GetSessions())) {
            if ($candidate.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { return $candidate }
        }
    }
    return $session
}

$Clock = @{ key = ''; pos = 0.0; at = [int64]0; playing = $false }
$Cover = @{ key = ''; id = 0; tries = 0; next = [int64]0 }
$lastCommand = ''

function Update-Clock($track, $key) {
    $now = NowMs
    [double]$reported = $track.position
    if ($track.playing -and $track.timeline_updated -gt 0 -and $track.timeline_updated -le $now) {
        $reported += ($now - $track.timeline_updated) / 1000.0 * $track.rate
    }
    [double]$estimate = $Clock.pos
    if ($Clock.playing) { $estimate += ($now - $Clock.at) / 1000.0 * $track.rate }
    if ($Clock.key -ne $key -or $Clock.playing -ne [bool]$track.playing -or [Math]::Abs($reported - $estimate) -gt 1.5) {
        $Clock.key = $key
        $Clock.pos = $reported
        $Clock.at = $now
        $Clock.playing = [bool]$track.playing
    }
}

function Clock-Position($rate) {
    [double]$p = $Clock.pos
    if ($Clock.playing) { $p += ((NowMs) - $Clock.at) / 1000.0 * $rate }
    return [Math]::Max(0.0, $p)
}

function Save-Cover($session, $props, $key) {
    if ($Cover.key -eq $key -and ($Cover.tries -ge 6 -or (NowMs) -lt $Cover.next)) { return }
    if ($Cover.key -ne $key) { $Cover.key = $key; $Cover.tries = 0 }
    $Cover.tries++
    $Cover.next = (NowMs) + 1500
    if (-not $props.Thumbnail) { return }
    $stream = Wait-WinRT ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    $net = $asStream.Invoke($null, @($stream))
    $memory = New-Object System.IO.MemoryStream
    $net.CopyTo($memory)
    $net.Dispose()
    $bytes = $memory.ToArray()
    if ($bytes.Length -lt 64 -or $bytes.Length -gt 4194304) { return }
    $id = $Cover.id + 1
    $temp = Join-Path $Dir ('cover_' + $id + '.tmp')
    [IO.File]::WriteAllBytes($temp, $bytes)
    Move-Item -LiteralPath $temp -Destination (Join-Path $Dir ('cover_' + $id + '.img')) -Force
    $old = Join-Path $Dir ('cover_' + $Cover.id + '.img')
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    $Cover.id = $id
    $Cover.tries = 6
    Log ('cover saved: cover_' + $id + '.img, ' + $bytes.Length + ' bytes')
}

$lastTrack = ''

function Read-State {
    $now = NowMs
    $state = @{ timestamp = $now; version = $Version; status = 'idle'; title = ''; playing = $false; volume = -1.0; muted = $false; cover = $Cover.id }
    Log-Sessions
    $session = Get-Session
    if (-not $session) { return $state }
    $aumid = [string]$session.SourceAppUserModelId
    if ($audioOk) {
        try {
            $state.volume = [double][NlAudio]::GetAppVolume($aumid)
            if ($state.volume -ge 0) { $state.muted = [bool][NlAudio]::GetAppMute($aumid) }
            $match = if ($state.volume -ge 0) { 'player audio session: ' + [NlAudio]::LastMatch } else { 'audio session for ' + $aumid + ' not found' }
            if ($match -ne $script:lastAudio) {
                $script:lastAudio = $match
                Log $match
            }
        } catch {
            if ($_.Exception.Message -ne $script:lastAudio) {
                $script:lastAudio = $_.Exception.Message
                Log ('audio session read failed: ' + $_.Exception.Message)
            }
        }
    }
    $props = Wait-WinRT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $timeline = $session.GetTimelineProperties()
    $info = $session.GetPlaybackInfo()
    [double]$rate = 1.0
    if ($null -ne $info.PlaybackRate) { $rate = [double]$info.PlaybackRate }
    $track = @{
        title = [string]$props.Title
        artist = [string]$props.Artist
        album = [string]$props.AlbumTitle
        playing = ($info.PlaybackStatus.ToString() -eq 'Playing')
        position = [double]$timeline.Position.TotalSeconds
        duration = [double]$timeline.EndTime.TotalSeconds
        timeline_updated = ([DateTimeOffset]$timeline.LastUpdatedTime).ToUnixTimeMilliseconds()
        rate = $rate
    }
    if (-not $track.title) {
        if ($script:lastTrack -ne 'empty') {
            $script:lastTrack = 'empty'
            Log ('session ' + $session.SourceAppUserModelId + ' has no title')
        }
        return $state
    }
    $key = @([string]$session.SourceAppUserModelId, $track.title, $track.artist, [Math]::Round($track.duration)) -join "`n"
    if ($key -ne $script:lastTrack) {
        $script:lastTrack = $key
        Log ('track: ' + $session.SourceAppUserModelId + ' | ' + $track.title + ' - ' + $track.artist + ' | ' + [Math]::Round($track.duration) + ' s | ' + $info.PlaybackStatus)
    }
    Update-Clock $track $key
    try { Save-Cover $session $props $key } catch { Log ('cover failed: ' + $_.Exception.Message) }
    [double]$position = Clock-Position $rate
    if ($track.duration -gt 0) { $position = [Math]::Min($track.duration, $position) }
    $state.status = 'ready'
    $state.title = $track.title
    $state.artist = $track.artist
    $state.album = $track.album
    $state.playing = $track.playing
    $state.position = $position
    $state.duration = $track.duration
    $state.rate = $rate
    $state.app = [string]$session.SourceAppUserModelId
    $state.cover = if ($Cover.key -eq $key) { $Cover.id } else { 0 }
    return $state
}

function Run-Command($text) {
    $parts = $text.Split('|', 2)
    if ($parts.Count -lt 2) { return }
    $command = $parts[1].Trim()
    Log ('command: ' + $command)
    if ($command -eq 'quit') {
        $script:quit = $true
        return
    }
    $session = Get-Session
    switch -Regex ($command) {
        '^toggle$' { if ($session) { Log ('toggle -> ' + (Wait-WinRT ($session.TryTogglePlayPauseAsync()) ([bool]))) } else { Log 'toggle: no media session' } }
        '^next$' { if ($session) { Log ('next -> ' + (Wait-WinRT ($session.TrySkipNextAsync()) ([bool]))) } else { Log 'next: no media session' } }
        '^prev$' { if ($session) { Log ('prev -> ' + (Wait-WinRT ($session.TrySkipPreviousAsync()) ([bool]))) } else { Log 'prev: no media session' } }
        '^seek:([0-9.]+)$' {
            if ($session) {
                [int64]$ticks = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * 10000000
                Log ('seek ' + $Matches[1] + ' s -> ' + (Wait-WinRT ($session.TryChangePlaybackPositionAsync($ticks)) ([bool])))
            } else { Log 'seek: no media session' }
        }
        '^mute$' { if ($session) { $null = [NlAudio]::ToggleAppMute([string]$session.SourceAppUserModelId) } }
        '^volume:([0-9.]+)$' { if ($session) { $null = [NlAudio]::SetAppVolume([string]$session.SourceAppUserModelId, [float]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)) } }
    }
}

function Write-State($state) {
    $json = $state | ConvertTo-Json -Depth 4 -Compress
    $temp = $statePath + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temp, $json, $utf8)
    if (Test-Path -LiteralPath $statePath) { [IO.File]::Replace($temp, $statePath, [NullString]::Value) }
    else { [IO.File]::Move($temp, $statePath) }
}

[int64]$started = NowMs
[int64]$nextMedia = 0
$state = $null
if (Test-Path -LiteralPath $commandPath) {
    try { $lastCommand = [IO.File]::ReadAllText($commandPath, $utf8).Trim() } catch {}
}
try {
    while ($true) {
        if (Test-Path -LiteralPath $commandPath) {
            try {
                $text = [IO.File]::ReadAllText($commandPath, $utf8).Trim()
                if ($text -and $text -ne $lastCommand) {
                    $lastCommand = $text
                    Run-Command $text
                    $nextMedia = 0
                }
            } catch { Log ('command failed: ' + $_.Exception.Message) }
        }
        [int64]$now = NowMs
        if ($now -ge $nextMedia) {
            $nextMedia = $now + 300
            try {
                $state = Read-State
                $lastError = ''
            } catch {
                if ($_.Exception.Message -ne $lastError) {
                    $lastError = $_.Exception.Message
                    Log ('read failed: ' + $lastError)
                }
            }
        }
        if ($state) {
            if ($state.status -eq 'ready') {
                $state.position = [double]$state.position
                if ($state.playing) {
                    $state.position = Clock-Position ([double]$state.rate)
                    if ($state.duration -gt 0) { $state.position = [Math]::Min([double]$state.duration, [double]$state.position) }
                }
            }
            $state.timestamp = NowMs
            try { Write-State $state } catch {
                if ($_.Exception.Message -ne $lastError) {
                    $lastError = $_.Exception.Message
                    Log ('state write failed: ' + $lastError)
                }
            }
        }
        if ($Once) { break }
        if ($script:quit) {
            Log 'quit requested by the script, exit'
            break
        }
        [int64]$heartbeat = 0
        try { [int64]$heartbeat = [int64]([IO.File]::ReadAllText($heartbeatPath).Trim()) } catch {}
        if ((NowMs) - [Math]::Max($heartbeat, $started) -gt 45000) {
            Log 'no heartbeat from the script for 45 s, exit'
            break
        }
        Start-Sleep -Milliseconds 150
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
