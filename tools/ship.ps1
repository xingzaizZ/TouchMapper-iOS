# 推送 + 触发构建 + 取回 IPA
#
# 用法（PowerShell）：
#   $env:GITHUB_TOKEN = "<你的 PAT>"
#   ./tools/ship.ps1
#
# token 需要有 repo 与 workflow 权限。

param(
    [string]$Repo = "xingzaizZ/TouchMapper-iOS",
    [string]$Branch = "main",
    [string]$OutFile = "TouchMapper-unsigned.ipa"
)

$ErrorActionPreference = "Stop"

if (-not $env:GITHUB_TOKEN) {
    throw "先设置环境变量 GITHUB_TOKEN"
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    # 1) 推送
    Write-Host "==> 推送到 $Repo ($Branch)" -ForegroundColor Cyan
    $remote = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$Repo.git"
    git push $remote "HEAD:$Branch"
    if ($LASTEXITCODE -ne 0) { throw "push 失败" }

    $api = "https://api.github.com/repos/$Repo"
    $headers = @{
        Authorization = "Bearer $($env:GITHUB_TOKEN)"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "touchmapper-ship"
    }

    # 2) 触发 workflow_dispatch
    Write-Host "==> 触发 Build IPA" -ForegroundColor Cyan
    $body = @{
        ref    = $Branch
        inputs = @{
            sign_mode      = "unsigned"
            create_release = "true"
        }
    } | ConvertTo-Json

    Invoke-RestMethod -Method Post -Uri "$api/actions/workflows/build-ipa.yml/dispatches" `
        -Headers $headers -Body $body -ContentType "application/json"

    # 3) 等这次 run 出现
    Write-Host "==> 等待构建启动" -ForegroundColor Cyan
    $run = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 4
        $runs = Invoke-RestMethod -Uri "$api/actions/workflows/build-ipa.yml/runs?per_page=5" -Headers $headers
        $run = $runs.workflow_runs | Where-Object { $_.event -eq "workflow_dispatch" } | Select-Object -First 1
        if ($run -and $run.status -ne "queued") { break }
        if ($run) { break }
    }
    if (-not $run) { throw "没等到 workflow run" }

    Write-Host "    run #$($run.run_number)  $($run.html_url)" -ForegroundColor Yellow

    # 4) 轮询到结束
    Write-Host "==> 构建中（首次约 5-10 分钟）" -ForegroundColor Cyan
    while ($true) {
        Start-Sleep -Seconds 20
        $cur = Invoke-RestMethod -Uri "$api/actions/runs/$($run.id)" -Headers $headers
        Write-Host "    [$($cur.status)] $($cur.conclusion)"
        if ($cur.status -eq "completed") {
            if ($cur.conclusion -ne "success") {
                Write-Host "==> 构建失败：$($cur.html_url)" -ForegroundColor Red
                exit 1
            }
            break
        }
    }

    # 5) 取 artifact 下载链接
    Write-Host "==> 下载 IPA" -ForegroundColor Cyan
    $arts = Invoke-RestMethod -Uri "$api/actions/runs/$($run.id)/artifacts" -Headers $headers
    $art = $arts.artifacts | Where-Object { $_.name -eq "TouchMapper-ipa" } | Select-Object -First 1
    if (-not $art) { throw "没找到 TouchMapper-ipa artifact" }

    $zipPath = Join-Path $root "ipa-artifact.zip"
    Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zipPath

    Expand-Archive -Path $zipPath -DestinationPath (Join-Path $root "ipa-out") -Force
    Remove-Item $zipPath -Force

    $ipa = Get-ChildItem (Join-Path $root "ipa-out") -Filter *.ipa | Select-Object -First 1
    if (-not $ipa) { throw "压缩包里没有 ipa" }

    $target = Join-Path $root $OutFile
    Copy-Item $ipa.FullName $target -Force

    $hash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
    Write-Host ""
    Write-Host "==> 完成" -ForegroundColor Green
    Write-Host "    IPA : $target"
    Write-Host "    大小: $([math]::Round((Get-Item $target).Length / 1MB, 2)) MB"
    Write-Host "    SHA256: $hash"
    Write-Host "    构建页: $($run.html_url)"
}
finally {
    Pop-Location
}
