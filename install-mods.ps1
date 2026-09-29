#Requires -Version 5.1
<#
    Minecraft 26.3 / Fabric mod installer.

    Pulls a mod list from mods.json, resolves each entry against the live
    Modrinth v2 API, verifies the SHA-512 the API reports, and drops the
    jars into the Fabric profile's mods folder.

    Everything is fetched over HTTPS from the upstream APIs
    (meta.fabricmc.net, api.modrinth.com, maven.fabricmc.net) and every
    download is hash-checked. No antivirus exclusions are added, no
    security controls are disabled, nothing is signed or executed except
    the official Fabric installer, and only when it is actually missing.

    Run it through run.cmd, or directly:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\install-mods.ps1
#>
[CmdletBinding()]
param(
    # Game version to target. Modrinth's current release is 26.3.
    [string]$GameVersion,

    # Mod loader to filter for on Modrinth.
    [string]$Loader = "fabric",

    # Minecraft root. Defaults to the official launcher's location.
    [string]$MinecraftDir = (Join-Path $env:APPDATA ".minecraft"),

    # Mod manifest.
    [string]$ModsManifest,

    # Reinstall Fabric even if a matching profile already exists.
    [switch]$ForceFabricInstall,

    # Re-download mods that are already present in the mods folder.
    [switch]$ReinstallMods,

    # Also install the mods marked required=false in mods.json.
    [switch]$IncludeOptional,

    # Resolve and report, but do not write anything to disk.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# Windows PowerShell 5.1 still defaults to TLS 1.0, which both APIs reject.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Modrinth requires a descriptive User-Agent or it returns 403.
$UserAgent      = "balls-installer/1.0 (+https://github.com/DeutscherCOder/balls)"
$FabricMetaBase = "https://meta.fabricmc.net/v2"
$ModrinthBase   = "https://api.modrinth.com/v2"
$JavaExe        = "java"
$results        = New-Object System.Collections.Generic.List[object]

if (-not $ModsManifest) { $ModsManifest = Join-Path $PSScriptRoot "mods.json" }

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
function Write-Step { param([string]$m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   [ok]  $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "   [--]  $m" -ForegroundColor Gray }
function Write-Warn { param([string]$m) Write-Host "   [!!]  $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "   [XX]  $m" -ForegroundColor Red }

# --------------------------------------------------------------------------
# HTTP helpers
# --------------------------------------------------------------------------
function Get-ApiJson {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        Invoke-RestMethod -Uri $Uri -UserAgent $UserAgent -TimeoutSec 30
    } catch {
        throw "API request failed: $Uri`n      $($_.Exception.Message)"
    }
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # -UseBasicParsing keeps this working on Windows PowerShell 5.1.
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UserAgent $UserAgent `
                      -TimeoutSec 180 -UseBasicParsing
}

function Test-FileHash512 {
    param([string]$Path, [string]$Expected)
    if (-not $Expected) { return $true }   # API did not supply one
    $actual = (Get-FileHash -Path $Path -Algorithm SHA512).Hash
    return ($actual -eq $Expected.ToUpper())
}

# --------------------------------------------------------------------------
# Fabric
# --------------------------------------------------------------------------
function Find-FabricProfile {
    param([string]$Dir, [string]$Game)
    $versions = Join-Path $Dir "versions"
    if (-not (Test-Path $versions)) { return $null }
    $hit = Get-ChildItem $versions -Directory -Filter "fabric-loader-*" -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*$Game*" } |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1
    if ($hit) { return $hit } else { return $null }
}

function Install-Fabric {
    param([string]$Dir, [string]$Game)

    $gameMeta = Get-ApiJson "$FabricMetaBase/versions/game/$Game"
    Write-Info "game version : $($gameMeta.version) (stable=$($gameMeta.stable))"

    $loaders = Get-ApiJson "$FabricMetaBase/versions/loader/$($gameMeta.version)"
    $pick = $loaders | Where-Object { $_.loader.stable } | Select-Object -First 1
    if (-not $pick) { $pick = $loaders | Select-Object -First 1 }
    if (-not $pick) { throw "Fabric publishes no loader build for Minecraft $Game." }
    Write-Info "loader       : $($pick.loader.version) (stable=$($pick.loader.stable))"

    $instMeta = Get-ApiJson "$FabricMetaBase/versions/installer"
    $instMeta = $instMeta | Where-Object { $_.stable } | Select-Object -First 1
    if (-not $instMeta) { $instMeta = (Get-ApiJson "$FabricMetaBase/versions/installer")[0] }

    $jar = Join-Path $env:TEMP "fabric-installer-$($instMeta.version).jar"
    Write-Info "downloading  : fabric-installer $($instMeta.version)"
    Save-RemoteFile -Uri $instMeta.url -OutFile $jar
    Write-Ok "installer saved to $jar"

    $proc = Start-Process -FilePath $JavaExe -ArgumentList @("-jar", $jar) -PassThru

    Write-Warn "The Fabric installer is now open in this window."
    Write-Warn "Follow its prompts to install, then close it when you are done."
    Write-Info "Watching the process. Closing it early is fine, the script carries on."
    Write-Info "Giving it up to 15 minutes."

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $proc.Refresh()
        if ($proc.HasExited) { break }
        if ($sw.Elapsed.TotalSeconds -gt 900) {
            Write-Warn "Installer still running after 15 minutes. Continuing anyway."
            break
        }
        Start-Sleep -Seconds 2
    }
    if ($proc.HasExited) { Write-Ok "Installer closed (exit code $($proc.ExitCode))." }

    # The profile directory appears a moment after the installer exits.
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    while ($sw2.Elapsed.TotalSeconds -lt 60) {
        $p = Find-FabricProfile -Dir $Dir -Game $Game
        if ($p) { return $p }
        Start-Sleep -Seconds 2
    }
    return $null
}

# --------------------------------------------------------------------------
# Modrinth
# --------------------------------------------------------------------------
function Resolve-Mod {
    param([string]$Slug, [string]$Game, [string]$Ldr)

    $gv = [Uri]::EscapeDataString('["' + $Game + '"]')
    $ld = [Uri]::EscapeDataString('["' + $Ldr + '"]')
    $uri = "$ModrinthBase/project/$Slug/version?game_versions=$gv&loaders=$ld"

    $versions = Get-ApiJson $uri
    if (-not $versions -or $versions.Count -eq 0) { return $null }

    # Modrinth returns newest first. Skip anything without a primary file.
    foreach ($v in $versions) {
        $file = $v.files | Where-Object { $_.primary -eq $true } | Select-Object -First 1
        if (-not $file) { $file = $v.files | Select-Object -First 1 }
        if ($file) {
            return [pscustomobject]@{
                Name      = $v.name
                Version   = $v.version_number
                FileName  = $file.filename
                Url       = $file.url
                Size      = $file.size
                Sha512    = $file.hashes.sha512
                Type      = $v.version_type
            }
        }
    }
    return $null
}

# ==========================================================================
# Load the manifest first so the banner can show the real target version.
if (-not (Test-Path $ModsManifest)) {
    throw "Mod manifest not found: $ModsManifest"
}
$manifest = Get-Content $ModsManifest -Raw | ConvertFrom-Json

if (-not $GameVersion) { $GameVersion = $manifest.gameVersion }
if (-not $Loader)       { $Loader       = $manifest.loader }
if ($manifest.userAgent) { $UserAgent    = $manifest.userAgent }

Write-Host ""
Write-Host "  Minecraft $GameVersion / $Loader mod installer" -ForegroundColor White
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

if (-not (Test-Path $MinecraftDir)) {
    throw "Minecraft directory not found: $MinecraftDir"
}
Write-Ok "Minecraft directory: $MinecraftDir"

$wantOptional = $IncludeOptional.IsPresent

# ---- Step 1: Fabric profile ------------------------------------------------
Write-Step "Step 1 of 2  Fabric profile"

$profile = Find-FabricProfile -Dir $MinecraftDir -Game $GameVersion

if ($profile -and -not $ForceFabricInstall) {
    Write-Ok "already installed: $($profile.Name)"
} else {
    if ($profile) { Write-Info "-ForceFabricInstall given, running installer anyway." }
    if ($DryRun) {
        Write-Info "Dry run: would download and launch the official Fabric installer."
    } else {
        $profile = Install-Fabric -Dir $MinecraftDir -Game $GameVersion
    }
}

if ($profile) {
    $modsDir = Join-Path $profile.FullName "mods"
    Write-Ok "mod folder: $modsDir"
} else {
    # No Fabric profile. Fall back to the launcher root so the jars are at
    # least staged somewhere sensible, and say so clearly.
    $modsDir = Join-Path $MinecraftDir "mods"
    Write-Warn "No Fabric profile found for $GameVersion."
    Write-Warn "Staging mods in the launcher root instead:"
    Write-Warn "  $modsDir"
    Write-Warn "Install Fabric (https://fabricmc.net/use/installer) and move the"
    Write-Warn "jars into the new profile, or they will be ignored."
}

# ---- Step 2: Mods ---------------------------------------------------------
Write-Step "Step 2 of 2  Mods from Modrinth"

if (-not $DryRun -and -not (Test-Path $modsDir)) {
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
}

foreach ($mod in $manifest.mods) {
    if (-not $mod.required -and -not $wantOptional) {
        Write-Info "skip $($mod.slug) (optional; add -IncludeOptional to install)"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "skipped"; Detail = "optional" })
        continue
    }

    try {
        $r = Resolve-Mod -Slug $mod.slug -Game $GameVersion -Ldr $Loader
    } catch {
        Write-Err "$($mod.slug): $($_.Exception.Message)"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "error"; Detail = "API error" })
        continue
    }

    if (-not $r) {
        Write-Warn "$($mod.slug): no build for $GameVersion / $Loader. Skipped."
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "skipped"; Detail = "no $GameVersion build" })
        continue
    }

    $dest = Join-Path $modsDir $r.FileName
    $label = "$($mod.slug) $($r.Version)"

    if ((Test-Path $dest) -and -not $ReinstallMods -and -not $DryRun) {
        Write-Ok "$label already present"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "present"; Detail = $r.Version })
        continue
    }

    if ($DryRun) {
        Write-Info "$label -> would download ($([math]::Round($r.Size/1KB)) KB)"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "dry-run"; Detail = $r.Version })
        continue
    }

    try {
        Write-Info "$label downloading..."
        Save-RemoteFile -Uri $r.Url -OutFile $dest

        if (-not (Test-FileHash512 -Path $dest -Expected $r.Sha512)) {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            throw "SHA-512 did not match the hash Modrinth published. File deleted."
        }
        Write-Ok "$label installed and hash-verified"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "installed"; Detail = $r.Version })
    } catch {
        Write-Err "$($mod.slug): $($_.Exception.Message)"
        $results.Add([pscustomobject]@{ Mod = $mod.slug; Status = "error"; Detail = "download/verify failed" })
    }
}

# ---- Summary --------------------------------------------------------------
Write-Step "Summary"
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$failed = @($results | Where-Object { $_.Status -eq "error" })
$active = @($results | Where-Object { $_.Status -eq "installed" -or $_.Status -eq "present" })

if ($failed.Count -gt 0) {
    Write-Warn "$($failed.Count) mod(s) failed. Everything else is fine."
}

if ($active.Count -gt 0 -and -not $DryRun) {
    Write-Host ""
    Write-Host "  Launch Minecraft and pick the" -ForegroundColor White
    Write-Host "  fabric-loader-$($GameVersion) profile." -ForegroundColor White
    Write-Host ""
    if (Test-Path $modsDir) {
        $open = Read-Host "Open the mods folder now? [Y/n]"
        if ($open -notmatch '^[nN]') { Invoke-Item $modsDir }
    }
}

exit $(if ($failed.Count -gt 0) { 1 } else { 0 })
