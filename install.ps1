$ErrorActionPreference="Stop"
$src=Split-Path -Parent $MyInvocation.MyCommand.Path
$bin=Join-Path $env:USERPROFILE "bin"

New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item "$src\proxy.ps1" "$bin\proxy.ps1" -Force
Copy-Item "$src\proxy.cmd" "$bin\proxy.cmd" -Force
Copy-Item "$src\install.ps1" "$bin\install.ps1" -Force
Copy-Item "$src\uninstall.ps1" "$bin\uninstall.ps1" -Force

# Add proxy CLI to PATH
$path=[Environment]::GetEnvironmentVariable("Path","User")
$items=@()
if($path){$items=$path -split ';' | Where-Object {$_ -and ($_.Trim() -ne '')}}
$items = @($items | Where-Object { $_ -ine $bin -and $_ -notmatch 'proxy-cli' })
$newItems = @($items + $bin)
if ($newItems -notcontains $bin) {
    [Environment]::SetEnvironmentVariable("Path",($newItems -join ';'),"User")
}

# Check for sing-box and add to PATH if found
$singBoxCandidates = @(
    "F:\ProgramFiles\sing-box\bin\data\sing-box",
    (Join-Path $env:ProgramFiles "sing-box"),
    (Join-Path $env:LOCALAPPDATA "sing-box")
)
$singBoxDir = $null
foreach ($d in $singBoxCandidates) {
    if (Test-Path -LiteralPath (Join-Path $d "sing-box.exe") -PathType Leaf) {
        $singBoxDir = $d
        break
    }
}
if ($singBoxDir) {
    $currentPath = [Environment]::GetEnvironmentVariable("Path","User")
    $pathItems = @()
    if($currentPath){$pathItems=$currentPath -split ';' | Where-Object {$_ -and ($_.Trim() -ne '')}}
    if ($pathItems -notcontains $singBoxDir) {
        $pathItems += $singBoxDir
        [Environment]::SetEnvironmentVariable("Path",($pathItems -join ';'),"User")
        Write-Host "  sing-box added to PATH: $singBoxDir" -ForegroundColor Green
    } else {
        Write-Host "  sing-box already in PATH: $singBoxDir" -ForegroundColor Cyan
    }
} else {
    Write-Host "  sing-box not found, skipping PATH config." -ForegroundColor Yellow
    Write-Host "  After installing sing-box, run: proxy singbox config [exePath] [configPath]"
}

Write-Host ""
Write-Host "  proxy CLI installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Location: $bin"
Write-Host ""
Write-Host "  Open a NEW terminal, then run:" -ForegroundColor Cyan
Write-Host "    proxy init"
Write-Host ""
Write-Host "  To uninstall, run:" -ForegroundColor Cyan
$uninstallCmd = 'powershell -ExecutionPolicy Bypass -File ' + $bin + '\uninstall.ps1'
Write-Host "    $uninstallCmd"
Write-Host ""
