<#
    .SYNOPSIS
    撤销整理：把文件与文件夹还原到整理前的位置。
    默认撤销最近一次；也可用 -LogFile 指定某次日志。
#>
param(
    [string]$LogFile,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$historyDir = Join-Path $scriptDir 'history'

if (-not (Test-Path -LiteralPath $historyDir)) {
    Write-Host '还没有任何整理记录。' -ForegroundColor Yellow
    exit 0
}

$logs = @(Get-ChildItem -LiteralPath $historyDir -Filter 'undo-*.json' | Sort-Object Name -Descending)

if ($List) {
    Write-Host ''
    Write-Host "=== 整理记录（共 $($logs.Count) 次）===" -ForegroundColor Cyan
    $logs | ForEach-Object { Write-Host "  $($_.Name)" }
    exit 0
}

if (-not $LogFile) {
    if ($logs.Count -eq 0) { Write-Host '还没有任何整理记录。' -ForegroundColor Yellow; exit 0 }
    $LogFile = $logs[0].FullName
}
elseif (-not (Test-Path -LiteralPath $LogFile)) {
    throw "找不到撤销日志: $LogFile"
}

$raw = [IO.File]::ReadAllText($LogFile, [System.Text.Encoding]::UTF8)
$ops = $raw | ConvertFrom-Json
if ($ops -isnot [array]) { $ops = @($ops) }

Write-Host ''
Write-Host "=== 撤销：$(Split-Path -Leaf $LogFile) ===" -ForegroundColor Yellow
Write-Host "共 $($ops.Count) 项，开始还原..."
Write-Host ''

# 先还原文件，再还原文件夹：否则文件会被困在尚未还原的文件夹里
$ordered = @($ops | Sort-Object { if ($_.kind -eq 'Folder') { 1 } else { 0 } })

$ok = 0
foreach ($op in $ordered) {
    try {
        if (Test-Path -LiteralPath $op.to) {
            $parent = Split-Path -Parent $op.from
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $op.to -Destination $op.from -Force -ErrorAction Stop
            $ok++
        }
        else {
            Write-Host "  [已不在原位，跳过] $($op.to)" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  [还原失败] $($op.to): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "还原完成：$ok / $($ops.Count) 项已回到原位" -ForegroundColor Green
