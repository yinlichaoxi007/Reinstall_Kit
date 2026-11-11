# -*- coding: utf-8 -*-
"""
Joplin 笔记库备份（一致快照）
================================================================
默认「干跑」：只打印计划，不动任何文件。
确认后加 --run 才真正备份。

    python 备份Joplin.py                    # 看计划
    python 备份Joplin.py --run              # 备份库+设置+插件（约 200 MB）
    python 备份Joplin.py --run --with-resources   # 连 4.5 GB 附件一起（约 4.8 GB）
    python 备份Joplin.py --run --zip        # 打包成一个 zip

为什么要专门写一个脚本：
  Joplin 运行时一直往 database.sqlite 里写（WAL 模式），直接 copy 可能拿到
  不一致的库（缺最新笔记、甚至损坏）。这里用 SQLite 官方在线备份 API
  （Connection.backup）生成一致性快照，Joplin 开着也安全。

不包含什么（重要）：
  · 主密码 / App Locker 锁屏密码 —— 存在 Windows 凭据管理器，不在 profile 目录里
  · 同步账号的 token —— 同上
  这些重装后要自己重新输入。

输出：<backupRoot>\\joplin-<时间戳>\\
      backupRoot 由工程包根目录的 kit.config.json 决定，留空时用 <工程包>\\backup
"""
import argparse
import datetime
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import threading

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_ROOT = os.path.dirname(SCRIPT_DIR)
KIT_CONFIG_FILE = os.path.join(KIT_ROOT, "kit.config.json")
HOME = os.path.expanduser("~")


def load_backup_root():
    """读取 kit.config.json 的 backupRoot

    返回值: 备份根目录；文件缺失或字段留空时返回 <工程包>\\backup
    备注: 只有独立运行本脚本时才用到，被 02-备份.py 调用时由它传 --out
    """
    try:
        with open(KIT_CONFIG_FILE, encoding="utf-8-sig") as fh:
            cfg = json.load(fh) or {}
        root = (cfg.get("backupRoot") or "").strip()
    except (OSError, ValueError):
        root = ""
    return root or os.path.join(KIT_ROOT, "backup")


DEFAULT_OUT = load_backup_root()


def progress_line(text):
    """单行实时刷新：\\r 覆盖当前行，行尾补空格清掉残留"""
    if len(text) > 110:
        text = text[:110]
    sys.stdout.write("\r" + text + " " * max(0, 118 - len(text)))
    sys.stdout.flush()


def dir_bytes(p):
    """统计目录实际字节数，用于监控拷贝进度"""
    total = 0
    for dp, dn, fn in os.walk(p):
        for f in fn:
            try:
                total += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return total

CANDIDATE_PROFILES = [
    os.path.join(HOME, ".config", "joplin-desktop"),
    os.path.join(os.environ.get("APPDATA", ""), "joplin-desktop"),
    os.path.join(os.environ.get("APPDATA", ""), "Joplin"),
]


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit)
        n /= 1024.0


def say(msg=""):
    print(msg, flush=True)


def dir_size(path):
    total = 0
    files = 0
    for root, _dirs, names in os.walk(path):
        for name in names:
            try:
                total += os.path.getsize(os.path.join(root, name))
                files += 1
            except OSError:
                pass
    return total, files


def find_profile():
    for p in CANDIDATE_PROFILES:
        if p and os.path.isdir(p):
            db = os.path.join(p, "database.sqlite")
            if os.path.isfile(db):
                return p
    return None


def joplin_running():
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq Joplin.exe", "/NH"],
            capture_output=True, text=True, timeout=15, encoding="mbcs", errors="ignore")
        return "Joplin.exe" in (out.stdout or "")
    except Exception:
        return False


def db_stats(db_path):
    """只统计数量，不读正文"""
    con = sqlite3.connect("file:%s?mode=ro" % db_path.replace("\\", "/"), uri=True, timeout=15)
    try:
        cur = con.cursor()
        st = {}
        for key, sql in (
            ("notes", "select count(*) from notes where deleted_time=0"),
            ("notes_total", "select count(*) from notes"),
            ("folders", "select count(*) from folders where deleted_time=0"),
            ("tags", "select count(*) from tags"),
            ("note_tags", "select count(*) from note_tags"),
            ("revisions", "select count(*) from revisions"),
            ("resources", "select count(*) from resources"),
        ):
            try:
                st[key] = cur.execute(sql).fetchone()[0]
            except sqlite3.Error:
                st[key] = None
        try:
            st["last_note_update"] = cur.execute("select max(updated_time) from notes").fetchone()[0]
        except sqlite3.Error:
            st["last_note_update"] = None
        return st
    finally:
        con.close()


def snapshot_db(src, dst):
    """SQLite 在线备份 API：源库被写入时也能拿到一致快照；带页级进度"""
    src_con = sqlite3.connect("file:%s?mode=ro" % src.replace("\\", "/"), uri=True, timeout=30)
    try:
        if os.path.exists(dst):
            os.remove(dst)
        dst_con = sqlite3.connect(dst)
        try:
            def cb(status, remaining, total):
                if total > 0:
                    pct = (total - remaining) * 100.0 / total
                    progress_line("        快照 %5.1f%%  （剩 %d / %d 页）" % (pct, remaining, total))
            with dst_con:
                src_con.backup(dst_con, pages=512, progress=cb)
        finally:
            dst_con.close()
    finally:
        src_con.close()
    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true", help="真正执行（默认只干跑）")
    ap.add_argument("--with-resources", action="store_true", help="连 4.5 GB 附件一起备份")
    ap.add_argument("--zip", action="store_true", help="备份完成后打包成 zip")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出根目录")
    ap.add_argument("--purge-logs", action="store_true", help="顺手把 profile 里的 log.txt 清掉（可释放 150 MB）")
    args = ap.parse_args()

    profile = find_profile()
    print("=" * 64)
    print("  Joplin 笔记库备份")
    print("=" * 64)
    if not profile:
        print("  [失败] 没找到 Joplin 数据目录。找过这些位置：")
        for p in CANDIDATE_PROFILES:
            print("         " + (p or "(空)"))
        return 2

    db = os.path.join(profile, "database.sqlite")
    resources = os.path.join(profile, "resources")
    plugins = os.path.join(profile, "plugins")

    real = os.path.realpath(profile)
    print("  数据目录 : %s" % profile)
    if real.lower() != os.path.abspath(profile).lower():
        print("  实际位置 : %s  （junction）" % real)
    print("  数据库   : %.1f MB" % (os.path.getsize(db) / 1048576))

    st = db_stats(db)
    print("  笔记 %s 条（含回收站 %s）、笔记本 %s、标签 %s、修订 %s、资源 %s"
          % (st["notes"], st["notes_total"], st["folders"], st["tags"], st["revisions"], st["resources"]))
    if st.get("last_note_update"):
        print("  最近更新 : %s" % datetime.datetime.fromtimestamp(
            st["last_note_update"] / 1000).strftime("%Y-%m-%d %H:%M"))

    rsize = 0
    rfiles = 0
    psize, pfiles = dir_size(plugins) if os.path.isdir(plugins) else (0, 0)
    if args.with_resources and os.path.isdir(resources):
        rsize, rfiles = dir_size(resources)
        print("  附件目录 : %s / %d 个文件  （会一起备份）" % (human(rsize), rfiles))
    else:
        print("  附件目录 : %s 个资源，默认不备份（要连附件就加 --with-resources）" % st["resources"])
    print("  插件目录 : %s / %d 个文件" % (human(psize), pfiles))

    running = joplin_running()
    print("  Joplin   : %s" % ("运行中（用在线备份 API，安全）" if running else "未运行"))

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(args.out, "joplin-" + stamp)
    print("")
    print("  输出到   : %s" % dest)
    print("  预计占用 : %s" % human(183 * 1048576 + psize + (rsize if args.with_resources else 0)))

    if not args.run:
        print("")
        print("  这是干跑。确认无误后加 --run 真正执行。")
        print("  （开始.cmd 菜单 2 → 选分类 → joplin 会带着 --run 调这个脚本）")
        return 0

    # ---------------------------------------------------------------- 执行
    os.makedirs(dest, exist_ok=True)

    print("")
    print("  [1/4] 生成数据库一致性快照 ...")
    snap = os.path.join(dest, "database.sqlite")
    snapshot_db(db, snap)
    print("        完成: %.1f MB" % (os.path.getsize(snap) / 1048576))

    print("  [2/4] 校验快照 ...")
    con = sqlite3.connect(snap)
    try:
        ok = con.execute("pragma integrity_check").fetchone()[0]
    finally:
        con.close()
    snap_st = db_stats(snap)
    if ok != "ok":
        print("        [失败] 快照损坏：%s" % ok)
        return 3
    diff = []
    for k in ("notes", "notes_total", "folders", "tags", "note_tags", "revisions", "resources"):
        if snap_st.get(k) != st.get(k):
            diff.append("%s: 源 %s / 快照 %s" % (k, st.get(k), snap_st.get(k)))
    if diff:
        print("        [警告] 快照计数与源库不一致（Joplin 可能刚写入过，重跑一次即可）：")
        for d in diff:
            print("               " + d)
    else:
        print("        integrity_check=ok，计数完全一致")

    print("  [3/4] 拷贝设置与插件 ...")
    for name in ("settings.json", "plugins", "window-state-prod.json"):
        src = os.path.join(profile, name)
        if not os.path.exists(src):
            continue
        dst = os.path.join(dest, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)
        print("        + %s" % name)

    if args.with_resources:
        print("  [4/4] 拷贝附件（%s，实时显示进度）..." % human(rsize))
        dst_res = os.path.join(dest, "resources")
        stop = threading.Event()
        t0 = time.time()

        def mon_res():
            while not stop.wait(2.0):
                done = dir_bytes(dst_res)
                pct = min(99.9, done * 100.0 / max(rsize, 1))
                rate = done / max(0.5, time.time() - t0)
                progress_line("        %5.1f%%  %s / %s  %s/s" % (
                    pct, human(done), human(rsize), human(rate)))

        th = threading.Thread(target=mon_res, daemon=True)
        th.start()
        shutil.copytree(resources, dst_res, dirs_exist_ok=True)
        stop.set()
        th.join(timeout=5)
        progress_line("        拷贝完成 %s  用时 %d 秒\n" % (human(rsize), int(time.time() - t0)))
        csize, cfiles = dir_size(os.path.join(dest, "resources"))
        print("        %s / %d 个文件" % (human(csize), cfiles))
    else:
        print("  [4/4] 跳过附件（想连附件一起，加 --with-resources）")

    manifest = {
        "created": stamp,
        "source_profile": profile,
        "source_real": real,
        "source_db_size": os.path.getsize(db),
        "snapshot_db_size": os.path.getsize(snap),
        "stats": st,
        "snapshot_stats": snap_st,
        "with_resources": args.with_resources,
        "resources_files": rfiles if args.with_resources else 0,
        "plugins_files": pfiles,
        "joplin_running_at_backup": running,
        "note": "主密码/App Locker 密码存在 Windows 凭据管理器，不在此备份内；恢复后需重新设置。",
    }
    with open(os.path.join(dest, "MANIFEST.json"), "w", encoding="utf-8-sig") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    with open(os.path.join(dest, "怎么恢复.txt"), "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write("Joplin 备份恢复说明\r\n")
        f.write("=" * 40 + "\r\n\r\n")
        f.write("这个备份是在 %s 生成的。\r\n\r\n" % stamp)
        f.write("恢复步骤：\r\n")
        f.write("  1. 完全退出 Joplin（任务栏图标右键 → 退出）\r\n")
        f.write("  2. 打开 %%USERPROFILE%%\\.config\\ 目录\r\n")
        f.write("  3. 把现有的 joplin-desktop 改名备份（如 joplin-desktop.bad）\r\n")
        f.write("  4. 新建 joplin-desktop 目录，把本目录下的 database.sqlite / settings.json /\r\n")
        f.write("     plugins\\ 拷进去（有 resources\\ 也一起拷）\r\n")
        f.write("  5. 启动 Joplin，笔记应全部在；同步账号需重新登录一次\r\n\r\n")
        f.write("注意：主密码与 App Locker 密码不在备份里（在 Windows 凭据管理器），\r\n")
        f.write("      恢复后按需重新设置即可，不影响笔记本身。\r\n")

    print("")
    print("  完成：%s" % dest)
    total = 0
    files = 0
    for root, _d, names in os.walk(dest):
        for n in names:
            try:
                total += os.path.getsize(os.path.join(root, n))
                files += 1
            except OSError:
                pass
    print("  共 %s / %d 个文件" % (human(total), files))

    if args.zip:
        print("  打包 zip ...")
        base = dest.rstrip("\\/")
        zip_path = base + ".zip"
        stop = threading.Event()
        t0 = time.time()

        def mon_zip():
            while not stop.wait(1.0):
                sz = os.path.getsize(zip_path) if os.path.exists(zip_path) else 0
                progress_line("        已打包 %s  用时 %d 秒" % (human(sz), int(time.time() - t0)))

        th = threading.Thread(target=mon_zip, daemon=True)
        th.start()
        shutil.make_archive(base, "zip", root_dir=os.path.dirname(base), base_dir=os.path.basename(base))
        stop.set()
        th.join(timeout=5)
        progress_line("        打包完成 %s  用时 %d 秒\n" % (human(os.path.getsize(zip_path)), int(time.time() - t0)))
        print("  zip: %s" % zip_path)

    if args.purge_logs:
        for name in ("log.txt",):
            p = os.path.join(profile, name)
            if os.path.exists(p):
                try:
                    os.remove(p)
                    print("  已清理 %s" % name)
                except OSError as e:
                    print("  清理 %s 失败: %s" % (name, e))

    return 0


if __name__ == "__main__":
    sys.exit(main())
