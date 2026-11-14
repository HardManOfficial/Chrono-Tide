/// PATCH-VAULT 渲染探针（flutter_tester，零真实游戏目录）。
///
/// 🔴 2026-11-11 灰屏事故铁律：改动落在哪个页面的 build，就必须把**那个页面
/// 整屏渲染一次**；只探子页面会假绿。所以本探针渲染 `LibraryPage` 本体 +
/// 5 项右键菜单 + 补丁主面板 + 预览页 + 转移框 + 记录卡片。
/// 🔴 必须加「必然存在的文案」断言：整树塌成 ErrorWidget 时文本数=0 也会假绿。
/// 🔴 异常判据用自设 `FlutterError.onError`（不转发给 binding），
/// `takeException()` 只回 "Multiple exceptions" 且会漏掉被压扁。
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dart <gen_kernel_aot>.snapshot --platform <flutter_patched_sdk>/platform_strong.dill \
///     --target flutter --packages .dart_tool/package_config.json \
///     --output patch_vault_ui.dill dev_probe/patch_vault_ui_probe.dart
///   flutter_tester.exe --disable-vm-service --enable-checked-mode patch_vault_ui.dill

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/patch_vault_record.dart';
import 'package:chrono_tide/pages/library_page.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/library_context_menu.dart';
import 'package:chrono_tide/widgets/patch_vault/patch_apply_preview.dart';
import 'package:chrono_tide/widgets/patch_vault/patch_record_card.dart';
import 'package:chrono_tide/widgets/patch_vault/patch_transfer_dialog.dart';
import 'package:chrono_tide/widgets/patch_vault/patch_vault_dialog.dart';
import 'package:chrono_tide/services/patch_vault/game_dirs.dart';
import 'package:chrono_tide/services/patch_vault/patch_vault_index.dart';

int _pass = 0;
int _fail = 0;

void L(String m) => stdout.writeln(m);

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  L('  ${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : ' | $detail'}');
}

Size? _probeSize;

Widget _app(Widget child) => MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      builder: (context, inner) {
        final base = MediaQuery.of(context);
        final s = _probeSize;
        return MediaQuery(
          data: s == null ? base : base.copyWith(size: s),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(backgroundColor: const Color(0xFF1E1E1E), body: child),
    );

/// 复现主壳：Column[32px 标题栏, Expanded(Row[侧栏, 内容])]
Widget _shell(Widget content) => Column(
      children: [
        const SizedBox(height: 32, child: ColoredBox(color: Color(0xFF333333))),
        Expanded(
          child: Row(
            children: [
              const SizedBox(width: 72, child: ColoredBox(color: Color(0xFF2A2A2A))),
              Expanded(child: content),
            ],
          ),
        ),
      ],
    );

void _collectText(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  if (w is RichText && w.text is TextSpan) {
    out.add((w.text as TextSpan).toPlainText());
  }
  e.visitChildren((c) => _collectText(c, out));
}

void _collectBoxes(Element e, List<RenderBox> out) {
  final r = e.renderObject;
  if (r is RenderBox) out.add(r);
  e.visitChildren((c) => _collectBoxes(c, out));
}

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  ThemeRegistry.registerBuiltinThemes();

  final details = <FlutterErrorDetails>[];
  final prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (d) {
    details.add(d);
    return prevBuilder(d);
  };

  final prevOnError = FlutterError.onError;
  await binding.runTest(() async {
    FlutterError.onError = (d) => details.add(d);
    void clearErr() => details.clear();
    String? firstErr() {
      if (details.isEmpty) return null;
      final e = details.first.exception.toString();
      L('      | ${e.length > 240 ? e.substring(0, 240) : e}');
      final st = details.first.stack?.toString().split('\n') ?? <String>[];
      for (final l in st.where((l) => l.contains('chrono_tide')).take(6)) {
        L('      @ ${l.trim()}');
      }
      return e.length > 80 ? e.substring(0, 80) : e;
    }

    Future<void> mount(Widget child, Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(child)));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
    }

    List<String> texts() {
      final out = <String>[];
      final root = binding.renderViewElement;
      if (root != null) _collectText(root, out);
      return out;
    }

    List<RenderBox> boxes() {
      final out = <RenderBox>[];
      final root = binding.renderViewElement;
      if (root != null) _collectBoxes(root, out);
      return out;
    }

    bool hasText(String needle) =>
        texts().any((t) => t.contains(needle));

    // ═══════════ B. 右键菜单（5 项 + 底部上翻）═══════════
    L('=== B. LibraryContextMenu：5 项 / 上翻边界 ===');
    for (final size in <Size>[
      const Size(1280, 720),
      const Size(1600, 900),
    ]) {
      clearErr();
      await mount(
        _shell(Stack(children: <Widget>[
          LibraryContextMenu(
            position: Offset(600, size.height - 30),
            onDetails: () {},
            onLaunchManager: () {},
            onPatchVault: () {},
            onCollection: () {},
            onDelete: () {},
            onClose: () {},
          ),
        ])),
        size,
      );
      final t = texts();
      check('W=${size.width} 菜单 5 项齐全',
          t.any((e) => e.contains('补丁管理')) &&
              t.any((e) => e.contains('启动管理')) &&
              t.any((e) => e.contains('加入收藏夹')) &&
              t.any((e) => e.contains('删')) &&
              t.any((e) => e.contains('详')),
          '文本数=${t.length}');
      check('W=${size.width} 菜单渲染无异常', details.isEmpty,
          firstErr() ?? '');
      // 上翻后菜单必须整块在屏内
      // 菜单外框：宽 160、高约 5×48=240（区分于同为 160 宽的单个菜单项）
      final menuBoxes = boxes()
          .where((b) =>
              b.size.width >= 159 &&
              b.size.width <= 161 &&
              b.size.height >= 210 &&
              b.size.height <= 260)
          .toList();
      for (final b in menuBoxes.take(3)) {
        final o = b.localToGlobal(Offset.zero);
        L('      box ${b.size.width.toStringAsFixed(0)}x'
            '${b.size.height.toStringAsFixed(0)} @ '
            '${o.dx.toStringAsFixed(0)},${o.dy.toStringAsFixed(0)}');
      }
      var inside = false;
      for (final b in menuBoxes) {
        final topLeft = b.localToGlobal(Offset.zero);
        if (topLeft.dx >= 0 &&
            topLeft.dy >= 0 &&
            topLeft.dx + b.size.width <= size.width &&
            topLeft.dy + b.size.height <= size.height) {
          inside = true;
        }
      }
      check('W=${size.width} 菜单完整落在屏内', inside,
          '候选=${menuBoxes.length}');
    }

    // ═══════════ C. 主面板 ═══════════
    L('=== C. PatchVaultDialog 主面板 ===');
    for (final size in <Size>[
      const Size(1280, 720),
      const Size(1600, 900),
    ]) {
      clearErr();
      await mount(
        _shell(PatchVaultDialog(
          game: _fakeGame(),
          debugSkipLoad: true,
        )),
        size,
      );
      final t = texts();
      check('W=${size.width} 主面板：必然存在文案「补丁管理」',
          t.any((e) => e.contains('补丁管理')));
      check('W=${size.width} 主面板：固定提示条存在',
          hasText('打补丁前'));
      check('W=${size.width} 主面板：导入与恢复入口存在',
          hasText('导入补丁文件') && hasText('一键恢复原版'));
      check('W=${size.width} 主面板：空态文案存在', hasText('还没有登记补丁'));
      check('W=${size.width} 主面板渲染无异常', details.isEmpty,
          firstErr() ?? '');
      final big = boxes()
          .where((b) => b.size.width >= 900 && b.size.height >= 640)
          .toList();
      check('W=${size.width} 面板未被压扁（存在 >=900x640 容器）',
          big.isNotEmpty, '候选=${big.length}');
    }

    // ═══════════ D. 预览页（debugSkipLoad）═══════════
    L('=== D. PatchApplyPreview ===');
    clearErr();
    await mount(
      _shell(PatchApplyPreview(
        record: _fakeRecord(),
        dirs: _fakeDirs(),
        gameId: 'game-001',
        gameTitle: '测试游戏',
        indexRoot: r'D:\tmp',
        gameExeNames: const <String>['game.exe'],
        gameTopDirs: const <String>['gamedata'],
        debugSkipLoad: true,
      )),
      const Size(1280, 720),
    );
    check('预览页：二次确认文案存在', hasText('二次确认'));
    check('预览页：说明提示存在', hasText('打补丁前'));
    check('预览页渲染无异常', details.isEmpty, firstErr() ?? '');

    // ═══════════ E. 转移框 ═══════════
    L('=== E. PatchTransferDialog ===');
    clearErr();
    await mount(
      _shell(PatchTransferDialog(
        sourcePath: r'D:\patches\汉化补丁.zip',
        defaultTargetDir: r'D:\game\补丁',
      )),
      const Size(1280, 720),
    );
    check('转移框：默认目标已预填', hasText(r'D:\game\补丁') ||
        texts().any((t) => t.contains('启动程序目录')));
    check('转移框：移动语义文案存在', hasText('移动原文件'));
    check('转移框渲染无异常', details.isEmpty, firstErr() ?? '');

    // ═══════════ F. 记录卡片 ═══════════
    L('=== F. PatchRecordCard ===');
    clearErr();
    await mount(
      _shell(SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PatchRecordCard(
            record: _fakeRecord(),
            check: const PatchRecordCheck(
                exists: true, changed: false, message: ''),
            appliedTxCount: 1,
            busy: false,
            onApply: () {},
            onUndo: () {},
            onTransfer: () {},
            onRemove: () {},
            onOpenContaining: () {},
          ),
        ),
      )),
      const Size(1280, 720),
    );
    check('卡片：状态/操作齐全',
        hasText('已应用') && hasText('应用补丁') && hasText('转移'));
    check('卡片渲染无异常', details.isEmpty, firstErr() ?? '');

    // ═══════════ A. LibraryPage 本体（放最后：若它触发磁盘 IO 挂起，
    //              前面的结论已经打印，不会白跑一轮）═══════════
    L('=== A. LibraryPage 整屏渲染 ===');
    clearErr();
    await mount(
      _shell(LibraryPage(onGoDiscover: () {})),
      const Size(1280, 720),
    );
    final libTexts = texts();
    check('LibraryPage 整树存在文本（防整屏灰块）', libTexts.isNotEmpty,
        '文本数=${libTexts.length}');
    check('LibraryPage 渲染无新增异常', details.isEmpty, firstErr() ?? '');
    L('      LibraryPage 文本数=${libTexts.length}');

    // 库页 initState 挂了一个 12s 的云同步 Timer；fake-async 结束时会把
    // 未触发的 timer 判为失败 ⇒ 显式推进时间把它消化掉。
    await binding.pump(const Duration(seconds: 13));

    FlutterError.onError = prevOnError;
  }, () {});

  ErrorWidget.builder = prevBuilder;
  L('========================================');
  L('PATCH-VAULT UI PROBE: $_pass PASS / $_fail FAIL');
  L('========================================');
  if (_fail > 0) exitCode = 1;
}

LibraryGame _fakeGame() => LibraryGame(
      gameId: 'game-001',
      title: '测试游戏',
      directoryPath: r'D:\game',
      metaDataDir: r'D:\meta',
      installedAt: '',
    );

GameDirs _fakeDirs() => GameDirs.compute(
      bodyRoot: r'D:\game',
      launchPath: 'game.exe',
      resolvedExePath: r'D:\game\game.exe',
    );

PatchRecord _fakeRecord() => PatchRecord(
      id: 'rec-1',
      gameId: 'game-001',
      sourcePath: r'D:\patches\汉化补丁.zip',
      fileName: '汉化补丁.zip',
      sizeBytes: 1024 * 1024,
      mtimeMs: 0,
      sha256: 'abc',
      container: PatchContainer.zip,
      kind: PatchKind.overlay,
      hasReadme: true,
      hasExe: false,
      status: PatchVaultStatus.applied,
      addedAt: '',
    );
