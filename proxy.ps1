<#
.SYNOPSIS
copilot-go - OpenCode Go models in VS 2026 GitHub Copilot.
Pure PowerShell (Windows built-in) without external dependencies.

.DESCRIPTION
Runs an Ollama-compatible HTTP proxy at localhost:11435.
VS Copilot connects as an "Ollama" provider. The proxy
translates requests and forwards them to opencode.ai.

.PARAMETER Port
Port to listen on (default 11435). Falls back to env:PORT,
auto-increments if taken.
.PARAMETER Update
Check for updates and self-update from GitHub.
.PARAMETER Log
Enable request traffic logging to logs/traffic.log.
#>
param([int]$Port = 0, [switch]$Update, [switch]$Log)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

# Resolve port: param > env > default
if ($Port -eq 0) { $Port = if ($env:PORT) { [int]$env:PORT } else { 11435 } }
$REPO = "jp64k/copilot-go"
$OPENCODE_BASE = "https://opencode.ai/zen/go/v1"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$KEY_FILE = Join-Path $SCRIPT_DIR ".opencode_go_key"
$VERSION_FILE = Join-Path $SCRIPT_DIR ".version"
$MODELS_CACHE = Join-Path $SCRIPT_DIR ".models_cache.json"

function Get-HarnessFile($mode) {
    Join-Path $SCRIPT_DIR ".copilot_harness-$mode.txt"
}

function Detect-HarnessMode($systemContent) {
    if ($systemContent -match "automated coding agent") { return "agent" }
    if ($systemContent -match "planning assistant") { return "plan" }
    if ($systemContent -match "Markdown formatting") { return "ask" }
    return "agent"
}

# models.dev cache — auto-refreshes every 12h

function Sync-ModelsCache {
    $stale = $true
    if (Test-Path $MODELS_CACHE) {
        $age = (Get-Date) - (Get-Item $MODELS_CACHE).LastWriteTime
        if ($age.TotalHours -lt 12) { $stale = $false }
    }
    if ($stale) {
        try {
            Write-Host "  Fetching models from models.dev..."
            $data = $HttpClient.GetStringAsync("https://models.dev/api.json").Result
            Set-Content -Path $MODELS_CACHE -Value $data -NoNewline
            Write-Host "  Models refreshed ($([math]::Round($data.Length/1024)) KB)"
            Write-Log "MODELS refreshed ($($data.Length) bytes)"
        } catch {
            Write-Log "MODELS fetch err: $_"
        }
    }
    if (Test-Path $MODELS_CACHE) {
        try {
            $script:ModelLookup = @{}
            $all = Get-Content $MODELS_CACHE -Raw | ConvertFrom-Json
            foreach ($p in $all.PSObject.Properties) {
                $providerId = $p.Name
                $provider = $p.Value
                foreach ($mid in $provider.models.PSObject.Properties) {
                    $m = $mid.Value
                    $shortKey = $m.id
                    $fullKey = "$providerId/$shortKey"
                    if (-not $script:ModelLookup[$fullKey]) {
                        $display = $m.name
                        if ($display -match '^[a-z0-9][-a-z0-9.]*$' -and $display -eq $shortKey) { $display = $null }
                        $entry = @{
                            display = $display
                            family = if ($m.family) { $m.family } else { $shortKey }
                            context_length = if ($m.limit.context) { $m.limit.context } else { 131072 }
                            capabilities = @()
                        }
                        if ($m.reasoning) { $entry.capabilities += "thinking" }
                        if ($m.tool_call) { $entry.capabilities += "tools" }
                        $entry.capabilities += "completion"
                        $script:ModelLookup[$fullKey] = $entry
                        if (-not $script:ModelLookup[$shortKey]) {
                            $script:ModelLookup[$shortKey] = $entry
                        }
                    }
                }
            }
            Write-Log "MODELS lookup built ($($script:ModelLookup.Count) entries)"
            $script:DISPLAY_TO_ID = @{}
            foreach ($mid in $MODEL_INFO.Keys) {
                $d = Get-ModelDisplay $mid
                $script:DISPLAY_TO_ID[$d] = @($mid, "")
                $script:DISPLAY_TO_ID["$mid" + ":cloud"] = @($mid, "")
                $script:DISPLAY_TO_ID[$mid] = @($mid, "")
                foreach ($lvl in (Get-ThinkingModes $mid)) {
                    $script:DISPLAY_TO_ID[(Get-ModelDisplay $mid $lvl)] = @($mid, $lvl)
                    $script:DISPLAY_TO_ID["$mid" + ":cloud:" + $lvl] = @($mid, $lvl)
                    $script:DISPLAY_TO_ID["$mid" + ":" + $lvl] = @($mid, $lvl)
                }
            }
            foreach ($key in $script:ModelLookup.Keys) {
                $mid = ($key -split "/")[-1]
                $isOcGo = $key.StartsWith("opencode-go/")
                if ($isOcGo -or -not $script:DISPLAY_TO_ID[$mid]) {
                    $d = Get-ModelDisplay $mid
                    if ($isOcGo -or -not $script:DISPLAY_TO_ID[$d]) {
                        $script:DISPLAY_TO_ID[$d] = @($mid, "")
                        $script:DISPLAY_TO_ID["$mid" + ":cloud"] = @($mid, "")
                        $script:DISPLAY_TO_ID[$mid] = @($mid, "")
                        foreach ($lvl in (Get-ThinkingModes $mid)) {
                            $script:DISPLAY_TO_ID[(Get-ModelDisplay $mid $lvl)] = @($mid, $lvl)
                            $script:DISPLAY_TO_ID["$mid" + ":cloud:" + $lvl] = @($mid, $lvl)
                            $script:DISPLAY_TO_ID["$mid" + ":" + $lvl] = @($mid, $lvl)
                        }
                    }
                }
            }
        } catch {
            $script:ModelLookup = @{}
            $script:DISPLAY_TO_ID = @{}
            Write-Log "MODELS parse err: $_"
        }
    } else {
        $script:ModelLookup = @{}
        $script:DISPLAY_TO_ID = @{}
    }
}

function Get-ModelMeta($modelId) {
    if ($script:ModelLookup["opencode-go/$modelId"]) { return $script:ModelLookup["opencode-go/$modelId"] }
    if ($script:ModelLookup["opencode/$modelId"]) { return $script:ModelLookup["opencode/$modelId"] }
    if ($script:ModelLookup[$modelId]) { return $script:ModelLookup[$modelId] }
    foreach ($key in $script:ModelLookup.Keys) {
        if ($key.EndsWith("/$modelId")) { return $script:ModelLookup[$key] }
    }
    return $null
}

function Lookup-ModelInfo($modelId) {
    $m = Get-ModelMeta $modelId
    if ($m) { return $m }
    return @{}
}

# API key management

function Get-ApiKeys {
    if (Test-Path $KEY_FILE) {
        $raw = (Get-Content $KEY_FILE -Raw) -replace "`r`n", "`n"
        $lines = @($raw -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        if ($lines) { return ,@($lines) }
    }
    if ($env:OPENCODE_GO_API_KEY) {
        $keys = $env:OPENCODE_GO_API_KEY -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        if ($keys) { return ,@($keys) }
    }
    return ,@()
}

function Get-CurrentApiKey {
    if ($script:ApiKeys.Count -eq 0) { return "" }
    return $script:ApiKeys[$script:CurrentKeyIndex]
}

function Rotate-ApiKey {
    if ($script:ApiKeys.Count -le 1) { return }
    $script:CurrentKeyIndex = ($script:CurrentKeyIndex + 1) % $script:ApiKeys.Count
    Write-Log "KEY rotate -> $(($script:CurrentKeyIndex + 1))/$($script:ApiKeys.Count)"
}

function Mask-Key($key) {
    $s = "$key"
    if ($s.Length -le 8) { return $s.Substring(0, [Math]::Min(3, $s.Length)) + "..." }
    return $s.Substring(0, 6) + "..."
}

function Prompt-ApiKey {
    Write-Host "  No OpenCode Go API key found."
    Write-Host "  Get yours at: https://opencode.ai/auth"
    Write-Host "  For multiple keys, paste them one per line (press Enter twice to finish):`n"
    $lines = @()
    while ($true) {
        $line = Read-Host "  Key"
        if (-not $line) { break }
        $lines += $line.Trim()
    }
    if ($lines.Count -gt 0) {
        Set-Content -Path $KEY_FILE -Value ($lines -join "`n") -NoNewline
        $msg = if ($lines.Count -eq 1) { "1 key" } else { "$($lines.Count) keys" }
        Write-Host "  Saved $msg to $KEY_FILE`n"
        return ,@($lines)
    }
    return ,@()
}

# Versioning and self-update

function Get-CurrentSha {
    if (Test-Path $VERSION_FILE) { return (Get-Content $VERSION_FILE -Raw).Trim() }
    return ""
}

function Check-Updates {
    $current = Get-CurrentSha
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "https://api.github.com/repos/$REPO/commits/main")
        $req.Headers.Add("User-Agent", "copilot-go")
        $resp = $HttpClient.SendAsync($req).Result
        $body = $resp.Content.ReadAsStringAsync().Result
        if (-not $resp.IsSuccessStatusCode -or -not $body) { throw "GitHub API returned $($resp.StatusCode)" }
        $data = $body | ConvertFrom-Json
        $latest = $data.sha
        return @{ Update = ($current -and $latest -and $current -ne $latest); Sha = $latest; Short = $latest.Substring(0, 7) }
    } catch {
        Write-Log "UPDATE check err: $_"
        return @{ Update = $false; Sha = ""; Short = "" }
    }
}

function Invoke-SelfUpdate($sha) {
    Write-Host "  Downloading latest..."
    $zipUrl = "https://github.com/$REPO/archive/$sha.zip"
    $zipPath = Join-Path $SCRIPT_DIR "_update.zip"
    try {
        $bytes = $HttpClient.GetByteArrayAsync($zipUrl).Result
        [System.IO.File]::WriteAllBytes($zipPath, $bytes)
        Write-Host "  Extracting..."
        $extractDir = Join-Path $SCRIPT_DIR "_update"
        if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        $srcDir = Get-ChildItem $extractDir | Select-Object -First 1
        $srcPath = Join-Path $srcDir.FullName "*"
        Copy-Item -Path $srcPath -Destination $SCRIPT_DIR -Recurse -Force
        Remove-Item -Recurse -Force $extractDir
        Remove-Item $zipPath
        Set-Content -Path $VERSION_FILE -Value $sha -NoNewline
        Write-Host "  Updated to #$($sha.Substring(0,7)). Restart proxy to apply.`n"
    } catch {
        Write-Host "  Update failed: $_"
        if (Test-Path $zipPath) { Remove-Item $zipPath }
        if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    }
}

$MODEL_INFO = @{}

$THINKING_TAG_LABEL = @{ LOW="Low"; MEDIUM="Mid"; HIGH="High"; MAXIMUM="Max" }
$THINKING_TAG_PARAMS = @{ LOW="low"; MEDIUM="medium"; HIGH="high"; MAXIMUM="max" }
$THINKING_TAG_SHORT = @{
    L="LOW"; M="MEDIUM"; H="HIGH"; X="MAXIMUM"
    LO="LOW"; MD="MEDIUM"; HI="HIGH"; MX="MAXIMUM"
    MED="MEDIUM"; MAX="MAXIMUM"
}

function Get-ThinkingModes($modelId) {
    $cid = ($modelId -replace ":.*", "").Trim().ToLower()
    $exclude = @("glm","kimi","k2p","minimax","qwen","big-pickle","hy3","ring","nemotron",
                 "deepseek-chat","deepseek-reasoner","deepseek-r1","deepseek-v3")
    foreach ($e in $exclude) { if ($cid.Contains($e)) { return @() } }
    if ($cid.Contains("deepseek-v4")) { return @("LOW","MEDIUM","HIGH","MAXIMUM") }
    if ($cid.Contains("mimo") -and ((Lookup-ModelInfo $modelId).capabilities -contains "thinking")) {
        return @("LOW","MEDIUM","HIGH")
    }
    return @()
}

function Format-Context($n) {
    if ($n -ge 1000000) { return "$([math]::Floor($n/1000000))M" }
    if ($n -ge 1000) { return "$([math]::Floor($n/1000))K" }
    return "$n"
}

function Get-ModelDisplay($modelId, $level="") {
    $info = Lookup-ModelInfo $modelId
    if ($info.display) {
        $name = $info.display
    } else {
        $name = ($modelId -replace "-", " ") -replace '([a-z]{3,})(\d)', '$1 $2'
        $name = [regex]::Replace($name, '\b\w', { param($m) $m.Value.ToUpper() })
    }
    $ctx = if ($info.context_length) { " [$(Format-Context $info.context_length)]" } else { "" }
    $base = "$name$ctx"
    $label = $THINKING_TAG_LABEL[$level]
    if ($label) { return "$base - $label" } else { return $base }
}

function Normalize-Model($raw) {
    $clean = ($raw -replace ":latest$", "").Trim()
    if (-not $clean) { return @("", "") }

    # VSCode format: deepseek-v4-pro/1_(low)
    if ($clean -match '^(.+?)/(\d)_\(?(low|medium|high|maximum|xhigh)\)?$') {
        $tag = $Matches[3].ToUpper()
        return @(("$($Matches[1].Trim()):latest"), $(if ($tag -eq "MAXIMUM") { $tag } else { $tag }))
    }
    # Bracket format: DeepSeek V4 Pro [HIGH]
    if ($clean -match '^(.+?)[\-\-: \u2009]\s*\[?(L|M|H|X|LOW|MEDIUM|HIGH|MAXIMUM|MED|MAX|XHIGH|MINIMAL|NONE|LO|MD|HI|MX)\]\s*$') {
        $rawTag = $Matches[2].ToUpper()
        $tag = if ($THINKING_TAG_SHORT[$rawTag]) { $THINKING_TAG_SHORT[$rawTag] } else { $rawTag }
        return @(("$($Matches[1].Trim()):latest"), $tag)
    }
    # Encoded suffix
    foreach ($level in $THINKING_TAG_PARAMS.Keys) {
        if ($clean -like "*:$level") {
            $mid = $clean.Substring(0, $clean.Length - $level.Length - 1) -replace ":cloud",""
            if ((Lookup-ModelInfo $mid).Count -gt 0) { return @($mid, $level) }
        }
        $ll = $level.ToLower()
        if ($clean -like "*:$ll") {
            $mid = $clean.Substring(0, $clean.Length - $ll.Length - 1) -replace ":cloud",""
            if ((Lookup-ModelInfo $mid).Count -gt 0) { return @($mid, $level) }
        }
    }
    # Display name lookup
    if ($script:DISPLAY_TO_ID[$clean]) { return $script:DISPLAY_TO_ID[$clean] }
    foreach ($display in $script:DISPLAY_TO_ID.Keys) {
        if ($display.StartsWith($clean)) { return $script:DISPLAY_TO_ID[$display] }
    }
    $stripped = $clean -replace ":cloud",""
    if ($script:DISPLAY_TO_ID[$stripped]) { return $script:DISPLAY_TO_ID[$stripped] }
    return @($stripped, "")
}

# Upstream OpenCode Go HTTP client

$HttpClient = [System.Net.Http.HttpClient]::new()
$HttpClient.Timeout = [TimeSpan]::FromSeconds(300)

function Invoke-UpstreamGet($path, $apiKey) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$OPENCODE_BASE$path")
    $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    $req.Headers.Add("User-Agent", "copilot-go")
    $req.Headers.ConnectionClose = $true
    $resp = $HttpClient.SendAsync($req).Result
    $body = $resp.Content.ReadAsStringAsync().Result
    if (-not $resp.IsSuccessStatusCode) { throw "Upstream error $($resp.StatusCode): $body" }
    return $body | ConvertFrom-Json
}

function Get-UpstreamPath($modelId) {
    $cid = $modelId.ToLower()
    if ($cid.Contains("qwen") -or $cid.Contains("minimax")) { return "/messages" }
    return "/chat/completions"
}

function ConvertTo-AnthropicBody($body) {
    $system = ""
    $msgs = [System.Collections.Generic.List[object]]::new()
    foreach ($msg in $body.messages) {
        if ($msg.role -eq "system") {
            if ($msg.content) { $system += $(if ($system) { "`n" } else { "" }) + $msg.content }
        } else {
            $m = @{ role = $msg.role; content = $msg.content }
            if ($msg.tool_calls) {
                $tc = [System.Collections.Generic.List[object]]::new()
                foreach ($call in $msg.tool_calls) {
                    $tc.Add(@{ id = $call.id; type = "function"; function = @{ name = $call.function.name; arguments = $call.function.arguments } })
                }
                $m.tool_calls = $tc
            }
            if ($msg.tool_call_id) { $m.tool_call_id = $msg.tool_call_id }
            $msgs.Add($m)
        }
    }
    $result = @{ model = $body.model; messages = $msgs; max_tokens = $(if ($body.max_tokens) { $body.max_tokens } else { 4096 }) }
    if ($system) { $result.system = $system }
    if ($body.stream) { $result.stream = $body.stream }
    if ($body.tools) {
        $atools = [System.Collections.Generic.List[object]]::new()
        foreach ($t in $body.tools) {
            $at = @{ name = $t.function.name; description = $t.function.description }
            if ($t.function.parameters) { $at.input_schema = $t.function.parameters }
            $atools.Add($at)
        }
        $result.tools = $atools
    }
    if ($body.temperature) { $result.temperature = $body.temperature }
    return $result
}

function ConvertFrom-AnthropicResponse($resp, $modelId) {
    $text = ""; $thinking = ""; $toolCalls = @()
    if ($resp.content) {
        foreach ($c in $resp.content) {
            if ($c.type -eq "text") { $text += $c.text }
            elseif ($c.type -eq "thinking") { $thinking += $c.thinking }
            elseif ($c.type -eq "tool_use") {
                $toolCalls += @{ id = $c.id; type = "function"; function = @{ name = $c.name; arguments = ($c.input | ConvertTo-Json -Depth 5 -Compress) } }
            }
        }
    }
    $msg = @{ role = $resp.role; content = $(if ($text) { $text } else { $null }) }
    if ($thinking) { $msg.reasoning_content = $thinking }
    if ($toolCalls.Count -gt 0) { $msg.tool_calls = $toolCalls }
    $usage = if ($resp.usage) { @{
        prompt_tokens = $resp.usage.input_tokens
        completion_tokens = $resp.usage.output_tokens
        total_tokens = $resp.usage.input_tokens + $resp.usage.output_tokens
    }} else { $null }
    $finish = if ($resp.stop_reason -eq "end_turn") { "stop" } elseif ($resp.stop_reason -eq "tool_use") { "tool_calls" } elseif ($resp.stop_reason -eq "max_tokens") { "length" } else { "stop" }
    $result = @{
        id = $resp.id; object = "chat.completion"; model = $modelId
        choices = @(@{ index = 0; message = $msg; finish_reason = $finish })
    }
    if ($usage) { $result.usage = $usage }
    return $result
}

function Convert-AnthropicChunk($json, $refId, $refModel) {
    try { $a = $json | ConvertFrom-Json } catch { return $null }
    $type = $a.type
    if ($type -eq "message_start") {
        return @{ id = $a.message.id; model = $a.message.model; object = "chat.completion.chunk"; choices = @(@{ index = 0; delta = @{ role = "assistant" }; finish_reason = $null }) }
    }
    if ($type -eq "content_block_start") {
        $cb = $a.content_block
        if ($cb.type -eq "text") { return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ content = "" }; finish_reason = $null }) } }
        if ($cb.type -eq "thinking") { return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ reasoning_content = "" }; finish_reason = $null }) } }
        if ($cb.type -eq "tool_use") { return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ tool_calls = @(@{ index = 0; id = $cb.id; type = "function"; function = @{ name = $cb.name; arguments = "" } }) }; finish_reason = $null }) } }
    }
    if ($type -eq "content_block_delta") {
        $d = $a.delta
        if ($d.type -eq "text_delta") { return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ content = $d.text }; finish_reason = $null }) } }
        if ($d.type -eq "thinking_delta") { return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ reasoning_content = $d.thinking }; finish_reason = $null }) } }
        if ($d.type -eq "input_json_delta") {
            $tc = @(@{ index = 0; function = @{ arguments = $d.partial_json } })
            return @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{ tool_calls = $tc }; finish_reason = $null }) }
        }
    }
    if ($type -eq "content_block_stop") { return $null }
    if ($type -eq "message_delta") {
        $finish = if ($a.delta.stop_reason -eq "end_turn") { "stop" } elseif ($a.delta.stop_reason -eq "tool_use") { "tool_calls" } else { "stop" }
        $usage = if ($a.usage) { @{ prompt_tokens = $a.usage.input_tokens; completion_tokens = $a.usage.output_tokens; total_tokens = $a.usage.input_tokens + $a.usage.output_tokens } } else { $null }
        $result = @{ id = $refId; object = "chat.completion.chunk"; model = $refModel; choices = @(@{ index = 0; delta = @{}; finish_reason = $finish }) }
        if ($usage) { $result.usage = $usage }
        return $result
    }
    if ($type -eq "message_stop") { return $null }
    return $null
}

function Invoke-UpstreamPost($path, $bodyJson, $apiKey) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$OPENCODE_BASE$path")
    $req.Content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, "application/json")
    if ($path -eq "/messages") {
        $req.Headers.Add("x-api-key", $apiKey)
    } else {
        $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    }
    $req.Headers.Add("User-Agent", "copilot-go")
    $req.Headers.ConnectionClose = $true
    return $HttpClient.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
}

# HTTP server: TcpListener with manual HTTP parsing

$LOG_DIR = Join-Path $SCRIPT_DIR "logs"
$LOG_FILE = Join-Path $LOG_DIR "traffic.log"

function Write-Log($entry) {
    if (-not $script:Log) { return }
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR | Out-Null }
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff") + " " + $entry
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

function Read-HttpRequest($stream) {
    # Read in bulk chunks until \r\n\r\n found, then parse headers + body
    $data = [System.Collections.Generic.List[byte]]::new()
    $buf = New-Object byte[] 8192
    $bodyBytes = $null
    $method = ""; $path = ""; $headers = @{}; $contentLength = 0

    while ($true) {
        $n = $stream.Read($buf, 0, 8192)
        if ($n -eq 0) { break }
        $chunk = New-Object byte[] $n
        [Array]::Copy($buf, 0, $chunk, 0, $n)
        $data.AddRange($chunk)

        # Search for \r\n\r\n in accumulated data
        $arr = $data.ToArray()
        $headerEnd = $null
        for ($i = 0; $i -le $arr.Length - 4; $i++) {
            if ($arr[$i] -eq 13 -and $arr[$i+1] -eq 10 -and $arr[$i+2] -eq 13 -and $arr[$i+3] -eq 10) {
                $headerEnd = $i; break
            }
        }
        if ($headerEnd -ne $null) {
            # Parse headers
            $headerText = [System.Text.Encoding]::ASCII.GetString($arr, 0, $headerEnd)
            $lines = $headerText -split "`r`n"
            if ($lines.Count -gt 0) {
                $rl = $lines[0] -split ' '
                $method = $rl[0]; $path = $rl[1]
            }
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -eq "") { continue }
                $ci = $line.IndexOf(':')
                if ($ci -gt 0) {
                    $k = $line.Substring(0, $ci).Trim()
                    $v = $line.Substring($ci + 1).Trim()
                    $headers[$k] = $v
                    if ($k -eq "Content-Length") { $contentLength = [int]$v }
                }
            }
            # Extract body bytes that were already read past headers
            $bodyStart = $headerEnd + 4
            $remaining = $arr.Length - $bodyStart
            if ($contentLength -gt 0) {
                $bodyBytes = New-Object byte[] $contentLength
                if ($remaining -gt 0) {
                    $copyLen = [Math]::Min($remaining, $contentLength)
                    [Array]::Copy($arr, $bodyStart, $bodyBytes, 0, $copyLen)
                    $bodyRead = $copyLen
                } else { $bodyRead = 0 }
                # Read remaining body if any
                while ($bodyRead -lt $contentLength) {
                    $n2 = $stream.Read($bodyBytes, $bodyRead, $contentLength - $bodyRead)
                    if ($n2 -eq 0) { break }
                    $bodyRead += $n2
                }
            }
            break
        }
    }
    if (-not $method) { return $null }
    return @{
        Method = $method; Path = $path; Headers = $headers
        BodyBytes = $bodyBytes; ContentLength = $contentLength; Stream = $stream
    }
}

function Write-Response($stream, $statusCode, $statusText, $contentType, $body) {
    $bodyBytes = if ($body) { [System.Text.Encoding]::UTF8.GetBytes($body) } else { @() }
    Write-Log "RESP $statusCode $contentType  len=$($bodyBytes.Length)  body=$($body.Substring(0,[Math]::Min(200,$body.Length)))"
    $headers = "HTTP/1.1 $statusCode $statusText`r`n" +
               "Content-Type: $contentType`r`n" +
               "Content-Length: $($bodyBytes.Length)`r`n" +
               "Connection: close`r`n" +
               "Server: copilot-go`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $stream.Flush()
}

function Write-Error($stream, $msg, $statusCode=500) {
    Write-Log "RESP $statusCode ERROR  $msg"
    Write-Response $stream $statusCode "Error" "application/json; charset=utf-8" "{`"error`":`"$msg`"}"
}

# Route handlers: /api/tags, /api/show, /v1/chat/completions

function Get-TagsJson($apiKey) {
    $data = Invoke-UpstreamGet "/models" $apiKey
    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $data.data) {
        $mid = $m.id
        $info = Lookup-ModelInfo $mid
        $models.Add((New-ModelEntry (Get-ModelDisplay $mid) ("$mid" + ":cloud") $mid $info))
        foreach ($level in (Get-ThinkingModes $mid)) {
            $models.Add((New-ModelEntry (Get-ModelDisplay $mid $level) ("$mid" + ":cloud:" + $level) $mid $info))
        }
    }
    return (@{ models = $models } | ConvertTo-Json -Depth 4 -Compress)
}

function New-ModelEntry($name, $model, $remote, $info) {
    return @{
        name = $name; model = $model; remote_model = $remote
        remote_host = "https://opencode.ai"
        modified_at = "2026-05-22T00:00:00+02:00"; size = 384
        digest = "sha256:" + "0" * 64
        details = @{
            parent_model = ""; format = ""
            family = if ($info.family) { $info.family } else { $remote }
            families = if ($info.family) { [string[]]@($info.family) } else { $null }
            parameter_size = ""; quantization_level = ""
        }
    }
}

function Get-ShowJson($body, $apiKey) {
    $raw = if ($body.model) { $body.model } else { $body.name }
    $result = Normalize-Model $raw
    $modelName = $result[0]
    $info = Lookup-ModelInfo $modelName
    $family = if ($info.family) { $info.family } else { $modelName }
    $ctx = if ($info.context_length) { $info.context_length } else { 131072 }
    $mi = @{ "general.parameter_count" = if ($info.param_count) { $info.param_count } else { 0 } }
    if ($family) {
        $mi["general.architecture"] = $family
        $mi["$family.context_length"] = $ctx
    }
    $caps = if ($info.capabilities) { $info.capabilities } else { @("completion","tools") }
    return (@{
        details = @{ parent_model=$modelName; format=""; family=$family; families=$null
                     parameter_size="$($info.param_count)"; quantization_level="" }
        model_info = $mi; capabilities = $caps; modified_at = "2026-05-22T00:00:00Z"
    } | ConvertTo-Json -Depth 3 -Compress)
}

function Handle-Chat($req, $bodyObj, $apiKey) {
    $stream = $req.Stream
    $rawModel = if ($bodyObj.model) { $bodyObj.model } else { "" }
    $result = Normalize-Model $rawModel
    $modelId = $result[0]; $reasoningLevel = $result[1]
    $bodyObj.model = $modelId
    if ($reasoningLevel -and $THINKING_TAG_PARAMS[$reasoningLevel]) {
        $bodyObj | Add-Member -NotePropertyName "reasoning_effort" -NotePropertyValue $THINKING_TAG_PARAMS[$reasoningLevel] -Force
    }
    foreach ($msg in $bodyObj.messages) {
        if ($msg.role -eq "system" -and $msg.content) {
            $mode = Detect-HarnessMode $msg.content
            $hf = Get-HarnessFile $mode
            if (Test-Path $hf) {
                try {
                    $custom = (Get-Content $hf -Raw).Trim()
                } catch {
                    Write-Log "HARNESS read err: $_"
                    $custom = ""
                }
                if ($custom) {
                    $msg.content = $custom
                    Write-Log "HARNESS injected ($mode, $($custom.Length) chars)"
                }
            } else {
                try {
                    Set-Content -Path $hf -Value $msg.content -NoNewline
                    Write-Log "HARNESS exported ($mode, $($msg.content.Length) chars)"
                } catch {
                    Write-Log "HARNESS export err: $_"
                }
            }
            break
        }
    }
    foreach ($msg in $bodyObj.messages) {
        if ($msg.role -eq "assistant" -and $msg.tool_calls -and (-not (Get-Member -InputObject $msg -Name "reasoning_content" -MemberType Properties))) {
            $msg | Add-Member -NotePropertyName "reasoning_content" -NotePropertyValue "" -Force
        }
    }
    $isStream = $bodyObj.stream -eq $true
    $toolNames = if ($bodyObj.tools) { ($bodyObj.tools | ForEach-Object { $_.function.name }) -join ", " } else { "none" }
    Write-Log "CHAT rawModel=$rawModel modelId=$modelId level=$reasoningLevel msgs=$($bodyObj.messages.Count) tools=[$toolNames] stream=$isStream"
    
    $isAnthropic = (Get-UpstreamPath $modelId) -eq "/messages"
    if ($isAnthropic) {
        $bodyObj = ConvertTo-AnthropicBody $bodyObj
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    $keyIdx = $script:CurrentKeyIndex
    $tried = 0
    $upstream = $null
    while ($tried -lt $script:ApiKeys.Count) {
        $key = $script:ApiKeys[$keyIdx]
        try {
            $upstream = Invoke-UpstreamPost (Get-UpstreamPath $modelId) $bodyJson $key
        } catch {
            Write-Error $stream "Upstream error: $_" 502
            return
        }
        if ($upstream.StatusCode -eq 429) {
            Write-Log "RATELIMIT key=$(Mask-Key $key) rotating..."
            try { $upstream.Dispose() } catch {}
            $tried++; $keyIdx = ($keyIdx + 1) % $script:ApiKeys.Count
            continue
        }
        if (-not $upstream.IsSuccessStatusCode) {
            $errBody = $upstream.Content.ReadAsStringAsync().Result
            $upstream.Dispose()
            Write-Error $stream "Upstream error $($upstream.StatusCode): $errBody" 502
            return
        }
        $script:CurrentKeyIndex = $keyIdx
        break
    }
    if (-not $upstream -or -not $upstream.IsSuccessStatusCode) {
        Write-Error $stream "All API keys exhausted" 429
        return
    }

    try {
    if ($isStream) {
        Relay-Sse $stream $upstream $modelId $isAnthropic
    } else {
        $respBody = $upstream.Content.ReadAsStringAsync().Result
        $respObj = $respBody | ConvertFrom-Json
        if ($isAnthropic) {
            $respObj = ConvertFrom-AnthropicResponse $respObj $modelId
        }
        if (-not (Get-Member -InputObject $respObj -Name "system_fingerprint" -MemberType Properties)) {
            $respObj | Add-Member -NotePropertyName "system_fingerprint" -NotePropertyValue "fp_ollama" -Force
        }
        Write-Response $stream 200 "OK" "application/json; charset=utf-8" ($respObj | ConvertTo-Json -Depth 10 -Compress)
    }
    } finally {
        try { $upstream.Dispose() } catch {}
    }
}

function Relay-Sse($clientStream, $upstreamResp, $modelId, $isAnthropic) {
    $headers = "HTTP/1.1 200 OK`r`n" +
               "Content-Type: text/event-stream`r`n" +
               "Cache-Control: no-cache`r`n" +
               "Connection: close`r`n" +
               "Server: copilot-go`r`n`r`n"
    $clientStream.Write([System.Text.Encoding]::ASCII.GetBytes($headers), 0, $headers.Length)
    $clientStream.Flush()

    $upstreamStream = $upstreamResp.Content.ReadAsStreamAsync().Result
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $charBuf = New-Object char[] 8192
    $buffer = ""
    $readBuf = New-Object byte[] 8192
    $chunkCount = 0; $outputTokens = 0; $tpsTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $tpsLastUpdate = 0
    $antId = ""; $antModel = ""
    try {
        while ($true) {
            $n = $upstreamStream.Read($readBuf, 0, 8192)
            if ($n -eq 0) { break }
            $charCount = $decoder.GetChars($readBuf, 0, $n, $charBuf, 0)
            $buffer += (New-Object string (,$charBuf[0..($charCount - 1)]))

            while ($buffer.Contains("`n`n")) {
                $idx = $buffer.IndexOf("`n`n")
                $block = $buffer.Substring(0, $idx)
                $buffer = $buffer.Substring($idx + 2)
                $lines = $block -split "`n"
                $outLines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $lines) {
                    $s = $line.Trim()
                    if ($s -eq "") { $outLines.Add(""); continue }
                    if (($s -like "data: *" -or $s -like "data:*") -and $s -ne "data: [DONE]") {
                        $deltaJson = if ($s[5] -eq ' ') { $s.Substring(6) } else { $s.Substring(5) }
                        if ($isAnthropic) {
                            $oaChunk = Convert-AnthropicChunk $deltaJson $antId $antModel
                            if ($oaChunk) {
                                if ($oaChunk.id) { $antId = $oaChunk.id; $antModel = $oaChunk.model }
                                $outLines.Add("data: " + ($oaChunk | ConvertTo-Json -Depth 5 -Compress))
                            }
                        } else {
                            $chunkCount++
                            if ($deltaJson -notmatch 'system_fingerprint') {
                                $deltaJson = $deltaJson -replace '^{(.*)', '{ "system_fingerprint":"fp_ollama", $1'
                            }
                            $outLines.Add("data: " + $deltaJson)
                        }
                        if (-not $isAnthropic) {
                            if ($chunkCount -eq 1) {
                                try { $obj = $deltaJson | ConvertFrom-Json } catch { $obj = $null }
                                if ($obj) {
                                    $delta = $obj.choices[0].delta
                                    Write-Log "SSE chunk1 hasContent=$($delta.content -ne $null) hasTools=$($delta.tool_calls -ne $null) finish=$($obj.choices[0].finish_reason)"
                                }
                            }
                            try { $obj2 = $deltaJson | ConvertFrom-Json } catch { $obj2 = $null }
                            if ($obj2 -and $obj2.usage) { $outputTokens = $obj2.usage.completion_tokens }
                        }
                        $curTokens = [Math]::Max($outputTokens, $chunkCount)
                        if (($isAnthropic -or $chunkCount % 5 -eq 0) -and $curTokens -gt 0) {
                            $elapsed = $tpsTimer.Elapsed.TotalSeconds
                            if ($elapsed - $tpsLastUpdate -ge 0.3) {
                                Update-Tps $curTokens $elapsed
                                $tpsLastUpdate = $elapsed
                            }
                        }
                        if (-not $isAnthropic) { $chunkCount++ } else { $chunkCount++ }
                    } else { $outLines.Add($s) }
                }
                $out = ($outLines -join "`n") + "`n`n"
                $outBytes = [System.Text.Encoding]::UTF8.GetBytes($out)
                $clientStream.Write($outBytes, 0, $outBytes.Length)
                $clientStream.Flush()
            }
        }
        if ($buffer.Trim()) {
            $remBytes = [System.Text.Encoding]::UTF8.GetBytes($buffer)
            $clientStream.Write($remBytes, 0, $remBytes.Length)
            $clientStream.Flush()
        }
        Update-Tps ([Math]::Max($outputTokens, $chunkCount)) $tpsTimer.Elapsed.TotalSeconds
        $modelLabel = if ($isAnthropic) { $antModel } else { "" }
        Write-Log "SSE done chunks=$chunkCount tokens=$outputTokens model=$modelLabel"
    } catch {
        Write-Log "SSE err: $_"
    }
    $upstreamStream.Dispose()
}

function Update-Tps($tokens, $elapsedSec) {
    if ($elapsedSec -gt 0 -and $tokens -gt 0) {
        $script:LastTps = [math]::Round($tokens / $elapsedSec, 1)
    }
    $title = "copilot-go"
    if ($script:LastTps) { $title += " [$($script:LastTps) t/s]" }
    $host.UI.RawUI.WindowTitle = $title
}

# Main entry point

function Main {
    if ($Update) {
        $result = Check-Updates
        if ($result.Update) {
            Invoke-SelfUpdate $result.Sha
        } else {
            Write-Host "  Already up to date ($($result.Short))."
        }
        return
    }

    $script:ApiKeys = Get-ApiKeys
    $script:CurrentKeyIndex = 0
    $currentSha = Get-CurrentSha

    # Sync .version on first run before displaying tag
    if (-not $currentSha) {
        Check-Updates | Out-Null
        $currentSha = Get-CurrentSha
    }

    $tag = if ($currentSha) { $currentSha.Substring(0, [Math]::Min(7, $currentSha.Length)) } else { $null }
    $tagStr = if ($tag) { "#$tag" } else { "dev" }

    Write-Host "  copilot-go ($tagStr)"
    Write-Host "  OpenCode Go models in VS 2026 Copilot"
    Write-Host "  https://github.com/$REPO`n"

    Sync-ModelsCache

    if ($script:ApiKeys.Count -eq 0) { $script:ApiKeys = Prompt-ApiKey }
    if ($script:ApiKeys.Count -eq 1) { Write-Host "  Loaded API key: $(Mask-Key $script:ApiKeys[0])" }
    elseif ($script:ApiKeys.Count -gt 1) { Write-Host "  Loaded $($script:ApiKeys.Count) API keys (auto-rotates on rate limit)" }
    else {
        Write-Host "  No API key - models won't load."
        Write-Host "  Set OPENCODE_GO_API_KEY env var or create .opencode_go_key`n"
    }

    $update = Check-Updates
    if ($update.Update) {
        Write-Host "`n  New updates available (latest: #$($update.Short))"
        try { $ans = Read-Host "  Update now? [y/n]" } catch { $ans = "" }
        if ($ans -eq "" -or $ans -eq "y" -or $ans -eq "yes") {
            Invoke-SelfUpdate $update.Sha
        }
    }

    $tries = 0
    $maxTries = 10
    while ($tries -lt $maxTries) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            break
        } catch {
            $tries++
            if ($tries -eq $maxTries) {
                Write-Host "`n  Could not bind to port $Port or nearby — all taken.`n"; return
            }
            $Port++
        }
    }

    Write-Host "`n  Proxy active — Set VS Copilot Ollama endpoint to: http://localhost:$Port"
    Write-Host "  Close this window to stop proxy.`n"
    Write-Log "START port=$Port pid=$PID"
    $host.UI.RawUI.WindowTitle = "copilot-go"

    while ($true) {
        try {
            try {
                $client = $listener.AcceptTcpClient()
                $client.NoDelay = $true
                $client.ReceiveTimeout = 300000
                $client.SendTimeout = 300000
                $stream = $client.GetStream()

                $req = Read-HttpRequest $stream
                if (-not $req) { $client.Close(); continue }

                $method = $req.Method
                $path = $req.Path
                Write-Log "REQ $method $path  CL=$($req.ContentLength)  UA=$($req.Headers['User-Agent'])"

                if ($method -eq "GET" -and $path -eq "/") {
                    Write-Response $stream 200 "OK" "text/plain; charset=utf-8" "Ollama is running"
                }
                elseif ($method -eq "GET" -and $path -eq "/api/tags") {
                    $key = Get-CurrentApiKey
                    if (-not $key) { Write-Error $stream "No API key" 500 }
                    else {
                        try { Write-Response $stream 200 "OK" "application/json; charset=utf-8" (Get-TagsJson $key) }
                        catch { Write-Error $stream $_ 502 }
                    }
                }
                elseif ($method -eq "GET" -and $path -eq "/api/version") {
                    $v = @{version="0.6.5"} | ConvertTo-Json -Compress
                    Write-Response $stream 200 "OK" "application/json; charset=utf-8" $v
                }
                elseif ($method -eq "POST" -and $path -eq "/api/show") {
                    try {
                        $b = if ($req.BodyBytes) { [System.Text.Encoding]::UTF8.GetString($req.BodyBytes) | ConvertFrom-Json } else { @{} }
                        Write-Response $stream 200 "OK" "application/json; charset=utf-8" (Get-ShowJson $b (Get-CurrentApiKey))
                    } catch { Write-Error $stream "Invalid request" 400 }
                }
                elseif ($method -eq "POST" -and $path -eq "/v1/chat/completions") {
                    $key = Get-CurrentApiKey
                    if (-not $key) { Write-Error $stream "No API key" 500 }
                    else {
                        try {
                            $b = if ($req.BodyBytes) { [System.Text.Encoding]::UTF8.GetString($req.BodyBytes) | ConvertFrom-Json } else { @{} }
                            Handle-Chat $req $b $key
                        } catch { Write-Error $stream $_ 500 }
                    }
                }
                elseif ($method -eq "POST" -and ($path -eq "/api/chat" -or $path -eq "/api/generate")) {
                    $key = Get-CurrentApiKey
                    if (-not $key) { Write-Error $stream "No API key" 500 }
                    else {
                        try {
                            $b = if ($req.BodyBytes) { [System.Text.Encoding]::UTF8.GetString($req.BodyBytes) | ConvertFrom-Json } else { @{} }
                            if ($b.prompt) {
                                $msgs = @(@{role="user";content=$b.prompt})
                                if ($b.system) { $msgs = @(@{role="system";content=$b.system}) + $msgs }
                                $b | Add-Member -NotePropertyName "messages" -NotePropertyValue $msgs -Force
                            }
                            Handle-Chat $req $b $key
                        } catch { Write-Error $stream $_ 500 }
                    }
                }
                else {
                    Write-Error $stream "Not found" 404
                }
                $client.Close()
            } catch {
                Write-Log "ERR  $_"
                try { $client.Close() } catch {}
            }
        } catch {
            try { Write-Log "FATAL $_" } catch {}
            try { $client.Close() } catch {}
            Start-Sleep 1
        }
    }
    $listener.Stop()
}

Main
