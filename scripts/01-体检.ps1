#requires -Version 5.1
<#
    全流程体检（只读，不改任何东西）
    ============================================================
    把「重装前要准备的东西」和「重装后要确认的状态」一次性核一遍，
    缺什么直接告诉你缺什么、哪个脚本去补。

    用法：
        开始.cmd  →  1
        或： powershell -ExecutionPolicy Bypass -File 01-体检.ps1
            powershell -ExecutionPolicy Bypass -File 01-体检.ps1 -Deep

    退出码：0 = 没有 FAIL；1 = 有 FAIL（此时不要继续下一步）
#>
[CmdletBinding()]
param(
    [string]$Iso = 'D:\软件包\系统\Win10_IoT_Enterprise_LTSC_2021_64-Bit_2608.iso',
    [switch]$Deep      # 对出厂镜像做逐文件 SHA256（约 16 分钟）
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'preflight' | Out-Null
Write-Head "重装工程包体检"
Write-Info ("工程包: " + $script:KitRoot)
Write-Info ("时间  : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Info ("权限  : " + $(if (Test-Admin) { '管理员' } else { '普通用户（部分检查会跳过）' }))

$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Level, [string]$Item, [string]$Detail)
    $null = $checks.Add([pscustomobject]@{ Level = $Level; Item = $Item; Detail = $Detail })
    $tag = ''
    $color = 'Gray'
    switch ($Level) {
        'OK'    { $tag = '[OK]  '; $color = 'Green' }
        'WARN'  { $tag = '[警告]'; $color = 'Yellow' }
        'FAIL'  { $tag = '[失败]'; $color = 'Red' }
        default { $tag = '[信息]'; $color = 'Gray' }
    }
    Write-Host ("  {0} {1,-14} {2}" -f $tag, $Item, $Detail) -ForegroundColor $color
}

# ================================================================= 1 环境
Write-Step "1. 环境"

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$build = 0
if ($os) {
    $build = [int]$os.BuildNumber
    $caption = $os.Caption
    if ($build -ge 22000) {
        Add-Check 'INFO' '当前系统' ("{0} (build {1}) —— 还没重装" -f $caption, $build)
    }
    elseif ($build -ge 19041 -and $build -le 19045) {
        Add-Check 'OK' '当前系统' ("{0} (build {1}) —— 已是 Win10" -f $caption, $build)
    }
    else {
        Add-Check 'WARN' '当前系统' ("{0} (build {1}) —— 版本比较少见" -f $caption, $build)
    }
} else {
    Add-Check 'WARN' '当前系统' '查不到 Win32_OperatingSystem'
}

$sysDiskNo = Get-SystemDiskNumber
if ($null -ne $sysDiskNo) {
    $sd = Get-Disk -Number $sysDiskNo -ErrorAction SilentlyContinue
    if ($sd) {
        Add-Check 'OK' '系统盘' ("磁盘 {0}  {1}  {2}" -f $sd.Number, $sd.FriendlyName, (Format-Human $sd.Size))
    }
} else {
    Add-Check 'FAIL' '系统盘' '定位不到系统所在磁盘'
}

$c = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
if ($c) {
    Add-Check 'OK' 'C 盘' ("总 {0} / 可用 {1}" -f (Format-Human $c.Size), (Format-Human $c.SizeRemaining))
}

$d = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
if ($d) {
    if ($d.SizeRemaining -gt 30GB) {
        Add-Check 'OK' 'D 盘' ("总 {0} / 可用 {1}" -f (Format-Human $d.Size), (Format-Human $d.SizeRemaining))
    } else {
        Add-Check 'WARN' 'D 盘' ("可用只剩 " + (Format-Human $d.SizeRemaining) + "，备份可能不够")
    }
    if ($d.FileSystemLabel -ne 'DATA') {
        Add-Check 'WARN' 'D 盘卷标' ("卷标是 '{0}'，不是 DATA（bootstrap 靠卷标找盘）" -f $d.FileSystemLabel)
    } else {
        Add-Check 'OK' 'D 盘卷标' 'DATA'
    }
} else {
    Add-Check 'FAIL' 'D 盘' '没有 D: 盘 —— 工程包必须在 D 盘上'
}

if (-not (Test-Path -LiteralPath 'D:\migration')) {
    Add-Check 'WARN' 'D:\migration' '不存在 —— 当前可能已重装或 D 盘未接'
} else {
    Add-Check 'OK' 'D:\migration' '存在'
}

# ================================================================= 2 备份
Write-Step "2. 阶段 0 备份"

$backupRoot = Join-Path $script:KitRoot 'backup'
$latest = $null
if (Test-Path -LiteralPath $backupRoot) {
    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
}
if (-not $latest) {
    Add-Check 'FAIL' '备份' 'backup\ 下没有任何备份 —— 先跑「2 备份 C 盘漏网数据」'
}
else {
    $manifest = Join-Path $latest.FullName '恢复清单.md'
    $files = @(Get-ChildItem -LiteralPath $latest.FullName -Recurse -File -ErrorAction SilentlyContinue)
    $sum = 0
    if ($files.Count -gt 0) {
        $m = $files | Measure-Object -Property Length -Sum
        $sum = [int64]$m.Sum
    }
    if ($files.Count -lt 50) {
        Add-Check 'WARN' '备份' ("{0} 只有 {1} 个文件，看起来不完整" -f $latest.Name, $files.Count)
    } else {
        Add-Check 'OK' '备份' ("{0}  {1} 个文件 / {2}" -f $latest.Name, $files.Count, (Format-Human $sum))
    }
    if (Test-Path -LiteralPath $manifest) { Add-Check 'OK' '恢复清单.md' '存在' }
    else { Add-Check 'WARN' '恢复清单.md' '缺失（不影响数据，但恢复时要靠自己找）' }

    foreach ($need in @('AppData\Local\JetBrains', 'AppData\Local\Microsoft\VisualStudio', '.ssh')) {
        $p = Join-Path $latest.FullName $need
        if (Test-Path -LiteralPath $p) { Add-Check 'OK' ("备份·" + $need) '在' }
        else { Add-Check 'WARN' ("备份·" + $need) '没备到（源目录可能本来就没有）' }
    }
}

# ================================================================= 3 链接清单
Write-Step "3. 链接清单 links.csv"

$csvPath = Join-Path $script:KitRoot 'links.csv'
if (-not (Test-Path -LiteralPath $csvPath)) {
    Add-Check 'FAIL' 'links.csv' '不存在'
} else {
    try {
        $rows = (Get-Content -LiteralPath $csvPath -Encoding UTF8 -Raw) | ConvertFrom-Csv
        Add-Check 'OK' 'links.csv' ("{0} 条映射" -f @($rows).Count)
        $miss = @()
        foreach ($r in $rows) {
            if (-not (Test-Path -LiteralPath $r.target)) { $miss += $r.rel }
        }
        if ($miss.Count -eq 0) {
            Add-Check 'OK' '链接目标' ("{0}/{0} 个 D 盘目标都在" -f @($rows).Count)
        } elseif ($miss.Count -eq @($rows).Count) {
            Add-Check 'WARN' '链接目标' '全部不在 —— 刚重装完、D 盘还没识别时属正常'
        } else {
            Add-Check 'WARN' '链接目标' ("{0} 个目标不存在，例如 {1}" -f $miss.Count, $miss[0])
        }
    } catch {
        Add-Check 'FAIL' 'links.csv' ('解析失败: ' + $_.Exception.Message)
    }
}

# ================================================================= 4 软件清单
Write-Step "4. 软件清单"

foreach ($name in @('packages-core.json', 'packages-all.json')) {
    $p = Join-Path $script:KitRoot $name
    if (-not (Test-Path -LiteralPath $p)) { Add-Check 'FAIL' $name '不存在'; continue }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $cnt = 0
        if ($j.Sources -and $j.Sources[0].Packages) { $cnt = @($j.Sources[0].Packages).Count }
        Add-Check 'OK' $name ("{0} 个包" -f $cnt)
    } catch {
        Add-Check 'FAIL' $name ('JSON 解析失败: ' + $_.Exception.Message)
    }
}

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
    Add-Check 'OK' 'winget' '可用（重装后 LTSC 不自带，靠离线包）'
} else {
    Add-Check 'WARN' 'winget' '当前系统没有 —— 重装后必须先装 App Installer'
}

$appInst = Join-Path $script:KitRoot 'pkgs\appinstaller'
if (Test-Path -LiteralPath $appInst) {
    $msix = @(Get-ChildItem -LiteralPath $appInst -File -ErrorAction SilentlyContinue)
    if ($msix.Count -ge 2) {
        Add-Check 'OK' '离线包' ("{0} 个文件 / {1}" -f $msix.Count, (Format-Human (($msix | Measure-Object Length -Sum).Sum)))
    } else {
        Add-Check 'WARN' '离线包' ("只有 {0} 个文件，跑「3 准备离线包」补全" -f $msix.Count)
    }
} else {
    Add-Check 'FAIL' '离线包' 'pkgs\appinstaller 不存在 —— LTSC 装完没有 winget，跑「3 准备离线包」'
}

# ================================================================= 5 安装介质
Write-Step "5. 安装介质（ISO + 应答文件）"

$isoOk = $false
if (-not (Test-Path -LiteralPath $Iso)) {
    Add-Check 'FAIL' 'ISO' ("找不到 " + $Iso)
} else {
    $fi = Get-Item -LiteralPath $Iso
    Add-Check 'OK' 'ISO 文件' ("{0}  {1}" -f $fi.Name, (Format-Human $fi.Length))

    Write-Info '  正在挂载 ISO 读取映像名（约 5 秒）...'
    $r = Get-IsoImageNames -IsoPath $Iso
    if ($r.Ok) {
        $isoOk = $true
        Add-Check 'OK' 'ISO 映像' ("{0}: {1}" -f $r.File, ($r.Names -join ' | '))
    } else {
        if (-not (Test-Admin)) {
            Add-Check 'WARN' 'ISO 映像' ($r.Error + '（普通权限读不出时，可在「4 做U盘」里以管理员再核对）')
        } else {
            Add-Check 'WARN' 'ISO 映像' ($r.Error + '（不影响做 U 盘，装机时在版本选择页核对一眼）')
        }
    }
}

$xmls = @(Get-ChildItem -LiteralPath $script:KitRoot -Filter 'autounattend*.xml' -File -ErrorAction SilentlyContinue)
if ($xmls.Count -eq 0) {
    Add-Check 'FAIL' '应答文件' '一个都没有'
}

# 先算一遍每个应答文件要装的映像名，再判断哪个能配这支 ISO
$xmlRows = @()
foreach ($x in $xmls) {
    $row = [pscustomobject]@{ Name = $x.Name; Image = ''; SyntaxOk = $true; Match = $false; HasImage = $false }
    if (-not (Test-XmlFile -Path $x.FullName)) { $row.SyntaxOk = $false; $xmlRows += $row; continue }
    $raw = Get-Content -LiteralPath $x.FullName -Raw -Encoding UTF8
    $m = [regex]::Match($raw, '(?s)<ImageInstall>.*?</ImageInstall>')
    if ($m.Success) {
        $vm = [regex]::Match($m.Value, '<Value>([^<]*)</Value>')
        if ($vm.Success) {
            $row.Image = $vm.Groups[1].Value.Trim()
            $row.HasImage = $true
            if ($isoOk -and ($r.Names -contains $row.Image)) { $row.Match = $true }
        }
    }
    $xmlRows += $row
}

$matchedXml = @($xmlRows | Where-Object { $_.Match })
foreach ($row in $xmlRows) {
    $title = "XML·" + $row.Name
    if (-not $row.SyntaxOk) { Add-Check 'FAIL' $title 'XML 语法错误'; continue }
    if (-not $row.HasImage) { Add-Check 'OK' $title '语法正常（不指定映像，安装时手选）'; continue }
    if (-not $isoOk) { Add-Check 'OK' $title ('映像名: ' + $row.Image); continue }

    if ($row.Match) {
        Add-Check 'OK' $title ('映像名匹配: ' + $row.Image)
    } elseif ($matchedXml.Count -gt 0) {
        Add-Check 'INFO' $title ('不适用于这支 ISO（要 ' + $row.Image + '，那是官方镜像用的）')
    } else {
        Add-Check 'FAIL' $title ("映像名 '{0}' 在这支 ISO 里不存在" -f $row.Image)
    }
}
if ($matchedXml.Count -gt 0) {
    Add-Check 'OK' '可用于装机' (($matchedXml | ForEach-Object { $_.Name }) -join ', ')
}

$usb = Get-UsbDisks
if ($usb.Count -eq 0) {
    Add-Check 'WARN' 'U 盘' '当前没插 U 盘（做盘时再插）'
} else {
    foreach ($u in $usb) { Add-Check 'OK' 'U 盘' ("磁盘 {0} {1} {2} 盘符 {3} 卷标 {4}" -f $u.Number, $u.Friendly, (Format-Human $u.SizeBytes), $u.DriveLetter, $u.Label) }
}

# ================================================================= 6 出厂镜像
Write-Step "6. 出厂镜像备份"

$factory = Join-Path $script:KitRoot 'DellFactoryImage'
$manJson = Join-Path $factory 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $manJson)) {
    Add-Check 'FAIL' '出厂镜像' 'DellFactoryImage\MANIFEST.json 不存在'
} else {
    try {
        $man = Get-Content -LiteralPath $manJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @($man.Files)
        if ($entries.Count -eq 0) { $entries = @($man.entries) }
        if ($entries.Count -eq 0) { $entries = @($man) }
        Add-Check 'OK' '清单' ("{0} 个文件条目" -f $entries.Count)

        $missing = 0; $badSize = 0; $realCount = 0
        $realSum = 0
        foreach ($e in $entries) {
            $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
            if (-not $abs) { continue }
            if (-not (Test-Path -LiteralPath $abs)) { $missing++; continue }
            $realCount++
            $realSum += (Get-Item -LiteralPath $abs).Length
            $expSize = $e.bytes; if (-not $expSize) { $expSize = $e.Size }
            if ($expSize -and ([int64]$expSize -ne (Get-Item -LiteralPath $abs).Length)) { $badSize++ }
        }
        if ($missing -eq 0 -and $badSize -eq 0) {
            Add-Check 'OK' '文件完整性' ("{0}/{0} 个文件存在且大小一致 / {1}" -f $realCount, (Format-Human $realSum))
        } else {
            Add-Check 'FAIL' '文件完整性' ("缺失 {0} 个 / 大小不符 {1} 个" -f $missing, $badSize)
        }

        $swm = Join-Path $factory 'P5_Image\Image\install.swm'
        if (Test-Path -LiteralPath $swm) { Add-Check 'OK' 'install.swm' '在（还原系统用这个）' }
        else { Add-Check 'FAIL' 'install.swm' '缺失 —— 还原系统会失败' }

        $winre = Join-Path $factory 'P5_Image\Image\winre.wim'
        if (Test-Path -LiteralPath $winre) { Add-Check 'OK' 'winre.wim' '在' }
        else { Add-Check 'WARN' 'winre.wim' '缺失（不影响系统还原，只影响修恢复环境）' }

        if ($Deep) {
            Write-Info '  逐文件 SHA256（约 16 分钟，实时显示进度，请勿关闭窗口）...'
            $bad = 0; $i = 0
            foreach ($e in $entries) {
                $i++
                $abs = Resolve-FactoryPath -FactoryRoot $factory -Entry $e
                if (-not $abs) { continue }
                if (-not (Test-Path -LiteralPath $abs)) { continue }
                $hash = Get-Sha256WithProgress -Path $abs -KeepLine `
                        -Label ("[{0}/{1}] {2}" -f $i, $entries.Count, (Split-Path $abs -Leaf))
                if ($e.sha256 -and $hash -ne $e.sha256) { $bad++; Write-Host ""; Write-Warn ("哈希不符: " + $e.rel) }
            }
            Write-Host ""
            if ($bad -eq 0) { Add-Check 'OK' 'SHA256 深度校验' ("{0} 个全部通过" -f $entries.Count) }
            else { Add-Check 'FAIL' 'SHA256 深度校验' ("{0} 个不符" -f $bad) }
        }
    } catch {
        Add-Check 'FAIL' '出厂镜像' ('MANIFEST 解析失败: ' + $_.Exception.Message)
    }
}

# ================================================================= 7 恢复分区
Write-Step "7. Dell 恢复分区现状"

if ($null -ne $sysDiskNo) {
    $rec = @(Get-DellRecoveryPartitions -DiskNumber $sysDiskNo)
    if ($rec.Count -eq 0) {
        Add-Check 'OK' '恢复分区' '已不存在（已回收过）'
    } else {
        $total = ($rec | Measure-Object SizeBytes -Sum).Sum
        foreach ($p in $rec) {
            $mark = ''
            if ($p.IsDell) { $mark = '  <- Dell' } else { $mark = '  <- 非 Dell 卷标，脚本不会动它' }
            Add-Check 'INFO' ("分区 " + $p.PartitionNumber) ("{0,-12} {1}{2}" -f $p.Label, (Format-Human $p.SizeBytes), $mark)
        }
        Add-Check 'INFO' '合计可回收' (Format-Human $total)
        if ($rec.Count -ge 3 -and @($rec | Where-Object { $_.IsDell }).Count -eq 3) {
            Add-Check 'OK' '回收条件' '三个 Dell 分区齐全，可用「8 回收恢复分区」'
        } else {
            Add-Check 'WARN' '回收条件' '分区构成与预期不符，回收脚本会拒绝执行'
        }
    }
}

# ================================================================= 汇总
Write-Head "结论"

$fail = @($checks | Where-Object { $_.Level -eq 'FAIL' })
$warn = @($checks | Where-Object { $_.Level -eq 'WARN' })

Write-Info ("通过 {0} 项 / 警告 {1} 项 / 失败 {2} 项" -f `
    @($checks | Where-Object { $_.Level -eq 'OK' }).Count, $warn.Count, $fail.Count)

if ($fail.Count -gt 0) {
    Write-Host ""
    Write-Err "以下问题必须先解决："
    foreach ($f in $fail) { Write-Host ("    · {0} —— {1}" -f $f.Item, $f.Detail) -ForegroundColor Red }
    Write-Host ""
    Write-Info "对照处理："
    Write-Info "  备份缺失        -> 菜单 2"
    Write-Info "  离线包缺失      -> 菜单 3"
    Write-Info "  ISO/应答文件    -> 见 00-重装总手册.md 第 4 节"
} else {
    Write-Host ""
    Write-Ok "没有阻塞项。可以按菜单顺序往下走。"
    if ($build -ge 22000) {
        Write-Info "下一步：菜单 2（备份）→ 4（做 U 盘）→ 6（重启装机）"
    } else {
        Write-Info "下一步：菜单 7（重建链接+装软件）→ 9（收尾）"
    }
}

Write-Host ""
Write-Host ("日志: " + $script:LogFile) -ForegroundColor DarkGray
Stop-KitLog

if ($fail.Count -gt 0) { exit 1 } else { exit 0 }
