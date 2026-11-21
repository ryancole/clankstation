# Clankstation Windows base image setup (design: 5.5).
# Runs once, at the first logon after unattended setup, from the answer-file
# CD. Progress goes to C:\clank\setup.log and to COM1, which the host writes
# to vm/build/<name>/serial.log. The last line is CLANK-SETUP-DONE or
# CLANK-SETUP-FAILED, then the VM shuts down and the host finalizes the image.
#
# Tools are fetched at their latest release (design: principle 2).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content (Join-Path $here 'config.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force C:\clank, C:\clank\downloads | Out-Null

$serial = $null
try {
    $serial = New-Object System.IO.Ports.SerialPort COM1, 115200
    $serial.Open()
} catch { $serial = $null }

function Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'), $msg
    Add-Content C:\clank\setup.log $line
    if ($serial) { try { $serial.WriteLine($line) } catch {} }
}

function Download([string]$url, [string]$name) {
    $out = Join-Path C:\clank\downloads $name
    Log "download $url"
    for ($i = 1; $i -le 5; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return $out }
        catch { Log "  attempt $i failed: $($_.Exception.Message)"; Start-Sleep -Seconds (10 * $i) }
    }
    throw "could not download $url"
}

function LatestAsset([string]$repo, [string]$pattern) {
    $release = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
    if (-not $asset) { throw "no asset matching $pattern in $repo $($release.tag_name)" }
    Log "$repo $($release.tag_name): $($asset.name)"
    return $asset
}

function Run([string]$file, [string[]]$arguments, [int[]]$ok = @(0)) {
    Log "run $file $($arguments -join ' ')"
    $p = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($ok -notcontains $p.ExitCode) { throw "$file exited with $($p.ExitCode)" }
    Log "  exit $($p.ExitCode)"
}

try {
    Log "CLANK-SETUP-START $($config.name)"

    # --- drivers and guest agent ------------------------------------------------
    Run (Join-Path $here 'virtio-win-guest-tools.exe') @('/install', '/quiet', '/norestart') @(0, 3010)

    # --- network ----------------------------------------------------------------
    Log 'waiting for network'
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri 'https://api.github.com' -Method Head | Out-Null; break }
        catch { Start-Sleep -Seconds 5 }
    }

    # --- system settings ---------------------------------------------------------
    Log 'settings'
    powercfg /h off
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c   # High performance
    reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
    # Updates download but never restart a VM in the middle of a task.
    reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null
    reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v AUOptions /t REG_DWORD /d 2 /f | Out-Null
    # Trusted box (design: section 1): keep Defender out of build directories.
    Add-MpPreference -ExclusionPath 'C:\work', 'C:\Users\agent' -ErrorAction SilentlyContinue
    Set-LocalUser -Name agent -PasswordNeverExpires $true

    # --- OpenSSH server (how the host drives task VMs) --------------------------
    Log 'OpenSSH server'
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Set-Service sshd -StartupType Automatic
    Start-Service sshd

    # --- PowerShell 7 -------------------------------------------------------------
    $asset = LatestAsset 'PowerShell/PowerShell' '*-win-x64.zip'
    $zip = Download $asset.browser_download_url $asset.name
    $pwshDir = 'C:\Program Files\PowerShell\7'
    New-Item -ItemType Directory -Force $pwshDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $pwshDir -Force
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$pwshDir*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$pwshDir", 'Machine')
    }
    # SSH sessions get PowerShell 7.
    New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value "$pwshDir\pwsh.exe" -PropertyType String -Force | Out-Null

    # --- Git for Windows ------------------------------------------------------------
    $asset = LatestAsset 'git-for-windows/git' 'Git-*-64-bit.exe'
    $exe = Download $asset.browser_download_url $asset.name
    Run $exe @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES',
               '/COMPONENTS=gitlfs,assoc,assoc_sh', '/o:PathOption=Cmd', '/o:CRLFOption=CRLFAlways')

    # --- Visual Studio Build Tools (latest stable) ---------------------------------
    if ($config.buildTools) {
        $exe = Download 'https://aka.ms/vs/stable/vs_buildtools.exe' 'vs_buildtools.exe'
        $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache')
        foreach ($w in $config.buildTools) { $vsArgs += @('--add', $w) }
        $vsArgs += '--includeRecommended'
        Run $exe $vsArgs @(0, 3010)
        # The installer can exit 0 without installing anything; check for the compiler.
        $cl = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio' -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*\bin\Hostx64\x64\cl.exe' } | Select-Object -First 1
        if (-not $cl) { throw 'VS Build Tools finished but cl.exe is missing' }
        Log "MSVC: $($cl.FullName)"
    }

    # --- clean up --------------------------------------------------------------------
    # Best effort: nothing here may fail the build (Windows may already have
    # removed some of these, e.g. the autologon password after LogonCount).
    Log 'clean up'
    Remove-Item -Recurse -Force C:\clank\downloads -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
    # No more autologon in the base image; task VMs are driven over SSH.
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue

    Log 'CLANK-SETUP-DONE'
} catch {
    Log "CLANK-SETUP-FAILED $($_.Exception.Message)"
} finally {
    if ($serial) { $serial.Close() }
    shutdown /s /t 10 /f
}
