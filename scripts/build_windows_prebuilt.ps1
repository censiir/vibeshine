<#
.SYNOPSIS
    Build Vibeshine Windows exe using prebuilt WebRTC artifacts from CI.

.DESCRIPTION
    Downloads the latest prebuilt libwebrtc artifacts from a successful GitHub Actions
    run (skipping the multi-hour WebRTC build), then configures and builds Vibeshine
    with MSYS2/MinGW. Requires:
      - gh (GitHub CLI, authenticated)
      - MSYS2 with ucrt64 toolchain installed
      - Git with submodules checked out

.PARAMETER Repo
    GitHub repository in owner/repo form. Default: Nonary/vibeshine

.PARAMETER Branch
    Branch to pull the latest successful CI run from. Default: current git branch.

.PARAMETER OutDir
    Where to place the finished installer/exe. Default: .\dist

.PARAMETER WebrtcRoot
    Override path for the libwebrtc artifacts cache.
    Default: %LOCALAPPDATA%\Vibeshine\deps\libwebrtc\out

.PARAMETER Msys2Root
    Path to the MSYS2 installation root. Default: C:\msys64

.PARAMETER SkipDownload
    Skip downloading WebRTC artifacts (use whatever is already in WebrtcRoot).

.EXAMPLE
    .\scripts\build_windows_prebuilt.ps1
    .\scripts\build_windows_prebuilt.ps1 -Branch vibe -SkipDownload
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Nonary/vibeshine',
    [string]$Branch = '',
    [string]$OutDir = '.\dist',
    [string]$WebrtcRoot = '',
    [string]$Msys2Root = 'C:\msys64',
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Fail([string]$msg)       { throw "FAILED: $msg" }

# ── resolve paths ─────────────────────────────────────────────────────────────

if (-not $WebrtcRoot) {
    if ($env:VIBESHINE_DEPS_DIR) {
        $WebrtcRoot = Join-Path $env:VIBESHINE_DEPS_DIR 'libwebrtc\out'
    } elseif ($env:LOCALAPPDATA) {
        $WebrtcRoot = Join-Path $env:LOCALAPPDATA 'Vibeshine\deps\libwebrtc\out'
    } else {
        $WebrtcRoot = Join-Path $PSScriptRoot '..\build\libwebrtc'
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $Branch) {
    $Branch = & git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
    if (-not $Branch) { $Branch = 'vibe' }
}

$msys2Ucrt = Join-Path $Msys2Root 'ucrt64\bin'
$msys2Bin  = Join-Path $Msys2Root 'usr\bin'
$bash      = Join-Path $msys2Bin 'bash.exe'

Write-Host "Repo        : $Repo"
Write-Host "Branch      : $Branch"
Write-Host "WebrtcRoot  : $WebrtcRoot"
Write-Host "Msys2Root   : $Msys2Root"
Write-Host "OutDir      : $OutDir"

# ── prereq checks ─────────────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "gh (GitHub CLI) not found. Install from https://cli.github.com/ and run 'gh auth login'."
}
if (-not (Test-Path $bash)) {
    Fail "MSYS2 bash not found at $bash. Install MSYS2 from https://www.msys2.org/"
}
Write-Ok "gh and MSYS2 found"

# ── download prebuilt WebRTC artifacts ────────────────────────────────────────

$webrtcCached = (Test-Path (Join-Path $WebrtcRoot 'include\libwebrtc.h')) -and
                (Test-Path (Join-Path $WebrtcRoot 'lib\libwebrtc.dll')) -and
                (Test-Path (Join-Path $WebrtcRoot 'lib\libwebrtc.dll.a'))

if ($webrtcCached) {
    Write-Host "  Using cached WebRTC artifacts at $WebrtcRoot" -ForegroundColor Yellow
}

if (-not $SkipDownload -and -not $webrtcCached) {
    Write-Step "Finding latest successful CI run for branch '$Branch' on $Repo"

    $runJson = & gh api `
        "repos/$Repo/actions/workflows/ci-windows.yml/runs" `
        --field "branch=$Branch" `
        --field "status=success" `
        --field "per_page=1" `
        --jq '.workflow_runs[0] | {id: .id, name: .name, created_at: .created_at}' 2>&1

    if ($LASTEXITCODE -ne 0 -or -not $runJson) {
        # Try the main CI workflow
        $runJson = & gh api `
            "repos/$Repo/actions/workflows/ci.yml/runs" `
            --field "branch=$Branch" `
            --field "status=success" `
            --field "per_page=1" `
            --jq '.workflow_runs[0] | {id: .id, name: .name, created_at: .created_at}' 2>&1
    }

    if ($LASTEXITCODE -ne 0 -or -not $runJson) {
        Fail "Could not find a successful CI run for branch '$Branch'. Check 'gh auth status' and that the branch has passing CI."
    }

    $run = $runJson | ConvertFrom-Json
    Write-Ok "Found run #$($run.id) from $($run.created_at)"

    Write-Step "Downloading webrtc-Windows artifact from run #$($run.id)"
    $artifactTmp = Join-Path $env:TEMP "vibeshine-webrtc-$($run.id)"
    if (Test-Path $artifactTmp) { Remove-Item $artifactTmp -Recurse -Force }
    New-Item -ItemType Directory $artifactTmp | Out-Null

    & gh run download $run.id `
        --repo $Repo `
        --name 'webrtc-Windows' `
        --dir $artifactTmp

    if ($LASTEXITCODE -ne 0) {
        Fail "Artifact download failed. The artifact may have expired (retention is 1 day for WebRTC artifacts). Trigger a new CI run or build WebRTC locally with scripts\build_mingw_webrtc.ps1"
    }

    Write-Step "Installing artifacts to $WebrtcRoot"
    New-Item -ItemType Directory -Force $WebrtcRoot | Out-Null
    Copy-Item -Recurse -Force "$artifactTmp\*" $WebrtcRoot
    Remove-Item $artifactTmp -Recurse -Force
    Write-Ok "Artifacts installed"
} else {
    Write-Host "  Skipping download (--SkipDownload)" -ForegroundColor Yellow
}

# ── validate artifacts ────────────────────────────────────────────────────────

Write-Step "Validating WebRTC artifacts at $WebrtcRoot"

$requiredFiles = @(
    'include\libwebrtc.h',
    'lib\libwebrtc.dll',
    'lib\libwebrtc.dll.a'
)
foreach ($rel in $requiredFiles) {
    $full = Join-Path $WebrtcRoot $rel
    if (-not (Test-Path $full)) {
        Fail "Missing artifact: $full`nRe-run without -SkipDownload or build manually."
    }
}
Write-Ok "All required artifact files present"

# ── submodules ────────────────────────────────────────────────────────────────

Write-Step "Ensuring submodules are up to date"
& git -C $repoRoot submodule update --init --recursive --depth 1
if ($LASTEXITCODE -ne 0) { Fail "git submodule update failed" }
Write-Ok "Submodules ready"

# ── cmake configure + build via MSYS2 ────────────────────────────────────────

Write-Step "Configuring and building with CMake/Ninja (MSYS2 ucrt64)"

$webrtcRootFwd  = $WebrtcRoot -replace '\\','/'
$repoRootFwd    = $repoRoot -replace '\\','/'
$outDirAbs      = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutDir))
$outDirFwd      = $outDirAbs -replace '\\','/'

# Convert to MSYS2 paths (/c/... form)
function To-Msys2Path([string]$winPath) {
    $winPath = $winPath -replace '\\','/'
    if ($winPath -match '^([A-Za-z]):(.*)') {
        return '/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $winPath
}

$repoMsys  = To-Msys2Path $repoRootFwd
$webrtcMsys = To-Msys2Path $webrtcRootFwd
$outMsys   = To-Msys2Path $outDirFwd

$buildScript = @"
set -e
export PATH="/ucrt64/bin:/usr/bin:\$PATH"
cd "$repoMsys"
mkdir -p build
cmake \
  -B build \
  -G Ninja \
  -S . \
  -DBUILD_WERROR=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_DOCS=OFF \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DSUNSHINE_ENABLE_WEBRTC=ON \
  -DWEBRTC_ROOT="$webrtcMsys" \
  -DWEBRTC_INCLUDE_DIR="$webrtcMsys/include" \
  -DWEBRTC_LIBRARY="$webrtcMsys/lib/libwebrtc.dll.a" \
  -DWEBRTC_MSYS2_BIN="/ucrt64/bin"
cmake --build build --parallel
mkdir -p "$outMsys"
cp build/sunshine.exe "$outMsys/" 2>/dev/null || true
cp build/*.exe "$outMsys/" 2>/dev/null || true
cp "$webrtcMsys/lib/libwebrtc.dll" "$outMsys/" 2>/dev/null || true
echo "Build complete. Output in $outMsys"
"@

$tmpScript = Join-Path $env:TEMP 'vibeshine_build.sh'
[IO.File]::WriteAllText($tmpScript, $buildScript, [Text.Encoding]::UTF8)
$tmpScriptMsys = To-Msys2Path ($tmpScript -replace '\\','/')

& $bash --login -c "bash '$tmpScriptMsys'"
if ($LASTEXITCODE -ne 0) { Fail "Build failed — see output above" }

# ── done ─────────────────────────────────────────────────────────────────────

Write-Step "Done"
Write-Host "`nBuild artifacts are in: $outDirAbs" -ForegroundColor Green
Write-Host "sunshine.exe and libwebrtc.dll are ready to run." -ForegroundColor Green
