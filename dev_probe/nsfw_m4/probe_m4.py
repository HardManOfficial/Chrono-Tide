"""M4 采样探针（一次性诊断）：ctypes 直调 onnxruntime.dll (ORT 1.15.1) C API，
对 dev_probe/nsfw_m4/*.rgba 输出 4 类原始概率，落盘 probs.jsonl。

用途：为 NSFW 纯净模式分级判定定阈（尤其 explicit 单项 → 露点硬门）。
索引规则：OrtApi 成员序号 + 3（前置 CreateStatus/GetErrorCode/GetErrorMessage）。
"""
import ctypes, json, os, sys
from ctypes import (CDLL, CFUNCTYPE, POINTER, Structure, byref, cast, c_char_p,
                    c_float, c_int, c_void_p, c_wchar_p, c_size_t, c_uint32, c_int64)

DLL = r'D:\CTLIB\dev_probe\nsfw_m4\onnxruntime.dll'
MODEL = r'D:/Chrono Tide/data/models/anime_dbrating_mv3_v0.onnx'
DIR = r'D:\CTLIB\dev_probe\nsfw_m4'
SIZE = 384

ort = CDLL(DLL)


class _Base(Structure):
    _fields_ = [('GetApi', c_void_p), ('GetVersionString', c_void_p)]


ort.OrtGetApiBase.restype = POINTER(_Base)
_api_ptr = CFUNCTYPE(c_void_p, c_uint32)(ort.OrtGetApiBase().contents.GetApi)(15)
T = cast(_api_ptr, POINTER(c_void_p))


def F(i):
    return T[i + 3]


def errmsg(st):
    # OrtStatus { const char* msg_; OrtErrorCode code_; }（不透明结构首成员即消息串）
    if not st:
        return ''
    try:
        s = cast(st, POINTER(c_char_p))
        return (s[0] or b'').decode('utf-8', 'ignore')
    except Exception as e:
        return f'<errmsg failed: {e}>'


def ck(st, what):
    if st:
        raise RuntimeError(f'{what}: {errmsg(st)}')


CreateEnv = CFUNCTYPE(c_void_p, c_int, c_char_p, POINTER(c_void_p))(F(0))
CreateSession = CFUNCTYPE(c_void_p, c_void_p, c_wchar_p, c_void_p, POINTER(c_void_p))(F(4))
Run = CFUNCTYPE(c_void_p, c_void_p, c_void_p, POINTER(c_char_p), POINTER(c_void_p),
                c_size_t, POINTER(c_char_p), c_size_t, POINTER(c_void_p))(F(6))
CreateSessionOptions = CFUNCTYPE(c_void_p, POINTER(c_void_p))(F(7))
SetGraphOpt = CFUNCTYPE(c_void_p, c_void_p, c_int)(F(20))
SetIntraOp = CFUNCTYPE(c_void_p, c_void_p, c_int)(F(21))
SetInterOp = CFUNCTYPE(c_void_p, c_void_p, c_int)(F(22))
CreateRunOptions = CFUNCTYPE(c_void_p, POINTER(c_void_p))(F(36))
# 签名顺序：(info, data, data_len, shape, shape_len, type, out) —— type 在 out 之前
CreateTensorWithData = CFUNCTYPE(c_void_p, c_void_p, c_void_p, c_size_t,
                                 POINTER(c_int64), c_size_t, c_int,
                                 POINTER(c_void_p))(F(46))
GetTensorMutableData = CFUNCTYPE(c_void_p, c_void_p, POINTER(c_void_p))(F(48))
CreateCpuMemoryInfo = CFUNCTYPE(c_void_p, c_int, c_int, POINTER(c_void_p))(F(66))

env = c_void_p()
ck(CreateEnv(2, b'm4probe', byref(env)), 'CreateEnv')

opts = c_void_p()
ck(CreateSessionOptions(byref(opts)), 'CreateSessionOptions')
SetGraphOpt(opts, 99)
SetIntraOp(opts, 1)
SetInterOp(opts, 1)

sess = c_void_p()
ck(CreateSession(env, MODEL, opts, byref(sess)), 'CreateSession')

in_name, out_name = b'input', b'output'  # 由 ONNX protobuf 确认（pytorch 导出，非 images/output0）

mem = c_void_p()
ck(CreateCpuMemoryInfo(1, 0, byref(mem)), 'CreateCpuMemoryInfo')

ro = c_void_p()
ck(CreateRunOptions(byref(ro)), 'CreateRunOptions')

manifest = json.load(open(os.path.join(DIR, 'manifest.json'), encoding='utf-8'))
out_path = os.path.join(DIR, 'probs.jsonl')
done = 0
with open(out_path, 'w', encoding='utf-8') as sink:
    for e in manifest:
        idx = e['idx']
        p_rgba = os.path.join(DIR, f'{idx}.rgba')
        if not os.path.exists(p_rgba):
            continue
        rgb = open(p_rgba, 'rb').read()
        if len(rgb) != SIZE * SIZE * 3:
            continue
        plane = SIZE * SIZE
        buf = (c_float * (plane * 3))()
        inv = 2.0 / 255.0
        si = 0
        for i in range(plane):
            buf[i] = rgb[si] * inv - 1.0
            buf[plane + i] = rgb[si + 1] * inv - 1.0
            buf[plane * 2 + i] = rgb[si + 2] * inv - 1.0
            si += 3
        shape = (c_int64 * 4)(1, 3, SIZE, SIZE)
        val = c_void_p()
        ck(CreateTensorWithData(mem, cast(buf, c_void_p), c_size_t(plane * 3 * 4),
                                shape, 4, 1, byref(val)), 'CreateTensor')
        in_names = (c_char_p * 1)(in_name)
        in_vals = (c_void_p * 1)(val)
        out_names = (c_char_p * 1)(out_name)
        out_vals = (c_void_p * 1)()
        ck(Run(sess, ro, in_names, in_vals, 1, out_names, 1, out_vals), 'Run')
        data = c_void_p()
        ck(GetTensorMutableData(out_vals[0], byref(data)), 'GetTensorMutableData')
        probs = ctypes.cast(data, POINTER(c_float))
        p = [probs[i] for i in range(4)]
        row = dict(idx=idx, name=e['name'], cached_c=e['cached_c'],
                   cached_flagged=e['cached_flagged'], probs=p, qe=p[2] + p[3])
        sink.write(json.dumps(row, ensure_ascii=False) + '\n')
        print(f"{idx} qe={p[2]+p[3]:.4f} pe={p[3]:.4f} ps={p[1]:.4f} {e['name']}", file=sys.stderr)
        done += 1

print(f'DONE {done} -> {out_path}', file=sys.stderr)
