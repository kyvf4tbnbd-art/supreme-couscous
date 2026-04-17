param(
    [Parameter(Mandatory = $false)]
    [string]$RepoName = "rbtray-arm64",

    [Parameter(Mandatory = $false)]
    [string]$Token = $env:GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Missing GitHub token. Set GITHUB_TOKEN or pass -Token."
}

$projectRoot = Split-Path -Parent $PSScriptRoot

$filesToPublish = @(
    "RBTray.sln",
    "RBTray.vcxproj",
    "RBHook.vcxproj",
    ".github/workflows/build-arm64.yml"
)

$headers = @{
    Authorization = "Bearer $Token"
    Accept        = "application/vnd.github+json"
    "User-Agent"  = "codex-rbtray-arm64"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)][object]$Body
    )

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType "application/json"
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Get-ContentSha {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    $escapedPath = [uri]::EscapeDataString($Path).Replace("%2F", "/")
    $uri = "https://api.github.com/repos/$Owner/$Repo/contents/$escapedPath?ref=$Branch"

    try {
        $content = Invoke-Gh -Method Get -Uri $uri
        return $content.sha
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

Write-Host "Authenticating token..."
$viewer = Invoke-Gh -Method Get -Uri "https://api.github.com/user"
$owner = $viewer.login
Write-Host "Authenticated as $owner"

Write-Host "Creating fork '$RepoName' from benbuck/rbtray..."
$fork = Invoke-Gh -Method Post -Uri "https://api.github.com/repos/benbuck/rbtray/forks" -Body @{
    name = $RepoName
}

$repoFullName = $fork.full_name
Write-Host "Fork requested: $repoFullName"

Write-Host "Waiting for fork branch data..."
$repo = $null
for ($i = 0; $i -lt 30; $i++) {
    try {
        $repo = Invoke-Gh -Method Get -Uri "https://api.github.com/repos/$owner/$RepoName"
        if ($repo.default_branch) { break }
    } catch {
        Start-Sleep -Seconds 2
        continue
    }
    Start-Sleep -Seconds 2
}

if (-not $repo -or -not $repo.default_branch) {
    throw "Fork did not become ready in time."
}

$branch = $repo.default_branch
Write-Host "Using default branch: $branch"

foreach ($relativePath in $filesToPublish) {
    $fullPath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "File not found: $fullPath"
    }

    $content = Get-Content -LiteralPath $fullPath -Raw
    $contentB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $existingSha = Get-ContentSha -Owner $owner -Repo $RepoName -Path $relativePath -Branch $branch

    $body = @{
        message = "Add ARM64 build support and workflow"
        content = $contentB64
        branch  = $branch
    }
    if ($existingSha) {
        $body.sha = $existingSha
    }

    $escapedPath = [uri]::EscapeDataString($relativePath).Replace("%2F", "/")
    $uri = "https://api.github.com/repos/$owner/$RepoName/contents/$escapedPath"
    Invoke-Gh -Method Put -Uri $uri -Body $body | Out-Null
    Write-Host "Published $relativePath"
}

Write-Host "Triggering GitHub Actions workflow..."
Invoke-Gh -Method Post -Uri "https://api.github.com/repos/$owner/$RepoName/actions/workflows/build-arm64.yml/dispatches" -Body @{
    ref = $branch
} | Out-Null

Write-Host ""
Write-Host "Done."
Write-Host "Repository: https://github.com/$owner/$RepoName"
Write-Host "Actions:    https://github.com/$owner/$RepoName/actions"
