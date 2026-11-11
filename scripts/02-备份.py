# -*- coding: utf-8 -*-
"""
重装前备份（阶段 0）
================================================================
备份清单由 backup.config.json 定义，本机可用 backup.local.json 整体覆盖。
默认「干跑」：只打印计划，不动任何文件；确认后加 --run 才真正执行。

    python 02-备份.py                  # 全部默认分类，看计划
    python 02-备份.py --select         # 选择分类，看计划
    python 02-备份.py --run            # 全部默认分类，真跑
    python 02-备份.py --select --run   # 选择分类后真跑
    python 02-备份.py --list           # 只列出分类
    python 02-备份.py --only keys,joplin --run

输出：<destRoot>/<时间戳>/
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
import stat

# ---------------------------------------------------------------- 配置
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_ROOT = os.path.dirname(SCRIPT_DIR)
CONFIG_FILE = os.path.join(KIT_ROOT, "backup.config.json")
LOCAL_CONFIG_FILE = os.path.join(KIT_ROOT, "backup.local.json")
HOME = os.path.expanduser("~")
DEFAULT_DEST_ROOT = os.path.join(KIT_ROOT, "backup")
SKIP_LARGE_BYTES = 200 * 1024 * 1024
CANCEL = object()          # 子菜单返回上一级的哨兵值


def is_link_like(path):
    """判断路径是否为链接类对象（junction / 符号链接）

    参数:
        path: 待判断的路径
    返回值: True 表示是链接（含 Windows junction）
    备注: Windows 上 os.path.islink() 对 junction 返回 False，
          必须看 lstat 的 st_file_attributes 重解析点标志。
    """
    try:
        st = os.lstat(path)
    except OSError:
        return False
    attrs = getattr(st, "st_file_attributes", 0)
    if attrs & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
        return True
    return os.path.islink(path)


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


def load_config():
    """读取备份配置：backup.local.json 存在时整体覆盖 backup.config.json

    返回值: dict，至少包含 categories（分类列表）与 destRoot（输出根目录）。
    备注: 配置文件不存在或格式错误时直接终止，避免半套清单静默执行。
    """
    path = LOCAL_CONFIG_FILE if os.path.isfile(LOCAL_CONFIG_FILE) else CONFIG_FILE
    if not os.path.isfile(path):
        raise SystemExit("找不到备份配置：%s" % path)
    try:
        with open(path, encoding="utf-8-sig") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError) as e:
        raise SystemExit("备份配置读取失败：%s（%s）" % (path, e))
    cats = cfg.get("categories") or []
    if not cats:
        raise SystemExit("备份配置里没有任何分类：%s" % path)
    for cat in cats:
        if not cat.get("id") or not cat.get("name"):
            raise SystemExit("备份配置的分类缺少 id/name：%s" % path)
    if path == LOCAL_CONFIG_FILE:
        print("  [配置] 使用本机覆盖配置：%s" % path)
    cfg["_path"] = path
    return cfg


def print_categories(cats):
    """打印分类清单，供手工选择或 --list 查看"""
    print(" 可用备份分类：")
    for i, cat in enumerate(cats, 1):
        mark = "默认" if cat.get("default") else "默认不选"
        extra = ""
        if cat.get("external"):
            extra = "（外部脚本）"
        print("   %2d  %-34s %s%s" % (i, cat.get("name"), mark, extra))


def parse_selection(text, count):
    """解析 1,3,5 / 1-5 / a 形式的选择

    参数:
        text: 用户输入的字符串
        count: 可选项总数
    返回值: 升序编号列表；空输入返回空列表
    异常: ValueError 表示输入不合法或越界
    """
    text = text.strip().lower()
    if not text:
        return []
    if text == "a":
        return list(range(1, count + 1))
    picked = set()
    for part in text.replace("，", ",").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo_s, hi_s = part.split("-", 1)
            if not (lo_s.strip().isdigit() and hi_s.strip().isdigit()):
                raise ValueError(part)
            lo, hi = int(lo_s), int(hi_s)
            if lo > hi:
                lo, hi = hi, lo
            picked.update(range(lo, hi + 1))
        elif part.isdigit():
            picked.add(int(part))
        else:
            raise ValueError(part)
    if any(p < 1 or p > count for p in picked):
        raise ValueError(text)
    return sorted(picked)


def choose_categories(cats):
    """交互选择备份分类；直接回车使用默认分类

    返回值: 选中的分类列表；输入 0 或中断时返回 None（表示取消，返回上一级）
    """
    print_categories(cats)
    default_idx = [i for i, cat in enumerate(cats, 1) if cat.get("default")]
    print("")
    print(" 输入编号选择（如 1,3,5 或 1-5；a=全选；直接回车=默认分类）")
    print("   0  返回上一级（不备份）")
    while True:
        try:
            raw = input(" 选择: ")
        except (EOFError, KeyboardInterrupt):
            print("")
            return None
        if raw.strip() == "0":
            return None
        try:
            picked = parse_selection(raw, len(cats))
        except ValueError:
            print("  [无效] 请输入 1,3,5 或 1-5 或 a；0=返回")
            continue
        if not picked:
            picked = default_idx
        if not picked:
            print("  [提示] 默认分类为空，请手动输入编号")
            continue
        chosen = [cats[i - 1] for i in picked]
        print("  已选：%s" % "、".join(c.get("name") for c in chosen))
        return chosen


def choose_variant(cat):
    """为带外部脚本的分类选择备份方式（如 Joplin 是否含附件）

    参数:
        cat: 分类配置
    返回值: 变体 dict；没有变体时返回 None；输入 0 或中断时返回 CANCEL
    """
    variants = (cat.get("external") or {}).get("variants") or []
    if not variants:
        return None
    if len(variants) == 1:
        return variants[0]
    print("")
    print(" %s 备份方式：" % cat.get("name"))
    for i, var in enumerate(variants, 1):
        print("   %d  %s" % (i, var.get("name")))
    print("   0  返回上一级")
    while True:
        try:
            raw = input(" 选择[1]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            return CANCEL
        if raw == "0":
            return CANCEL
        if not raw:
            return variants[0]
        if raw.isdigit() and 1 <= int(raw) <= len(variants):
            return variants[int(raw) - 1]
        print("  [无效] 请输入 1-%d；0=返回" % len(variants))


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return "%.1f %s" % (n, u)
        n /= 1024.0
    return "%.0f PB" % n


def dir_size(p, budget=6.0):
    """快速估算目录体积（带时间预算，大目录只给下限）"""
    total = 0
    t0 = time.time()
    for dp, dn, fn in os.walk(p, followlinks=False):
        # 跳过 junction，避免顺着链接把 D 盘数据算两遍
        dn[:] = [d for d in dn
                 if not (is_link_like(os.path.join(dp, d)))]
        for f in fn:
            try:
                total += os.stat(os.path.join(dp, f), follow_symlinks=False).st_size
            except OSError:
                pass
        if time.time() - t0 > budget:
            return total, True
    return total, False


def dir_bytes(p):
    """统计目录实际字节数（跳过 junction），用于监控拷贝进度"""
    total = 0
    for dp, dn, fn in os.walk(p, followlinks=False):
        dn[:] = [d for d in dn if not is_link_like(os.path.join(dp, d))]
        for f in fn:
            try:
                total += os.stat(os.path.join(dp, f), follow_symlinks=False).st_size
            except OSError:
                pass
    return total


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


def make_plan(selections):
    """按选中的分类生成备份计划

    参数:
        selections: [(分类配置, 变体或 None)]
    返回值: (计划列表, 目录总体积, 统计 dict)
    计划项: (分类名, 相对路径, 源路径, 说明, 体积, 显示文本)
    """
    plan = []
    total = 0
    stats = {"files": 0, "browsers": 0, "sysfiles": 0, "reg": 0, "external": 0,
             "links": 0, "links_off_c": 0}
    for cat, variant in selections:
        for item in cat.get("dirs") or []:
            rel = item.get("rel")
            note = item.get("note", "")
            src = os.path.join(HOME, rel)
            if not os.path.isdir(src):
                continue
            if is_link_like(src):
                # 链接指向不在 C 盘时，数据随目标盘保留，重装后要靠 links.csv 重建
                try:
                    target = os.path.realpath(src)
                except OSError:
                    target = ""
                drive = os.path.splitdrive(target)[0].upper() if target else ""
                off_c = bool(drive) and drive != "C:"
                if off_c:
                    info = "跳过：链接指向 %s（不在 C 盘）" % target
                    stats["links_off_c"] += 1
                else:
                    info = "跳过：本身是链接"
                plan.append((cat.get("name"), rel, src, note, 0, info))
                stats["links"] += 1
                continue
            progress_line("  估算体积: %s ..." % rel)
            size, truncated = dir_size(src)
            total += size
            plan.append((cat.get("name"), rel, src, note, size,
                         "约 %s%s" % (human(size), " 起" if truncated else "")))
        stats["files"] += len(cat.get("files") or [])
        stats["browsers"] += len(cat.get("browsers") or [])
        sys_cfg = cat.get("system") or {}
        stats["sysfiles"] += len(sys_cfg.get("files") or [])
        stats["reg"] += len(sys_cfg.get("regExports") or [])
        if cat.get("external"):
            stats["external"] += 1
    sys.stdout.write("\n")
    sys.stdout.flush()
    return plan, total, stats


def print_plan(selections, plan, total, stats, dest_root, skip_large):
    """打印备份计划，返回实际会处理的目录总体积"""
    print("=" * 68)
    print(" 备份计划  ->  %s" % dest_root)
    print("=" * 68)
    last_cat = None
    real_total = 0
    skipped = []
    for cat_name, rel, src, note, size, info in plan:
        if cat_name != last_cat:
            print("  [%s]" % cat_name)
            last_cat = cat_name
        if skip_large and size > SKIP_LARGE_BYTES:
            skipped.append(rel)
            print("    %-42s 跳过(>200MB)" % rel[:42])
            continue
        real_total += size
        print("    %-42s %s" % (rel[:42], info))
    print("  " + "-" * 64)
    print("  目录合计约 %s（实际执行 %s）"
          % (human(total), "跳过大目录后约 %s" % human(real_total) if skipped else "全部"))
    print("")

    extra = []
    for cat, variant in selections:
        if cat.get("files"):
            extra.append("%d 个单文件" % len(cat.get("files")))
        if cat.get("browsers"):
            extra.append("%d 类浏览器配置" % len(cat.get("browsers")))
        sys_cfg = cat.get("system") or {}
        if sys_cfg.get("files"):
            extra.append("%d 个系统文件" % len(sys_cfg.get("files")))
        if sys_cfg.get("regExports"):
            extra.append("%d 项注册表导出" % len(sys_cfg.get("regExports")))
        if cat.get("external") and variant:
            extra.append("%s：%s" % (cat.get("name"), variant.get("name")))
    if extra:
        print("  另含：" + "、".join(extra))
        print("")
    if stats.get("links_off_c"):
        print("  注意：%d 个目录是链接且目标不在 C 盘，已跳过。" % stats["links_off_c"])
        print("        这些数据随目标盘保留，重装后靠 links.csv 重建链接；")
        print("        请先跑菜单 16「扫描 / 记录链接」，把未登记的链接补进清单。")
        print("")
    return real_total, skipped


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


def copy_files(cat, dest):
    """拷贝分类里的单文件，返回失败说明列表"""
    errors = []
    print("  -> [%s] 单文件 ..." % cat.get("name"), end="", flush=True)
    for item in cat.get("files") or []:
        rel = item.get("rel")
        src = os.path.join(HOME, rel)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            shutil.copy2(src, dst)
        except OSError as e:
            errors.append("%s : %s" % (rel, e))
            print("\n     ! %s : %s" % (rel, e))
    print(" OK")
    return errors


def copy_browsers(cat, dest):
    """拷贝浏览器书签/偏好/历史/扩展，并导出扩展清单"""
    errors = []
    profile_files = cat.get("profileFiles") or []
    for browser in cat.get("browsers") or []:
        rel = browser.get("rel")
        label = browser.get("label") or rel
        base = os.path.join(HOME, rel)
        if not os.path.isdir(base):
            continue
        for prof in sorted(os.listdir(base)):
            pdir = os.path.join(base, prof)
            if not os.path.isdir(pdir) or not (prof == "Default" or prof.startswith("Profile ")):
                continue
            for fname in profile_files:
                src = os.path.join(pdir, fname)
                if not os.path.isfile(src):
                    continue
                dst_dir = os.path.join(dest, "browser", "%s_%s" % (label, prof))
                os.makedirs(dst_dir, exist_ok=True)
                try:
                    shutil.copy2(src, os.path.join(dst_dir, fname))
                except OSError as e:
                    # 浏览器在运行时会独占 SQLite 文件，这里只告警不中断
                    errors.append("%s\\%s\\%s : %s" % (label, prof, fname, e))
                    print("\n     ! %s\\%s\\%s : %s" % (label, prof, fname, e))
            ext = os.path.join(pdir, "Extensions")
            if os.path.isdir(ext):
                ext_dst = os.path.join(dest, "browser", "%s_%s" % (label, prof), "Extensions")
                try:
                    if os.path.isdir(ext_dst):
                        shutil.rmtree(ext_dst)
                    shutil.copytree(ext, ext_dst)
                except OSError as e:
                    errors.append("%s\\%s\\Extensions : %s" % (label, prof, e))
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
                    errors.append("%s\\%s\\Secure Preferences : %s" % (label, prof, e))
                    print("\n     ! %s\\%s\\Secure Preferences : %s" % (label, prof, e))
        # Local State 故意不备份：内含 DPAPI 加密的主密钥，换机器无法解密，还会破坏新系统的配置
    return errors


def export_system(cat, dest):
    """导出系统项：hosts、注册表、winget 清单、环境变量快照"""
    errors = []
    sys_cfg = cat.get("system") or {}
    for item in sys_cfg.get("files") or []:
        src = item.get("path")
        if src and os.path.isfile(src):
            try:
                shutil.copy2(src, os.path.join(dest, item.get("name") or os.path.basename(src)))
            except OSError as e:
                errors.append("%s : %s" % (src, e))
                print("  ! %s : %s" % (src, e))

    for item in sys_cfg.get("regExports") or []:
        out_path = os.path.join(dest, "registry", item.get("name"))
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        code, _ = run(["reg", "export", item.get("key"), out_path, "/y"], timeout=120)
        print("  reg %s : %s" % (item.get("key"), "OK" if code == 0 else "失败"))
        if code != 0:
            errors.append("reg %s 导出失败" % item.get("key"))

    if sys_cfg.get("wingetExport"):
        with Spin("winget export（导出已装软件清单，最长等 10 分钟）"):
            code, _ = run(["winget", "export", "-o", os.path.join(dest, "winget_export.json"),
                           "--accept-source-agreements", "--disable-interactivity"], timeout=600)
        print("  winget export : %s" % ("OK" if code == 0 else "失败"))
        if code != 0:
            errors.append("winget export 失败")

    if sys_cfg.get("environmentSnapshot"):
        try:
            with open(os.path.join(dest, "environment.txt"), "w", encoding="utf-8-sig") as f:
                for k, v in sorted(os.environ.items()):
                    f.write("%s=%s\n" % (k, v))
        except OSError as e:
            errors.append("environment.txt : %s" % e)
    return errors


def run_external(cat, variant, dest):
    """调用外部脚本（如 Joplin 备份），返回是否成功"""
    ext = cat.get("external") or {}
    script = os.path.join(SCRIPT_DIR, ext.get("script") or "")
    if not os.path.isfile(script):
        print("  ! 找不到外部脚本：%s" % script)
        return False
    cmd = [sys.executable, script] + list((variant or {}).get("args") or []) + ["--out", dest]
    print("  -> [%s] %s ..." % (cat.get("name"), (variant or {}).get("name", "")))
    code = subprocess.call(cmd)
    print("        %s" % ("OK" if code == 0 else "失败(退出码 %s)" % code))
    return code == 0


def write_readme(dest, results, ts, dest_root):
    lines = []
    lines.append("# 恢复清单（备份时间 %s）" % ts)
    lines.append("")
    lines.append("备份根目录：`%s`" % dest)
    lines.append("")
    lines.append("## 备份项")
    lines.append("")
    lines.append("| 分类 | 项目 | 状态 |")
    lines.append("|---|---|---|")
    for cat_name, label, ok, detail in results:
        status = "✅" if ok else "❌ %s" % detail
        lines.append("| %s | `%s` | %s |" % (cat_name, label, status))
    lines.append("")
    lines.append("## 恢复方法")
    lines.append("")
    lines.append("重装完成后，把上表里的目录**逐个**拷回对应位置即可。命令模板：")
    lines.append("")
    lines.append("```bat")
    lines.append(r'robocopy "%s\%s\AppData\Local\JetBrains" "%%LOCALAPPDATA%%\JetBrains" /E /XJ /R:1 /W:1' % (dest, ""))
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true", help="真正执行拷贝（默认只打印计划）")
    ap.add_argument("--select", action="store_true", help="先交互选择备份分类")
    ap.add_argument("--only", default="", help="只备份指定分类 id，逗号分隔")
    ap.add_argument("--list", action="store_true", help="只列出分类")
    ap.add_argument("--skip-large", action="store_true", help="跳过体积 >200MB 的目录")
    args = ap.parse_args()

    cfg = load_config()
    cats = cfg.get("categories") or []
    dest_root = os.path.expandvars(os.path.expanduser(cfg.get("destRoot") or DEFAULT_DEST_ROOT))

    if args.list:
        print_categories(cats)
        return 0

    if args.only:
        ids = [x.strip() for x in args.only.split(",") if x.strip()]
        by_id = {cat.get("id"): cat for cat in cats}
        unknown = [x for x in ids if x not in by_id]
        if unknown:
            print("❌ 未知分类 id：%s" % "、".join(unknown))
            print("")
            print_categories(cats)
            return 2
        chosen = [by_id[x] for x in ids]
    elif args.select:
        chosen = choose_categories(cats)
        if chosen is None:
            print(" 已取消，返回上一级。")
            return 3
    else:
        chosen = [cat for cat in cats if cat.get("default")]

    if not chosen:
        print("没有选择任何备份分类，退出。")
        return 0

    selections = []
    for cat in chosen:
        variant = choose_variant(cat) if cat.get("external") else None
        if variant is CANCEL:
            print(" 已取消，返回上一级。")
            return 3
        selections.append((cat, variant))

    preflight()
    plan, total, stats = make_plan(selections)
    real_total, skipped = print_plan(selections, plan, total, stats, dest_root, args.skip_large)

    if not args.run:
        print("=" * 68)
        print(" 这是干跑。确认无误后加 --run 真正执行；")
        print(" 想先选分类再执行，用 --select --run：")
        print("   python \"%s\" --select --run" % os.path.abspath(__file__))
        print("=" * 68)
        return 0

    if args.select:
        try:
            ans = input(" 确认按以上分类开始备份？输入 y 回车: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("")
            return 3
        if ans != "y":
            print(" 已取消，返回上一级。")
            return 3

    # ---------------- 真跑 ----------------
    if not os.path.isdir(dest_root.split(":")[0] + ":\\"):
        print("❌ 目标盘不存在：%s" % dest_root)
        return 1

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dest = os.path.join(dest_root, ts)
    os.makedirs(dest, exist_ok=True)
    logdir = os.path.join(dest, "_logs")
    os.makedirs(logdir, exist_ok=True)
    master = os.path.join(logdir, "robocopy.log")

    results = []
    todo = []
    for cat_name, rel, src, note, size, info in plan:
        if args.skip_large and size > SKIP_LARGE_BYTES:
            results.append((cat_name, rel, True, "已按 --skip-large 跳过"))
            continue
        if is_link_like(src):
            continue
        todo.append((cat_name, rel, src, size))

    ndirs = len(todo)
    for idx, (cat_name, rel, src, size) in enumerate(todo, 1):
        target = os.path.join(dest, rel)
        code = copy_dir(src, target, master, max(size, 1), rel, idx, ndirs)
        ok = code < 8
        print("        %s" % ("OK" if ok else "失败(robocopy 退出码 %s，见日志)" % code))
        results.append((cat_name, rel, ok, "robocopy 退出码 %s" % code))

    for cat, variant in selections:
        if cat.get("files"):
            errs = copy_files(cat, dest)
            results.append((cat.get("name"), "单文件", not errs, "；".join(errs)))
        if cat.get("browsers"):
            errs = copy_browsers(cat, dest)
            results.append((cat.get("name"), "浏览器配置", not errs, "；".join(errs)))
        if cat.get("system"):
            errs = export_system(cat, dest)
            results.append((cat.get("name"), "系统项", not errs, "；".join(errs)))
        if cat.get("external"):
            ok = run_external(cat, variant, dest)
            results.append((cat.get("name"), variant.get("name", "外部备份"), ok, "退出码非 0"))

    write_readme(dest, results, ts, dest_root)

    failed = [r for r in results if not r[2]]
    print("")
    print("=" * 68)
    print(" 完成：%s" % dest)
    print(" 恢复说明：%s" % os.path.join(dest, "恢复清单.md"))
    if failed:
        print(" ⚠️  有 %d 项失败，详见恢复清单" % len(failed))
    print("=" * 68)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
