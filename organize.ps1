<#
    .SYNOPSIS
    桌面整理工具 —— 按客户归档业务文件，杂物分类存放。
    只移动，不改名、不删除、不修改内容。
#>
param(
    [switch]$Apply,
    # 加这个开关表示"我确定这些文件不用了"，连最近改过的也一并归档
    [switch]$ForceHot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath   = Join-Path $scriptDir 'config.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { throw "找不到配置文件: $cfgPath" }
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$desktop      = $cfg.desktop
$businessRoot = Join-Path $desktop $cfg.businessRootName
$otherFolder  = Join-Path $businessRoot $cfg.otherFolderName
$hotDays      = [int]$cfg.hotDays
$cutoff       = (Get-Date).AddDays(-$hotDays)

$businessExt = @($cfg.businessExtensions  | ForEach-Object { $_.ToLower() })
$installExt  = @($cfg.installerExtensions | ForEach-Object { $_.ToLower() })
$imageExt    = @($cfg.imageExtensions     | ForEach-Object { $_.ToLower() })
$neverExt    = @($cfg.neverMoveExtensions | ForEach-Object { $_.ToLower() })

$plan    = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList

# 客户匹配：长名优先，避免 "Qin" 这类短名误吞其他客户
function Find-ClientFolder {
    param([string]$Name)
    foreach ($c in ($cfg.clients | Sort-Object { $_.key.Length } -Descending)) {
        if ($Name.ToLower().Contains($c.key.ToLower())) { return $c.folder }
    }
    return $null
}

# 内容识别给出的客户 key → 对应文件夹
function Get-ClientFolderByKey {
    param([string]$Key)
    foreach ($c in $cfg.clients) {
        if ($c.key.ToLower() -eq $Key.ToLower()) { return $c.folder }
    }
    return $null
}

# 扫描 PDF 正文，建立「文件名 → 内容判定的客户」。
# 扫描件读不出文本，不会出现在本映射里，最终兜底进「其他」。
$contentMap = @{}
$scanJs = Join-Path $scriptDir 'scanpdf.js'
if ($cfg.enableContentScan -and (Test-Path -LiteralPath $scanJs) -and (Get-Command node -ErrorAction SilentlyContinue)) {
    try {
        $raw = (& node $scanJs $desktop 2>$null | Out-String).Trim()
        if ($raw.StartsWith('[')) {
            foreach ($s in ($raw | ConvertFrom-Json)) {
                if ($s.best) { $contentMap[$s.file] = $s.best }
            }
        }
    }
    catch { }
}

# 目标已存在同名文件时加序号，绝不覆盖
function Get-FreePath {
    param([string]$Dir, [string]$Name)
    $base   = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext    = [IO.Path]::GetExtension($Name)
    $target = Join-Path $Dir $Name
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $Dir ($base + '_' + $i + $ext)
        $i++
    }
    return $target
}

# 移动文件夹：目标若已存在则逐项合并，避免 Move-Item 把文件夹塞进它自己内部（X\X）
function Move-FolderContents {
    param([string]$From, [string]$To)

    if (-not (Test-Path -LiteralPath $To)) {
        $parent = Split-Path -Parent $To
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Move-Item -LiteralPath $From -Destination $To -Force
        return
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
        $dest = Join-Path $To $item.Name
        $i    = 1
        while (Test-Path -LiteralPath $dest) {
            $base = [IO.Path]::GetFileNameWithoutExtension($item.Name)
            $ext  = [IO.Path]::GetExtension($item.Name)
            $dest = Join-Path $To ($base + '_' + $i + $ext)
            $i++
        }
        Move-Item -LiteralPath $item.FullName -Destination $dest -Force
    }

    # 源目录已空 → 移除空壳（只删空文件夹，不涉及任何文件）
    if (@(Get-ChildItem -LiteralPath $From -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $From -Force
    }
}

# ---------- 1. 桌面根目录的文件 ----------
$files = @(Get-ChildItem -LiteralPath $desktop -File -Force -ErrorAction SilentlyContinue |
    Where-Object { ($neverExt -notcontains $_.Extension.ToLower()) -and ($cfg.exclude -notcontains $_.Name) })

# ~$ 开头是 Office 的临时锁文件（文档关掉就自行消失），不搬也不删
if ($cfg.excludePrefixes) {
    $files = @($files | Where-Object {
        $keep = $true
        foreach ($p in $cfg.excludePrefixes) { if ($_.Name.StartsWith($p)) { $keep = $false } }
        $keep
    })
}

foreach ($f in $files) {
    # 活跃保护：最近 N 天动过的文件不动，避免刚下载就消失
    if (-not $ForceHot -and $f.LastWriteTime -gt $cutoff) {
        [void]$skipped.Add([pscustomobject]@{ Name = $f.Name; Reason = "最近 $hotDays 天内修改过，保护不动" })
        continue
    }

    $ext     = $f.Extension.ToLower()
    $destDir = $null
    $bucket  = $null

    if ($businessExt -contains $ext) {
        $cf  = Find-ClientFolder $f.Name
        $via = '文件名'
        # 文件名里没有客户名时，退一步看 PDF 正文里的 Borrower 是谁
        if (-not $cf -and $contentMap.ContainsKey($f.Name)) {
            $cf  = Get-ClientFolderByKey $contentMap[$f.Name]
            $via = '内容'
        }
        if ($cf) { $destDir = Join-Path $businessRoot $cf; $bucket = "客户 · $cf（${via}识别）" }
        else     { $destDir = $otherFolder;               $bucket = '其他（教程/通用）' }
    }
    elseif ($installExt -contains $ext) {
        $destDir = Join-Path $desktop '软件与安装包'; $bucket = '软件与安装包'
    }
    elseif ($imageExt -contains $ext) {
        $destDir = Join-Path $desktop '临时文件';     $bucket = '临时文件（截图）'
    }
    else {
        [void]$skipped.Add([pscustomobject]@{ Name = $f.Name; Reason = '类型未归类，保守不动' })
        continue
    }

    [void]$plan.Add([pscustomobject]@{
        Kind = 'File'; Name = $f.Name; From = $f.FullName
        To = (Get-FreePath $destDir $f.Name); Bucket = $bucket
    })
}

# ---------- 2. 归入业务大文件夹的现有文件夹 ----------
foreach ($fd in $cfg.foldersToBusiness) {
    $src = Join-Path $desktop $fd
    if ((Test-Path -LiteralPath $src) -and ($src -ne $businessRoot)) {
        [void]$plan.Add([pscustomobject]@{
            Kind = 'Folder'; Name = $fd; From = $src
            To = (Join-Path $businessRoot $fd); Bucket = '美国房贷业务'
        })
    }
}

# ---------- 输出计划 ----------
Write-Host ''
if ($Apply) { Write-Host '=== 桌面整理 【执行模式】 ===' -ForegroundColor Yellow }
else        { Write-Host '=== 桌面整理 【预览模式 · 不会动任何文件】 ===' -ForegroundColor Cyan }
$protectNote = if ($ForceHot) { '活跃保护: 已关闭（强制归档，刚改过的也搬）' } else { "活跃保护: $hotDays 天内修改过的不动" }
Write-Host "目标: $($cfg.businessRootName)    $protectNote"
Write-Host ''

if ($plan.Count -eq 0) {
    Write-Host '没有需要整理的项目。'
}
else {
    Write-Host "计划移动 $($plan.Count) 项：" -ForegroundColor White
    foreach ($g in ($plan | Group-Object Bucket | Sort-Object Name)) {
        Write-Host ''
        Write-Host "  ▸ $($g.Name)  ($($g.Count) 项)" -ForegroundColor Cyan
        foreach ($a in $g.Group) {
            $rel = $a.To.Replace($desktop, '').TrimStart('\')
            Write-Host "      $($a.Name)   →   $rel"
        }
    }
}

if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host "跳过 $($skipped.Count) 项（保持原位）：" -ForegroundColor DarkGray
    foreach ($s in $skipped) { Write-Host "      $($s.Name)   —   $($s.Reason)" -ForegroundColor DarkGray }
}

if (-not $Apply) {
    Write-Host ''
    Write-Host '预览结束，未改动任何文件。确认无误后加 -Apply 执行。' -ForegroundColor Yellow
    exit 0
}

# ---------- 执行 ----------
foreach ($d in @($businessRoot, $otherFolder)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# 文件夹必须先于文件移动：否则文件先创建出目标目录后，
# 后续移动的同名文件夹会被塞进它自己内部，形成 X\X 嵌套
$ordered = @($plan | Sort-Object { if ($_.Kind -eq 'Folder') { 0 } else { 1 } })

$moved = New-Object System.Collections.ArrayList
foreach ($a in $ordered) {
    try {
        if ($a.Kind -eq 'Folder') {
            Move-FolderContents -From $a.From -To $a.To
        }
        else {
            $parent = Split-Path -Parent $a.To
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Move-Item -LiteralPath $a.From -Destination $a.To -Force -ErrorAction Stop
        }
        [void]$moved.Add([pscustomobject]@{ from = $a.From; to = $a.To; kind = $a.Kind })
    }
    catch {
        Write-Host "  [失败] $($a.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}

$historyDir = Join-Path $scriptDir 'history'
if (-not (Test-Path -LiteralPath $historyDir)) { New-Item -ItemType Directory -Path $historyDir -Force | Out-Null }
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$undoFile = Join-Path $historyDir "undo-$stamp.json"

if ($moved.Count -gt 0) {
    $json = $moved | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($undoFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host "完成：成功移动 $($moved.Count) / $($plan.Count) 项" -ForegroundColor Green
if ($moved.Count -gt 0) { Write-Host "撤销日志 → $undoFile" -ForegroundColor Green }
