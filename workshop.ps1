<#
.SYNOPSIS
Start, pause, restart or stop the standalone Windows simulator workshop.
.EXAMPLE
.\workshop.ps1 start
.EXAMPLE
.\workshop.ps1 start -Controller example
.EXAMPLE
.\workshop.ps1 evaluate -Controller example -Laps 3
#>
param(
    [ValidateSet('start', 'pause', 'restart', 'evaluate', 'stop', 'status', 'logs', 'test', 'help')]
    [string]$Action = 'start',
    [ValidateSet('starter', 'example')][string]$Controller,
    [string]$SimulatorPath,
    [ValidateRange(1, 100)][int]$Laps = 3,
    [ValidateRange(10, 3600)][int]$Timeout = 300,
    [switch]$Follow,
    [switch]$Launcher,
    # Internal: run the launcher self-checks in this (fresh) process.
    [Parameter(DontShow)][switch]$SelfTestProcess
)

$ErrorActionPreference = 'Stop'
$runtimePath = Join-Path $PSScriptRoot '.runtime'
$sessionPath = Join-Path $runtimePath 'session.json'
$composeArgs = @('compose', '--project-name', 'autodrive-workshop',
    '--project-directory', $PSScriptRoot, '-f', (Join-Path $PSScriptRoot 'compose.yaml'))

function Invoke-WorkshopCompose {
    & docker @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed: $args" }
}

if ($Action -eq 'help') {
    Write-Host @'
Start Docker Desktop with Linux containers, then:
  .\workshop.ps1 start                      Open simulator with your controller.py
  .\workshop.ps1 start -Controller example   Run the supplied teaching example
  .\workshop.ps1 pause                      Stop the controller; leave simulator open
  .\workshop.ps1 restart -Controller starter Reload your code and resume
  .\workshop.ps1 evaluate                   Reset the car, drive 3 laps (or until a crash)
                                            and report lap times and speeds
  .\workshop.ps1 stop                       Stop workshop containers and its simulator
  .\workshop.ps1 status                     Inspect containers
  .\workshop.ps1 logs -Follow               Follow controller and bridge logs
  .\workshop.ps1 test                       Run launcher checks, then Python checks in a container
  .\workshop.ps1 test -Launcher             Run only the launcher checks (no Docker needed)
start also accepts -SimulatorPath 'C:\path\AutoDRIVE Simulator.exe'.
evaluate also accepts -Laps 3 and -Timeout 300 (seconds); results go to .runtime\results.
Save edits before restart. Without -Controller, the previous selection is reused.
'@
    return
}

function Invoke-LauncherSelfTest {
    # Runs in a fresh PowerShell process. All Docker, download and process calls are mocked.
    $fixtureRoot = Join-Path $PSScriptRoot ('.runtime\launcher-tests\' + [Guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $fixtureRoot 'folder with spaces'
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath, (Join-Path $PSScriptRoot 'compose.yaml') -Destination $fixture
    $fakeExe = Join-Path $fixture 'AutoDRIVE Simulator.exe'
    'fixture' | Set-Content -LiteralPath $fakeExe
    $launcher = Join-Path $fixture (Split-Path -Leaf $PSCommandPath)
    $global:workshopCalls = [Collections.Generic.List[object]]::new()
    $global:workshopPlayer = $null
    $global:workshopPortBusy = $false
    $global:workshopBridgeRunning = $false
    $global:workshopDockerFailure = $false
    $global:workshopDownloads = 0
    $global:workshopEvaluationExit = 0
    $global:workshopZip = ''

    function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
    function Expect-Failure([scriptblock]$Operation, [string]$Message) {
        $failed = $false
        try { & $Operation | Out-Null } catch { $failed = $true }
        Assert $failed $Message
    }
    function global:Write-Host { }
    function global:Start-Sleep { }
    function global:Get-NetTCPConnection { if ($global:workshopPortBusy) { return 'listener' } }
    function global:Get-Process { param($Name, $Id, $ErrorAction) return $global:workshopPlayer }
    function global:Start-Process {
        param($FilePath, $WorkingDirectory, $WindowStyle, $ArgumentList, [switch]$PassThru)
        if ($WindowStyle -ne 'Normal') { throw 'Simulator window should be visible' }
        $global:workshopPlayer = [pscustomobject]@{ Id = 7654; Path = $FilePath; Closed = $false }
        $global:workshopPlayer | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $this.Closed = $true }
        return $global:workshopPlayer
    }
    function global:docker {
        $global:workshopCalls.Add([pscustomobject]@{ Args = @($args); Controller = $env:WORKSHOP_CONTROLLER })
        $global:LASTEXITCODE = if ($global:workshopDockerFailure) { 1 } else { 0 }
        if ($global:workshopDockerFailure) { return }
        if ($args[0] -eq 'info') { return 'linux' }
        if ($args -contains 'run') { $global:LASTEXITCODE = $global:workshopEvaluationExit; return }
        if ($args -contains 'ps' -and $args -contains '-q' -and $global:workshopBridgeRunning) { return 'fixture-bridge' }
        if ($args -contains 'up') { $global:workshopBridgeRunning = $true }
        if ($args -contains 'down') { $global:workshopBridgeRunning = $false }
    }
    function global:curl.exe {
        $destination = $args[[Array]::IndexOf($args, '--output') + 1]
        Copy-Item -LiteralPath $global:workshopZip -Destination $destination
        $global:workshopDownloads++
        $global:LASTEXITCODE = 0
    }

    Push-Location -LiteralPath $PSScriptRoot
    try {
        & $launcher help | Out-Null
        Assert ($global:workshopCalls.Count -eq 0) 'Help contacted Docker'
        $global:workshopPortBusy = $true
        Expect-Failure { & $launcher start -SimulatorPath $fakeExe } 'Occupied port was accepted'
        $global:workshopPortBusy = $false
        Expect-Failure { & $launcher restart } 'Restart created a missing bridge'
        Expect-Failure { & $launcher evaluate } 'Evaluate ran without a bridge'

        $env:WORKSHOP_CONTROLLER = 'previous-value'
        & $launcher start -SimulatorPath $fakeExe -Controller example | Out-Null
        Assert ($env:WORKSHOP_CONTROLLER -eq 'previous-value') 'Environment was not restored'
        Assert ($global:workshopPlayer.Path -eq $fakeExe) 'Launch from another working directory failed'
        $sessionFile = Join-Path $fixture '.runtime\session.json'
        $saved = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
        Assert ($saved.controller -eq 'example') 'Controller selection was not saved'
        $global:workshopCalls.Clear()
        & $launcher restart | Out-Null
        $calls = @($global:workshopCalls | Where-Object { $_.Args -contains 'stop' -or $_.Args -contains 'up' })
        Assert ($calls[0].Args -contains 'stop') 'Reload did not stop old controller first'
        Assert ($calls[1].Args -contains '--no-deps') 'Reload could replace bridge'
        Assert ($calls[1].Controller -eq 'examples.follow_the_gap') 'Reload forgot selected example'
        $global:workshopCalls.Clear()
        & $launcher evaluate -Laps 2 | Out-Null
        $run = @($global:workshopCalls | Where-Object { $_.Args -contains 'run' })
        Assert ($run.Count -eq 1 -and $run[0].Args -contains 'evaluator' -and $run[0].Args -contains '--no-deps') 'Evaluate did not run the evaluator alone'
        $runArgs = $run[0].Args
        Assert ($runArgs[[Array]::IndexOf($runArgs, '--controller') + 1] -eq 'examples.follow_the_gap') 'Evaluate used the wrong controller'
        Assert ($runArgs[[Array]::IndexOf($runArgs, '--laps') + 1] -eq 2) 'Evaluate ignored -Laps'
        Assert ($global:workshopCalls[-1].Args -contains 'stop') 'Evaluate left the controller driving'
        $global:workshopEvaluationExit = 3
        & $launcher evaluate | Out-Null
        $global:workshopEvaluationExit = 2
        Expect-Failure { & $launcher evaluate } 'Evaluation setup failure was hidden'
        Assert ($global:workshopCalls[-1].Args -contains 'stop') 'Failed evaluation left the controller driving'
        $global:workshopEvaluationExit = 0
        & $launcher restart -Controller starter | Out-Null
        $saved = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
        Assert ($saved.controller -eq 'starter') 'Could not switch back to participant code'
        & $launcher pause | Out-Null
        Assert (-not $global:workshopPlayer.Closed) 'Pause closed the simulator'
        & $launcher stop | Out-Null
        Assert $global:workshopPlayer.Closed 'Stop left owned simulator open'
        $global:workshopPlayer = $null
        $global:workshopDockerFailure = $true
        Expect-Failure { & $launcher status } 'Docker errors were hidden'
        $global:workshopDockerFailure = $false
        [Console]::WriteLine('PASS: paths, port ownership, reload, evaluate, selection, pause, stop and Docker failures')

        # Exercise the real ZIP extraction using a local archive, without downloads.
        Remove-Item -LiteralPath $sessionFile
        $downloadSource = Join-Path $fixture 'download fixture\autodrive_simulator'
        New-Item -ItemType Directory -Path $downloadSource -Force | Out-Null
        'downloaded fixture' | Set-Content -LiteralPath (Join-Path $downloadSource 'AutoDRIVE Simulator.exe')
        $global:workshopZip = Join-Path $fixture 'download.zip'
        Compress-Archive -LiteralPath $downloadSource -DestinationPath $global:workshopZip
        & $launcher start | Out-Null
        Assert ($global:workshopDownloads -eq 1) 'Simulator was not downloaded'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fixture '.runtime\practice.zip'))) 'Successful download retained duplicate ZIP'
        & $launcher start | Out-Null
        Assert ($global:workshopDownloads -eq 1) 'Second start downloaded again'
        [Console]::WriteLine('PASS: download, extraction and cached runtime reuse')
    } finally {
        Pop-Location
        Remove-Item Env:WORKSHOP_CONTROLLER -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Action -eq 'test' -and $SelfTestProcess) { Invoke-LauncherSelfTest; return }
if ($Action -eq 'test') {
    # A fresh process keeps the mocks out of the caller's session.
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath test -SelfTestProcess
    if ($LASTEXITCODE -ne 0) { throw 'Launcher checks failed.' }
    if ($Launcher) { return }
}

$session =@{ controller = 'starter'; executable = ''; process_id = 0 }
if (Test-Path -LiteralPath $sessionPath) {
    $saved = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if ($saved.controller -notin @('starter', 'example')) { throw 'Invalid workshop session file.' }
    $session.controller = $saved.controller
    $session.executable = $saved.executable
    $session.process_id = $saved.process_id
}
if ($Controller) { $session.controller = $Controller }
$previousController = $env:WORKSHOP_CONTROLLER
$env:WORKSHOP_CONTROLLER = if ($session.controller -eq 'example') { 'examples.follow_the_gap' } else { 'controller' }

function Save-WorkshopSession {
    New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
    $session | ConvertTo-Json | Set-Content -LiteralPath $sessionPath -Encoding UTF8
}

function Get-WorkshopSimulator {
    if ($session.process_id -and $session.executable) {
        Get-Process -Id $session.process_id -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $session.executable }
    }
}

try {
    if ($Action -eq 'status') { Invoke-WorkshopCompose ps -a; return }
    if ($Action -eq 'logs') {
        $options = @('--tail', '100')
        if ($Follow) { $options += '--follow' }
        Invoke-WorkshopCompose logs @options controller bridge
        return
    }
    if ($Action -eq 'pause' -or $Action -eq 'stop') {
        # Keep the bridge alive long enough to transmit stopped commands or expire them.
        Invoke-WorkshopCompose stop controller
        Start-Sleep -Milliseconds 700
        if ($Action -eq 'stop') {
            $player = Get-WorkshopSimulator
            if ($player) { $player.CloseMainWindow() | Out-Null }
            Invoke-WorkshopCompose down
            $session.process_id = 0
            Save-WorkshopSession
        }
        Write-Host 'Workshop controller stopped.'
        return
    }
    $engine = & docker info --format '{{.OSType}}'
    if ($LASTEXITCODE -ne 0 -or $engine -ne 'linux') {
        throw 'Start Docker Desktop and select Linux containers, then retry.'
    }
    if ($Action -eq 'test') {
        Write-Host 'Running Python checks in a container...'
        & docker run --rm --network none --env PYTHONDONTWRITEBYTECODE=1 `
            --volume "${PSScriptRoot}:/workshop:ro" --workdir /workshop --entrypoint python3 `
            autodriveecosystem/autodrive_roboracer_api:2026-icra-practice `
            -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw 'Workshop tests failed.' }
        return
    }
    if ($Action -eq 'restart' -or $Action -eq 'evaluate') {
        $bridge = Invoke-WorkshopCompose ps --status running -q bridge
        if (-not $bridge) { throw 'Start the workshop first: .\workshop.ps1 start' }
        Invoke-WorkshopCompose stop controller
        Start-Sleep -Milliseconds 700
        Invoke-WorkshopCompose up -d --no-deps --force-recreate controller
        Save-WorkshopSession
    }
    if ($Action -eq 'evaluate') {
        New-Item -ItemType Directory -Path (Join-Path $runtimePath 'results') -Force | Out-Null
        try {
            & docker @composeArgs --profile evaluate run --rm --no-deps evaluator `
                python3 -m runtime.evaluate --controller $env:WORKSHOP_CONTROLLER `
                --laps $Laps --timeout $Timeout
            $evaluation = $LASTEXITCODE
        } finally {
            # Leave the car stopped after every run, including Ctrl+C.
            Invoke-WorkshopCompose stop controller
        }
        if ($evaluation -eq 3) { Write-Host 'Run ended before all laps were completed.' }
        elseif ($evaluation -ne 0) { throw 'Evaluation failed; check .\workshop.ps1 logs.' }
        return
    }
    if ($Action -eq 'restart') {
        Write-Host "Reloaded $($session.controller). Driving resumes when Autonomous is selected."
        return
    }

    $ownBridge = Invoke-WorkshopCompose ps --status running -q bridge
    $listener = Get-NetTCPConnection -LocalPort 4567 -State Listen -ErrorAction SilentlyContinue
    if ($listener -and -not $ownBridge) {
        throw 'Port 4567 is in use. Stop the main project or other simulator bridge first.'
    }
    $ownedPlayer = Get-WorkshopSimulator
    $otherPlayers = @(Get-Process -Name 'AutoDRIVE Simulator' -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_ -and (-not $ownedPlayer -or $_.Id -ne $ownedPlayer.Id) })
    if ($otherPlayers.Count) { throw 'Close the other AutoDRIVE simulator before starting the workshop.' }

    if ($SimulatorPath) {
        $executable = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SimulatorPath)
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Simulator executable not found: $executable"
        }
    } elseif ($session.executable) {
        $executable = $session.executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw 'Saved simulator path is missing. Supply -SimulatorPath or remove .runtime/session.json.'
        }
    } else {
        $executable = Join-Path $runtimePath 'practice\autodrive_simulator\AutoDRIVE Simulator.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
            $archive = Join-Path $runtimePath 'practice.zip'
            $url = 'https://github.com/AutoDRIVE-Ecosystem/AutoDRIVE-RoboRacer-Sim-Racing/releases/download/2026-icra/autodrive_simulator_practice_windows.zip'
            & curl.exe --fail --location --retry 3 --output $archive $url
            if ($LASTEXITCODE -ne 0) { throw 'Simulator download failed; check the network and retry.' }
            Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $runtimePath 'practice') -Force
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                throw 'Download did not contain the expected simulator. Archive kept for inspection.'
            }
            Remove-Item -LiteralPath $archive
        }
    }
    if ($ownedPlayer -and $ownedPlayer.Path -ne $executable) {
        throw 'Stop the workshop before selecting another simulator executable.'
    }
    Invoke-WorkshopCompose up -d bridge controller
    $session.executable = $executable
    if (-not $ownedPlayer) {
        New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
        $logPath = Join-Path $runtimePath 'simulator.log'
        $player = Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) `
            -WindowStyle Normal -ArgumentList '-screen-fullscreen 0 -screen-width 1280 -screen-height 720 -ip 127.0.0.1 -port 4567 -logFile', ('"' + $logPath + '"') -PassThru
        $session.process_id = $player.Id
    }
    Save-WorkshopSession
    Write-Host "Workshop running with $($session.controller). In Unity select Connection (127.0.0.1:4567) and Autonomous."
    Write-Host 'The starter stays stopped until you implement controller.py. Pause with .\workshop.ps1 pause.'
} finally {
    if ($null -eq $previousController) { Remove-Item Env:WORKSHOP_CONTROLLER -ErrorAction SilentlyContinue }
    else { $env:WORKSHOP_CONTROLLER = $previousController }
}
