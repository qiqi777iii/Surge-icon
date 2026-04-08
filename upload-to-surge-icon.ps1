param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$RepoDir = (Join-Path $PSScriptRoot "_surge-icon-repo"),
    [string]$RemoteUrl = "https://github.com/qiqi777iii/Surge-icon.git",
    [string]$Branch = "main",
    [switch]$NoCommit,
    [switch]$NoPush,
    [switch]$SkipHashDuplicate = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Command {
    param([Parameter(Mandatory)] [string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing command: $Name"
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Args
    )

    & git -C $Repo @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git -C `"$Repo`" $($Args -join ' ')"
    }
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Args
    )

    $output = & git -C $Repo @Args 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return ($output | Out-String).Trim()
}

function Ensure-Repo {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$BranchName
    )

    if (-not (Test-Path -LiteralPath $Repo)) {
        $parent = Split-Path -Parent $Repo
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        Write-Host "[1/6] Cloning repo to: $Repo"
        & git clone --branch $BranchName --single-branch $Url $Repo
        if ($LASTEXITCODE -ne 0) {
            throw "Clone failed."
        }
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        throw "RepoDir exists but is not a Git repo: $Repo"
    }

    $status = & git -C $Repo status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read repo status: $Repo"
    }
    if ($status) {
        throw "Repo has uncommitted changes, please clean it first: $Repo"
    }

    Write-Host "[1/6] Updating local repo"
    Invoke-Git -Repo $Repo fetch origin $BranchName --prune
    Invoke-Git -Repo $Repo checkout $BranchName
    Invoke-Git -Repo $Repo pull --rebase origin $BranchName
}

function Get-RawFileUrl {
    param(
        [Parameter(Mandatory)] [string]$BranchName,
        [Parameter(Mandatory)] [string]$FileName
    )

    $encoded = [System.Uri]::EscapeDataString($FileName)
    return "https://raw.githubusercontent.com/qiqi777iii/Surge-icon/$BranchName/icon/$encoded"
}

Require-Command -Name git

if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Source directory not found: $SourceDir"
}

$allowedExtensions = @('.png', '.jpg', '.jpeg', '.webp')
$summaryPath = Join-Path $PSScriptRoot 'upload-to-surge-icon.last.json'

Ensure-Repo -Repo $RepoDir -Url $RemoteUrl -BranchName $Branch

$iconDir = Join-Path $RepoDir 'icon'
$iconJsonPath = Join-Path $RepoDir 'icon.json'

if (-not (Test-Path -LiteralPath $iconDir)) {
    throw "icon directory not found in repo: $iconDir"
}
if (-not (Test-Path -LiteralPath $iconJsonPath)) {
    throw "icon.json not found in repo: $iconJsonPath"
}

Write-Host "[2/6] Scanning source files"
$sourceFiles = @(Get-ChildItem -LiteralPath $SourceDir -File | Where-Object {
    $allowedExtensions -contains $_.Extension.ToLowerInvariant()
} | Sort-Object Name)

$repoFiles = @(Get-ChildItem -LiteralPath $iconDir -File)
$existingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$existingHashes = @{}
foreach ($file in $repoFiles) {
    $null = $existingNames.Add($file.Name)
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
    if (-not $existingHashes.ContainsKey($hash)) {
        $existingHashes[$hash] = [System.Collections.Generic.List[string]]::new()
    }
    $existingHashes[$hash].Add($file.Name)
}

$newFiles = [System.Collections.Generic.List[string]]::new()
$skippedByName = [System.Collections.Generic.List[string]]::new()
$skippedByHash = [System.Collections.Generic.List[object]]::new()

Write-Host "[3/6] Comparing and copying new files"
foreach ($file in $sourceFiles) {
    if ($existingNames.Contains($file.Name)) {
        $skippedByName.Add($file.Name)
        continue
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
    if ($SkipHashDuplicate -and $existingHashes.ContainsKey($hash)) {
        $skippedByHash.Add([pscustomobject][ordered]@{
            name = $file.Name
            duplicateOf = @($existingHashes[$hash])
        })
        continue
    }

    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $iconDir $file.Name)
    $newFiles.Add($file.Name)
    $null = $existingNames.Add($file.Name)
    if (-not $existingHashes.ContainsKey($hash)) {
        $existingHashes[$hash] = [System.Collections.Generic.List[string]]::new()
    }
    $existingHashes[$hash].Add($file.Name)
}

Write-Host "[4/6] Updating icon.json"
$json = Get-Content -LiteralPath $iconJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allIcons = [System.Collections.Generic.List[object]]::new()
$seenUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($icon in $json.icons) {
    $item = [pscustomobject][ordered]@{
        name = [string]$icon.name
        url  = [string]$icon.url
    }
    if ($seenUrls.Add($item.url)) {
        $allIcons.Add($item)
    }
}

foreach ($name in $newFiles) {
    $url = Get-RawFileUrl -BranchName $Branch -FileName $name
    if ($seenUrls.Add($url)) {
        $allIcons.Add([pscustomobject][ordered]@{
            name = [System.IO.Path]::GetFileNameWithoutExtension($name)
            url  = $url
        })
    }
}

$sortedIcons = @($allIcons | Sort-Object name, url)
$outputObject = [pscustomobject][ordered]@{
    name        = [string]$json.name
    description = [string]$json.description
    icons       = $sortedIcons
}
$outputObject | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $iconJsonPath -Encoding UTF8

$committed = $false
$pushed = $false

if ($newFiles.Count -gt 0) {
    Write-Host "[5/6] Committing changes"
    $currentName = Get-GitOutput -Repo $RepoDir config --get user.name
    $currentEmail = Get-GitOutput -Repo $RepoDir config --get user.email

    if (-not $currentName) {
        $lastAuthorName = Get-GitOutput -Repo $RepoDir log -1 --format=%an
        if ($lastAuthorName) {
            Invoke-Git -Repo $RepoDir config user.name $lastAuthorName
        }
    }
    if (-not $currentEmail) {
        $lastAuthorEmail = Get-GitOutput -Repo $RepoDir log -1 --format=%ae
        if ($lastAuthorEmail) {
            Invoke-Git -Repo $RepoDir config user.email $lastAuthorEmail
        }
    }

    Invoke-Git -Repo $RepoDir add -- icon icon.json

    if (-not $NoCommit) {
        $message = "Add $($newFiles.Count) icon(s)"
        Invoke-Git -Repo $RepoDir commit -m $message
        $committed = $true
    }

    if (-not $NoPush -and -not $NoCommit) {
        Write-Host "[6/6] Pushing to GitHub"
        Invoke-Git -Repo $RepoDir push origin $Branch
        $pushed = $true
    }
}
else {
    Write-Host "[5/6] No new files, skipping commit"
    Write-Host "[6/6] No new files, skipping push"
}

$summary = [pscustomobject][ordered]@{
    timestamp          = (Get-Date).ToString('s')
    sourceDir          = $SourceDir
    repoDir            = $RepoDir
    uploadedCount      = $newFiles.Count
    uploaded           = @($newFiles)
    skippedByNameCount = $skippedByName.Count
    skippedByName      = @($skippedByName)
    skippedByHashCount = $skippedByHash.Count
    skippedByHash      = @($skippedByHash)
    committed          = $committed
    pushed             = $pushed
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "Done."
Write-Host "Uploaded new files: $($newFiles.Count)"
Write-Host "Skipped by same name: $($skippedByName.Count)"
Write-Host "Skipped by same content: $($skippedByHash.Count)"
Write-Host "Summary file: $summaryPath"
