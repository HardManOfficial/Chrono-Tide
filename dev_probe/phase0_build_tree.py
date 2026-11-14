# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 A：构造测试树
目的：造出覆盖「中文/日文文件名、长路径>260、只读文件、0 字节文件、空目录、
      大量小文件、可压/不可压混合体积」的源目录，供压缩→解压往返验证。

运行：python phase0_build_tree.py
产出：D:\\CTLIB\\.workbuddy\\tmp\\phase0\\src\\  （可整体删除，不在 git 内）
      D:\\CTLIB\\dev_probe\\phase0_tree_index.json（文件清单 + 每个文件 sha256）
"""
import os
import sys
import json
import random
import hashlib
import shutil

ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
INDEX = r"D:\CTLIB\dev_probe\phase0_tree_index.json"

# 体积预算（磁盘只剩 ~17G，克制）
BIG_FILE_MB = 64          # 2 个不可压大文件 → 128MB
REPEAT_MB = 48            # 1 个高可压大文件 → 48MB
MANY_FILES = 800          # 小文件数量（测 file_count 边界）

random.seed(20261002)


def sha256_of(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def w(path, data, long_path=False):
    """写文件；long_path=True 时用 \\\\?\\ 前缀绕过 MAX_PATH。"""
    p = path
    if long_path:
        p = "\\\\?\\" + os.path.abspath(path)
    d = os.path.dirname(p)
    os.makedirs(d, exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)


def main():
    if os.path.exists(SRC):
        shutil.rmtree(SRC)
    os.makedirs(SRC, exist_ok=True)

    print(f"[A] 测试树根: {SRC}")

    # ---------- 1. 基础文件（含边界类型） ----------
    w(os.path.join(SRC, "a_normal.bin"), random.randbytes(1 << 20))          # 1 MB 随机
    w(os.path.join(SRC, "b_small.txt"), "hello-chronotide".encode("utf-8"))  # 16 B
    w(os.path.join(SRC, "c_empty.txt"), b"")                                 # 0 B
    w(os.path.join(SRC, "d_zerobyte_noext"), b"")
    # 只读文件
    ro = os.path.join(SRC, "e_readonly.bin")
    w(ro, random.randbytes(256 << 10))
    os.chmod(ro, 0o444)

    # ---------- 2. 中文 / 日文 / 空格 / 特殊符号 文件名 ----------
    w(os.path.join(SRC, "中文目录", "中文测试文件.txt"), "中文内容测试\n".encode("utf-8") * 100)
    w(os.path.join(SRC, "中文目录", "日本語ファイル.dat"), random.randbytes(64 << 10))
    w(os.path.join(SRC, "中文目录", "子目录 空格与'单引号'", "数据.bin"), random.randbytes(32 << 10))
    w(os.path.join(SRC, "日文ディレクトリ", "テスト_セーブ.txt"), "テスト".encode("utf-8") * 200)
    w(os.path.join(SRC, "中文目录", "全角（括号）【方括号】、逗号。.txt"), "全角标点".encode("utf-8"))
    # 以点开头 / 结尾带空格（Windows 会截断，测 7z 与 fs 的一致性）
    w(os.path.join(SRC, "中文目录", ".hidden_config.ini"), b"[cfg]\nk=v\n")

    # ---------- 3. 空目录（7z 默认不存空目录，需 -mhe/或显式，测其行为） ----------
    os.makedirs(os.path.join(SRC, "空目录_should_be_empty"), exist_ok=True)
    os.makedirs(os.path.join(SRC, "中文目录", "空子目录"), exist_ok=True)

    # ---------- 4. 深层嵌套 → 总路径 > 260 字符 ----------
    deep_rel = "/".join(["nested"] + [f"lvl{i:02d}_层级名称测试" for i in range(1, 19)])
    deep_dir = os.path.join(SRC, *deep_rel.split("/"))
    w(os.path.join(deep_dir, "deep_target.txt"), "深层文件".encode("utf-8") * 50, long_path=True)
    deep_abs = os.path.join(deep_dir, "deep_target.txt")
    print(f"[A] 深层文件绝对路径长度 = {len(deep_abs)} 字符  (>260 ? {len(deep_abs) > 260})")
    print(f"    路径 = {deep_abs}")

    # ---------- 5. 大量小文件（file_count 边界） ----------
    many = os.path.join(SRC, "many_small")
    os.makedirs(many, exist_ok=True)
    for i in range(MANY_FILES):
        with open(os.path.join(many, f"f{i:04d}.txt"), "wb") as f:
            f.write(f"small-{i}".encode("utf-8"))

    # ---------- 6. 体积：不可压 + 高可压 ----------
    for i, mb in enumerate([BIG_FILE_MB, BIG_FILE_MB]):
        w(os.path.join(SRC, "big_incompressible", f"rand_{i}.bin"), random.randbytes(mb << 20))
    # 高可压：由 64KB 随机块反复重复（模拟游戏资源）
    block = random.randbytes(64 << 10)
    with open(os.path.join(SRC, "big_compressible.dat"), "wb") as f:
        for _ in range((REPEAT_MB << 20) // len(block)):
            f.write(block)

    # ---------- 7. 建索引（文件清单 + sha256）----------
    # 用 \\?\ 长路径前缀遍历，否则 >260 的深层目录会被跳过（假阴性）
    long_src = "\\\\?\\" + os.path.abspath(SRC)

    def scan_long(root):
        stack = [root]
        out_files, out_dirs = [], []
        while stack:
            d = stack.pop()
            try:
                entries = list(os.scandir(d))
            except OSError as e:
                print(f"!! scandir 失败: {d} {e}")
                continue
            for e in entries:
                if e.is_dir(follow_symlinks=False):
                    out_dirs.append(e.path[len(root) + 1:].replace("\\", "/"))
                    stack.append(e.path)
                else:
                    out_files.append(e.path)
        return out_files, out_dirs

    raw_files, dirs = scan_long(long_src)
    files = []
    total = 0
    for fp in raw_files:
        try:
            sz = os.path.getsize(fp)
        except OSError as e:
            print(f"!! 无法取大小: {fp} {e}")
            continue
        files.append({
            "rel": fp[len(long_src) + 1:].replace("\\", "/"),
            "size": sz,
            "sha256": sha256_of(fp),
        })
        total += sz

    idx = {
        "root": SRC,
        "file_count": len(files),
        "dir_count": len(dirs),
        "total_bytes": total,
        "files": files,
        "dirs": sorted(dirs),
    }
    with open(INDEX, "w", encoding="utf-8") as f:
        json.dump(idx, f, ensure_ascii=False, indent=1)

    print(f"[A] 完成：{len(files)} 个文件 / {len(dirs)} 个目录 / "
          f"{total/1048576:.1f} MB")
    print(f"[A] 索引已写: {INDEX}")


if __name__ == "__main__":
    sys.exit(main())
