#requires -Version 5.1
<#
    从 Windows.old 非破坏性恢复（阶段 4）
    ============================================================
    原则：
      - 只补缺失：目标里已存在的文件一律跳过，绝不覆盖
      - 目标目录不存在才新建；来源不存在则跳过
      - 恢复完成后执行 重建链接.ps1，把 .gitconfig/.ssh 等接回 C 盘用户目录

    默认干跑，只统计「需新增多少文件」，加 -Run 才真正复制。

    用法：
      powershell -ExecutionPolicy Bypass -File 从Windows.old恢复.ps1
      powershell -ExecutionPolicy Bypass -File 从Windows.old恢复.ps1 -Run
      powershell -ExecutionPolicy Bypass -File 从Windows.old恢复.ps1 -SkipEdge -Run

    日志：<Kit>\logs\restore-windowsold_<时间>.log
#>
[CmdletBinding()]
param(
    [string]$OldRoot = "C:\Windows.old\Users\$env:USERNAME",
    [string]$MigrationRoot = '',
    [switch]$Run,
    [switch]$SkipEdge
)

$ErrorActionPreference = 'Continue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitDir = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath (Join-Path $KitDir 'links.csv'))) { $KitDir = 'D:\Reinstall_Kit' }

# 迁移根：命令行参数优先，其次 kit.config.json；两处都没有就没法恢复
if (-not $MigrationRoot) {
    $kitCfgFile = Join-Path $KitDir 'kit.config.json'
    if (Test-Path -LiteralPath $kitCfgFile) {
        try {
            $kitCfg = Get-Content -LiteralPath $kitCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $MigrationRoot = [string]$kitCfg.migrationRoot
        } catch { }
    }
}
if (-not $MigrationRoot) {
    Write-Host "  [错误] 没有配置迁移根目录：kit.config.json 的 migrationRoot 为空。" -ForegroundColor Red
    Write-Host "         本脚本要把数据恢复到该目录，请先填好再跑。" -ForegroundColor Gray
    exit 2
}

$LogDir = Join-Path $KitDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath = Join-Path $LogDir "restore-windowsold_$Stamp.log"
$RcLog   = Join-Path $LogDir "restore-robocopy_$Stamp.log"   # robocopy 独立日志，不能和 Transcript 共用文件

Start-Transcript -Path $LogPath -Force | Out-Null

# 本脚本统计量
$script:OkCount = 0        # 有新增并成功的项
$script:OkFiles = 0        # 实际新增文件数
$script:OkBytes = 0        # 实际新增字节数
$script:SkipCount = 0      # 无需恢复/来源缺失的项
$script:FailCount = 0      # 失败的项
$script:PlanFiles = 0      # 干跑时的预计新增文件数
$script:PlanBytes = 0      # 干跑时的预计新增字节数

$UserHome  = $env:USERPROFILE
$DesktopDir = [Environment]::GetFolderPath('Desktop')
$DocsDir    = [Environment]::GetFolderPath('MyDocuments')
$PicsDir    = [Environment]::GetFolderPath('MyPictures')

function Format-Size {
    <#
        把字节数格式化成人类可读的文本
        参数：$Bytes 字节数
        返回：例如 "185.3 MB"
    #>
    param([double]$Bytes)
    foreach ($u in @('B', 'KB', 'MB', 'GB', 'TB')) {
        if ($Bytes -lt 1024) { return ('{0:N1} {1}' -f $Bytes, $u) }
        $Bytes = $Bytes / 1024
    }
    return ('{0:N1} PB' -f $Bytes)
}

function Get-TreeStat {
    <#
        统计目录里的文件数与总字节数
        参数：$Path 目录路径
        返回：含 Count / Bytes 的对象
    #>
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Count = $files.Count
        Bytes = [double](($files | Measure-Object -Sum Length).Sum)
    }
}

function Get-MergeStat {
    <#
        统计「把 $Src 合并到 $Dst」时有多少文件是目标缺少的
        先用目标现有文件的相对路径建哈希表，再逐项比对，避免上万次 Test-Path

        参数：$Src 来源目录、$Dst 目标目录
        返回：Total / TotalBytes（来源）、Missing / MissingBytes（需新增）
    #>
    param([string]$Src, [string]$Dst)

    $srcFiles = @(Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue)
    $exists = @{}
    if (Test-Path -LiteralPath $Dst -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dst -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($Dst.Length).TrimStart('\').ToLower()
            $exists[$rel] = $true
        }
    }

    $missCount = 0
    $missBytes = 0.0
    foreach ($f in $srcFiles) {
        $rel = $f.FullName.Substring($Src.Length).TrimStart('\').ToLower()
        if (-not $exists.ContainsKey($rel)) {
            $missCount++
            $missBytes += $f.Length
        }
    }

    [pscustomobject]@{
        Total        = $srcFiles.Count
        TotalBytes   = [double](($srcFiles | Measure-Object -Sum Length).Sum)
        Missing      = $missCount
        MissingBytes = $missBytes
    }
}

function Invoke-RobocopyMerge {
    <#
        非破坏式合并：/XO /XN /XC 三个排除项叠加后，只有目标里不存在的文件会被复制
        参数：$Src 来源、$Dst 目标、$LogFile 追加日志
        返回：含 ExitCode 的对象（robocopy 0-7 都算成功）
    #>
    param([string]$Src, [string]$Dst, [string]$LogFile)

    # 直接调用时参数按数组元素原样传递，不需要额外加引号
    $rcArgs = @(
        $Src, $Dst,
        '/E', '/XO', '/XN', '/XC', '/XJ', '/R:1', '/W:1', '/MT:8',
        '/NFL', '/NDL', '/NP', '/NJH', '/NJS',
        ('/LOG+:' + $LogFile)
    )
    # 直接调用控制台程序：$LASTEXITCODE 可靠；Start-Process -Wait 在进程秒退时会抛异常
    & robocopy.exe @rcArgs 2>&1 | Out-Null
    [pscustomobject]@{ ExitCode = $LASTEXITCODE }
}

function Restore-Dir {
    <#
        恢复一个目录（整棵合并，同名文件跳过）

        参数：
          $Name 显示名
          $Src  来源目录
          $Dst  目标目录
          $Note 说明文字
        返回：无。结果计入脚本级统计
    #>
    param([string]$Name, [string]$Src, [string]$Dst, [string]$Note = '')

    if (-not (Test-Path -LiteralPath $Src -PathType Container)) {
        Write-Host ("  [跳过] {0} —— 来源不存在" -f $Name) -ForegroundColor DarkYellow
        $script:SkipCount++
        return
    }

    $st = Get-MergeStat -Src $Src -Dst $Dst
    $line = "  {0,-32} 源 {1,6} 文件 / {2,9}   需新增 {3,6} 文件 / {4,9}" -f `
        $Name, $st.Total, (Format-Size $st.TotalBytes), $st.Missing, (Format-Size $st.MissingBytes)
    if ($Note) { $line += "   $Note" }

    if ($st.Total -eq 0) {
        Write-Host ("  {0,-32} 来源只有空目录，无需恢复   [跳过]" -f $Name) -ForegroundColor DarkGray
        $script:SkipCount++
        return
    }

    if ($st.Missing -eq 0) {
        Write-Host ($line + '   [已齐全]') -ForegroundColor DarkGray
        $script:SkipCount++
        return
    }

    if (-not $Run) {
        Write-Host ($line + '   [待恢复]') -ForegroundColor Cyan
        $script:PlanFiles += $st.Missing
        $script:PlanBytes += $st.MissingBytes
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Dst)) {
            New-Item -ItemType Directory -Path $Dst -Force | Out-Null
        }
        $r = Invoke-RobocopyMerge -Src $Src -Dst $Dst -LogFile $RcLog
        # 以复制后的实际缺失数为准：robocopy 的 8、9 号退出码可能只是目录/属性告警
        $after = Get-MergeStat -Src $Src -Dst $Dst
        if ($after.Missing -eq 0) {
            Write-Host ($line + '   [OK]') -ForegroundColor Green
            $script:OkCount++
            $script:OkFiles += $st.Missing
            $script:OkBytes += $st.MissingBytes
        }
        else {
            Write-Host ($line + ("   [失败] 仍缺 {0} 个文件，robocopy 退出码 {1}" -f $after.Missing, $r.ExitCode)) -ForegroundColor Red
            $script:FailCount++
        }
    }
    catch {
        Write-Host ($line + ("   [失败] {0}" -f $_.Exception.Message)) -ForegroundColor Red
        $script:FailCount++
    }
}

function Restore-Files {
    <#
        恢复目录下的若干个单文件（目标已存在则跳过）

        参数：
          $Name    显示名
          $SrcDir  来源目录
          $DstDir  目标目录
          $Files   要恢复的文件名数组
        返回：无。结果计入脚本级统计
    #>
    param([string]$Name, [string]$SrcDir, [string]$DstDir, [string[]]$Files)

    if (-not (Test-Path -LiteralPath $SrcDir -PathType Container)) {
        Write-Host ("  [跳过] {0} —— 来源目录不存在" -f $Name) -ForegroundColor DarkYellow
        $script:SkipCount++
        return
    }

    $new = @()
    $newBytes = 0.0
    $exist = 0
    foreach ($f in $Files) {
        $s = Join-Path $SrcDir $f
        if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { continue }
        $d = Join-Path $DstDir $f
        if (Test-Path -LiteralPath $d) { $exist++; continue }
        $new += $f
        $newBytes += (Get-Item -LiteralPath $s).Length
    }

    if ($new.Count -eq 0) {
        Write-Host ("  {0,-32} 已有 {1} 个文件，无缺失   [已齐全]" -f $Name, $exist) -ForegroundColor DarkGray
        $script:SkipCount++
        return
    }

    if (-not $Run) {
        Write-Host ("  {0,-32} 需新增 {1} 个文件 / {2}   [待恢复]" -f $Name, $new.Count, (Format-Size $newBytes)) -ForegroundColor Cyan
        $script:PlanFiles += $new.Count
        $script:PlanBytes += $newBytes
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $DstDir)) {
            New-Item -ItemType Directory -Path $DstDir -Force | Out-Null
        }
        $done = 0
        foreach ($f in $new) {
            $s = Join-Path $SrcDir $f
            $d = Join-Path $DstDir $f
            if (Test-Path -LiteralPath $d) { $exist++; continue }   # 二次确认，防并发
            Copy-Item -LiteralPath $s -Destination $d -Force
            $done++
        }
        Write-Host ("  {0,-32} 新增 {1} 个 / {2}   [OK]" -f $Name, $done, (Format-Size $newBytes)) -ForegroundColor Green
        $script:OkCount++
        $script:OkFiles += $done
        $script:OkBytes += $newBytes
    }
    catch {
        Write-Host ("  {0,-32} [失败] {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:FailCount++
    }
}

function Copy-ConflictingFile {
    <#
        目标已存在时，把来源另存为 <原文件名>.old-<时间戳>，两份数据都保留
        用于 sqlite 这类无法合并、且目标正在被程序占用的文件

        参数：
          $Name 显示名
          $Src  来源文件
          $Dst  目标文件
        返回：无。结果计入脚本级统计
    #>
    param([string]$Name, [string]$Src, [string]$Dst)

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Write-Host ("  [跳过] {0} —— 来源不存在" -f $Name) -ForegroundColor DarkYellow
        $script:SkipCount++
        return
    }

    $alt = $Dst + ".old-$Stamp"
    if (-not (Test-Path -LiteralPath $Dst)) {
        # 目标不存在，走普通恢复流程
        Restore-Files -Name $Name -SrcDir (Split-Path $Src -Parent) -DstDir (Split-Path $Dst -Parent) -Files @(Split-Path $Src -Leaf)
        return
    }

    $bytes = (Get-Item -LiteralPath $Src).Length
    # 目标已与来源等大，说明旧库早已覆盖到位，再另存只会重复占用空间
    if ((Get-Item -LiteralPath $Dst).Length -eq $bytes) {
        Write-Host ("  {0,-32} 目标与来源等大，视为已恢复   [已齐全]" -f $Name) -ForegroundColor DarkGray
        $script:SkipCount++
        return
    }
    if (Test-Path -LiteralPath $alt) {
        Write-Host ("  {0,-32} 已存在副本 {1}   [已齐全]" -f $Name, (Split-Path $alt -Leaf)) -ForegroundColor DarkGray
        $script:SkipCount++
        return
    }

    if (-not $Run) {
        Write-Host ("  {0,-32} 目标在使用中，另存为 {1} / {2}   [待恢复]" -f $Name, (Split-Path $alt -Leaf), (Format-Size $bytes)) -ForegroundColor Cyan
        $script:PlanFiles++
        $script:PlanBytes += $bytes
        return
    }

    try {
        Copy-Item -LiteralPath $Src -Destination $alt -Force
        Write-Host ("  {0,-32} 另存为 {1} / {2}   [OK]" -f $Name, (Split-Path $alt -Leaf), (Format-Size $bytes)) -ForegroundColor Green
        $script:OkCount++
        $script:OkFiles++
        $script:OkBytes += $bytes
    }
    catch {
        Write-Host ("  {0,-32} [失败] {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:FailCount++
    }
}

function Protect-SshPrivateKeys {
    <#
        收紧私钥 ACL：去掉继承，只保留当前用户读取权限
        OpenSSH 遇到权限过宽的私钥会拒绝使用

        参数：$SshDir 存放密钥的目录
        返回：无
    #>
    param([string]$SshDir)

    if (-not (Test-Path -LiteralPath $SshDir -PathType Container)) { return }
    $user = $env:USERNAME
    $keys = @(Get-ChildItem -LiteralPath $SshDir -File -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike '*.pub' -and $_.Name -notin @('known_hosts', 'known_hosts.old', 'config') })
    foreach ($k in $keys) {
        & icacls.exe $k.FullName /inheritance:r 2>$null | Out-Null
        & icacls.exe $k.FullName /grant:r "${user}:(R)" 2>$null | Out-Null
        Write-Host ("  私钥权限已收紧：{0}" -f $k.Name) -ForegroundColor DarkGray
    }
}

# ================================================================ 开始
Write-Host ""
Write-Host "=== 从 Windows.old 非破坏性恢复 ===" -ForegroundColor Cyan
Write-Host "来源: $OldRoot"
Write-Host "用户: $UserHome"
Write-Host "模式: $(if ($Run) { '执行' } else { '干跑（加 -Run 才复制）' })"
Write-Host ""

if (-not (Test-Path -LiteralPath $OldRoot)) {
    Write-Host "来源目录不存在，可能 Windows.old 已被系统清理。" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ---------------------------------------------------------------- 1. 用户文件夹
Write-Host "--- 1. 桌面 / 文档 / 图片 ---" -ForegroundColor Cyan

# 桌面只捡两份文档，旧系统桌面上的 recycle_*.log 是临时文件不恢复
Restore-Files -Name '桌面文档' -SrcDir (Join-Path $OldRoot 'Desktop') -DstDir $DesktopDir -Files @(
    'Qoder新版接入ai-env-clone_适配器与数据迁移要点.md',
    'WorkBuddy接入ai-env-clone_适配器与数据迁移参考.md'
)

Restore-Dir -Name 'Documents\Qoder'  -Src (Join-Path $OldRoot 'Documents\Qoder')  -Dst (Join-Path $DocsDir 'Qoder')  -Note '会话记录'
Restore-Dir -Name 'Documents\Navicat' -Src (Join-Path $OldRoot 'Documents\Navicat') -Dst (Join-Path $DocsDir 'Navicat') -Note '连接配置（D 盘已有更新版，只补缺）'
Restore-Files -Name 'Documents 单文件' -SrcDir (Join-Path $OldRoot 'Documents') -DstDir $DocsDir -Files @('Default.rdp')

Restore-Files -Name 'Pictures 单文件' -SrcDir (Join-Path $OldRoot 'Pictures') -DstDir $PicsDir -Files @(
    'deepseek-color.ico',
    'deepseek-color.png',
    'deepseek-color.svg',
    'SaveAll.svg',
    'v2-02fe6bcb282c4c16cb9d3314a7c556e5_720w.jpg',
    'v2-9c950799a964eeb6d4ece16595f17684_r.jpg'
)
Restore-Dir -Name 'Pictures\Screenshots'  -Src (Join-Path $OldRoot 'Pictures\Screenshots')  -Dst (Join-Path $PicsDir 'Screenshots')
Restore-Dir -Name 'Pictures\IQIYISnapShot' -Src (Join-Path $OldRoot 'Pictures\IQIYISnapShot') -Dst (Join-Path $PicsDir 'IQIYISnapShot')

# ---------------------------------------------------------------- 2. 用户目录下的工具与开发数据
Write-Host ""
Write-Host "--- 2. AI 工具数据 ---" -ForegroundColor Cyan

Restore-Dir -Name '.dsh'          -Src (Join-Path $OldRoot '.dsh')          -Dst (Join-Path $UserHome '.dsh')          -Note 'DSH 会话/配置'
Restore-Dir -Name '.qwenworkcn'   -Src (Join-Path $OldRoot '.qwenworkcn')   -Dst (Join-Path $UserHome '.qwenworkcn')   -Note '千问办公 skills/projects'
Restore-Dir -Name '.catpaw'       -Src (Join-Path $OldRoot '.catpaw')       -Dst (Join-Path $UserHome '.catpaw')       -Note '猫爪项目记录'
Restore-Dir -Name '.catpawai'     -Src (Join-Path $OldRoot '.catpawai')     -Dst (Join-Path $UserHome '.catpawai')     -Note '猫爪扩展与 argv'
Restore-Dir -Name '.3T_community' -Src (Join-Path $OldRoot '.3T_community') -Dst (Join-Path $UserHome '.3T_community') -Note 'Studio 3T 连接与工作区'
Restore-Dir -Name '.cagent'       -Src (Join-Path $OldRoot '.cagent')       -Dst (Join-Path $UserHome '.cagent')
Restore-Dir -Name '.qoder-cli'    -Src (Join-Path $OldRoot '.qoder-cli')    -Dst (Join-Path $UserHome '.qoder-cli')    -Note 'CLI 统计'
Restore-Dir -Name '.sankuai'      -Src (Join-Path $OldRoot '.sankuai')      -Dst (Join-Path $UserHome '.sankuai')      -Note 'CatPawAI 会话库 / MCopilot 索引'
# 这两个 sqlite 在当前系统已有新版本且正被猫爪使用，旧库另存为 .old-时间戳，绝不覆盖
Copy-ConflictingFile -Name '.sankuai 旧会话库' `
    -Src (Join-Path $OldRoot '.sankuai\CatPawAI\sqliteDB\globalCache.sqlite') `
    -Dst (Join-Path $UserHome '.sankuai\CatPawAI\sqliteDB\globalCache.sqlite')
Copy-ConflictingFile -Name '.sankuai 旧索引' `
    -Src (Join-Path $OldRoot '.sankuai\MCopilot\index\index.sqlite') `
    -Dst (Join-Path $UserHome '.sankuai\MCopilot\index\index.sqlite')

Write-Host ""
Write-Host "--- 3. 开发与笔记数据 ---" -ForegroundColor Cyan

Restore-Dir -Name 'JoplinBackup'  -Src (Join-Path $OldRoot 'JoplinBackup')  -Dst (Join-Path $UserHome 'JoplinBackup')  -Note 'Joplin 导出备份'
Restore-Dir -Name 'sdk'          -Src (Join-Path $OldRoot 'sdk')          -Dst (Join-Path $UserHome 'sdk')          -Note 'Go 工具链'
Restore-Dir -Name 'GolandProjects' -Src (Join-Path $OldRoot 'GolandProjects') -Dst (Join-Path $UserHome 'GolandProjects') -Note 'Go 项目'
Restore-Dir -Name 'source\repos' -Src (Join-Path $OldRoot 'source\repos') -Dst (Join-Path $UserHome 'source\repos') -Note 'VS 项目'
Restore-Dir -Name '.docker'      -Src (Join-Path $OldRoot '.docker')      -Dst (Join-Path $UserHome '.docker')      -Note 'Docker CLI 配置'

# ---------------------------------------------------------------- 4. 应用配置
Write-Host ""
Write-Host "--- 4. 应用配置 ---" -ForegroundColor Cyan

Restore-Dir -Name 'MobaXterm' -Src (Join-Path $OldRoot 'AppData\Roaming\MobaXterm') -Dst (Join-Path $UserHome 'AppData\Roaming\MobaXterm') -Note '会话与设置'

# ---------------------------------------------------------------- 5. Git / SSH（写入 D 盘迁移目录）
Write-Host ""
Write-Host "--- 5. Git / SSH（迁移目录） ---" -ForegroundColor Cyan

Restore-Files -Name 'Git 全局配置' -SrcDir $OldRoot -DstDir $MigrationRoot -Files @('.gitconfig')
Restore-Dir   -Name '.ssh'         -Src (Join-Path $OldRoot '.ssh') -Dst (Join-Path $MigrationRoot '.ssh') -Note '密钥与 known_hosts'
if ($Run) { Protect-SshPrivateKeys -SshDir (Join-Path $MigrationRoot '.ssh') }

# ---------------------------------------------------------------- 6. Edge
if ($SkipEdge) {
    Write-Host ""
    Write-Host "--- 6. Edge 已按参数跳过 ---" -ForegroundColor DarkYellow
}
else {
    Write-Host ""
    Write-Host "--- 6. Edge 收藏夹/历史/自动填充/扩展 ---" -ForegroundColor Cyan

    $EdgeSrc = Join-Path $OldRoot 'AppData\Local\Microsoft\Edge\User Data'
    $EdgeDst = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $edgeFiles = @('Bookmarks', 'Preferences', 'Secure Preferences', 'Login Data', 'Login Data For Account',
                   'Web Data', 'History', 'Favicons', 'Top Sites')

    if (-not (Test-Path -LiteralPath $EdgeSrc -PathType Container)) {
        Write-Host "  [跳过] Edge —— 旧系统里没有 User Data" -ForegroundColor DarkYellow
        $script:SkipCount++
    }
    elseif ($Run -and @(Get-Process msedge -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host "  [跳过] Edge —— 进程正在运行，请先完全退出 Edge 再重跑本脚本" -ForegroundColor Yellow
        Write-Host "          （运行中的 SQLite 文件会锁定，强行复制可能得到不完整的数据）" -ForegroundColor DarkGray
        $script:SkipCount++
    }
    else {
        # 旧系统里有 Default 和 Profile 2，逐个 profile 补缺失文件
        $profiles = @(Get-ChildItem -LiteralPath $EdgeSrc -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
        foreach ($p in $profiles) {
            $pSrc = $p.FullName
            $pDst = Join-Path $EdgeDst $p.Name
            Write-Host ("  [{0}]" -f $p.Name) -ForegroundColor DarkGray
            Restore-Files -Name ('  ' + $p.Name + ' 数据文件') -SrcDir $pSrc -DstDir $pDst -Files $edgeFiles
            Restore-Dir   -Name ('  ' + $p.Name + '\Extensions') -Src (Join-Path $pSrc 'Extensions') -Dst (Join-Path $pDst 'Extensions') -Note '扩展本体（是否生效还取决于 Secure Preferences 校验）'
        }
    }
}

# ---------------------------------------------------------------- 7. 明确不恢复
Write-Host ""
Write-Host "--- 7. 明确不恢复（已确认） ---" -ForegroundColor Cyan
$notRestore = @(
    '.qoder（旧版 17.7 MB，已被 .qoder-cn 取代）',
    '.codeartsdoer / .codegraph / .codebase-cli（工具本体与缓存，重装后重建）',
    'Documents\WeChat Files、WXWorkLocal（D 盘数据已更新且更大）',
    'Edge Local State（DPAPI 密钥绑旧用户，跨机器失效且会破坏现有登录态）',
    'Desktop 下 recycle_*.log 等临时文件；旧 JetBrains / Code / InputMethod 配置'
)
foreach ($n in $notRestore) { Write-Host ("  - " + $n) -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 汇总
Write-Host ""
Write-Host "=== 汇总 ===" -ForegroundColor Cyan
if ($Run) {
    Write-Host ("  成功 {0} 项，共新增 {1} 个文件 / {2}" -f $script:OkCount, $script:OkFiles, (Format-Size $script:OkBytes)) -ForegroundColor Green
}
else {
    Write-Host ("  待恢复 {0} 个文件 / {1}（干跑，未改动任何文件）" -f $script:PlanFiles, (Format-Size $script:PlanBytes)) -ForegroundColor Cyan
}
Write-Host ("  已齐全或来源缺失 {0} 项，失败 {1} 项" -f $script:SkipCount, $script:FailCount) -ForegroundColor Gray
Write-Host ""

if (-not $Run) {
    Write-Host "确认无误后加 -Run 真正执行：" -ForegroundColor Yellow
    Write-Host ("  powershell -ExecutionPolicy Bypass -File `"{0}`" -Run" -f $MyInvocation.MyCommand.Path) -ForegroundColor Yellow
}
else {
    Write-Host "下一步：执行 重建链接.ps1，把 .gitconfig / .ssh 等接回 C 盘用户目录。" -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
Write-Host "日志: $LogPath" -ForegroundColor DarkGray
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
