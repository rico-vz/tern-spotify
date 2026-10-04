param([Parameter(Mandatory = $true)][string]$Data)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $Data 'state.txt'
$CmdDir = Join-Path $Data 'cmd'
$ArtDir = Join-Path $Data 'art'
$BinDir = Join-Path $Data 'bin'
$LogPath = Join-Path $Data 'helper.log'
$LeasePath = Join-Path $Data 'lease'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Clock = [Diagnostics.Stopwatch]::StartNew()

$script:lastLogged = @{}
function Write-Log([string]$Message) {
	$now = $Clock.ElapsedMilliseconds
	if ($script:lastLogged.ContainsKey($Message) -and $now - $script:lastLogged[$Message] -lt 60000) { return }
	$script:lastLogged[$Message] = $now
	try {
		if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 64KB) { [IO.File]::WriteAllText($LogPath, '', $Utf8) }
		[IO.File]::AppendAllText($LogPath, ('{0} windows {1}{2}' -f (Get-Date -Format o), $Message, "`n"), $Utf8)
	} catch {}
}

function Get-UnixSeconds { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

$mutex = New-Object System.Threading.Mutex($false, 'Local\tern-spotify-helper')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

foreach ($dir in @($Data, $CmdDir, $ArtDir, $BinDir)) { [void][IO.Directory]::CreateDirectory($dir) }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
		$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
		$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
	})[0]

function Wait-Op($Operation, [Type]$ResultType) {
	$task = $AsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
	if (-not $task.Wait(3000)) { throw 'Spotify did not answer within 3 seconds' }
	$task.Result
}

[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
[void][Windows.Media.MediaPlaybackAutoRepeatMode, Windows.Media, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$MediaProperties = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$StreamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]
$AsStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod(
	'AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))

$script:manager = $null
$script:problem = ''
try {
	$script:manager = Wait-Op ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
} catch {
	$script:problem = 'Windows media controls are unavailable on this system'
	Write-Log "session manager: $_"
}

function Get-SpotifySession {
	if (-not $script:manager) { return $null }
	foreach ($session in $script:manager.GetSessions()) {
		if ($session.SourceAppUserModelId -match 'spotify') { return $session }
	}
	$null
}

$script:volumeReady = $null
function Initialize-Volume {
	if ($null -ne $script:volumeReady) { return $script:volumeReady }
	$script:volumeReady = $false
	try {
		$source = [IO.File]::ReadAllText((Join-Path $Here 'AppVolume.cs'))
		$sha = [Security.Cryptography.SHA1]::Create()
		$hash = -join ($sha.ComputeHash($Utf8.GetBytes($source))[0..5] | ForEach-Object { $_.ToString('x2') })
		$dll = Join-Path $BinDir "TernSpotifyAudio-$hash.dll"
		if (-not (Test-Path $dll)) {
			$tmp = Join-Path $BinDir ("build-{0}-{1}.dll" -f $hash, $PID)
			Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library
			try { [IO.File]::Move($tmp, $dll) } catch { if (-not (Test-Path $dll)) { throw } }
		}
		Add-Type -Path $dll
		$script:volumeReady = $true
	} catch {
		Write-Log "app volume unavailable: $_"
	}
	$script:volumeReady
}

# Spotify drops its audio session a while after pausing, so $null is normal.
function Get-AppVolume {
	if (-not (Initialize-Volume)) { return $null }
	$value = [TernSpotify.AppVolume]::Get('Spotify')
	if ($null -eq $value) { return $null }
	@{ level = [int][Math]::Round($value[0] * 100); muted = ($value[1] -ge 0.5) }
}

$script:art = @{ key = ''; file = ''; track = ''; checks = @() }

function Update-Art($Properties) {
	if ($null -eq $Properties.Thumbnail) { return }
	$stream = Wait-Op ($Properties.Thumbnail.OpenReadAsync()) $StreamType
	$read = $AsStreamForRead.Invoke($null, @($stream))
	try {
		$buffer = New-Object IO.MemoryStream
		$read.CopyTo($buffer)
		$bytes = $buffer.ToArray()
	} finally {
		$read.Dispose()
	}
	if ($bytes.Length -lt 8) { return }
	$sha = [Security.Cryptography.SHA1]::Create()
	$key = -join ($sha.ComputeHash($bytes)[0..7] | ForEach-Object { $_.ToString('x2') })
	if ($key -eq $script:art.key) { return }
	$ext = if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { 'jpg' } else { 'png' }
	$file = Join-Path $ArtDir "$key.$ext"
	if (-not (Test-Path $file)) { [IO.File]::WriteAllBytes($file, $bytes) }
	$keep = @($file, $script:art.file)
	foreach ($old in [IO.Directory]::GetFiles($ArtDir)) {
		if ($keep -notcontains $old) { try { [IO.File]::Delete($old) } catch {} }
	}
	$script:art.key = $key
	$script:art.file = $file
}

$script:seq = 0
$script:posSeq = 0
$script:track = $null
$script:status = $null
$script:pos = $null
$script:posAt = 0
$script:ack = ''
$script:cmdError = ''
$script:volume = $null
$script:volumeAt = -100000
$script:runningAt = -100000
$script:running = $false
$script:lastBody = ''
$script:lastWriteAt = -100000
$script:forceRead = $false

function Format-Value($Value) {
	if ($null -eq $Value) { return '' }
	if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
	([string]$Value) -replace "[`r`n]+", ' '
}

function Get-Flag([bool]$Value) { if ($Value) { '1' } else { '0' } }

function Read-State {
	$now = $Clock.ElapsedMilliseconds
	$session = $null
	try { $session = Get-SpotifySession } catch { Write-Log "sessions: $_" }

	if ($null -eq $session) {
		if ($now - $script:runningAt -ge 2000) {
			$script:running = $null -ne (Get-Process -Name Spotify -ErrorAction SilentlyContinue)
			$script:runningAt = $now
		}
	} else {
		$script:running = $true
	}

	$s = [ordered]@{
		status = ''; title = ''; artist = ''; album = ''; track_id = ''
		duration_ms = ''; position_ms = ''; shuffle = ''; repeat = ''
		volume = ''; muted = ''
		can_play = '0'; can_next = '0'; can_prev = '0'; can_seek = '0'
		can_shuffle = '0'; can_repeat = '0'; can_volume = '0'; can_mute = '0'
		art_file = ''; art_url = ''; art_key = ''
	}

	if ($null -ne $session) {
		$info = $session.GetPlaybackInfo()
		$timeline = $session.GetTimelineProperties()
		$props = Wait-Op ($session.TryGetMediaPropertiesAsync()) $MediaProperties
		$controls = $info.Controls

		$status = switch ([string]$info.PlaybackStatus) {
			'Playing' { 'playing' }
			'Paused' { 'paused' }
			default { 'stopped' }
		}
		$track = '{0}|{1}|{2}' -f $props.Title, $props.Artist, $props.AlbumTitle

		$durationMs = [long]($timeline.EndTime - $timeline.StartTime).TotalMilliseconds
		$posMs = [long]$timeline.Position.TotalMilliseconds
		if ($status -eq 'playing') {
			# SMTC reports the position as of LastUpdatedTime move it to now.
			$posMs += [long]([DateTimeOffset]::Now - $timeline.LastUpdatedTime).TotalMilliseconds
		}
		if ($durationMs -gt 0) { $posMs = [Math]::Min($posMs, $durationMs) }
		$posMs = [Math]::Max($posMs, 0)

		$expected = $script:pos
		if ($null -ne $expected -and $script:status -eq 'playing') { $expected += $now - $script:posAt }
		if ($track -ne $script:track -or $status -ne $script:status -or $null -eq $expected -or
			[Math]::Abs($posMs - $expected) -gt 1500) {
			$script:posSeq++
		}
		if ($track -ne $script:track) {
			$script:art.track = $track
			# The cover art doesnt show until after a bit
			$script:art.checks = @($now, ($now + 1000), ($now + 3000))
		}
		$script:track = $track
		$script:status = $status
		$script:pos = $posMs
		$script:posAt = $now

		if ($script:art.checks.Count -gt 0 -and $now -ge $script:art.checks[0]) {
			$script:art.checks = @($script:art.checks | Select-Object -Skip 1)
			try { Update-Art $props } catch { Write-Log "cover: $_" }
		}

		if ($now - $script:volumeAt -ge 1000 -or $script:forceRead) {
			try { $script:volume = Get-AppVolume } catch { $script:volume = $null; Write-Log "volume: $_" }
			$script:volumeAt = $now
		}

		$s.status = $status
		$s.title = $props.Title
		$s.artist = $props.Artist
		$s.album = $props.AlbumTitle
		$s.track_id = $track
		if ($durationMs -gt 0) { $s.duration_ms = $durationMs }
		$s.position_ms = $posMs
		if ($null -ne $info.IsShuffleActive) { $s.shuffle = Get-Flag ([bool]$info.IsShuffleActive) }
		if ($null -ne $info.AutoRepeatMode) {
			$s.repeat = switch ([string]$info.AutoRepeatMode) { 'Track' { 'track' } 'List' { 'context' } default { 'off' } }
		}
		if ($null -ne $script:volume) {
			$s.volume = $script:volume.level
			$s.muted = Get-Flag $script:volume.muted
		}
		$s.can_play = Get-Flag ($controls.IsPlayPauseToggleEnabled -or $controls.IsPlayEnabled -or $controls.IsPauseEnabled)
		$s.can_next = Get-Flag $controls.IsNextEnabled
		$s.can_prev = Get-Flag $controls.IsPreviousEnabled
		$s.can_seek = Get-Flag ($controls.IsPlaybackPositionEnabled -and $durationMs -gt 0)
		$s.can_shuffle = Get-Flag $controls.IsShuffleEnabled
		$s.can_repeat = Get-Flag $controls.IsRepeatEnabled
		$s.can_volume = Get-Flag ($null -ne $script:volume)
		$s.can_mute = $s.can_volume
		$s.art_file = $script:art.file
		$s.art_key = $script:art.key
	} else {
		if ($null -ne $script:track) { $script:posSeq++ }
		$script:track = $null
		$script:status = $null
		$script:pos = $null
		$script:art = @{ key = ''; file = ''; track = ''; checks = @() }
	}
	$script:forceRead = $false
	$s
}

function Write-State($Fields) {
	$playing = $Fields.status -eq 'playing'
	$body = New-Object System.Text.StringBuilder
	[void]$body.Append("v=1`nbackend=windows`npid=$PID`n")
	[void]$body.Append('running=' + (Get-Flag $script:running) + "`n")
	foreach ($key in $Fields.Keys) {
		if ($key -ne 'position_ms') { [void]$body.Append($key + '=' + (Format-Value $Fields[$key]) + "`n") }
	}
	[void]$body.Append("pos_seq=$($script:posSeq)`nack=$(Format-Value $script:ack)`nerror=$(Format-Value $script:cmdError)`n")
	[void]$body.Append("problem=$(Format-Value $script:problem)`n")
	$text = $body.ToString()

	$now = $Clock.ElapsedMilliseconds
	$changed = $text -ne $script:lastBody
	$beatEvery = if ($playing) { 1000 } else { 2000 }
	if (-not $changed -and $now - $script:lastWriteAt -lt $beatEvery) { return }
	if ($changed) { $script:seq++ }

	$full = $text + "seq=$($script:seq)`nbeat=$(Get-UnixSeconds)`nposition_ms=$(Format-Value $Fields.position_ms)`n"
	$tmp = "$StatePath.tmp"
	[IO.File]::WriteAllText($tmp, $full, $Utf8)
	try {
		# [NullString]: PowerShell would pass $null to a string parameter as "".
		if (Test-Path $StatePath) { [IO.File]::Replace($tmp, $StatePath, [NullString]::Value) } else { [IO.File]::Move($tmp, $StatePath) }
	} catch {
		return
	}
	$script:lastBody = $text
	$script:lastWriteAt = $now
}

function Invoke-Try($Operation, [string]$What) {
	if (-not (Wait-Op $Operation ([bool]))) { throw "Spotify refused to $What" }
}

function Invoke-SpotifyCommand([string]$Name, [string]$Arg) {
	switch ($Name) {
		'open' { Start-Process 'spotify:'; return }
	}
	$session = Get-SpotifySession
	if ($null -eq $session) { throw "Spotify isn't running" }
	switch ($Name) {
		'toggle' { Invoke-Try $session.TryTogglePlayPauseAsync() 'play or pause' }
		'play' { Invoke-Try $session.TryPlayAsync() 'play' }
		'pause' { Invoke-Try $session.TryPauseAsync() 'pause' }
		'next' { Invoke-Try $session.TrySkipNextAsync() 'skip' }
		'previous' { Invoke-Try $session.TrySkipPreviousAsync() 'go back' }
		'seek' { Invoke-Try $session.TryChangePlaybackPositionAsync([long]$Arg * 10000) 'seek' }
		'shuffle' { Invoke-Try $session.TryChangeShuffleActiveAsync($Arg -eq '1') 'change shuffle' }
		'repeat' {
			$mode = switch ($Arg) {
				'track' { [Windows.Media.MediaPlaybackAutoRepeatMode]::Track }
				'context' { [Windows.Media.MediaPlaybackAutoRepeatMode]::List }
				default { [Windows.Media.MediaPlaybackAutoRepeatMode]::None }
			}
			Invoke-Try $session.TryChangeAutoRepeatModeAsync($mode) 'change repeat'
		}
		'volume' {
			if (-not (Initialize-Volume)) { throw "Spotify's volume can't be changed on this system" }
			$level = [Math]::Min(100, [Math]::Max(0, [int]$Arg)) / 100.0
			if ([TernSpotify.AppVolume]::Set('Spotify', $level, -1) -eq 0) { throw 'Spotify has no audio yet; start playback first' }
		}
		'mute' {
			if (-not (Initialize-Volume)) { throw "Spotify's volume can't be changed on this system" }
			$mute = if ($Arg -eq '1') { 1 } else { 0 }
			if ([TernSpotify.AppVolume]::Set('Spotify', -1, $mute) -eq 0) { throw 'Spotify has no audio yet; start playback first' }
		}
		default { throw "Unknown command $Name" }
	}
}

function Invoke-Queue {
	$ran = $false
	$files = [IO.Directory]::GetFiles($CmdDir, '*.cmd') | Sort-Object
	foreach ($file in $files) {
		$id = [IO.Path]::GetFileNameWithoutExtension($file)
		$work = "$file.work"
		try { [IO.File]::Move($file, $work) } catch { continue }
		$lines = @([IO.File]::ReadAllLines($work, $Utf8))
		$name = if ($lines.Count -ge 1) { $lines[0].Trim() } else { '' }
		$arg = if ($lines.Count -ge 2) { $lines[1].Trim() } else { '' }
		$written = 0
		[void][long]::TryParse(($id -split '-')[0], [ref]$written)
		if ($name -eq '' -and (Get-UnixSeconds) - $written -lt 3) {
			try { [IO.File]::Move($work, $file) } catch { [IO.File]::Delete($work) }
			continue
		}
		[IO.File]::Delete($work)
		if ($name -eq '' -or (Get-UnixSeconds) - $written -gt 15) { continue }
		$script:ack = $id
		$script:cmdError = ''
		try {
			Invoke-SpotifyCommand $name $arg
		} catch {
			$script:cmdError = $_.Exception.Message
			if ($script:cmdError -notmatch "Spotify isn't running|Spotify refused|no audio yet") { Write-Log "command $name failed: $_" }
		}
		$ran = $true
	}
	if ($ran) { $script:forceRead = $true }
	$ran
}

function Get-LeaseAge {
	try {
		$lease = 0
		if ([long]::TryParse([IO.File]::ReadAllText($LeasePath).Trim(), [ref]$lease)) { return (Get-UnixSeconds) - $lease }
	} catch {}
	[long]::MaxValue
}

$watcher = New-Object IO.FileSystemWatcher($CmdDir, '*.cmd')
$leaseCheckedAt = -100000
try {
	while ($true) {
		$now = $Clock.ElapsedMilliseconds
		if ($now - $leaseCheckedAt -ge 2000) {
			$leaseCheckedAt = $now
			if ($now -gt 45000 -and (Get-LeaseAge) -gt 45) { break }
		}
		try {
			[void](Invoke-Queue)
			Write-State (Read-State)
		} catch {
			Write-Log "tick: $_"
		}
		$change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::Created -bor [IO.WatcherChangeTypes]::Renamed, 300)
		if (-not $change.TimedOut) { Start-Sleep -Milliseconds 15 }
	}
} finally {
	$watcher.Dispose()
	$mutex.ReleaseMutex()
}
