$ErrorActionPreference = "Continue"

$headers = @{
    "User-Agent" = "okhttp/3.15"
    "Accept" = "application/json,text/plain,*/*"
}

function ConvertFrom-TVBoxJson {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text -split "`n"
    $withoutLineComments = foreach ($line in $lines) {
        if ($line -match "^\s*//") { continue }
        $line
    }

    ($withoutLineComments -join "`n") | ConvertFrom-Json
}

function Test-TextUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $headers -TimeoutSec 25 -MaximumRedirection 5
        return [pscustomobject]@{
            Ok = $true
            Status = [int]$resp.StatusCode
            ContentType = [string]$resp.Headers["Content-Type"]
            Length = [int]$resp.RawContentLength
            Text = [string]$resp.Content
            Error = $null
        }
    } catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        return [pscustomobject]@{
            Ok = $false
            Status = $status
            ContentType = $null
            Length = 0
            Text = $null
            Error = $_.Exception.Message
        }
    }
}

function Resolve-ConfigUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Value -match "^(clan|assets)://") {
        return $null
    }

    $plain = ($Value -split ";")[0]
    if ($plain -match "^https?://") {
        return $plain
    }

    if ($plain.StartsWith("./") -or $plain.StartsWith("../") -or $plain.StartsWith("/")) {
        try {
            return ([Uri]::new([Uri]$BaseUrl, $plain)).AbsoluteUri
        } catch {
            return $null
        }
    }

    return $null
}

function Test-ConfigCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $r = Test-TextUrl -Url $Url
    $kind = "unreachable"
    $sites = 0
    $nestedUrls = @()
    $spider = $null
    $spiderStatus = $null
    $score = 0
    $note = $r.Error

    if ($r.Ok) {
        $score += 1
        $text = $r.Text.TrimStart()
        if ($text -match "<!DOCTYPE html|<html") {
            $kind = "html"
            $note = "Returned HTML instead of config"
        } else {
            try {
                $json = ConvertFrom-TVBoxJson -Text $r.Text
                if ($json.urls) {
                    $kind = "multi-repo"
                    $nestedUrls = @($json.urls)
                    $sites = $nestedUrls.Count
                    $score += 2
                } elseif ($json.sites) {
                    $kind = "tvbox-config"
                    $sites = @($json.sites).Count
                    if ($sites -gt 0) { $score += 3 }
                } elseif ($json.msg -or $json.state) {
                    $kind = "api-error"
                    $note = "msg=$($json.msg); state=$($json.state)"
                } else {
                    $kind = "json-no-sites"
                }

                if ($json.spider) {
                    $spider = [string]$json.spider
                    $spiderUrl = Resolve-ConfigUrl -BaseUrl $Url -Value $spider
                    if ($spiderUrl) {
                        $sr = Test-TextUrl -Url $spiderUrl
                        $spiderStatus = $sr.Status
                        if ($sr.Ok) {
                            $score += 2
                        } else {
                            $note = "Spider not reachable: $($sr.Error)"
                        }
                    } else {
                        $spiderStatus = "local-or-unsupported"
                    }
                }
            } catch {
                $kind = "invalid-json"
                $note = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        Name = $Name
        Url = $Url
        Source = $Source
        Status = $r.Status
        Kind = $kind
        Sites = $sites
        SpiderStatus = $spiderStatus
        Score = $score
        Note = $note
        NestedUrls = $nestedUrls
    }
}

$queue = New-Object System.Collections.Generic.Queue[object]
$seen = [System.Collections.Generic.HashSet[string]]::new()

foreach ($file in @("DC.json", "singles.json")) {
    $list = Get-Content -Raw -Encoding UTF8 $file | ConvertFrom-Json
    foreach ($entry in $list.urls) {
        $queue.Enqueue([pscustomobject]@{
            Name = [string]$entry.name
            Url = [string]$entry.url
            Source = $file
            Depth = 0
        })
    }
}

$results = @()
$maxDepth = 1
$maxCandidates = 80

while ($queue.Count -gt 0 -and $results.Count -lt $maxCandidates) {
    $item = $queue.Dequeue()
    if (-not $seen.Add($item.Url)) {
        continue
    }

    Write-Host "Testing [$($item.Depth)] $($item.Name) <$($item.Url)>"
    $result = Test-ConfigCandidate -Name $item.Name -Url $item.Url -Source $item.Source
    $results += $result

    if ($item.Depth -lt $maxDepth -and $result.Kind -eq "multi-repo") {
        foreach ($nested in $result.NestedUrls) {
            if ($nested.url) {
                $queue.Enqueue([pscustomobject]@{
                    Name = [string]$nested.name
                    Url = [string]$nested.url
                    Source = "$($item.Source) -> $($item.Name)"
                    Depth = $item.Depth + 1
                })
            }
        }
    }
}

$publicResults = $results | Select-Object Name,Url,Source,Status,Kind,Sites,SpiderStatus,Score,Note
$publicResults | Sort-Object -Property Score, Sites -Descending | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "weekly-report.json"

$good = $publicResults | Where-Object {
    $_.Kind -eq "tvbox-config" -and
    $_.Sites -gt 0 -and
    ($null -eq $_.SpiderStatus -or $_.SpiderStatus -eq 200 -or $_.SpiderStatus -eq "local-or-unsupported")
} | Sort-Object -Property Score, Sites -Descending

$good | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "discovered-sources.json"

Write-Host "`nTop healthy candidates:"
$good | Select-Object -First 20 Name,Url,Sites,SpiderStatus,Score,Source | Format-Table -AutoSize

Write-Host "`nSummary:"
[pscustomobject]@{
    Tested = $publicResults.Count
    Healthy = @($good).Count
    Report = (Resolve-Path "weekly-report.json").Path
    Discovered = (Resolve-Path "discovered-sources.json").Path
} | Format-List

Write-Host "`nRunning local source validation..."
& "$PSScriptRoot\validate-sources.ps1"
