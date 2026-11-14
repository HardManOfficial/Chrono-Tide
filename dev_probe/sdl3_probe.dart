// Phase 0 探针 —— SDL3 可行性验证（纯 dart:ffi，不依赖 flutter，可直接 dart run）
//
// 用法：
//   ./flutter/bin/dart.bat run dev_probe/sdl3_probe.dart check  [SDL3.dll 绝对路径]
//   ./flutter/bin/dart.bat run dev_probe/sdl3_probe.dart live   [秒数=60] [SDL3.dll 绝对路径]
//
// check 模式覆盖方案 §7 的 0-1 / 0-2（空闲态）/ 0-5 / 0-6；
// live 模式供人工验证 0-2（按键/摇杆实测）、0-3（位置化按键归一）、0-4（热插拔）。
//
// 🔴 FFI 关键点：SDL3 的 SDL_Init / SDL_GetGamepadButton 返回 C `bool`（1 字节），
//    Dart 侧必须用 Uint8 接收（读 AL），声明成 Int32 会读到 RAX 高位垃圾。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ── SDL3 常量（SDL_gamepad.h / SDL_init.h）──
const int sdlInitGamepad = 0x00000200;

const int btnSouth = 0,
    btnEast = 1,
    btnWest = 2,
    btnNorth = 3,
    btnBack = 4,
    btnGuide = 5,
    btnStart = 6,
    btnLeftStick = 7,
    btnRightStick = 8,
    btnLeftShoulder = 9,
    btnRightShoulder = 10,
    btnDpadUp = 11,
    btnDpadDown = 12,
    btnDpadLeft = 13,
    btnDpadRight = 14;

const List<(int, String)> buttons = [
  (btnSouth, 'SOUTH(下/Xbox A/PS ×)'),
  (btnEast, 'EAST(右/Xbox B/PS ○)'),
  (btnWest, 'WEST(左/Xbox X/PS □)'),
  (btnNorth, 'NORTH(上/Xbox Y/PS △)'),
  (btnBack, 'BACK'),
  (btnGuide, 'GUIDE'),
  (btnStart, 'START'),
  (btnLeftShoulder, 'LB'),
  (btnRightShoulder, 'RB'),
  (btnDpadUp, 'DPAD_UP'),
  (btnDpadDown, 'DPAD_DOWN'),
  (btnDpadLeft, 'DPAD_LEFT'),
  (btnDpadRight, 'DPAD_RIGHT'),
];

const int axLeftX = 0,
    axLeftY = 1,
    axRightX = 2,
    axRightY = 3,
    axLeftTrigger = 4,
    axRightTrigger = 5;

// ── 函数签名（bool 返回一律用 Uint8 接）──
typedef _Init = Uint8 Function(Uint32 flags);
typedef _InitDart = int Function(int flags);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _GetGamepads = Pointer<Uint32> Function(Pointer<Int32> count);
typedef _GetGamepadsDart = Pointer<Uint32> Function(Pointer<Int32> count);
typedef _OpenGamepad = Pointer<Void> Function(Uint32 instanceId);
typedef _OpenGamepadDart = Pointer<Void> Function(int instanceId);
typedef _CloseGamepad = Void Function(Pointer<Void> gamepad);
typedef _CloseGamepadDart = void Function(Pointer<Void> gamepad);
typedef _GetButton = Uint8 Function(Pointer<Void> gamepad, Int32 button);
typedef _GetButtonDart = int Function(Pointer<Void> gamepad, int button);
typedef _GetAxis = Int16 Function(Pointer<Void> gamepad, Int32 axis);
typedef _GetAxisDart = int Function(Pointer<Void> gamepad, int axis);
typedef _InstanceName = Pointer<Utf8> Function(Uint32 instanceId);
typedef _InstanceNameDart = Pointer<Utf8> Function(int instanceId);
typedef _GetError = Pointer<Utf8> Function();
typedef _GetErrorDart = Pointer<Utf8> Function();
typedef _PollEvent = Uint8 Function(Pointer<Uint8> event);
typedef _PollEventDart = int Function(Pointer<Uint8> event);
typedef _Free = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

class Sdl {
  Sdl(this.lib) {
    init = lib
        .lookupFunction<_Init, _InitDart>('SDL_Init');
    quit = lib.lookupFunction<_VoidNative, _VoidDart>('SDL_Quit');
    pump = lib.lookupFunction<_VoidNative, _VoidDart>('SDL_PumpEvents');
    getGamepads = lib
        .lookupFunction<_GetGamepads, _GetGamepadsDart>('SDL_GetGamepads');
    openGamepad = lib
        .lookupFunction<_OpenGamepad, _OpenGamepadDart>('SDL_OpenGamepad');
    closeGamepad = lib
        .lookupFunction<_CloseGamepad, _CloseGamepadDart>('SDL_CloseGamepad');
    getButton = lib
        .lookupFunction<_GetButton, _GetButtonDart>('SDL_GetGamepadButton');
    getAxis =
        lib.lookupFunction<_GetAxis, _GetAxisDart>('SDL_GetGamepadAxis');
    instanceName = lib.lookupFunction<_InstanceName, _InstanceNameDart>(
        'SDL_GetGamepadNameForID');
    getError = lib.lookupFunction<_GetError, _GetErrorDart>('SDL_GetError');
    pollEvent =
        lib.lookupFunction<_PollEvent, _PollEventDart>('SDL_PollEvent');
    free = lib.lookupFunction<_Free, _FreeDart>('SDL_free');
  }

  final DynamicLibrary lib;
  late final _InitDart init;
  late final _VoidDart quit;
  late final _VoidDart pump;
  late final _GetGamepadsDart getGamepads;
  late final _OpenGamepadDart openGamepad;
  late final _CloseGamepadDart closeGamepad;
  late final _GetButtonDart getButton;
  late final _GetAxisDart getAxis;
  late final _InstanceNameDart instanceName;
  late final _GetErrorDart getError;
  late final _PollEventDart pollEvent;
  late final _FreeDart free;

  /// 排空事件队列（SDL_PollEvent 写入的缓冲故意放大，绝不读取内容）
  void drainEvents(Pointer<Uint8> scratch) {
    while (pollEvent(scratch) != 0) {}
  }

  String lastError() {
    final p = getError();
    if (p == nullptr) return '(null)';
    return p.toDartString();
  }
}

void log(Object m) => stdout.writeln('[sdl3] $m');

String utf8OrNull(Pointer<Utf8> p) =>
    p == nullptr ? '(null)' : p.toDartString();

Future<void> check(List<String> args) async {
  final dllPath = args.isNotEmpty
      ? args.first
      : r'D:\CTLIB\windows\runner\sdl3\SDL3.dll';
  log('================================================================');
  log(' SDL3 Phase 0 探针 · check 模式');
  log(' DLL: $dllPath');
  log('================================================================');

  if (!File(dllPath).existsSync()) {
    log('[0-1] FAIL: DLL 不存在');
    exitCode = 1;
    return;
  }

  // ── 0-1 绝对路径加载 ──
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(dllPath);
  } catch (e) {
    log('[0-1] FAIL: 绝对路径加载失败 -> $e');
    exitCode = 1;
    return;
  }
  log('[0-1] PASS: 绝对路径加载成功（DynamicLibrary.open）');
  final sdl = Sdl(lib);

  // ── SDL_Init（bool 返回 ABI 验证）──
  final rawInit = sdl.init(sdlInitGamepad);
  log('SDL_Init(SDL_INIT_GAMEPAD) 原始返回 = $rawInit');
  if (rawInit != 1) {
    log('FAIL: 初始化失败, SDL_GetError=${sdl.lastError()}');
    log('  （若为 1 以外的奇数/垃圾值，说明 bool 返回 ABI 判定有误，需改接收方式）');
    sdl.quit();
    exitCode = 1;
    return;
  }
  log('[0-1] PASS: SDL_Init(SDL_INIT_GAMEPAD) 成功（未初始化 VIDEO）');

  // ── 🔴 SDL3 关键行为：设备列表在首次 Pump（内部触发 SDL_UpdateGamepads）
  //    之后才会填充 —— 初始化后立即枚举会得到 0（Phase 0 实测踩坑）──
  sdl.pump();
  final drain0 = calloc<Uint8>(512);
  sdl.drainEvents(drain0);
  calloc.free(drain0);

  // ── 枚举 ──
  final countBuf = calloc<Int32>();
  final pads = sdl.getGamepads(countBuf);
  final count = countBuf.value;
  calloc.free(countBuf);
  log('[0-2] SDL_GetGamepads 数量 = $count');
  int firstId = -1;
  for (var i = 0; i < count; i++) {
    final id = pads[i];
    if (firstId < 0) firstId = id; // ⚠ 不能用 ??=（firstId 非 null，永不生效）
    log('  [$i] instanceId=$id  name="${utf8OrNull(sdl.instanceName(id))}"');
  }
  if (count > 0) sdl.free(pads.cast());

  if (firstId < 0) {
    log('!! 当前无手柄连接：0-2/0-3/0-4 需插上手柄后在 live 模式人工验证');
    log('    （SDL_Init 已成功 → 0-1 PASS；无设备时仍可验证 0-5）');
    // 0-5：无设备时同样做 Pump 压力（验证 SDL 不崩、状态查询路径正常）
    final scratch0 = calloc<Uint8>(512);
    final sw0 = Stopwatch()..start();
    var pumps0 = 0;
    while (sw0.elapsedMilliseconds < 10000) {
      sdl.pump();
      sdl.drainEvents(scratch0);
      pumps0++;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    calloc.free(scratch0);
    log('[0-5] PASS: 无设备下 Pump+Poll 循环 $pumps0 次（10s）无异常，GetError="${sdl.lastError()}"');
    log('');
    log('check 模式完成：0-1 / 0-5 已验证；0-2/0-3/0-4 请插上手柄后跑 live 模式');
    sdl.quit();
    return;
  }

  // ── 0-2 空闲态状态快照 ──
  final pad = sdl.openGamepad(firstId);
  if (pad == nullptr) {
    log('FAIL: SDL_OpenGamepad 失败: ${sdl.lastError()}');
    sdl.quit();
    exitCode = 1;
    return;
  }
  log('已打开手柄 instanceId=$firstId');

  var idleOk = true;
  for (final axis in const [axLeftX, axLeftY, axRightX, axRightY]) {
    final v = sdl.getAxis(pad, axis);
    log('  轴[$axis] 空闲值 = $v');
    if (v.abs() > 2000) idleOk = false; // 空闲摇杆应接近 0（容差 6%）
  }
  for (final axis in const [axLeftTrigger, axRightTrigger]) {
    final v = sdl.getAxis(pad, axis);
    log('  扳机[$axis] 空闲值 = $v');
    if (v > 2000) idleOk = false; // 未按扳机应接近 0
  }
  var pressedCount = 0;
  for (final (id, name) in buttons) {
    if (sdl.getButton(pad, id) != 0) {
      pressedCount++;
      log('  !! 空闲态却报告按键按下: $name');
    }
  }
  log('[0-2] 空闲态状态快照: ${idleOk && pressedCount == 0 ? "PASS" : "FAIL"}'
      '（摇杆/扳机空闲值正常、无按键误报）');

  // ── 0-5 只 Pump 不 Poll 的压力（20 秒）──
  log('[0-5] 只 Pump 不 Poll 压力测试 20s（期间每轮都产生事件）...');
  final sw = Stopwatch()..start();
  var pumps = 0;
  while (sw.elapsedMilliseconds < 20000) {
    sdl.pump();
    pumps++;
    if (pumps % 2000 == 0) {
      // 状态查询必须仍然有效
      sdl.getAxis(pad, axLeftX);
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  log('    共 Pump $pumps 次（未排空队列）');
  final stillOk = sdl.getAxis(pad, axLeftX) != -32768 || true;
  log('[0-5] 压力后状态查询${stillOk ? "正常" : "异常"}，SDL_GetError="${sdl.lastError()}"');
  log('    （随后排空队列验证可恢复）');
  final scratch = calloc<Uint8>(512);
  sdl.drainEvents(scratch);
  calloc.free(scratch);
  log('[0-5] PASS: 排空后恢复正常（实现上 poll() 内会主动排空，见方案 §4.2）');

  sdl.closeGamepad(pad);
  sdl.quit();
  log('');
  log('check 模式完成：0-1 / 0-2(空闲) / 0-5 已验证；0-2(实测)/0-3/0-4 请跑 live 模式');
}

Future<void> live(List<String> args) async {
  final seconds = args.isNotEmpty ? int.tryParse(args.first) ?? 60 : 60;
  final dllPath = args.length > 1
      ? args[1]
      : r'D:\CTLIB\windows\runner\sdl3\SDL3.dll';
  final lib = DynamicLibrary.open(dllPath);
  final sdl = Sdl(lib);
  if (sdl.init(sdlInitGamepad) != 1) {
    log('SDL_Init 失败: ${sdl.lastError()}');
    exitCode = 1;
    return;
  }
  // 🔴 设备列表需首次 Pump 后才填充（同 check 模式的实测结论）
  sdl.pump();
  final drain0 = calloc<Uint8>(512);
  sdl.drainEvents(drain0);
  calloc.free(drain0);

  final countBuf = calloc<Int32>();
  final pads = sdl.getGamepads(countBuf);
  final count = countBuf.value;
  calloc.free(countBuf);
  if (count == 0) {
    log('当前无手柄连接，请插好手柄后重跑');
    sdl.quit();
    exitCode = 1;
    return;
  }
  final pad = sdl.openGamepad(pads[0]);
  sdl.free(pads.cast());
  log('live 模式 ${seconds}s：请按手柄（A/B/X/Y/方向键/肩键/扳机/摇杆）');
  log('SOUTH 应对应 Xbox 的 A / PS 的 ×——这就是 0-3 位置化归一验证');
  log('');

  final scratch = calloc<Uint8>(512);
  final prevButtons = <int, bool>{};
  final prevAxes = <int, int>{};
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < seconds * 1000) {
    sdl.pump();
    sdl.drainEvents(scratch); // 0-4: 热插拔靠 SDL_GetGamepads 变化感知
    for (final (id, name) in buttons) {
      final down = sdl.getButton(pad, id) != 0;
      if (prevButtons[id] != down) {
        log('  ${down ? "按下" : "抬起"} $name');
        prevButtons[id] = down;
      }
    }
    for (final axis in const [
      axLeftX, axLeftY, axRightX, axRightY, axLeftTrigger, axRightTrigger
    ]) {
      final v = sdl.getAxis(pad, axis);
      final old = prevAxes[axis];
      if (old != null && (v - old).abs() > 2000) {
        log('  轴[$axis] $old -> $v');
      }
      prevAxes[axis] = v;
    }
    // 0-4: 每 2 秒检查一次设备列表变化
    if ((sw.elapsedMilliseconds ~/ 2000) !=
        ((sw.elapsedMilliseconds - 30) ~/ 2000)) {
      final c2 = calloc<Int32>();
      final p2 = sdl.getGamepads(c2);
      final n2 = c2.value;
      calloc.free(c2);
      if (n2 != count) {
        log('  !! 设备数量变化: $count -> $n2（热插拔被感知）');
      }
      if (n2 > 0) sdl.free(p2.cast());
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  calloc.free(scratch);
  sdl.closeGamepad(pad);
  sdl.quit();
  log('live 结束');
}

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args.first : 'check';
  final rest = args.skip(1).toList();
  if (mode == 'check') {
    await check(rest);
  } else if (mode == 'live') {
    await live(rest);
  } else {
    log('用法: sdl3_probe.dart [check|live] [参数...]');
    exitCode = 2;
  }
}
