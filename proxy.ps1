#requires -Version 5.1
# proxy CLI v2 - Windows per-app proxy manager for ProxyBridge + sing-box.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Self-elevate to admin if needed (ProxyBridge needs WinDivert)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "需要管理员权限，正在重新启动..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait
    exit
}

$Root = Join-Path $env:USERPROFILE ".proxy"
$ConfigFile = Join-Path $Root "config.json"
$ProfileFile = Join-Path $Root "proxybridge.pbprofile"
$PidFile = Join-Path $Root "proxybridge.pid"
$LogFile = Join-Path $Root "proxybridge.log"
$SingBoxPidFile = Join-Path $Root "singbox.pid"
$SingBoxLogFile = Join-Path $Root "singbox.log"

function Write-Log($Message) {
    Ensure-Root
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $Message" | Add-Content -LiteralPath $LogFile -Encoding UTF8
}

function Write-Color($Text, $ForegroundColor = "White") {
    Write-Host $Text -ForegroundColor $ForegroundColor
}

function Ensure-Root {
    if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
}

function Start-DetachedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = ""
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Default-Config {
    [ordered]@{
        version = 2
        proxy = [ordered]@{
            type = "socks5"
            host = "127.0.0.1"
            port = 7891
            username = ""
            password = ""
        }
        options = [ordered]@{
            localhostViaProxy = $false
            trafficLogging = $true
            protocol = "BOTH"
            targetHosts = "*"
            targetPorts = "*"
        }
        apps = @()
        singbox = [ordered]@{
            enabled = $false
            exePath = ""
            configPath = ""
        }
    }
}

function Save-Json($Object, $Path) {
    Ensure-Root
    try {
        $Object | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        throw "保存配置失败: $($_.Exception.Message)"
    }
}

function Load-Config {
    Ensure-Root
    if (-not (Test-Path $ConfigFile)) {
        $c = Default-Config
        Save-Json $c $ConfigFile
        return $c
    }
    try {
        $raw = Get-Content $ConfigFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning "配置文件为空，正在重置。"
            $c = Default-Config
            Save-Json $c $ConfigFile
            return $c
        }
        $c = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "配置文件损坏，正在重置为默认配置。"
        Write-Log "Config corrupt, resetting: $($_.Exception.Message)"
        $c = Default-Config
        Save-Json $c $ConfigFile
        return $c
    }
    if (-not $c.proxy) {
        $c | Add-Member NoteProperty proxy ([pscustomobject]@{type="socks5";host="127.0.0.1";port=7891;username="";password=""}) -Force
    }
    if (-not $c.options) {
        $c | Add-Member NoteProperty options ([pscustomobject]@{localhostViaProxy=$false;trafficLogging=$true;protocol="BOTH";targetHosts="*";targetPorts="*"}) -Force
    }
    if (-not $c.apps) { $c | Add-Member NoteProperty apps @() -Force }
    if (-not ($c.PSObject.Properties.Name -contains 'singbox')) {
        $c | Add-Member NoteProperty singbox ([pscustomobject]@{enabled=$false;exePath="";configPath=""}) -Force
    }
    if ($c.proxy) {
        if (-not $c.proxy.type) { $c.proxy | Add-Member NoteProperty type "socks5" -Force }
        if (-not $c.proxy.host) { $c.proxy | Add-Member NoteProperty host "127.0.0.1" -Force }
        if (-not $c.proxy.port) { $c.proxy | Add-Member NoteProperty port 7891 -Force }
    }
    return $c
}

function Get-ProxyBridgeCli {
    $cmd = Get-Command ProxyBridge_CLI.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\ProxyBridge\ProxyBridge_CLI.exe",
        "${env:ProgramFiles(x86)}\ProxyBridge\ProxyBridge_CLI.exe",
        "$env:LOCALAPPDATA\ProxyBridge\ProxyBridge_CLI.exe",
        "$env:USERPROFILE\bin\ProxyBridge_CLI.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    $pathCandidates = ($env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'ProxyBridge_CLI.exe')) }) | ForEach-Object { Join-Path $_ 'ProxyBridge_CLI.exe' }
    if ($pathCandidates.Count -gt 0) { return $pathCandidates[0] }
    throw "找不到 ProxyBridge_CLI.exe。请安装官方 ProxyBridge，并把它加入 PATH。"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BridgePid {
    if (-not (Test-Path $PidFile)) { return $null }
    try {
        $raw = (Get-Content $PidFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue; return $null }
        $id = [int]$raw
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like "ProxyBridge_CLI*") { return $id }
    } catch {
        return $null
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    return $null
}

function Is-Running { return $null -ne (Get-BridgePid) }

function Wait-BridgeReady {
    $timeout = 10000
    $interval = 500
    $elapsed = 0
    Write-Host "等待 ProxyBridge 就绪..."
    while ($elapsed -lt $timeout) {
        if (Is-Running) {
            $bridgePid = Get-BridgePid
            Start-Sleep -Milliseconds 1000
            if (Is-Running) {
                Write-Color "ProxyBridge 已就绪 (PID $bridgePid)" Green
                return $true
            }
            Write-Color "ProxyBridge 进程已退出，请检查配置。" Red
            return $false
        }
        Start-Sleep -Milliseconds $interval
        $elapsed += $interval
    }
    Write-Color "ProxyBridge 启动超时！" Red
    return $false
}

function Normalize-CommandName($Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "应用名不能为空。" }
    return $Name.Trim()
}

function Resolve-CommandInfo($Name) {
    $n = Normalize-CommandName $Name
    if (Test-Path -LiteralPath $n -PathType Leaf) {
        $item = Get-Item -LiteralPath $n
        $ext = $item.Extension.TrimStart('.').ToLowerInvariant()
        return [pscustomobject]@{
            Input=$n; Source=$item.FullName; Leaf=$item.Name
            Type=$ext; CommandType="File"
        }
    }
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if (-not $cmd) {
        foreach ($candidate in @("$n.exe","$n.cmd","$n.bat","$n.ps1")) {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) { break }
        }
    }
    if (-not $cmd) {
        return [pscustomobject]@{
            Input=$n; Source=$null; Leaf=$n
            Type="unknown"; CommandType="Unknown"
        }
    }
    $source = $cmd.Source
    $leaf = [IO.Path]::GetFileName($source)
    $ext = [IO.Path]::GetExtension($source).TrimStart('.').ToLowerInvariant()
    return [pscustomobject]@{
        Input=$n; Source=$source; Leaf=$leaf
        Type=$ext; CommandType=[string]$cmd.CommandType
    }
}

function Find-App($Config, $Name) {
    $n = Normalize-CommandName $Name
    return @($Config.apps | Where-Object {
        $_.id -ieq $n -or $_.name -ieq $n -or $_.process -ieq $n -or $_.path -ieq $n
    }) | Select-Object -First 1
}

function Get-ProcessCandidates($Info) {
    $out = [System.Collections.Generic.List[object]]::new()
    if ($Info.Source -and $Info.Type -eq "exe") {
        $out.Add([pscustomobject]@{ kind="process"; value=$Info.Leaf; confidence="high" })
        $out.Add([pscustomobject]@{ kind="path"; value=$Info.Source; confidence="high" })
        return $out
    }
    if ($Info.Source) {
        $text = ""
        try { $text = Get-Content -LiteralPath $Info.Source -Raw -ErrorAction Stop } catch { }
        if ($Info.Type -in @("cmd","bat")) {
            $nodeRefs = [regex]::Matches($text, '(?i)(?:node(?:\.exe)?)[\s"]+([^"\r\n]+)')
            foreach ($m in $nodeRefs) {
                if ($m.Groups.Count -gt 1) {
                    $target = $m.Groups[1].Value.Trim()
                    if ($target) {
                        $out.Add([pscustomobject]@{ kind="wrapper-target"; value=$target; confidence="medium" })
                    }
                }
            }
        }
        if ($Info.Type -eq "ps1") {
            $matches = [regex]::Matches($text, '(?i)(?:node(?:\.exe)?)[\s-]+([^\r\n]+)')
            foreach ($m in $matches) {
                if ($m.Groups.Count -gt 1) {
                    $out.Add([pscustomobject]@{ kind="wrapper-target"; value=$m.Groups[1].Value.Trim(); confidence="medium" })
                }
            }
        }
    }
    $out.Add([pscustomobject]@{ kind="warning"; value="wrapper"; confidence="manual" })
    return $out
}

function Add-App($Name) {
    $c = Load-Config
    $info = Resolve-CommandInfo $Name
    if (-not $info.Source) {
        throw "找不到命令 '$Name'。可以使用完整 exe 路径，例如 C:\Tools\foo.exe"
    }
    $existing = Find-App $c $Name
    if ($existing) {
        $existing.enabled = $true
        Save-Json $c $ConfigFile
        Write-Profile $c
        Write-Color "已启用: $($existing.id)" Green
        return
    }
    if ($info.Type -eq "exe") {
        $app = [pscustomobject]@{
            id=$Name; name=$info.Leaf; process=$info.Leaf; path=$info.Source; enabled=$true; kind="exe"
        }
        $c.apps = @($c.apps) + $app
        Save-Json $c $ConfigFile
        Write-Profile $c
        Write-Color "已加入代理: $($info.Leaf)" Green
        return
    }
    Write-Warning "$($info.Leaf) 是 .$($info.Type) 包装脚本。"
    Write-Warning "为了避免代理所有 node.exe，本次不会把 node.exe 加入规则。"
    $candidates = Get-ProcessCandidates $info
    $targets = ($candidates | Where-Object { $_.kind -eq "wrapper-target" }).ForEach({ $_.value })
    if ($targets.Count -gt 0) {
        Write-Host "该脚本可能调用以下程序:"
        foreach ($t in $targets) { Write-Host "  -> $t" }
    }
    Write-Host ""
    Write-Host "运行以下命令可查看详细信息:"
    Write-Host "  proxy tree $Name"
    Write-Host "然后把实际的可执行文件路径加入配置。"
    $app = [pscustomobject]@{
        id=$Name; name=$info.Leaf; process=""; path=$info.Source; enabled=$true; kind="wrapper"
    }
    $c.apps = @($c.apps) + $app
    Save-Json $c $ConfigFile
    Write-Profile $c
    Write-Host "已记录 wrapper: $Name（当前不会产生全局 node.exe 规则）"
}

function Remove-App($Name) {
    $c = Load-Config
    $a = Find-App $c $Name
    if (-not $a) { Write-Warning "没有找到: $Name"; return }
    $id = $a.id
    $c.apps = @($c.apps | Where-Object { $_.id -ine $id })
    Save-Json $c $ConfigFile
    Write-Profile $c
    Write-Color "已移除: $id" Green
}

function Set-AppEnabled($Name,[bool]$Enabled) {
    $c = Load-Config
    $a = Find-App $c $Name
    if (-not $a) { throw "没有找到: $Name" }
    $a.enabled=$Enabled
    Save-Json $c $ConfigFile
    Write-Profile $c
    Write-Color "$($a.id): $(if($Enabled){"ON / PROXY"}else{"OFF / DIRECT"})" Green
}

function Show-List {
    $c=Load-Config
    Write-Host ""
    Write-Color "Proxy: $($c.proxy.type)://$($c.proxy.host):$($c.proxy.port)" Cyan
    Write-Color "Default: DIRECT" Cyan
    Write-Color "Bridge: $(if(Is-Running){"RUNNING"}else{"STOPPED"})" Cyan
    Write-Host ""
    if (@($c.apps).Count -eq 0) {
        Write-Host "没有配置应用。"
        return
    }
    $appCount = @($c.apps).Count
    $appColWidth = [Math]::Max(18, ($c.apps | ForEach-Object { $_.id.Length } | Measure-Object -Maximum).Maximum + 2)
    $procColWidth = [Math]::Max(20, ($c.apps | ForEach-Object { if($_.process){$_.process}else{"(wrapper)"} } | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 2)
    $fmt = "{0,-$appColWidth} {1,-$procColWidth} {2,-10} {3,-8}"
    $sep = "-" * $appColWidth + " " + "-" * $procColWidth + " " + "-" * 10 + " " + "-" * 8
    $fmt -f "APP","PROCESS","STATUS","KIND" | Write-Host
    $sep | Write-Host
    foreach($a in $c.apps) {
        $status=if($a.enabled){"PROXY"}else{"DIRECT"}
        $proc=if($a.process){$a.process}else{"(wrapper)"}
        $color=if($a.enabled){"Yellow"}else{"Gray"}
        Write-Host ($fmt -f $a.id,$proc,$status,$a.kind) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "共 $appCount 个应用，其中 $((@($c.apps | Where-Object enabled).Count)) 个已启用"
}

function Show-Which($Name) {
    $info=Resolve-CommandInfo $Name
    Write-Host ""
    Write-Host "Input : $($info.Input)"
    Write-Host "Source: $($info.Source)"
    Write-Host "Leaf  : $($info.Leaf)"
    Write-Host "Type  : $($info.Type)"
    Write-Host "Cmd   : $($info.CommandType)"
    if($info.Type -in @("cmd","bat","ps1")) {
        Write-Host ""
        Write-Host "这是 wrapper；不会自动代理 node.exe。"
        Write-Host "使用 proxy tree $Name 检查它的真实调用链。"
        $candidates = Get-ProcessCandidates $info
        $targets = ($candidates | Where-Object { $_.kind -eq "wrapper-target" }).ForEach({ $_.value })
        if ($targets.Count -gt 0) {
            Write-Host "可能调用的程序:"
            foreach ($t in $targets) { Write-Host "  -> $t" }
        }
    }
}

function Show-Tree($Name) {
    $info=Resolve-CommandInfo $Name
    Write-Host ""
    Write-Host "=== command tree: $Name ==="
    if(-not $info.Source) {
        Write-Host "找不到命令。"
        return
    }
    Write-Host "wrapper/exe: $($info.Source)"
    if($info.Type -eq "exe") {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='$($info.Leaf)'" -ErrorAction SilentlyContinue)
        if($running.Count) {
            foreach($p in $running) {
                Write-Host "PID $($p.ProcessId): $($p.ExecutablePath)"
                Write-Host "  CMD: $($p.CommandLine)"
            }
        } else {
            Write-Host "当前没有运行中的 $($info.Leaf)。"
        }
        return
    }
    try {
        $text=Get-Content -LiteralPath $info.Source -Raw -ErrorAction Stop
        Write-Host "--- wrapper content (relevant lines) ---"
        $text -split "`r?`n" | Where-Object { $_ -match '(?i)node|npm|npx|bun|deno' } | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Host "无法读取 wrapper 文件。"
    }
    Write-Host ""
    Write-Host "当前策略：不把 node.exe 作为全局代理规则。"
    Write-Host "建议使用 proxy add <具体exe路径> 来精确匹配。"
}

function New-Profile($Config) {
    $proxy=$Config.proxy
    $o=$Config.options
    $pc=[ordered]@{
        Id=1
        Type=[string]$proxy.type
        Host=[string]$proxy.host
        Port=[string]$proxy.port
        Username=[string]$proxy.username
        Password=[string]$proxy.password
    }
    $rules=@()
    foreach($a in @($Config.apps)) {
        if(-not $a.enabled) { continue }
        if($a.kind -ne "exe") { continue }
        if([string]::IsNullOrWhiteSpace($a.process)) { continue }
        $rules += [ordered]@{
            ProcessName=[string]$a.process
            TargetHosts=[string]$o.targetHosts
            TargetPorts=[string]$o.targetPorts
            Protocol=[string]$o.protocol
            Action="PROXY"
            IsEnabled=$true
            ProxyConfigId=1
        }
    }
    foreach($a in @($Config.apps)) {
        if(-not $a.enabled) { continue }
        if($a.kind -ne "exe") { continue }
        if([string]::IsNullOrWhiteSpace($a.path)) { continue }
        if(-not [string]::IsNullOrWhiteSpace($a.process)) { continue }
        $rules += [ordered]@{
            ProcessName=[string]$a.path
            TargetHosts=[string]$o.targetHosts
            TargetPorts=[string]$o.targetPorts
            Protocol=[string]$o.protocol
            Action="PROXY"
            IsEnabled=$true
            ProxyConfigId=1
        }
    }
    if($rules.Count -eq 0) {
        $rules += [ordered]@{
            ProcessName="__no_apps_configured__"
            TargetHosts=[string]$o.targetHosts
            TargetPorts=[string]$o.targetPorts
            Protocol=[string]$o.protocol
            Action="DIRECT"
            IsEnabled=$true
            ProxyConfigId=1
        }
    }
    return [ordered]@{
        Version="1.0"
        LocalhostViaProxy=[bool]$o.localhostViaProxy
        IsTrafficLoggingEnabled=[bool]$o.trafficLogging
        ProxyConfigs=@($pc)
        ProxyRules=$rules
    }
}

function Write-Profile($Config) {
    $p=New-Profile $Config
    try {
        $p | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ProfileFile -Encoding UTF8
    } catch {
        throw "生成 profile 失败: $($_.Exception.Message)"
    }
}

function Start-Bridge {
    $cli=Get-ProxyBridgeCli
    $c=Load-Config
    Write-Profile $c
    if(Is-Running) {
        Write-Color "ProxyBridge 已运行，PID $(Get-BridgePid)" Cyan
        return
    }
    $arguments = @("--profile", $ProfileFile, "--verbose", "1")
    Write-Host "启动 ProxyBridge ..."
    try {
        Start-DetachedProcess -FilePath $cli -ArgumentList $arguments
    } catch {
        throw "启动 ProxyBridge 失败: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 1500
    $proc = Get-Process -Name "ProxyBridge_CLI" -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.MainModule.FileName -eq $cli -or $_.Path -like "*ProxyBridge*"
        } catch {
            $true
        }
    } | Select-Object -First 1
    if(-not $proc) {
        throw "无法找到 ProxyBridge 进程，请手动启动。"
    }
    $proc.Id | Set-Content -LiteralPath $PidFile -Encoding ASCII
    Write-Host "ProxyBridge 已启动，PID=$($proc.Id)"
    Wait-BridgeReady
}

function Stop-Bridge {
    $bridgePid = Get-BridgePid
    if(-not $bridgePid) { Write-Host "ProxyBridge 未运行。"; return }
    Write-Host "正在停止 ProxyBridge (PID=$bridgePid)..."
    try {
        Stop-Process -Id $bridgePid -Force -ErrorAction Stop
    } catch {
        Write-Warning "停止过程出错: $($_.Exception.Message)"
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Write-Color "ProxyBridge 已停止。" Green
}

function Get-SingBoxCli {
    $c = Load-Config
    if ($c.singbox -and $c.singbox.exePath -and (Test-Path -LiteralPath $c.singbox.exePath -PathType Leaf)) {
        return $c.singbox.exePath
    }
    $cmd = Get-Command "sing-box" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:USERPROFILE "AppData\Local\sing-box\sing-box.exe"),
        "F:\ProgramFiles\sing-box\bin\data\sing-box\sing-box.exe",
        (Join-Path $env:ProgramFiles "sing-box\sing-box.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "sing-box\sing-box.exe")
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    foreach ($dir in ($env:Path -split ";")) {
        $p = Join-Path $dir.Trim() "sing-box.exe"
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    throw "找不到 sing-box.exe，请运行: proxy singbox config <exe路径> <配置文件路径>"
}

function Get-SingBoxPid {
    if (-not (Test-Path $SingBoxPidFile)) { return $null }
    try {
        $raw = (Get-Content $SingBoxPidFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { Remove-Item $SingBoxPidFile -Force -ErrorAction SilentlyContinue; return $null }
        $id = [int]$raw
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like "sing-box*") { return $id }
    } catch {
        return $null
    }
    Remove-Item $SingBoxPidFile -Force -ErrorAction SilentlyContinue
    return $null
}

function Is-SingBoxRunning { return $null -ne (Get-SingBoxPid) }

function Start-SingBox {
    $c = Load-Config
    if (-not $c.singbox.enabled) { return }
    if (Is-SingBoxRunning) {
        Write-Color "sing-box 已运行，PID $(Get-SingBoxPid)" Cyan
        return
    }
    $cli = Get-SingBoxCli
    $configPath = $c.singbox.configPath
    if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "sing-box 配置文件不存在: $configPath。请运行: proxy singbox config <exe路径> <配置文件路径>"
    }
    $arguments = @("run", "-c", $configPath)
    Write-Host "启动 sing-box ..."
    try {
        Start-DetachedProcess -FilePath $cli -ArgumentList $arguments
    } catch {
        throw "启动 sing-box 失败: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 1500
    $proc = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*sing-box*" } | Select-Object -First 1
    if (-not $proc) {
        throw "无法找到 sing-box 进程，请手动启动。"
    }
    $proc.Id | Set-Content -LiteralPath $SingBoxPidFile -Encoding ASCII
    Write-Host "sing-box 已启动，PID=$($proc.Id)"
    $timeout = 8000
    $interval = 500
    $elapsed = 0
    Write-Host "等待 sing-box 就绪..."
    while ($elapsed -lt $timeout) {
        if (Is-SingBoxRunning) {
            try {
                $tcp = [Net.Sockets.TcpClient]::new()
                $tcp.ReceiveTimeout = 2000
                $tcp.SendTimeout = 2000
                $tcp.Connect($c.proxy.host, [int]$c.proxy.port)
                $tcp.Close()
                Write-Color "sing-box 已就绪 (PID $(Get-SingBoxPid))" Green
                return $true
            } catch {
                Start-Sleep -Milliseconds $interval
                $elapsed += $interval
            }
        } else {
            Write-Color "sing-box 进程已退出，请检查配置。" Red
            return $false
        }
    }
    Write-Color "sing-box 启动超时！" Red
    return $false
}

function Stop-SingBox {
    $sbPid = Get-SingBoxPid
    if (-not $sbPid) { Write-Host "sing-box 未运行。"; return }
    Write-Host "正在停止 sing-box (PID=$sbPid)..."
    try {
        Stop-Process -Id $sbPid -Force -ErrorAction Stop
    } catch {
        Write-Warning "停止过程出错: $($_.Exception.Message)"
    }
    Remove-Item $SingBoxPidFile -Force -ErrorAction SilentlyContinue
    Write-Color "sing-box 已停止。" Green
}

function Set-SingBoxConfig($ExePath, $ConfigPath) {
    $c = Load-Config
    if (-not $c.singbox) {
        $c | Add-Member NoteProperty singbox ([pscustomobject]@{enabled=$false;exePath="";configPath=""}) -Force
    }
    if ($ExePath) {
        if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
            throw "文件不存在: $ExePath"
        }
        $c.singbox.exePath = $ExePath
    }
    if ($ConfigPath) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw "配置文件不存在: $ConfigPath"
        }
        $c.singbox.configPath = $ConfigPath
    }
    $c.singbox.enabled = $true
    Save-Json $c $ConfigFile
    Write-Color "sing-box 配置已保存:" Green
    Write-Host "  exePath    : $($c.singbox.exePath)"
    Write-Host "  configPath : $($c.singbox.configPath)"
    Write-Host "  enabled    : $($c.singbox.enabled)"
}

function Status {
    $c=Load-Config
    Write-Host ""
    Write-Color "proxy status" Cyan
    Write-Color "------------" Cyan
    Write-Color "Proxy      : $($c.proxy.type)://$($c.proxy.host):$($c.proxy.port)"
    Write-Color "Default    : DIRECT"
    Write-Color "Bridge     : $(if(Is-Running){"RUNNING PID=$(Get-BridgePid)"}else{"STOPPED"})"
    if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) {
        Write-Color "SingBox    : $(if(Is-SingBoxRunning){"RUNNING PID=$(Get-SingBoxPid)"}else{"STOPPED"})"
        Write-Color "SingBox cfg: $($c.singbox.configPath)"
    } else {
        Write-Color "SingBox    : DISABLED"
    }
    Write-Color "Admin      : $(Test-Admin)"
    Write-Color "Apps       : $(@($c.apps).Count) (enabled: $(@($c.apps | Where-Object enabled).Count))"
    Write-Color "Config     : $ConfigFile"
    Write-Color "PB profile : $ProfileFile"
    Write-Host ""
}

function Test-Proxy {
    $c=Load-Config
    Write-Host "Testing $($c.proxy.host):$($c.proxy.port) ..."
    try {
        $tcp=[Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 5000
        $tcp.SendTimeout = 5000
        $tcp.Connect($c.proxy.host,[int]$c.proxy.port)
        $tcp.Close()
        Write-Color "OK: proxy endpoint reachable." Green
    } catch {
        Write-Color "FAILED: $($_.Exception.Message)" Red
    }
}

function Set-Proxy($Type,$HostName,$Port) {
    if($Type -notin @("socks5","http")) { throw "只支持 socks5/http。" }
    $port=[int]$Port
    if($port -lt 1 -or $port -gt 65535) { throw "端口范围 1-65535。" }
    $c=Load-Config
    $c.proxy.type=$Type
    $c.proxy.host=$HostName
    $c.proxy.port=$port
    Save-Json $c $ConfigFile
    Write-Profile $c
    Write-Color ("Proxy set: {0}://{1}:{2}" -f $Type, $HostName, $port) Green
}

function Init {
    $c=Load-Config
    Write-Profile $c
    Write-Color "Initialized." Green
    Write-Host "Config : $ConfigFile"
    Write-Host "Profile: $ProfileFile"
}

function Update-Bridge {
    if(-not (Is-Running)) {
        Write-Warning "ProxyBridge 未运行。请先运行 proxy start。"
        return
    }
    $c=Load-Config
    Write-Profile $c
    Write-Color "Profile 已更新并应用到运行中的 ProxyBridge。" Green
}

function Restart-Bridge {
    Stop-Bridge
    Start-Sleep -Milliseconds 300
    Start-Bridge
}

function Run-ThroughProxy {
    $c = Load-Config
    if (-not (Is-Running)) {
        Write-Color "ProxyBridge 未运行。请先运行 proxy start。" Red
        Write-Host "  proxy start"
        return
    }
    $proxy = $c.proxy
    try {
        $tcp = [Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 3000
        $tcp.SendTimeout = 3000
        $tcp.Connect($proxy.host, [int]$proxy.port)
        $tcp.Close()
    } catch {
        Write-Color "代理端点不可达 ($($proxy.host):$($proxy.port))。" Red
        Write-Host "  proxy test"
        Write-Host "  proxy doctor"
        return
    }

    $proxyUrl = if ($proxy.username) {
        "$($proxy.type)://$($proxy.username):$($proxy.password)@$($proxy.host):$($proxy.port)"
    } else {
        "$($proxy.type)://$($proxy.host):$($proxy.port)"
    }
    $httpProxyUrl = "http://$($proxy.host):$($proxy.port)"

    Write-Color "通过代理运行: $proxyUrl" Cyan
    Write-Host ""

    $origAllProxy = $env:ALL_PROXY
    $origHttpProxy = $env:HTTP_PROXY
    $origHttpsProxy = $env:HTTPS_PROXY
    $origNoProxy = $env:NO_PROXY

    $env:ALL_PROXY = $proxyUrl
    $env:HTTP_PROXY = $httpProxyUrl
    $env:HTTPS_PROXY = $httpProxyUrl
    $env:NO_PROXY = "localhost,127.0.0.1,::1"

    $env:all_proxy = $proxyUrl
    $env:http_proxy = $httpProxyUrl
    $env:https_proxy = $httpProxyUrl

    $command = $args[0]
    $commandArgs = if ($args.Count -gt 1) { $args[1..($args.Count-1)] } else { @() }

    # For some tools, pass --proxy flag directly for better Windows compatibility
    $proxyFlagArgs = @()
    $cmdName = [IO.Path]::GetFileNameWithoutExtension($command)
    if ($cmdName -eq "curl") {
        $proxyFlagArgs = @("--proxy", $proxyUrl)
    } elseif ($cmdName -eq "wget") {
        $proxyFlagArgs = @("--proxy=on", "--http-proxy", $httpProxyUrl, "--https-proxy", $httpProxyUrl)
    } elseif ($cmdName -eq "git") {
        $proxyFlagArgs = @("-c", "http.proxy=$proxyUrl")
    }

    try {
        $info = Resolve-CommandInfo $command
        if (-not $info.Source) {
            throw "找不到命令 '$command' 或因为路径不存在。"
        }
        $allArgs = @()
        if ($proxyFlagArgs.Count -gt 0) { $allArgs += $proxyFlagArgs }
        $allArgs += $commandArgs
        & $info.Source @allArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Log "Command '$command' exited with code $exitCode"
        }
        exit $exitCode
    } catch {
        Write-Color "Error: $($_.Exception.Message)" Red
        Write-Log "Proxy run error: $($_.Exception.Message)"
        exit 1
    } finally {
        if ($origAllProxy -ne $null) { $env:ALL_PROXY = $origAllProxy } else { Remove-Item env:ALL_PROXY -ErrorAction SilentlyContinue }
        if ($origHttpProxy -ne $null) { $env:HTTP_PROXY = $origHttpProxy } else { Remove-Item env:HTTP_PROXY -ErrorAction SilentlyContinue }
        if ($origHttpsProxy -ne $null) { $env:HTTPS_PROXY = $origHttpsProxy } else { Remove-Item env:HTTPS_PROXY -ErrorAction SilentlyContinue }
        if ($origNoProxy -ne $null) { $env:NO_PROXY = $origNoProxy } else { Remove-Item env:NO_PROXY -ErrorAction SilentlyContinue }
        Remove-Item env:all_proxy -ErrorAction SilentlyContinue
        Remove-Item env:http_proxy -ErrorAction SilentlyContinue
        Remove-Item env:https_proxy -ErrorAction SilentlyContinue
    }
}

function Help {
@"
proxy v2 - per-app transparent proxy manager

核心:
  未命中规则 = DIRECT
  ON 的 EXE = PROXY
  OFF = DIRECT
  wrapper (.cmd/.bat/.ps1) 不会自动污染 node.exe

内置命令:
  proxy init                          # 初始化配置
  proxy config show                   # 显示代理配置
  proxy config set socks5 127.0.0.1 7891  # 设置代理
  proxy add <name|exe|path>           # 添加应用
  proxy rm <name>                     # 删除应用
  proxy ls / list                     # 列出应用
  proxy on <name>                     # 启用代理
  proxy off <name>                    # 禁用代理
  proxy which <name>                  # 解析命令信息
  proxy tree <name>                   # 显示命令调用链
  proxy start / stop / restart        # 启动/停止/重启 sing-box + ProxyBridge
  proxy status                        # 显示状态
  proxy test                          # 测试代理连接
  proxy doctor                        # 完整诊断
  proxy update                        # 重新生成 profile
  proxy profile                       # 显示并生成 profile
  proxy help                          # 显示帮助

sing-box 管理:
  proxy singbox config <exe路径> <配置文件路径>  # 配置 sing-box
  proxy singbox start                  # 仅启动 sing-box
  proxy singbox stop                   # 仅停止 sing-box
  proxy singbox status                 # 显示 sing-box 状态

通过代理运行命令:
  proxy run <command> [args...]       # 通过代理执行任意命令
  proxy curl https://www.google.com
  proxy git pull
  proxy npm install
  proxy node app.js
  proxy python script.py

浏览器代理:
  proxy chrome                        # 启动 Chrome 走代理（独立 profile）
  proxy system                        # 设置系统代理（Chrome/Edge 自动走代理）
  proxy system off                    # 关闭系统代理

示例:
  proxy singbox config "D:\sing-box\sing-box.exe" "D:\sing-box\config.json"
  proxy config set socks5 127.0.0.1 7890
  proxy add curl.exe
  proxy add git.exe
  proxy on git.exe
  proxy start
  proxy curl https://www.google.com
  proxy git status
  proxy chrome
  proxy system

颜色说明:
  绿色 = 成功/已启用
  红色 = 失败/错误
  黄色 = 已配置但未启用
  青色 = 信息/状态
"@
}

function Doctor {
    Write-Color "proxy doctor" Cyan
    Write-Color "-------------" Cyan
    try {
        $cli = Get-ProxyBridgeCli
        Write-Color "ProxyBridge CLI: $cli"
    } catch {
        Write-Color "ProxyBridge CLI: NOT FOUND" Red
    }
    $c = Load-Config
    if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) {
        try {
            $sbCli = Get-SingBoxCli
            Write-Color "sing-box CLI  : $sbCli"
        } catch {
            Write-Color "sing-box CLI  : NOT FOUND" Red
        }
        if ($c.singbox.configPath) {
            if (Test-Path -LiteralPath $c.singbox.configPath -PathType Leaf) {
                Write-Color "sing-box cfg  : $($c.singbox.configPath) (OK)"
            } else {
                Write-Color "sing-box cfg  : $($c.singbox.configPath) (NOT FOUND)" Red
            }
        } else {
            Write-Color "sing-box cfg  : NOT SET" Yellow
        }
    }
    Status
    Test-Proxy
    Write-Host ""
    Write-Color "Enabled rules:" Cyan
    $hasRules = $false
    foreach($a in @($c.apps | Where-Object enabled)) {
        if($a.kind -eq "exe") {
            Write-Color "  PROXY $($a.process)" Green
            $hasRules = $true
        } else {
            Write-Color "  WRAPPER(no rule) $($a.id)" Yellow
            $hasRules = $true
        }
    }
    if(-not $hasRules) {
        Write-Host "  无。"
    }
    Write-Host ""
    $running = Is-Running
    Write-Color "Bridge running: $running" $(if($running){"Green"}else{"Red"})
    if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) {
        $sbRunning = Is-SingBoxRunning
        Write-Color "sing-box run  : $sbRunning" $(if($sbRunning){"Green"}else{"Red"})
    }
    Write-Host ""
    if(-not $running) {
        Write-Color "提示: 运行 proxy start 启动全部服务"
    }
}

Ensure-Root
$KnownCommands = @("init","config","add","rm","remove","ls","list","on","enable","off","disable","which","tree","update","apply","start","stop","restart","status","test","doctor","profile","help","singbox","run","chrome","system")
$cmd=if($args.Count){$args[0].ToLowerInvariant()}else{"help"}

Write-Log "Command: proxy $cmd $($args -join ' ')"
$proxyArgs = $args

try {
    switch($cmd) {
        "init" { Init }
        "add" { if($args.Count -lt 2){throw "proxy add <name|exe|path>"}; Add-App $args[1] }
        "rm" { if($args.Count -lt 2){throw "proxy rm <name>"}; Remove-App $args[1] }
        "remove" { if($args.Count -lt 2){throw "proxy remove <name>"}; Remove-App $args[1] }
        "ls" { Show-List }
        "list" { Show-List }
        "on" { if($args.Count -lt 2){throw "proxy on <name>"}; Set-AppEnabled $args[1] $true }
        "enable" { if($args.Count -lt 2){throw "proxy enable <name>"}; Set-AppEnabled $args[1] $true }
        "off" { if($args.Count -lt 2){throw "proxy off <name>"}; Set-AppEnabled $args[1] $false }
        "disable" { if($args.Count -lt 2){throw "proxy disable <name>"}; Set-AppEnabled $args[1] $false }
        "which" { if($args.Count -lt 2){throw "proxy which <name>"}; Show-Which $args[1] }
        "tree" { if($args.Count -lt 2){throw "proxy tree <name>"}; Show-Tree $args[1] }
        "update" { Update-Bridge }
        "apply" { Update-Bridge }
        "start" {
            $c = Load-Config
            if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) { Start-SingBox }
            Start-Bridge
        }
        "stop" {
            Stop-Bridge
            $c = Load-Config
            if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) { Stop-SingBox }
        }
        "restart" {
            $c = Load-Config
            if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) { Stop-SingBox }
            Stop-Bridge
            if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) { Start-SingBox }
            Start-Bridge
        }
        "status" { Status }
        "test" { Test-Proxy }
        "doctor" { Doctor }
        "profile" {
            $c=Load-Config; Write-Profile $c; Get-Content $ProfileFile -Raw | Write-Host
        }
        "singbox" {
            if($args.Count -lt 2){throw "proxy singbox start|stop|status|config <exe路径> <配置文件路径>"}
            switch($args[1]) {
                "start"  { Start-SingBox }
                "stop"   { Stop-SingBox }
                "status" {
                    $c = Load-Config
                    if (($c.PSObject.Properties.Name -contains 'singbox') -and $c.singbox.enabled) {
                        $sbRunning = Is-SingBoxRunning
                        Write-Color "sing-box: $(if($sbRunning){"RUNNING PID=$(Get-SingBoxPid)"}else{"STOPPED"})" $(if($sbRunning){"Green"}else{"Red"})
                        Write-Host "  exePath    : $($c.singbox.exePath)"
                        Write-Host "  configPath : $($c.singbox.configPath)"
                    } else {
                        Write-Color "sing-box: 未配置" Yellow
                        Write-Host "  运行 proxy singbox config <exe路径> <配置文件路径> 进行配置"
                    }
                }
                "config" {
                    if($args.Count -lt 4){throw "proxy singbox config <exe路径> <配置文件路径>"}
                    Set-SingBoxConfig $args[2] $args[3]
                }
                default { throw "未知 singbox 命令: $($args[1])" }
            }
        }
        "config" {
            if($args.Count -lt 2){throw "proxy config show|set ..."}
            if($args[1] -eq "show") {
                $c=Load-Config
                $c.proxy | ConvertTo-Json | Write-Host
            } elseif($args[1] -eq "set") {
                if($args.Count -lt 5){throw "proxy config set <socks5|http> <host> <port>"}
                Set-Proxy $args[2] $args[3] $args[4]
            } else { throw "未知 config 命令。" }
        }
        "run" {
            if ($args.Count -lt 2) { throw "proxy run <command> [args...]" }
            $runCmd = $args[1]
            $runArgs = $args[2..($args.Count-1)]
            Run-ThroughProxy $runCmd $runArgs
        }
        "chrome" {
            $c = Load-Config
            $hostPort = "$($c.proxy.host):$($c.proxy.port)"
            $proxyType = $c.proxy.type
            Write-Host "启动 Chrome（走代理: ${proxyType}://${hostPort}）..."
            Write-Host "  使用独立 profile（可多开、数据隔离）"
            $chromeArgs = @(
                "--proxy-server=`"${proxyType}://${hostPort}`"",
                "--host-resolver-rules=`"MAP * ~NOTFOUND , EXCLUDE 127.0.0.1`"",
                "--user-data-dir=`"$env:USERPROFILE\.proxy\chrome-proxy-profile`""
            )
            Start-Process "chrome.exe" -ArgumentList $chromeArgs
        }
        "system" {
            $c = Load-Config
            $sysHost = $c.proxy.host
            $sysPort = $c.proxy.port
            $sysType = $c.proxy.type
            if ($args.Count -gt 1 -and $args[1] -eq "off") {
                Write-Host "关闭系统代理..."
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
                netsh winhttp reset proxy 2>&1 | Out-Null
                Write-Color "系统代理已关闭" Green
            } else {
                Write-Host "设置系统代理: ${sysType}://${sysHost}:${sysPort}"
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value "${sysType}://${sysHost}:${sysPort}"
                Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyOverride -Value "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*"
                Write-Color "系统代理已开启: ${sysType}://${sysHost}:${sysPort}" Green
                Write-Host "  Chrome/Edge 等浏览器将自动走代理"
                Write-Host "  运行 proxy system off 关闭系统代理"
            }
        }
        "help" { Help }
        default {
            if ($KnownCommands -notcontains $cmd) {
                Run-ThroughProxy @args
            } else {
                Help; exit 1
            }
        }
    }
} catch {
    Write-Color "Error: $($_.Exception.Message)" Red
    Write-Log "Error: $($_.Exception.Message)"
    exit 1
}
