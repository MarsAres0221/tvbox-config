$ErrorActionPreference = "Stop"

$repo = "MarsAres0221/tvbox-config"
$branch = "master"
$files = @("DC.json", "singles.json", "config.json")

foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        throw "Missing file: $file"
    }

    $json = Get-Content -Raw -Encoding UTF8 $file
    $null = $json | ConvertFrom-Json
    Write-Host "OK JSON: $file"
}

Write-Host "`nGit status:"
git status --short --branch

Write-Host "`nRemotes:"
git remote -v

$remoteUrl = git remote get-url --push github
if ($remoteUrl -notmatch "github\.com[:/]+MarsAres0221/tvbox-config(\.git)?$") {
    throw "Remote 'github' does not point to MarsAres0221/tvbox-config: $remoteUrl"
}

Write-Host "`nPushing to GitHub..."
git push github $branch
if ($LASTEXITCODE -ne 0) {
    throw "GitHub push failed. Create a public GitHub repository first: https://github.com/new"
}

Write-Host "`nRefreshing jsDelivr cache..."
foreach ($file in @("DC.json", "singles.json")) {
    $url = "https://purge.jsdelivr.net/gh/$repo@$branch/$file"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        Write-Host "Purged: $file"
    } catch {
        Write-Warning "Failed to purge ${file}: $($_.Exception.Message)"
    }
}

Write-Host "`nTesting CDN URLs..."
foreach ($file in @("DC.json", "singles.json")) {
    $url = "https://cdn.jsdelivr.net/gh/$repo@$branch/$file"
    $content = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
    $count = if ($content.urls) { $content.urls.Count } else { 0 }
    Write-Host "$url"
    Write-Host "  urls: $count"
}

Write-Host "`nDone."
