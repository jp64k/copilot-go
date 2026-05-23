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

# API key management

function Get-ApiKey {
    if (Test-Path $KEY_FILE) { return (Get-Content $KEY_FILE -Raw).Trim() }
    return $env:OPENCODE_GO_API_KEY
}

function Prompt-ApiKey {
    Write-Host "  No OpenCode Go API key found."
    Write-Host "  Get yours at: https://opencode.ai/auth`n"
    $key = Read-Host "  Paste your API key"
    if ($key) {
        Set-Content -Path $KEY_FILE -Value $key -NoNewline
        Write-Host "  Saved to $KEY_FILE`n"
        return $key
    }
    return ""
}

# Versioning and self-update

function Get-CurrentSha {
    if (Test-Path $VERSION_FILE) { return (Get-Content $VERSION_FILE -Raw).Trim() }
    return ""
}

function Check-Updates {
    $current = Get-CurrentSha
    try {
        $url = "https://api.github.com/repos/$REPO/commits/main"
        $data = Invoke-RestMethod -Uri $url -TimeoutSec 5 -Headers @{
            Accept="application/vnd.github+json"; "User-Agent"="copilot-go"
        }
        $latest = $data.sha
        # First run: sync .version to latest so we don't prompt
        if (-not $current -and $latest) {
            Set-Content -Path $VERSION_FILE -Value $latest -NoNewline
            $current = $latest
        }
        if ($latest -and $current -and $latest -ne $current) {
            return @{ Update=$true; Sha=$latest; Short=$latest.Substring(0,7) }
        }
        $s = if ($latest) { $latest.Substring(0,7) } else { if ($current) { $current.Substring(0,7) } else { "" } }
        return @{ Update=$false; Sha=""; Short=$s }
    } catch {
        $s = if ($current) { $current.Substring(0,7) } else { "" }
        return @{ Update=$false; Sha=""; Short=$s }
    }
}

function Invoke-SelfUpdate($latestSha) {
    $url = "https://raw.githubusercontent.com/$REPO/main/proxy.ps1"
    Write-Host "  Downloading $url ..."
    try {
        $proxyPath = Join-Path $SCRIPT_DIR "proxy.ps1"
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "copilot-go")
        $wc.DownloadFile($url, $proxyPath)
        $wc.Dispose()
        Set-Content -Path $VERSION_FILE -Value $latestSha -NoNewline
        Write-Host "  Updated. Restarting ...`n"
        Start-Sleep 1
        Start-Process powershell -NoNewWindow -ArgumentList "-NoExit -File `"$proxyPath`""
        exit 0
    } catch {
        Write-Host "  Update failed: $_"
    }
}

# Model metadata, thinking modes, display names

$MODEL_INFO = @{
    "deepseek-v4-pro" = @{
        display="DeepSeek V4 Pro"; family="deepseek4"
        param_count=1600000000000; context_length=1048576
        capabilities=@("completion","tools","thinking")
    }
    "deepseek-v4-flash" = @{
        display="DeepSeek V4 Flash"; family="deepseek4"
        param_count=158000000000; context_length=1048576
        capabilities=@("completion","tools","thinking")
    }
    "glm-5.1" = @{
        display="GLM 5.1"; family="glm"
        param_count=756000000000; context_length=202752
        capabilities=@("thinking","completion","tools")
    }
    "glm-5" = @{
        display="GLM 5"; family="glm"
        param_count=540000000000; context_length=202752
        capabilities=@("thinking","completion","tools")
    }
    "kimi-k2.6" = @{
        display="Kimi K2.6"; family="kimi-k2"
        param_count=1040000000000; context_length=262144
        capabilities=@("vision","thinking","completion","tools")
    }
    "kimi-k2.5" = @{
        display="Kimi K2.5"; family="kimi-k2"
        param_count=1040000000000; context_length=262144
        capabilities=@("thinking","completion","tools")
    }
    "minimax-m2.7" = @{
        display="MiniMax M2.7"; family="minimax-m2"
        param_count=229000000000; context_length=196608
        capabilities=@("completion","tools","thinking")
    }
    "minimax-m2.5" = @{
        display="MiniMax M2.5"; family="minimax-m2"
        param_count=200000000000; context_length=196608
        capabilities=@("completion","tools","thinking")
    }
    "mimo-v2.5-pro" = @{
        display="MiMo V2.5 Pro"; family="mimo"
        param_count=456000000000; context_length=262144
        capabilities=@("completion","tools","thinking")
    }
    "mimo-v2.5" = @{
        display="MiMo V2.5"; family="mimo"
        param_count=456000000000; context_length=262144
        capabilities=@("completion","tools","thinking")
    }
    "mimo-v2-pro" = @{
        display="MiMo V2 Pro"; family="mimo"
        param_count=456000000000; context_length=262144
        capabilities=@("completion","tools")
    }
    "mimo-v2-omni" = @{
        display="MiMo V2 Omni"; family="mimo"
        param_count=456000000000; context_length=262144
        capabilities=@("completion","tools")
    }
    "qwen3.6-plus" = @{
        display="Qwen 3.6 Plus"; family="qwen3"
        param_count=72000000000; context_length=131072
        capabilities=@("completion","tools","thinking")
    }
    "qwen3.5-plus" = @{
        display="Qwen 3.5 Plus"; family="qwen3"
        param_count=72000000000; context_length=131072
        capabilities=@("completion","tools","thinking")
    }
    "hy3-preview" = @{
        display="HY3 Preview"; family="hy3"
        param_count=0; context_length=131072
        capabilities=@("completion","tools")
    }
}

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
    if ($cid.Contains("mimo") -and ($MODEL_INFO[$modelId].capabilities -contains "thinking")) {
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
    $info = $MODEL_INFO[$modelId]
    if (-not $info) {
        return ($modelId -replace "-"," " -replace '\b\w', { $_.Value.ToUpper() })
    }
    $base = "$($info.display) [$(Format-Context $info.context_length)]"
    $label = $THINKING_TAG_LABEL[$level]
    if ($label) { return "$base - $label" } else { return $base }
}

# Reverse lookup: display name -> (modelId, level)
$DISPLAY_TO_ID = @{}
foreach ($mid in $MODEL_INFO.Keys) {
    $DISPLAY_TO_ID[(Get-ModelDisplay $mid)] = @($mid, "")
    foreach ($lvl in (Get-ThinkingModes $mid)) {
        $DISPLAY_TO_ID[(Get-ModelDisplay $mid $lvl)] = @($mid, $lvl)
    }
    $DISPLAY_TO_ID["$mid" + ":cloud"] = @($mid, "")
    $DISPLAY_TO_ID[$mid] = @($mid, "")
    foreach ($lvl in (Get-ThinkingModes $mid)) {
        $DISPLAY_TO_ID["$mid" + ":cloud:" + $lvl] = @($mid, $lvl)
        $DISPLAY_TO_ID["$mid" + ":" + $lvl] = @($mid, $lvl)
    }
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
            if ($MODEL_INFO[$mid]) { return @($mid, $level) }
        }
        $ll = $level.ToLower()
        if ($clean -like "*:$ll") {
            $mid = $clean.Substring(0, $clean.Length - $ll.Length - 1) -replace ":cloud",""
            if ($MODEL_INFO[$mid]) { return @($mid, $level) }
        }
    }
    # Display name lookup
    if ($DISPLAY_TO_ID[$clean]) { return $DISPLAY_TO_ID[$clean] }
    foreach ($display in $DISPLAY_TO_ID.Keys) {
        if ($display.StartsWith($clean)) { return $DISPLAY_TO_ID[$display] }
    }
    $stripped = $clean -replace ":cloud",""
    if ($MODEL_INFO[$stripped]) { return @($stripped, "") }
    if ($DISPLAY_TO_ID[$stripped]) { return $DISPLAY_TO_ID[$stripped] }
    return @($clean, "")
}

# Upstream OpenCode Go HTTP client

$HttpClient = [System.Net.Http.HttpClient]::new()
$HttpClient.Timeout = [TimeSpan]::FromSeconds(120)

function Invoke-UpstreamGet($path, $apiKey) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$OPENCODE_BASE$path")
    $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    $req.Headers.Add("User-Agent", "copilot-go")
    $resp = $HttpClient.SendAsync($req).Result
    $body = $resp.Content.ReadAsStringAsync().Result
    if (-not $resp.IsSuccessStatusCode) { throw "Upstream error $($resp.StatusCode): $body" }
    return $body | ConvertFrom-Json
}

function Invoke-UpstreamPost($path, $bodyJson, $apiKey) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$OPENCODE_BASE$path")
    $req.Content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, "application/json")
    $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $apiKey)
    $req.Headers.Add("User-Agent", "copilot-go")
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
            if ($remaining -gt 0 -and $contentLength -gt 0) {
                $bodyBytes = New-Object byte[] $contentLength
                $copyLen = [Math]::Min($remaining, $contentLength)
                [Array]::Copy($arr, $bodyStart, $bodyBytes, 0, $copyLen)
                $bodyRead = $copyLen
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
        $info = if ($MODEL_INFO[$mid]) { $MODEL_INFO[$mid] } else { @{} }
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
    $info = if ($MODEL_INFO[$modelName]) { $MODEL_INFO[$modelName] } else { @{} }
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
        if ($msg.role -eq "assistant" -and $msg.tool_calls -and (-not (Get-Member -InputObject $msg -Name "reasoning_content" -MemberType Properties))) {
            $msg | Add-Member -NotePropertyName "reasoning_content" -NotePropertyValue "" -Force
        }
    }
    $isStream = $bodyObj.stream -eq $true
    $toolNames = if ($bodyObj.tools) { ($bodyObj.tools | ForEach-Object { $_.function.name }) -join ", " } else { "none" }
    Write-Log "CHAT model=$modelId level=$reasoningLevel msgs=$($bodyObj.messages.Count) tools=[$toolNames] stream=$isStream"
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    try {
        $upstream = Invoke-UpstreamPost "/chat/completions" $bodyJson $apiKey
    } catch {
        Write-Error $stream "Upstream error: $_" 502
        return
    }

    if (-not $upstream.IsSuccessStatusCode) {
        $errBody = $upstream.Content.ReadAsStringAsync().Result
        Write-Error $stream "Upstream error $($upstream.StatusCode): $errBody" 502
        return
    }

    if ($isStream) {
        Relay-Sse $stream $upstream
    } else {
        $respBody = $upstream.Content.ReadAsStringAsync().Result
        $respObj = $respBody | ConvertFrom-Json
        if (-not (Get-Member -InputObject $respObj -Name "system_fingerprint" -MemberType Properties)) {
            $respObj | Add-Member -NotePropertyName "system_fingerprint" -NotePropertyValue "fp_ollama" -Force
        }
        Write-Response $stream 200 "OK" "application/json; charset=utf-8" ($respObj | ConvertTo-Json -Depth 10 -Compress)
    }
}

function Relay-Sse($clientStream, $upstreamResp) {
    $headers = "HTTP/1.1 200 OK`r`n" +
               "Content-Type: text/event-stream`r`n" +
               "Cache-Control: no-cache`r`n" +
               "Connection: close`r`n" +
               "Server: copilot-go`r`n`r`n"
    $clientStream.Write([System.Text.Encoding]::ASCII.GetBytes($headers), 0, $headers.Length)
    $clientStream.Flush()

    $upstreamStream = $upstreamResp.Content.ReadAsStreamAsync().Result
    $buffer = ""
    $readBuf = New-Object byte[] 8192
    $chunkCount = 0; $outputTokens = 0; $t0 = Get-Date
    try {
        while ($true) {
            $n = $upstreamStream.Read($readBuf, 0, 8192)
            if ($n -eq 0) { break }
            $buffer += [System.Text.Encoding]::UTF8.GetString($readBuf, 0, $n)

            while ($buffer.Contains("`n`n")) {
                $idx = $buffer.IndexOf("`n`n")
                $block = $buffer.Substring(0, $idx)
                $buffer = $buffer.Substring($idx + 2)
                $lines = $block -split "`n"
                $outLines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in $lines) {
                    $s = $line.Trim()
                    if ($s -eq "") { $outLines.Add(""); continue }
                    if ($s.StartsWith("data: ") -and $s -ne "data: [DONE]") {
                        $chunkCount++
                        $deltaJson = $s.Substring(6)
                        if ($deltaJson -notmatch 'system_fingerprint') {
                            $deltaJson = $deltaJson -replace '^{(.*)', '{ "system_fingerprint":"fp_ollama", $1'
                        }
                        $outLines.Add("data: " + $deltaJson)
                        if ($chunkCount -eq 1) {
                            try { $obj = $deltaJson | ConvertFrom-Json } catch { $obj = $null }
                            if ($obj) {
                                $delta = $obj.choices[0].delta
                                Write-Log "SSE chunk1 hasContent=$($delta.content -ne $null) hasTools=$($delta.tool_calls -ne $null) finish=$($obj.choices[0].finish_reason)"
                            }
                        }
                        try { $obj2 = $deltaJson | ConvertFrom-Json } catch { $obj2 = $null }
                        if ($obj2 -and $obj2.usage) { $outputTokens = $obj2.usage.completion_tokens }
                    } else { $outLines.Add($s) }
                }
                $out = ($outLines -join "`n") + "`n`n"
                $outBytes = [System.Text.Encoding]::UTF8.GetBytes($out)
                $clientStream.Write($outBytes, 0, $outBytes.Length)
                $clientStream.Flush()
            }
        }
        if ($buffer.Trim()) {
            $clientStream.Write([System.Text.Encoding]::UTF8.GetBytes($buffer), 0, $buffer.Length)
            $clientStream.Flush()
        }
        Update-Tps $outputTokens $t0
        Write-Log "SSE done chunks=$chunkCount tokens=$outputTokens"
    } catch {
        Write-Log "SSE err: $_"
    }
    $upstreamStream.Dispose()
}

function Update-Tps($tokens, $startTime) {
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    if ($elapsed -gt 0 -and $tokens -gt 0) {
        $script:LastTps = [math]::Round($tokens / $elapsed, 1)
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

    $apiKey = Get-ApiKey
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

    if (-not $apiKey) { $apiKey = Prompt-ApiKey }
    if ($apiKey) { Write-Host "  Loaded API key: $($apiKey.Substring(0,6))..." }
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
                if (-not $apiKey) { Write-Error $stream "No API key" 500 }
                else {
                    try { Write-Response $stream 200 "OK" "application/json; charset=utf-8" (Get-TagsJson $apiKey) }
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
                    Write-Response $stream 200 "OK" "application/json; charset=utf-8" (Get-ShowJson $b $apiKey)
                } catch { Write-Error $stream "Invalid request" 400 }
            }
            elseif ($method -eq "POST" -and $path -eq "/v1/chat/completions") {
                if (-not $apiKey) { Write-Error $stream "No API key" 500 }
                else {
                    try {
                        $b = if ($req.BodyBytes) { [System.Text.Encoding]::UTF8.GetString($req.BodyBytes) | ConvertFrom-Json } else { @{} }
                        Handle-Chat $req $b $apiKey
                    } catch { Write-Error $stream $_ 500 }
                }
            }
            elseif ($method -eq "POST" -and ($path -eq "/api/chat" -or $path -eq "/api/generate")) {
                if (-not $apiKey) { Write-Error $stream "No API key" 500 }
                else {
                    try {
                        $b = if ($req.BodyBytes) { [System.Text.Encoding]::UTF8.GetString($req.BodyBytes) | ConvertFrom-Json } else { @{} }
                        if ($b.prompt) {
                            $msgs = @(@{role="user";content=$b.prompt})
                            if ($b.system) { $msgs = @(@{role="system";content=$b.system}) + $msgs }
                            $b | Add-Member -NotePropertyName "messages" -NotePropertyValue $msgs -Force
                        }
                        Handle-Chat $req $b $apiKey
                    } catch { Write-Error $stream $_ 500 }
                }
            }
            else {
                Write-Error $stream "Not found" 404
            }
            $client.Close()
        } catch {
            Write-Log "ERR  $_"
        }
    }
    $listener.Stop()
}

Main
