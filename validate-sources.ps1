$ErrorActionPreference = "Continue"

$headers = @{
    "User-Agent" = "okhttp/3.15"
    "Accept" = "application/json,text/plain,*/*"
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

function ConvertFrom-TVBoxJson {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text -split "`n"
    $withoutLineComments = foreach ($line in $lines) {
        if ($line -match "^\s*//") { continue }
        $line
    }

    $clean = ($withoutLineComments -join "`n")
    return $clean | ConvertFrom-Json
}

function Test-HttpText {
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

$all = @()
foreach ($listFile in @("DC.json", "singles.json")) {
    $list = Get-Content -Raw -Encoding UTF8 $listFile | ConvertFrom-Json
    foreach ($entry in $list.urls) {
        Write-Host "Testing $($entry.name) <$($entry.url)>"
        $r = Test-HttpText -Url $entry.url

        $kind = "unreachable"
        $sites = 0
        $spider = $null
        $spiderStatus = $null
        $note = $r.Error

        if ($r.Ok) {
            $text = $r.Text.TrimStart()
            if ($text -match "<!DOCTYPE html|<html") {
                $kind = "html"
                $note = "Returned HTML instead of config"
            } else {
                try {
                    $json = ConvertFrom-TVBoxJson -Text $r.Text
                    if ($json.urls) {
                        $kind = "multi-repo"
                        $sites = [int]$json.urls.Count
                    } elseif ($json.sites) {
                        $kind = "tvbox-config"
                        $sites = [int]$json.sites.Count
                    } elseif ($json.msg -or $json.state) {
                        $kind = "api-error"
                        $note = "msg=$($json.msg); state=$($json.state)"
                    } else {
                        $kind = "json-no-sites"
                    }

                    if ($json.spider) {
                        $spider = [string]$json.spider
                        $spiderUrl = Resolve-ConfigUrl -BaseUrl $entry.url -Value $spider
                        if ($spiderUrl) {
                            $sr = Test-HttpText -Url $spiderUrl
                            $spiderStatus = $sr.Status
                            if (-not $sr.Ok) {
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

        $all += [pscustomobject]@{
            List = $listFile
            Name = $entry.name
            Url = $entry.url
            Status = $r.Status
            Kind = $kind
            Sites = $sites
            SpiderStatus = $spiderStatus
            Note = $note
        }
    }
}

$all | Format-Table -AutoSize
$all | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "validation-report.json"

$bad = $all | Where-Object {
    $_.Kind -notin @("tvbox-config", "multi-repo") -or
    ($_.Kind -eq "tvbox-config" -and $_.Sites -le 0) -or
    ($_.SpiderStatus -is [int] -and $_.SpiderStatus -ge 400)
}

Write-Host "`nBad or suspicious entries: $($bad.Count)"
if ($bad.Count -gt 0) {
    $bad | Format-Table List,Name,Status,Kind,Sites,SpiderStatus,Note -AutoSize
}
