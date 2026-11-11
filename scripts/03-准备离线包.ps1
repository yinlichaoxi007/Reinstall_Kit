#requires -Version 5.1
<#
    准备 winget 离线安装包（LTSC 必做）
    ============================================================
    Windows 10 IoT LTSC 2021 不带 App Installer，也就没有 winget。
    重装后第一次跑「装软件.ps1」时，脚本会从这个目录离线安装。

    下载三个文件到 <工程包>\pkgs\appinstaller\：
        Microsoft.VCLibs.x64.14.00.Desktop.appx        依赖
        Microsoft.UI.Xaml.2.8.x64.appx                 依赖
        Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle   本体

    用法：
        开始.cmd  →  3
        或： powershell -ExecutionPolicy Bypass -File 03-准备离线包.ps1
            powershell -ExecutionPolicy Bypass -File 03-准备离线包.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot '_common.ps1')

Start-KitLog -Name 'prepare-pkgs' | Out-Null
Write-Head "准备 winget 离线包"

$destDir = Join-Path $script:KitRoot 'pkgs\appinstaller'
if (-not (Test-Path -LiteralPath $destDir)) {
    if ($DryRun) { Write-Info "[演练] 会创建 $destDir" }
    else { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
}
Write-Info ("目标目录: " + $destDir)

$items = @(
    @{ Name = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'; Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; MinMB = 4 },
    @{ Name = 'Microsoft.UI.Xaml.2.8.x64.appx'; Url = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'; MinMB = 3 },
    @{ Name = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; Url = 'https://aka.ms/getwinget'; MinMB = 1 }
)

$okCount = 0
$failList = @()

foreach ($it in $items) {
    Write-Step $it.Name
    $path = Join-Path $destDir $it.Name

    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        $len = (Get-Item -LiteralPath $path).Length
        if ($len -ge ($it.MinMB * 1MB)) {
            Write-Ok ("已存在 " + (Format-Human $len) + "，跳过（要重下加 -Force）")
            $okCount++
            continue
        }
        Write-Warn ("已存在但只有 {0}，判定为坏文件，重下" -f (Format-Human $len))
    }

    if ($DryRun) {
        Write-Info ("[演练] 会下载 " + $it.Url)
        continue
    }

    try {
        Write-Info ("下载 " + $it.Url)
        $tmp = $path + '.part'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0 reinstall-kit')
        $wc.DownloadFile($it.Url, $tmp)
        $wc.Dispose()

        $size = (Get-Item -LiteralPath $tmp).Length
        if ($size -lt ($it.MinMB * 1MB)) { throw ("下载到的文件只有 {0}，像是错误页面" -f (Format-Human $size)) }

        Move-Item -LiteralPath $tmp -Destination $path -Force
        Write-Ok ("完成 " + (Format-Human $size))

        $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid') {
            Write-Info ("  签名: {0}" -f $sig.SignerCertificate.Subject)
        } elseif ($sig) {
            Write-Warn ("  签名状态: {0}（不是 Valid，留意来源）" -f $sig.Status)
        }
        $okCount++
    }
    catch {
        Write-Err ("失败: " + $_.Exception.Message)
        $failList += $it.Name
    }
}

Write-Step "结果"
if (Test-Path -LiteralPath $destDir) {
    $files = @(Get-ChildItem -LiteralPath $destDir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.appx', '.msix', '.msixbundle' })
    $sum = 0
    foreach ($f in $files) { $sum += $f.Length }
    Write-Info ("目录内 {0} 个安装包 / {1}" -f $files.Count, (Format-Human $sum))
    foreach ($f in $files) { Write-Info ("  {0,-58} {1}" -f $f.Name, (Format-Human $f.Length)) }
}

Write-Host ""
if ($failList.Count -gt 0) {
    Write-Err ("有 {0} 个没下成：{1}" -f $failList.Count, ($failList -join ', '))
    Write-Info "公司网络可能拦了 GitHub。手动下载后改名放进："
    Write-Info ("  " + $destDir)
    Write-Info "  · App Installer: https://aka.ms/getwinget"
    Write-Info "  · VCLibs:        https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
    Write-Info "  · UI.Xaml:       https://github.com/microsoft/microsoft-ui-xaml/releases (v2.8.6 的 x64 appx)"
    Stop-KitLog; exit 1
}

if ($DryRun) {
    Write-Ok "演练结束，未下载任何文件。"
} else {
    Write-Ok ("离线包就绪（{0}/3）" -f $okCount)
    Write-Info "重装后 装软件.ps1 会自动从这里装 winget。"
}

Stop-KitLog
exit 0
