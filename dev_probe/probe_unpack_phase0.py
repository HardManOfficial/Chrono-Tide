# -*- coding: utf-8 -*-
"""Phase 0 技术验证探针（智能解压方案 §7 Phase 0）。
验证四组假设：
  A. bz.exe 对独立 .lz4 / .zip.lz4 的解压能力（G5 修复前提）
  B. 7z l 对「加密文件名 7z / 加密 zip」的列表行为（计划探测前提）
  C. 错误密码时 7z 的 exitCode/错误文本（ZipCrypto vs 7z -mhe，密码轮换判定前提）
  D. 魔数嗅探表 + 7z 对改后缀文件的免疫性
产物：样本 D:\\CTLIB\\.workbuddy\\tmp_unpack_probe\\（临时，可删）
结果：D:\\CTLIB\\dev_probe\\probe_unpack_phase0_out.txt
"""
import os, shutil, subprocess, sys, json

try:
    import lz4.frame
    HAVE_LZ4 = True
except ImportError:
    HAVE_LZ4 = False

SEVENZIP = r"D:\CTLIB\windows\runner\tools\7z.exe"
BZ = r"D:\CTLIB\assets\tools\bz.exe"
WORK = r"D:\CTLIB\.workbuddy\tmp_unpack_probe"
OUT = r"D:\CTLIB\dev_probe\probe_unpack_phase0_out.txt"
PW = "Bilibili_Slpeey"   # 项目现有默认密码（顺带验证密码表第一项可用）
WRONG = "definitely_wrong_pw"

os.makedirs(WORK, exist_ok=True)
lines = []
def log(s=""):
    lines.append(s)
    print(s)

def run(cmd, **kw):
    """subprocess 包装：bytes 捕获 + utf8/gbk 兜底解码"""
    p = subprocess.run(cmd, capture_output=True, timeout=120, **kw)
    def dec(b):
        for enc in ("utf-8", "gbk"):
            try:
                return b.decode(enc)
            except UnicodeDecodeError:
                continue
        return b.decode("utf-8", errors="replace")
    return p.returncode, dec(p.stdout), dec(p.stderr)

def key_lines(text, keywords, limit=6):
    hits = [l.strip() for l in text.splitlines()
            if any(k.lower() in l.lower() for k in keywords)]
    return hits[:limit]

# ---------- 造样本 ----------
log("=" * 72)
log("样本构造  (lz4 lib: %s)" % HAVE_LZ4)
game_dir = os.path.join(WORK, "fake_game")
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(game_dir)
# 假 exe（MZ 头）+ 中文内容 txt（测编码）
with open(os.path.join(game_dir, "game.exe"), "wb") as f:
    f.write(b"MZ" + b"\x00" * 128)
with open(os.path.join(game_dir, "说明.txt"), "w", encoding="utf-8") as f:
    f.write("测试中文文件名与内容\nセーブデータ用\n")

S = {}  # 样本路径表
def make_archive(dst, args, cwd=WORK):
    rc, so, se = run([SEVENZIP, "a", "-y"] + args + [dst, "fake_game"], cwd=cwd)
    S[dst] = os.path.join(WORK, dst)
    log("  造 %-22s rc=%d %s" % (dst, rc, "OK" if rc == 0 else se[:120]))
    return rc == 0

make_archive("plain.zip",           ["-tzip"])
make_archive("plain.7z",            ["-t7z"])
make_archive("enc_name.7z",         ["-t7z", "-mhe=on", "-p" + PW])       # 加密文件名
make_archive("enc_zipcrypto.zip",   ["-tzip", "-p" + PW])                 # 传统 ZipCrypto
make_archive("enc_zip_aes.zip",     ["-tzip", "-p" + PW, "-mem=AES256"])  # AES-256 zip
# 伪装：zip 内容换 .mp4 后缀
shutil.copyfile(S["plain.zip"], os.path.join(WORK, "disguise.mp4"))
S["disguise.mp4"] = os.path.join(WORK, "disguise.mp4")
# lz4 系
if HAVE_LZ4:
    with open(S["plain.zip"], "rb") as f:
        raw = f.read()
    with open(os.path.join(WORK, "game.zip.lz4"), "wb") as f:
        f.write(lz4.frame.compress(raw))
    with open(os.path.join(WORK, "data.lz4"), "wb") as f:
        f.write(lz4.frame.compress("hello galgame 数据" .encode("utf-8") * 100))
    S["game.zip.lz4"] = os.path.join(WORK, "game.zip.lz4")
    S["data.lz4"] = os.path.join(WORK, "data.lz4")
    log("  造 game.zip.lz4 / data.lz4 OK")
else:
    log("  ⚠ 无 lz4 库，跳过 lz4 样本")

log("=" * 72)
log("T1-T9  7z.exe 行为矩阵")
def t(name, desc, cmd, expect_rc0=None, keywords=()):
    rc, so, se = run(cmd)
    ok = (rc == 0) if (expect_rc0 is not None) else None
    log("[%s] %s" % (name, desc))
    log("      cmd = %s" % " ".join(os.path.basename(c) if c.startswith("D:") else c for c in cmd))
    log("      rc=%d" % rc)
    hits = key_lines(so + "\n" + se, list(keywords) or ["error", "wrong", "password", "加密", "cannot", "type"])
    for h in hits:
        log("      | " + h)
    if expect_rc0 is not None:
        log("      => %s (期望 rc=%s)" % ("PASS" if ok == expect_rc0 else "❌UNEXPECTED", expect_rc0))
    return rc, so, se

out_dir = os.path.join(WORK, "out")
os.makedirs(out_dir, exist_ok=True)

t("T1", "基线：列明文 zip", [SEVENZIP, "l", "-sccUTF-8", S["plain.zip"]], expect_rc0=True)
t("T2", "列「加密文件名 7z」无密码（期望失败→探测断链点）",
  [SEVENZIP, "l", "-sccUTF-8", "-p", S["enc_name.7z"]], expect_rc0=False)
t("T3", "列「加密文件名 7z」正确密码（期望成功）",
  [SEVENZIP, "l", "-sccUTF-8", "-p" + PW, S["enc_name.7z"]], expect_rc0=True)
t("T4", "列「ZipCrypto zip」无密码（文件名不加密→期望能列）",
  [SEVENZIP, "l", "-sccUTF-8", "-p", S["enc_zipcrypto.zip"]])
t("T5", "列「AES zip」无密码（期望能列文件名）",
  [SEVENZIP, "l", "-sccUTF-8", "-p", S["enc_zip_aes.zip"]])
t("T6", "测试「ZipCrypto zip」错密码（观察 CRC vs Wrong password）",
  [SEVENZIP, "t", "-sccUTF-8", "-p" + WRONG, S["enc_zipcrypto.zip"]])
t("T7", "测试「加密文件名 7z」错密码（期望 Wrong password）",
  [SEVENZIP, "t", "-sccUTF-8", "-p" + WRONG, S["enc_name.7z"]])
t("T8", "解压「ZipCrypto zip」错密码（观察是否解出垃圾/CRC fail）",
  [SEVENZIP, "x", "-y", "-sccUTF-8", "-p" + WRONG, "-o" + os.path.join(out_dir, "t8"), S["enc_zipcrypto.zip"]])
t("T9", "完整性测试明文 zip（7z t 基线）",
  [SEVENZIP, "t", "-sccUTF-8", S["plain.zip"]], expect_rc0=True)

log("=" * 72)
log("T10-T15 bz.exe / 改后缀 / 7z-lz4")
if HAVE_LZ4:
    t("T10", "bz.exe 解独立 .lz4（G5 修复前提）",
      [BZ, "x", "-y", "-o:" + os.path.join(out_dir, "t10"), S["data.lz4"]], expect_rc0=True)
    t("T11", "bz.exe 解 .zip.lz4（期望解出 zip 文件）",
      [BZ, "x", "-y", "-o:" + os.path.join(out_dir, "t11"), S["game.zip.lz4"]], expect_rc0=True)
    t11_zip = os.path.join(out_dir, "t11", "plain.zip")
    if os.path.isfile(t11_zip):
        log("      | 产物确认: plain.zip 存在 (%d B)" % os.path.getsize(t11_zip))
    else:
        log("      | 产物确认: ❌ 未找到 plain.zip，实际: %s" % os.listdir(os.path.join(out_dir, "t11")))

t("T12", "bz.exe 解「伪装 .mp4」(=zip)——Bandizip 是否按内容识别",
  [BZ, "x", "-y", "-o:" + os.path.join(out_dir, "t12"), S["disguise.mp4"]])
t("T14", "7z l「伪装 .mp4」——7z 是否按内容识别（后缀免疫性）",
  [SEVENZIP, "l", "-sccUTF-8", S["disguise.mp4"]], expect_rc0=True)
if HAVE_LZ4:
    t("T15", "7z l .lz4——7z 23.01 是否原生支持 lz4（预期不支持→必须用 bz.exe）",
      [SEVENZIP, "l", "-sccUTF-8", S["data.lz4"]])

log("=" * 72)
log("T13 魔数嗅探表验证（前 16 字节）")
MAGIC = [
    (b"PK\x03\x04", "zip"), (b"PK\x05\x06", "zip(empty)"), (b"PK\x07\x08", "zip(spanned)"),
    (b"7z\xbc\xaf\x27\x1c", "7z"), (b"Rar!\x1a\x07", "rar"),
    (b"\x04\x22\x4d\x18", "lz4-frame"), (b"MSCF", "cab"),
]
def sniff(path):
    with open(path, "rb") as f:
        head = f.read(16)
    for magic, fmt in MAGIC:
        if head.startswith(magic):
            return fmt, head
    if b"CD001" in head[:9] + b"CD001":
        return "iso", head
    return None, head

for name in ["plain.zip", "plain.7z", "enc_name.7z", "enc_zipcrypto.zip",
             "enc_zip_aes.zip", "disguise.mp4", "game.zip.lz4", "data.lz4"]:
    if name in S and os.path.isfile(S[name]):
        fmt, head = sniff(S[name])
        log("  %-22s -> %-10s head=%s" % (name, fmt or "UNKNOWN", head.hex(" ")))

log("=" * 72)
log("T10/T11/T12 产物目录清点")
for d in sorted(os.listdir(out_dir)):
    full = os.path.join(out_dir, d)
    log("  %s/: %s" % (d, os.listdir(full) if os.path.isdir(full) else "(file)"))

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("\n>>> 结果已写 %s" % OUT)
