# -*- coding: utf-8 -*-
"""
重装前备份（阶段 0）
================================================================
默认「干跑」：只打印计划，不动任何文件。
确认后加 --run 才真正拷贝。

    python 1-备份.py            # 看计划
    python 1-备份.py --run      # 真跑

输出：D:\\Reinstall_Kit\\backup\\<时间戳>\\
"""
import os
import sys
import time
import threading
import shutil
import subprocess
import argparse
import datetime
import json

# ---------------------------------------------------------------- 配置
DEST_ROOT = r"D:\Reinstall_Kit\backup"
HOME = os.path.expanduser("~")


def progress_line(text):
    """单行实时刷新：\\r 覆盖当前行，行尾补空格清掉残留"""
    if len(text) > 110:
        text = text[:110]
    sys.stdout.write("\r" + text + " " * max(0, 118 - len(text)))
    sys.stdout.flush()


class Spin:
    """后台线程每秒刷新一次「已等待 x 秒」，用于没有进度可报的阻塞调用"""

    def __init__(self, label):
        self.label = label
        self.stop = threading.Event()
        self.th = threading.Thread(target=self._loop, daemon=True)

    def _loop(self):
        t0 = time.time()
        while not self.stop.wait(1.0):
            progress_line("  %s ... 已等待 %d 秒" % (self.label, int(time.time() - t0)))

    def __enter__(self):
        self.th.start()
        return self

    def __exit__(self, *a):
        self.stop.set()
        self.th.join(timeout=3)
        sys.stdout.write("\n")
        sys.stdout.flush()

# 目录：(相对 HOME 的路径, 说明)
DIRS = [
    (r"AppData\Local\JetBrains",                    "JetBrains 配置/索引/插件"),
    (r"AppData\Roaming\JetBrains",                  "JetBrains 用户设置"),
    (r"AppData\Local\Microsoft\VisualStudio",       "VS 用户配置/扩展"),
    (r"AppData\Roaming\Microsoft\VisualStudio",     "VS 漫游设置"),
    (r"AppData\Roaming\com.qodercn.app.stable",     "Qoder CN 真实数据"),
    (r"AppData\Roaming\com.qoder.app.stable",       "Qoder 数据"),
    (r"AppData\Roaming\QwenWorkCN",                 "千问办公"),
    (r"AppData\Roaming\@deepseek-ai",               "DeepSeek Harness"),
    (r"AppData\Roaming\ichat",                      "iChat"),
    (r"AppData\Local\github-copilot",               "Copilot 插件数据"),
    (r"AppData\Local\ai_env_clone",                 "AI 环境克隆"),
    (r"AppData\Local\WorkBuddy",                    "WorkBuddy 桌面端缓存"),
    (r"AppData\Local\Lertaro",                      "Lertaro 配置/别名/搜索历史"),
    (r"AppData\Roaming\Mozilla",                    "Firefox 配置/书签"),
    (r"AppData\Local\Docker",                       "Docker Desktop 用户配置"),
    (r".docker",                                    "Docker CLI 配置"),
    (r".m2",                                        "Maven 本地仓库"),
    (r".npm",                                       "npm 全局包"),
    (r".local",                                     "Python 用户级包"),
    (r".cache",                                     "各类缓存（可选）"),
    (r".claude",                                    "Claude Code 配置"),
    (r".ssh",                                       "★ SSH 私钥"),
    (r".gnupg",                                     "★ GPG 私钥"),
    (r"Documents",                                  "文档（C 盘这份与 D 盘有差异）"),
    (r"Desktop",                                    "桌面残留"),
    (r"Downloads",                                  "下载残留"),
    (r"Pictures",                                   "图片"),
    (r"AppData\Roaming\Microsoft\Windows\Recent",   "最近使用记录（可选）"),
    (r"Favorites",                                  "IE/旧版 Edge 收藏夹"),
]

# 单文件：(相对 HOME 的路径, 说明)
FILES = [
    (r".claude.json",           "Claude Code 索引"),
    (r".gitconfig",             "★ Git 全局配置"),
    (r".bash_history",          "命令行历史"),
    (r".viminfo",               "vim 状态"),
    (r".lesshst",               "less 历史"),
    (r".node_repl_history",     "node 历史"),
    (r".ganttproject",          "GanttProject 配置"),
    (r".pcr-stats.json",        "PCR 统计"),
    (r".rnd",                   "随机状态文件"),
]

# 浏览器：书签/偏好/自动填充/历史/扩展（密码与登录态是 DPAPI 加密且绑定旧机器，拷了也无法解密）
BROWSER_DIRS = [
    (r"AppData\Local\Microsoft\Edge\User Data", "Edge"),
    (r"AppData\Local\Google\Chrome\User Data",  "Chrome"),
]
# 每个配置目录（Default / Profile N）内要拷贝的文件
BROWSER_PROFILE_FILES = [
    "Bookmarks",
    "Preferences",
    "Secure Preferences",
    "Login Data",
    "Login Data For Account",
    "Web Data",
    "History",
    "Favicons",
    "Top Sites",
]

# 需要导出而非拷贝的系统项
SYSTEM_PATHS = [
    (r"C:\Windows\System32\drivers\etc\hosts", "hosts 文件"),
]

REG_EXPORTS = [
    (r"HKCU\Environment",
     "用户环境变量（含 PATH）.reg"),
    (r"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
     "系统环境变量（含 PATH）.reg"),
    (r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall",
     "用户级已装软件.reg"),
    (r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
     "机器级已装软件.reg"),
]


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.0f PB" % n


def dir_size(p, budget=6.0):
    """快速估算目录体积（带时间预算，大目录只给下限）"""
    import time
    total = 0
    t0 = time.time()
    for dp, dn, fn in os.walk(p, followlinks=False):
        # 跳过 junction，避免顺着链接把 D 盘算两遍
        dn[:] = [d for d in dn
                 if not (os.path.islink(os.path.join(dp, d)))]
        for f in fn:
            try:
                total += os.stat(os.path.join(dp, f), follow_symlinks=False).st_size
            except OSError:
                pass
        if time.time() - t0 > budget:
            return total, True
    return total, False


def run(cmd, timeout=120, shell=False):
    try:
        r = subprocess.run(cmd, capture_output=True, shell=shell, timeout=timeout)
        out = r.stdout.decode("gbk", errors="replace") + r.stderr.decode("gbk", errors="replace")
        return r.returncode, out
    except Exception as e:
        return -1, "<失败: %s>" % e


def preflight():
    print("=" * 68)
    print(" 预检")
    print("=" * 68)

    # C 盘 BitLocker
    code, out = run(["manage-bde", "-status", "C:"], timeout=60)
    if code == 0:
        conv = "已加密" if ("保护开启" in out or "Protection On" in out) else "未加密"
        print("  C 盘 BitLocker : %s" % conv)
    else:
        print("  C 盘 BitLocker : <需要管理员权限，跳过检查>")

    # D 盘空间
    for letter in ("D", "E", "F"):
        root = letter + ":\\"
        if os.path.exists(root):
            try:
                t, u, f = shutil.disk_usage(root)
                print("  %s 盘空间      : 总 %s / 可用 %s" % (letter, human(t), human(f)))
            except OSError:
                pass

    # WSL
    code, out = run(["wsl", "-l", "-v"], timeout=30)
    if code == 0 and out.strip():
        print("  WSL 发行版     :")
        for line in out.strip().splitlines():
            print("      " + line.strip())
        print("  ⚠️  WSL 必须单独导出，文件拷贝救不回来：")
        print("      wsl --export <发行版名> D:\\Reinstall_Kit\\backup\\wsl.tar")
    else:
        print("  WSL            : 无法查询（可能未安装或被安全策略拦截）")

    print("")


def make_plan():
    """返回 (要拷贝的目录列表, 总字节数)"""
    plan = []
    total = 0
    for idx, (rel, note) in enumerate(DIRS, 1):
        src = os.path.join(HOME, rel)
        if not os.path.isdir(src):
            continue
        if os.path.islink(src):
            plan.append((rel, src, note, 0, "跳过：本身是链接（数据已在 D 盘）"))
            continue
        progress_line("  [%d/%d] 估算体积: %s ..." % (idx, len(DIRS), rel))
        size, truncated = dir_size(src)
        total += size
        plan.append((rel, src, note, size, "约 %s%s" % (human(size), " 起" if truncated else "")))
    sys.stdout.write("\n")
    sys.stdout.flush()
    return plan, total


def dir_bytes(p):
    """统计目录实际字节数（跳过 junction），用于监控拷贝进度"""
    total = 0
    for dp, dn, fn in os.walk(p, followlinks=False):
        dn[:] = [d for d in dn if not os.path.islink(os.path.join(dp, d))]
        for f in fn:
            try:
                total += os.stat(os.path.join(dp, f), follow_symlinks=False).st_size
            except OSError:
                pass
    return total


def copy_dir(src, dst, log, expected, label, idx, ndirs):
    """用 robocopy 拷贝；后台线程每 2 秒读一次目标目录字节数，单行显示百分比"""
    os.makedirs(dst, exist_ok=True)
    stop = threading.Event()
    t0 = time.time()

    def monitor():
        while not stop.wait(2.0):
            done = dir_bytes(dst)
            pct = min(99.9, done * 100.0 / expected) if expected > 0 else 0.0
            rate = done / max(0.5, time.time() - t0)
            progress_line("  [%d/%d] %s  %5.1f%%  %s / %s  %s/s" % (
                idx, ndirs, label[:38], pct, human(done), human(expected), human(rate)))

    th = threading.Thread(target=monitor, daemon=True)
    th.start()
    cmd = ["robocopy", src, dst, "/E", "/XJ", "/R:1", "/W:1",
           "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/LOG+:" + log]
    code, out = run(cmd, timeout=3600)
    stop.set()
    th.join(timeout=5)
    done = dir_bytes(dst)
    pct = min(99.9, done * 100.0 / expected) if expected > 0 else 0.0
    progress_line("  [%d/%d] %s  %5.1f%%  %s / %s  用时 %d 秒\n" % (
        idx, ndirs, label[:38], pct, human(done), human(expected), int(time.time() - t0)))
    return code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true", help="真正执行拷贝（默认只打印计划）")
    ap.add_argument("--skip-large", action="store_true", help="跳过体积 >200MB 的目录")
    args = ap.parse_args()

    preflight()
    plan, total = make_plan()

    print("=" * 68)
    print(" 备份计划  ->  %s" % DEST_ROOT)
    print("=" * 68)
    print("  %-46s %10s" % ("目录", "体积"))
    print("  " + "-" * 58)
    skipped = []
    for rel, src, note, size, info in plan:
        if args.skip_large and size > 200 * 1024 * 1024:
            skipped.append(rel)
            print("  %-46s %s" % (rel[:46], "跳过(>200MB)"))
            continue
        print("  %-46s %s" % (rel[:46], info))
    print("  " + "-" * 58)
    print("  合计约 %s" % human(total))
    print("")

    print("  另含 %d 个单文件、%d 类浏览器配置、%d 个系统文件、%d 项注册表导出"
          % (len(FILES), len(BROWSER_DIRS), len(SYSTEM_PATHS), len(REG_EXPORTS)))
    print("")

    if not args.run:
        print("=" * 68)
        print(" 这是干跑。确认无误后加 --run 真正执行：")
        print("   python \"%s\" --run" % os.path.abspath(__file__))
        print("=" * 68)
        return 0

    # ---------------- 真跑 ----------------
    if not os.path.isdir(DEST_ROOT.split(":")[0] + ":\\"):
        print("❌ 目标盘不存在：%s" % DEST_ROOT)
        return 1

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dest = os.path.join(DEST_ROOT, ts)
    os.makedirs(dest, exist_ok=True)
    logdir = os.path.join(dest, "_logs")
    os.makedirs(logdir, exist_ok=True)
    master = os.path.join(logdir, "robocopy.log")

    results = []
    todo = [(rel, src, size) for rel, src, note, size, info in plan
            if not (args.skip_large and size > 200 * 1024 * 1024) and not os.path.islink(src)]
    ndirs = len(todo)
    idx = 0
    for rel, src, size in todo:
        idx += 1
        target = os.path.join(dest, rel)
        code = copy_dir(src, target, master, max(size, 1), rel, idx, ndirs)
        ok = code < 8
        print("        %s" % ("OK" if ok else "失败(robocopy 退出码 %s，见日志)" % code))
        results.append((rel, ok, code))

    # 单文件
    print("  -> 单文件 ...", end="", flush=True)
    for rel, note in FILES:
        src = os.path.join(HOME, rel)
        if os.path.isfile(src):
            dst = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            try:
                shutil.copy2(src, dst)
            except OSError as e:
                print("\n     ! %s : %s" % (rel, e))
    print(" OK")

    # 浏览器（书签/偏好/自动填充/历史/扩展；密码跨机器无法解密，仅作留档）
    for rel, label in BROWSER_DIRS:
        base = os.path.join(HOME, rel)
        if not os.path.isdir(base):
            continue
        for prof in sorted(os.listdir(base)):
            pdir = os.path.join(base, prof)
            if not os.path.isdir(pdir) or not (prof == "Default" or prof.startswith("Profile ")):
                continue
            for fname in BROWSER_PROFILE_FILES:
                src = os.path.join(pdir, fname)
                if not os.path.isfile(src):
                    continue
                dst_dir = os.path.join(dest, "browser", "%s_%s" % (label, prof))
                os.makedirs(dst_dir, exist_ok=True)
                try:
                    shutil.copy2(src, os.path.join(dst_dir, fname))
                except OSError as e:
                    # 浏览器在运行时会独占 SQLite 文件，这里只告警不中断
                    print("\n     ! %s\\%s\\%s : %s" % (label, prof, fname, e))
            ext = os.path.join(pdir, "Extensions")
            if os.path.isdir(ext):
                ext_dst = os.path.join(dest, "browser", "%s_%s" % (label, prof), "Extensions")
                try:
                    if os.path.isdir(ext_dst):
                        shutil.rmtree(ext_dst)
                    shutil.copytree(ext, ext_dst)
                except OSError as e:
                    print("\n     ! %s\\%s\\Extensions : %s" % (label, prof, e))
            # 导出扩展清单：扩展本身跨机器无法迁移（完整性校验绑定本机密钥），
            # 重装后照着 ID 到应用商店重新安装即可
            sec = os.path.join(pdir, "Secure Preferences")
            if os.path.isfile(sec):
                try:
                    with open(sec, encoding="utf-8") as fh:
                        settings = ((json.load(fh).get("extensions") or {}).get("settings")) or {}
                    rows = []
                    for eid, info in settings.items():
                        man = (info or {}).get("manifest") or {}
                        name = man.get("name")
                        if not name:
                            continue  # 没有名字的多为浏览器内置组件，跳过
                        rows.append("%s\t%s\t%s" % (name, eid, man.get("version", "?")))
                    if rows:
                        out = os.path.join(dest, "browser", "%s_%s_扩展清单.txt" % (label, prof))
                        os.makedirs(os.path.dirname(out), exist_ok=True)
                        with open(out, "w", encoding="utf-8") as fh:
                            fh.write("# 浏览器扩展清单（重装后按 ID 到应用商店重新安装）\n")
                            fh.write("名称\tID\t版本\n")
                            fh.write("\n".join(rows) + "\n")
                except (OSError, ValueError) as e:
                    print("\n     ! %s\\%s\\Secure Preferences : %s" % (label, prof, e))
        # Local State 故意不备份：内含 DPAPI 加密的主密钥，换机器无法解密，还会破坏新系统的配置

    # 系统文件
    for src, note in SYSTEM_PATHS:
        if os.path.isfile(src):
            try:
                shutil.copy2(src, os.path.join(dest, os.path.basename(src)))
            except OSError as e:
                print("  ! %s : %s" % (src, e))

    # 注册表
    for key, name in REG_EXPORTS:
        out_path = os.path.join(dest, "registry", name)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        code, o = run(["reg", "export", key, out_path, "/y"], timeout=120)
        print("  reg %s : %s" % (key, "OK" if code == 0 else "失败"))

    # 软件清单
    with Spin("winget export（导出已装软件清单，最长等 10 分钟）"):
        code, o = run(["winget", "export", "-o", os.path.join(dest, "winget_export.json"),
                       "--accept-source-agreements", "--disable-interactivity"], timeout=600)
    print("  winget export : %s" % ("OK" if code == 0 else "失败"))

    # 环境变量快照
    try:
        with open(os.path.join(dest, "environment.txt"), "w", encoding="utf-8-sig") as f:
            for k, v in sorted(os.environ.items()):
                f.write("%s=%s\n" % (k, v))
    except OSError:
        pass

    # 恢复清单
    write_readme(dest, results, ts)

    print("")
    print("=" * 68)
    print(" 完成：%s" % dest)
    print(" 恢复说明：%s" % os.path.join(dest, "恢复清单.md"))
    print("=" * 68)
    return 0


def write_readme(dest, results, ts):
    lines = []
    lines.append("# 恢复清单（备份时间 %s）" % ts)
    lines.append("")
    lines.append("备份根目录：`%s`" % dest)
    lines.append("")
    lines.append("## 目录级备份")
    lines.append("")
    lines.append("| 相对路径 | 状态 |")
    lines.append("|---|---|")
    for rel, ok, code in results:
        lines.append("| `%s` | %s |" % (rel, "✅" if ok else "❌ 退出码 %s" % code))
    lines.append("")
    lines.append("## 恢复方法")
    lines.append("")
    lines.append("重装完成后，把上表里的目录**逐个**拷回对应位置即可。命令模板：")
    lines.append("")
    lines.append("```bat")
    lines.append(r'robocopy "D:\Reinstall_Kit\backup\%s\AppData\Local\JetBrains" "%%LOCALAPPDATA%%\JetBrains" /E /XJ /R:1 /W:1' % ts)
    lines.append("```")
    lines.append("")
    lines.append("## 单文件 / 系统项")
    lines.append("")
    lines.append("- `hosts` → `C:\\Windows\\System32\\drivers\\etc\\hosts`（需管理员）")
    lines.append("- `registry\\*.reg` → 双击导入，**先看一遍内容再导**，PATH 可能覆盖新系统的值")
    lines.append("- `browser\\<浏览器>_<配置>\\` → 对应浏览器配置目录（书签/偏好/历史/扩展）")
    lines.append("- `winget_export.json` → 下次批量装软件用")
    lines.append("- `environment.txt` → 手工对照补 PATH")
    lines.append("")
    lines.append("## 别忘了")
    lines.append("")
    lines.append("- [ ] WSL 发行版：`wsl --import` 导回的 tar 包")
    lines.append("- [ ] 微信聊天记录确认指向 D 盘")
    lines.append("- [ ] 浏览器登录账号同步书签和密码")
    lines.append("- [ ] Office / EPLAN / Polyspace 等授权重新激活")
    with open(os.path.join(dest, "恢复清单.md"), "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
