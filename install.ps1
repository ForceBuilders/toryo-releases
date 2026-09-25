# toryo installer for native Windows: the headless CLI, and nothing else.
#
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/ForceBuilders/toryo-releases/main/install.ps1 | iex"
#
# The -ExecutionPolicy Bypass is not decoration. Windows blocks a downloaded
# .ps1 run directly under the default RemoteSigned policy, so `.\install.ps1`
# fails with "cannot be loaded because running scripts is disabled on this
# system" unless the file is unblocked first (`Unblock-File .\install.ps1`).
#
# What this installs: the native Windows `toryo` CLI, downloaded as
# toryo-<v>-windows-<arch>.tar.gz from the public releases repo, checksum-checked
# against SHA256SUMS and, when minisign is present, signature-checked against a
# key that never crossed the network. It unpacks into ~\.toryo\bin and appends
# that directory to the user PATH.
#
# What this does NOT install:
#
#   * Board, the desktop app. It is a separate installer and is not shipped for
#     Windows yet. See https://toryo.dev/docs.
#   * A WSL2 environment. WSL2 is Linux: open your distro and run install.sh
#     inside it (see the Linux and WSL2 page at https://toryo.dev/docs). This
#     script deliberately does not drive `wsl --install`.
#
# Honest about the state of the world: the Windows CLI archive is NOT published
# yet. SHIPPING_TARGETS in scripts/lib/build-targets.ts filters the Windows rows
# out and scripts/package.ts refuses a Windows --target, so the asset this script
# resolves is a name the release pipeline can spell and cannot yet produce. The
# download step will 404 against every release published to date. The resolution,
# checksum and PATH halves are real and tested; the install as a whole is not
# usable until the Windows build lands.
#
# Env overrides:
#   TORYO_HOME             install root (default ~\.toryo)
#   TORYO_UPDATE_CHANNEL   owner/repo of the releases repo (default ForceBuilders/toryo-releases)
#   TORYO_VERSION          pin an explicit version (default: latest release)
#   TORYO_PRINT_ASSET=1    print the asset name this machine resolves to, then exit
#   TORYO_RUN_SETUP=1      run `toryo setup` and `toryo skills install` after extracting
#   TORYO_SKIP_SKILLS=1    with TORYO_RUN_SETUP=1, still skip `toryo skills install`
#
# Setup is opt-in here, the reverse of install.sh. selectSupervisorKind in
# apps/toryo/src/setup/supervisor.ts has no native-Windows branch: mapPlatform in
# packages/config/src/platform.ts calls anything that is not darwin or linux
# 'other', and 'other' takes the systemd or login-shell path. On a real Windows
# box that writes a systemd unit no manager reads, or a guarded block into a
# ~/.bashrc no shell sources. Running that by default is a surprise, so this
# script prints why it skipped and leaves the choice to TORYO_RUN_SETUP=1.
#
# ASCII only, on purpose. Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# which mangles the non-ASCII ellipsis install.sh prints. The messages below are
# otherwise the same messages, so a support answer written for one fits both.

# The release signing key's public half. Rotated with
# `bun scripts/gen-release-keypair.ts`; must stay byte-identical to
# RELEASE_PUBLIC_KEY in packages/minisign/src/keys.ts, which
# scripts/tests/install-ps1.integration.test.ts asserts.
$PUBKEY = @'
untrusted comment: toryo release key C7EE1C6DD07ADC5B
RWRb3HrQbRzux4O8CkBYUHAQrlJ5pmxQ2a4SaVF6rGE5x+jN0J0J5K4y
'@

<#
.SYNOPSIS
  Map a Windows processor-architecture token onto a release asset architecture.
.DESCRIPTION
  Accepts what $env:PROCESSOR_ARCHITECTURE reports (AMD64, ARM64, x86) and what
  RuntimeInformation::OSArchitecture reports (X64, Arm64), since the second is
  the fallback when the first is unset. x86 has no build and is a named refusal
  rather than a 404 later on.
#>
function Resolve-ToryoArch {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Architecture
    )

    $token = if ([string]::IsNullOrWhiteSpace($Architecture)) { '(unknown)' } else { $Architecture.Trim() }

    switch ($token) {
        'AMD64' { return 'x64' }
        'x64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default {
            throw "unsupported architecture: $token (x64 and arm64 are supported; there is no 32-bit build)"
        }
    }
}

<#
.SYNOPSIS
  The release asset name for an architecture token and a version.
.DESCRIPTION
  Must agree with assetNameFor in apps/toryo/src/update/channel.ts, which is the
  single source of the filename. A second spelling here is a 404 nobody can
  debug from the error message.
#>
function Resolve-ToryoAsset {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Architecture,

        [Parameter(Mandatory)]
        [string]$Version
    )

    $arch = Resolve-ToryoArch -Architecture $Architecture
    return "toryo-$Version-windows-$arch.tar.gz"
}

<#
.SYNOPSIS
  The warning printed when minisign is unavailable, or $null when it is present.
.DESCRIPTION
  SHA256SUMS travels from the same host as the tarball, so on its own it proves
  only that the download is self-consistent. Saying which half was skipped is
  the whole point of the notice; a bare "unverified" tells a user nothing they
  can act on. The install routes are Windows ones, not the brew and apt lines
  install.sh prints.
#>
function Get-SignatureNotice {
    param(
        [Parameter(Mandatory, Position = 0)]
        [bool]$MinisignAvailable
    )

    if ($MinisignAvailable) { return $null }

    return @'
  WARNING: minisign is not installed, so the SHA256SUMS signature was NOT checked.
  The checksum below proves the download is intact, not that we published it.
  Install it and re-run to get the full check:
    winget install jedisct1.minisign
    scoop install minisign
'@
}

<#
.SYNOPSIS
  Whether a downloaded file matches its SHA256SUMS line.
.DESCRIPTION
  Get-FileHash -Algorithm SHA256 ships with PowerShell 5.1 and later, so unlike
  install.sh there is no shasum/sha256sum fallback to write. A line whose first
  field is not a 64-character hex digest is a malformed SHA256SUMS, which fails
  rather than being coerced into a comparison that happens to hold.
#>
function Test-ToryoChecksum {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SumsLine
    )

    $expected = ($SumsLine -split '\s+' | Where-Object { $_ } | Select-Object -First 1)
    if (-not $expected -or $expected -notmatch '^[0-9a-fA-F]{64}$') { return $false }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -eq $expected)
}

<#
.SYNOPSIS
  Whether a PATH string already contains a directory.
.DESCRIPTION
  Pure, so re-running the installer can be proven not to append a duplicate.
  Trailing separators and surrounding whitespace are normalised away, and the
  comparison is case-insensitive, which is how Windows compares paths.
#>
function Test-ToryoPathContains {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $target = $Directory.Trim().TrimEnd('\', '/')
    foreach ($entry in ($Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry.Trim().TrimEnd('\', '/') -eq $target) { return $true }
    }

    return $false
}

<#
.SYNOPSIS
  Append a directory to the persisted user PATH, once.
.DESCRIPTION
  Returns $true when it wrote and $false when the entry was already there. The
  User target is the per-user registry value, so it survives the terminal that
  ran the installer; the current process's PATH is updated too, so the rest of
  this script can find the binary it just extracted.
#>
function Add-ToryoPathEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-ToryoPathContains -Path $current -Directory $Directory) { return $false }

    $updated = if ([string]::IsNullOrWhiteSpace($current)) {
        $Directory
    }
    else {
        $current.TrimEnd(';') + ';' + $Directory
    }

    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    $env:Path = "$env:Path;$Directory"
    return $true
}

<# Whether this process is running on Windows. $IsWindows does not exist in
   Windows PowerShell 5.1, which only runs there, so its absence means yes. #>
function Test-ToryoOnWindows {
    if (-not (Test-Path Variable:IsWindows)) { return $true }
    return [bool]$IsWindows
}

<# The extracted CLI. The Windows build's binary name is not settled yet (the
   .exe rename in scripts/build-binaries.ts is the Windows build task's problem),
   so accept either rather than guess one and fail with a path nobody expects. #>
function Resolve-ToryoBinary {
    param(
        [Parameter(Mandatory)]
        [string]$BinDir
    )

    foreach ($name in @('toryo.exe', 'toryo')) {
        $candidate = Join-Path $BinDir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    throw "the archive did not contain a toryo binary in $BinDir"
}

<# Download one URL, naming the URL when it fails. Invoke-WebRequest's own
   message names an HTTP status and nothing else, which is useless when three
   files come from the same release. #>
function Invoke-ToryoDownload {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    }
    catch {
        throw "download failed: $Uri ($($_.Exception.Message))"
    }
}

<#
.SYNOPSIS
  Resolve, download, verify and unpack the Windows CLI.
.DESCRIPTION
  Throws on every refusal; the entrypoint at the bottom of this file turns a
  throw into "toryo install: <reason>" on stderr and exit 1, so the message
  prefix and exit code match install.sh.
#>
function Invoke-ToryoInstall {
    $ErrorActionPreference = 'Stop'
    # PowerShell 7.4 turns a non-zero native exit code into a terminating error
    # under ErrorActionPreference = Stop, which would replace the named refusals
    # below ("do not install this download") with a generic "Program failed".
    # The explicit $LASTEXITCODE checks own that decision on every version.
    $PSNativeCommandUseErrorActionPreference = $false
    # Windows PowerShell 5.1 negotiates TLS 1.0 by default, which github.com
    # refuses; and Invoke-WebRequest's progress bar costs more than the download.
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'

    $repo = if ($env:TORYO_UPDATE_CHANNEL) { $env:TORYO_UPDATE_CHANNEL } else { 'ForceBuilders/toryo-releases' }
    $toryoHome = if ($env:TORYO_HOME) { $env:TORYO_HOME } else { Join-Path $HOME '.toryo' }
    # binDir() in packages/config/src/index.ts is join(homeDir(), 'bin'), and
    # homeDir() is TORYO_HOME or ~\.toryo. So this is not a preference: anywhere
    # else and the installed CLI cannot find its own binaries without
    # TORYO_BIN_DIR set for every process that runs it.
    $bin = Join-Path $toryoHome 'bin'

    $archToken = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($archToken)) {
        $archToken = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    $arch = Resolve-ToryoArch -Architecture $archToken

    $version = ''
    $tag = ''
    if ($env:TORYO_VERSION) {
        $version = $env:TORYO_VERSION -replace '^v', ''
        $tag = "v$version"
    }

    # A debugging affordance, and what lets scripts/tests/install-ps1.integration.test.ts
    # check the mapping above without a network call. Before everything.
    if ($env:TORYO_PRINT_ASSET -eq '1') {
        $shown = if ($version) { $version } else { '<version>' }
        Write-Output (Resolve-ToryoAsset -Architecture $archToken -Version $shown)
        return
    }

    if (-not (Test-ToryoOnWindows)) {
        throw 'this installer is for native Windows; on macOS, Linux and WSL2 use install.sh'
    }

    if (-not $version) {
        Write-Output "resolving latest toryo release from $repo..."
        try {
            $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing
        }
        catch {
            throw "could not resolve latest release (is $repo public and does it have a release?): $($_.Exception.Message)"
        }
        $tag = $latest.tag_name
        if (-not $tag) { throw "could not resolve latest release (is $repo public and does it have a release?)" }
        $version = $tag -replace '^v', ''
    }

    $asset = Resolve-ToryoAsset -Architecture $archToken -Version $version
    $base = "https://github.com/$repo/releases/download/$tag"
    Write-Output "installing toryo $version (windows-$arch)"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('toryo-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $assetPath = Join-Path $tmp $asset
        $sumsPath = Join-Path $tmp 'SHA256SUMS'

        Write-Output "downloading $asset..."
        Invoke-ToryoDownload -Uri "$base/$asset" -OutFile $assetPath
        Invoke-ToryoDownload -Uri "$base/SHA256SUMS" -OutFile $sumsPath

        $minisign = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
        $notice = Get-SignatureNotice -MinisignAvailable ([bool]$minisign)
        if ($notice) {
            Write-Output ''
            Write-Output $notice
            Write-Output ''
        }
        else {
            $sigPath = Join-Path $tmp 'SHA256SUMS.minisig'
            Invoke-ToryoDownload -Uri "$base/SHA256SUMS.minisig" -OutFile $sigPath
            $pubPath = Join-Path $tmp 'toryo.pub'
            Set-Content -LiteralPath $pubPath -Value $PUBKEY -Encoding ascii
            # Unredirected on purpose: on success minisign echoes the trusted
            # comment, which names the version the signature actually covers. It
            # is signed too (see packages/minisign/src/format.ts), so it is the
            # one field worth reading.
            & $minisign.Source -V -p $pubPath -m $sumsPath
            if ($LASTEXITCODE -ne 0) {
                throw 'signature verification failed for SHA256SUMS; do not install this download'
            }
        }

        # SHA256SUMS also lists the other platforms' tarballs and the dmg, so
        # only this asset's line is checked.
        $pattern = '\s' + [regex]::Escape($asset) + '\s*$'
        $line = Get-Content -LiteralPath $sumsPath | Where-Object { $_ -match $pattern } | Select-Object -First 1
        if (-not $line) { throw "$asset is not listed in SHA256SUMS" }
        if (-not (Test-ToryoChecksum -Path $assetPath -SumsLine $line)) {
            throw "checksum verification failed for $asset"
        }
        Write-Output 'checksum verified.'

        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        # tar.exe is bsdtar, shipped with Windows 10 1803 and later. Expand-Archive
        # reads zip only and cannot open a .tar.gz.
        $tar = Get-Command tar.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if (-not $tar) {
            throw 'tar.exe is required (Windows 10 1803 and later ship it; Expand-Archive cannot read a .tar.gz)'
        }
        & $tar.Source -xzf $assetPath -C $bin
        if ($LASTEXITCODE -ne 0) { throw "could not extract $asset into $bin" }
        Write-Output "extracted to $bin"
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $pathAdded = Add-ToryoPathEntry -Directory $bin

    if ($env:TORYO_RUN_SETUP -eq '1') {
        $toryo = Resolve-ToryoBinary -BinDir $bin
        Write-Output 'TORYO_RUN_SETUP=1, running toryo setup...'
        & $toryo setup
        if ($LASTEXITCODE -ne 0) { throw "toryo setup failed with exit code $LASTEXITCODE" }

        if ($env:TORYO_SKIP_SKILLS -eq '1') {
            Write-Output "TORYO_SKIP_SKILLS=1, skipping 'toryo skills install'."
        }
        else {
            Write-Output 'installing toryo skills...'
            & $toryo skills install
            if ($LASTEXITCODE -ne 0) { Write-Output '  (skills install skipped, no bundle found)' }
        }
    }
    else {
        Write-Output ''
        Write-Output "skipping 'toryo setup': toryo's supervisor selection has no native-Windows"
        Write-Output '  branch yet, so setup would install a systemd unit or a ~/.bashrc block that'
        Write-Output '  nothing on this machine reads. Set TORYO_RUN_SETUP=1 to run it anyway.'
    }

    Write-Output ''
    Write-Output "toryo $version installed to $bin"
    if ($pathAdded) {
        Write-Output '  Added it to your user PATH. Open a new terminal for that to take effect.'
    }
    else {
        Write-Output '  It was already on your user PATH.'
    }
}

# Run only when executed. Dot-sourcing (`. .\install.ps1`) defines the functions
# above and installs nothing, which is how the pure halves are tested.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ToryoInstall
    }
    catch {
        [Console]::Error.WriteLine("toryo install: $($_.Exception.Message)")
        exit 1
    }
}
