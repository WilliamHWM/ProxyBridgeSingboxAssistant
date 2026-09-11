$ErrorActionPreference="Stop"
$bin=Join-Path $env:USERPROFILE "bin"

# Remove proxy CLI files
Remove-Item "$bin\proxy.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "$bin\proxy.cmd" -Force -ErrorAction SilentlyContinue
Remove-Item "$bin\install.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "$bin\uninstall.ps1" -Force -ErrorAction SilentlyContinue

# Clean up PATH
$path=[Environment]::GetEnvironmentVariable("Path","User")
if($path){
    $items=@($path -split ';' | Where-Object {$_ -and ($_.Trim() -ne '')})
    $newItems=@($items | Where-Object { $_ -ne $bin -and $_ -notmatch 'proxy-cli' })
    if ($newItems.Count -ne $items.Count) {
        [Environment]::SetEnvironmentVariable("Path",($newItems -join ';'),"User")
    }
}

# Optionally remove config and data
Write-Host ""
Write-Host "proxy CLI removed." -ForegroundColor Green
Write-Host ""
Write-Host "User profile data (%USERPROFILE%\.proxy) was kept."
Write-Host ""
Write-Host "To also remove all proxy data, delete this folder:" -ForegroundColor Cyan
Write-Host "  %USERPROFILE%\.proxy"
Write-Host ""
Write-Host "To remove everything including config, run:" -ForegroundColor Cyan
Write-Host "  Remove-Item $env:USERPROFILE\.proxy -Recurse -Force"
Write-Host ""
