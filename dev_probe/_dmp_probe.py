# -*- coding: utf-8 -*-
"""极简 minidump 解析：异常码 / 异常地址 / 所属模块 / 模块列表（无符号也能定方向）。"""
import struct
import sys


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def read_mdstring(buf, rva):
    n = u32(buf, rva)  # 字节数
    raw = buf[rva + 4: rva + 4 + n]
    return raw.decode("utf-16-le", "replace")


def main(path):
    with open(path, "rb") as f:
        b = f.read()
    assert b[:4] == b"MDMP", "not a minidump"
    nstreams = u32(b, 8)
    dir_rva = u32(b, 12)
    streams = {}
    for i in range(nstreams):
        o = dir_rva + i * 12
        stype, size, rva = u32(b, o), u32(b, o + 4), u32(b, o + 8)
        streams[stype] = (rva, size)

    print("streams:", sorted(streams))

    # 模块列表
    modules = []
    if 4 in streams:
        rva, _ = streams[4]
        n = u32(b, rva)
        o = rva + 4
        for _ in range(n):
            base = u64(b, o)
            size = u32(b, o + 8)
            name_rva = u32(b, o + 20)
            try:
                name = read_mdstring(b, name_rva)
            except Exception:
                name = "?"
            modules.append((base, base + size, name))
            o += 108
        print("modules:", len(modules))

    def who(addr):
        for lo, hi, name in modules:
            if lo <= addr < hi:
                return "%s +0x%x" % (name, addr - lo)
        return "outside-module"

    # 异常流
    if 6 in streams:
        rva, _ = streams[6]
        tid = u32(b, rva)
        er = rva + 8
        code = u32(b, er)
        flags = u32(b, er + 4)
        addr = u64(b, er + 16)
        nparams = u32(b, er + 24)
        params = [u64(b, er + 32 + i * 8) for i in range(min(nparams, 15))]
        print("thread id:", tid)
        print("exception code: 0x%08X" % code)
        print("exception flags: 0x%08X" % flags)
        print("exception address: 0x%X -> %s" % (addr, who(addr)))
        print("params:", ["0x%X" % p for p in params])
        if code == 0xC0000005 and len(params) >= 2:
            kind = {0: "READ", 1: "WRITE", 8: "EXEC"}.get(params[0], str(params[0]))
            print("  access violation: %s at 0x%X -> %s" % (kind, params[1], who(params[1])))

    # 线程数
    if 3 in streams:
        rva, _ = streams[3]
        print("threads:", u32(b, rva))


if __name__ == "__main__":
    main(sys.argv[1])
