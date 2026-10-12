#!/usr/bin/env bash
# Builds this tree and deploys it as the system OpenSSH, replacing the
# Windows optional feature (OpenSSH.Client / OpenSSH.Server) if present.
#
# Run from an elevated msys/Git bash, on the Windows console or RDP,
# not over ssh: the running sshd gets stopped and its binaries replaced.
#
# Usage: scripts/deploy.sh [--no-build] [--debug] [--arch x64|arm64] [--prefix <windows dir>]
#
# Build prerequisites: Visual Studio 2022 (not 2026) with the "Desktop development
# with C++" workload and the Spectre-mitigated libs. LibreSSL & co. come from
# a vcpkg clone next to this repo (or $VCPKG_ROOT), cloned on first run.

set -euo pipefail

build=1
config=Release
arch=x64
prefix='C:\Program Files\OpenSSH'

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) build=0 ;;
        --debug) config=Debug ;;
        --arch) arch="$2"; shift ;;
        --prefix) prefix="$2"; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
repo_win="$(cygpath -w "$repo")"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Runs the PowerShell script read from stdin; extra arguments land in $args.
run_ps() {
    local f rc=0
    f="$(mktemp --suffix=.ps1)"
    { echo '$ErrorActionPreference = "Stop"'; cat; } > "$f"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$f")" "$@" || rc=$?
    rm -f "$f"
    return $rc
}

command -v cygpath >/dev/null || die "run this from msys/Git bash on Windows"
net session >/dev/null 2>&1 || die "must run elevated (Run as administrator)"
[ -z "${SSH_CONNECTION:-}" ] || die "running over ssh; sshd will be stopped, use the console or RDP"

if [ "$build" = 1 ]; then
    # Same layout as upstream's .github/tools/Install-VcpkgDependencies.ps1:
    # a vcpkg clone next to the repo, or $VCPKG_ROOT
    vcpkg_root="$(dirname "$repo")/vcpkg"
    [ -n "${VCPKG_ROOT:-}" ] && vcpkg_root="$(cygpath -u "$VCPKG_ROOT")"
    if [ ! -d "$vcpkg_root" ]; then
        step "Cloning vcpkg into $vcpkg_root"
        git clone https://github.com/microsoft/vcpkg.git "$vcpkg_root"
    fi

    step "Installing dependencies with vcpkg"
    # The build helper only recognizes VS 2017-2022 and the projects pin the
    # v143 toolset, so VS 2026 alone won't do; VS 2022 can sit next to it.
    # Install-VcpkgDependencies.ps1 itself isn't used: it doesn't parse under
    # Windows PowerShell 5.1 (UTF-8 without BOM) and doesn't set an exit code.
    run_ps "$repo_win" "$arch" "$(cygpath -w "$vcpkg_root")" <<'PS'
$repo, $arch, $vcpkgRoot = $args
$vc = @{ x64 = 'x86.x64'; x86 = 'x86.x64'; arm64 = 'ARM64'; arm = 'ARM' }[$arch]
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = $null
if (Test-Path $vswhere) {
    $vs = & $vswhere -products * -version '[17.0,18.0)' -property installationPath -requires `
        "Microsoft.VisualStudio.Component.VC.Tools.$vc" "Microsoft.VisualStudio.Component.VC.Runtimes.$vc.Spectre" |
        Select-Object -First 1
}
if (-not $vs) {
    Write-Host "Visual Studio 2022 with C++ tools and Spectre-mitigated libs not found (VS 2026 is not supported by the build). Install the Build Tools with:"
    Write-Host "  winget install Microsoft.VisualStudio.2022.BuildTools --override `"--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Runtimes.$vc.Spectre --includeRecommended`""
    Write-Host "or add those components to an existing VS 2022 with the Visual Studio Installer."
    exit 1
}
# Otherwise vcpkg compiles the ports with the newest VS, i.e. 2026
$env:VCPKG_VISUAL_STUDIO_PATH = $vs

$vcpkg = Join-Path $vcpkgRoot 'vcpkg.exe'
if (-not (Test-Path $vcpkg)) {
    & (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
    if ($LASTEXITCODE -ne 0) { throw "bootstrap-vcpkg.bat failed" }
}

# The projects read vcpkg_installed\<triplet>\<triplet>\, the layout MSBuild's
# vcpkg integration produces, hence the explicit install root
$triplet = "$arch-custom"
Push-Location "$repo\contrib\win32\openssh"
try {
    & $vcpkg install --triplet $triplet --x-install-root="vcpkg_installed\$triplet" `
        --overlay-triplets=vcpkg_triplets --overlay-ports=vcpkg_overlay_ports
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed" }
    if (-not (Test-Path "vcpkg_installed\$triplet\$triplet\include\openssl\opensslv.h")) {
        throw "vcpkg install finished but LibreSSL headers are not in vcpkg_installed\$triplet\$triplet\include"
    }
}
finally { Pop-Location }
PS

    step "Building $config/$arch"
    # The build rewrites paths.targets with the local SDK version; put it back if it was clean
    targets=contrib/win32/openssh/paths.targets
    targets_clean=0
    git -C "$repo" diff --quiet -- "$targets" && targets_clean=1
    run_ps "$repo_win" "$config" "$arch" <<'PS'
$repo, $config, $arch = $args
Import-Module "$repo\contrib\win32\openssh\OpenSSHBuildHelper.psm1" -Force
Push-Location $repo
try { Start-OpenSSHBuild -NativeHostArch $arch -Configuration $config -Verbose }
finally { Pop-Location }
PS
    if [ "$targets_clean" = 1 ]; then git -C "$repo" checkout -q -- "$targets"; fi
fi

step "Removing existing OpenSSH"
run_ps "$prefix" <<'PS'
$prefix = $args[0]

# Win32-OpenSSH MSI (GitHub release / winget) owns the same directory; let its uninstaller handle it
$msi = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'OpenSSH*' }
if ($msi) {
    throw "MSI-installed '$($msi[0].DisplayName)' found; uninstall it first (Settings > Apps, or winget uninstall)"
}

foreach ($svc in 'sshd', 'ssh-agent') {
    if (Get-Service $svc -ErrorAction SilentlyContinue) {
        Write-Host "stopping $svc"
        Stop-Service $svc -Force
    }
}
# Leftover per-connection processes keep the binaries locked
Get-Process sshd, sshd-session, sshd-auth, ssh-agent -ErrorAction SilentlyContinue | Stop-Process -Force

$restart = $false
foreach ($cap in Get-WindowsCapability -Online -Name 'OpenSSH.*' | Where-Object State -eq 'Installed') {
    Write-Host "removing Windows capability $($cap.Name)"
    $r = Remove-WindowsCapability -Online -Name $cap.Name
    if ($r.RestartNeeded) { $restart = $true }
}
if ($restart) { Write-Warning "Windows wants a reboot to finish removing the built-in OpenSSH" }

if (Test-Path "$prefix\uninstall-sshd.ps1") {
    Write-Host "unregistering previous deploy in $prefix"
    & "$prefix\uninstall-sshd.ps1"
}
PS

step "Installing into $prefix"
run_ps "$repo_win" "$config" "$arch" "$prefix" <<'PS'
$repo, $config, $arch, $prefix = $args
Import-Module "$repo\contrib\win32\openssh\OpenSSHBuildHelper.psm1" -Force
Push-Location $repo
try { Start-OpenSSHPackage -NativeHostArch $arch -Configuration $config -DestinationPath $prefix }
finally { Pop-Location }

# Registers the sshd/ssh-agent services, fixes ACLs on the binaries and on
# an existing %ProgramData%\ssh, and adds $prefix to the machine PATH
& "$prefix\install-sshd.ps1"
PS

step "Starting sshd and fixing permissions"
run_ps "$prefix" <<'PS'
$prefix = $args[0]

# First start creates %ProgramData%\ssh with sshd_config and host keys if missing
Set-Service sshd -StartupType Automatic
Start-Service sshd

& "$prefix\FixHostFilePermissions.ps1" -Confirm:$false
& "$prefix\FixUserFilePermissions.ps1" -Confirm:$false

$config = "$env:ProgramData\ssh\sshd_config"
if (Select-String -Path $config -Pattern '^\s*AllowAgentForwarding\s+no' -Quiet) {
    Write-Warning "$config has 'AllowAgentForwarding no'; agent forwarding stays disabled"
}

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    Write-Host "adding firewall rule for port 22"
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Restart-Service sshd

& "$prefix\ssh.exe" -V
Get-Service sshd, ssh-agent | Format-Table -AutoSize Name, Status, StartType
PS

echo
echo "Done. Open a new shell to pick up the PATH change."
echo "Test from Linux: ssh -A <this machine>, then: ssh-add -l"
