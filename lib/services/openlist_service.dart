import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/path_helper.dart';
import 'openlist_provision.dart';

class OpenListService {

  static bool _isRunning = false;
  static Process? _process;
  static int? _processPid;
  static String? _authToken;

  /// 空闲自动关闭定时器
  static Timer? _idleTimer;
  /// 空闲超时时间（10分钟无请求则自动关闭）
  static const Duration _idleTimeout = Duration(minutes: 10);
  /// 是否正在启动中（防止并发启动）
  static bool _isBooting = false;

  static bool get isRunning => _isRunning;
  static int? get processPid => _processPid;
  static String? get authToken => _authToken;

  /// 标记 OpenList 被使用，重置空闲计时器
  static void _markUsed() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      debugPrint('[OL-IDLE] ⏰ 空闲超时 (${_idleTimeout.inMinutes}分钟)，自动关闭 OpenList');
      stop();
    });
  }

  /// 按需启动：仅在需要时调用
  /// 如果已在运行或正在启动中，直接返回
  static Future<void> ensureRunning() async {
    if (_isRunning) {
      _markUsed();
      return;
    }
    // 🔴 半移植化（2026-10-02）：未对接（openlist.exe 不存在）时短路，
    //    避免白跑 boot 半残流程（建空目录 / 拉配置失败的日志噪音）。
    //
    // ★ 2026-10-18 补充修复：原来这里「未对接 → 直接 return」，导致 3.1.2
    //   老用户在组件缺失时点下载只能拿到 null（「取不到链接」），且**永远
    //   不会自愈** —— 自动更新同样以 exe 存在为前提。现改为先现场补齐：
    //   · 有痕迹（曾经装过 OpenList）→ 对齐一次（可能下载组件包）后继续启动；
    //   · 无痕迹（真·从未对接）→ 立刻返回，不下载任何东西（产品决策：
    //     53MB 必须由用户在「对接」里明确同意）。
    if (!await OpenListProvision.isPaired()) {
      final repaired = await OpenListProvision.ensureReadyForUse();
      if (!repaired) {
        debugPrint('[OL-BOOT] ⏭️ OpenList 不可用（未对接或补齐失败），跳过启动');
        return;
      }
      debugPrint('[OL-BOOT] ✅ 组件已现场补齐，继续启动');
    }
    if (_isBooting) {
      // 等待启动完成
      while (_isBooting) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      _markUsed();
      return;
    }

    _isBooting = true;
    try {
      await boot();
    } finally {
      _isBooting = false;
    }
    _markUsed();
  }

  static Future<void> boot() async {
    debugPrint('[OL-BOOT] ========== OpenList 配置同步 & 启动 ==========');

    await _ensureOpenListFiles();
    await _syncConfig();
    await _startProcess();
    await _waitForReady();
    await _login();

    debugPrint(
        '[OL-BOOT] ✅ OpenList 就绪 | PID: $_processPid | Token: ${_authToken != null ? "已获取(${_authToken!.length}字符)" : "未获取"}');
  }

  static Future<void> _ensureOpenListFiles() async {
    debugPrint('[OL-BOOT] 0/3 检查OpenList文件完整性');

    try {
      final olDir = Directory(PathHelper.openlistDir);
      final exeFile = File(PathHelper.openlistExePath);

      if (!await olDir.exists()) {
        await olDir.create(recursive: true);
        debugPrint('[OL-BOOT]   创建 ${PathHelper.openlistDir} 目录');
      }

      if (!await exeFile.exists()) {
        debugPrint('[OL-BOOT]   ❌ openlist.exe 不存在！请确认打包脚本已正确复制 openlist/ 目录');
        debugPrint('[OL-BOOT]   期望路径: ${PathHelper.openlistExePath}');
        return;
      } else {
        debugPrint(
            '[OL-BOOT]   ✅ openlist.exe 已存在，跳过提取 (${(await exeFile.length()).toStringAsFixed(1)}KB)');
      }

      debugPrint('[OL-BOOT]   ✅ OpenList 文件就绪 (data.zip将从服务器同步)');
    } catch (e) {
      debugPrint('[OL-BOOT]   ⚠️ OpenList文件检查异常: $e');
    }
  }

  /// 拉取并应用服务配置（`data.zip`）。
  ///
  /// ★ 2026-10-16 数据源切换：原实现从 PocketBase 的 `openlist_configs`
  /// 记录取 `data_zip` 附件，现改为官方静态服务器
  /// `http://117.72.115.30:8000/data.zip`（与组件包同源）。理由：
  /// ① PB 通道**从未真正生效** —— file 字段返回的是数组，旧代码
  ///    `String x = List` 抛 TypeError 被外层 catch 吞掉，只留一行日志；
  /// ② 少一跳依赖、少一个失效点，配置与组件同源后版本口径统一；
  /// ③ 改为指纹（ETag）比对取代「文件存在性」判定 —— 旧实现
  ///    `_needsDataExtraction` 只检查 data.db 是否存在，存在即跳过，
  ///    导致老用户**永远不会**被刷新。
  ///
  /// 下载 / 校验 / 落盘 / 失败回滚 / 运行中挂起 全部收敛在
  /// `OpenListProvision`（`ensureConfigFresh`），本方法只做编排与日志。
  static Future<void> _syncConfig() async {
    debugPrint('[OL-BOOT] 1/3 同步服务配置（官方服务器 data.zip）');
    try {
      final updated = await OpenListProvision.ensureConfigFresh();
      debugPrint(updated
          ? '[OL-BOOT] ✅ 配置已更新'
          : '[OL-BOOT] 配置已是最新（或未更新，详见上方 OL-UPD 日志）');
    } catch (e) {
      // 配置同步失败不阻断启动：本地已有 data/ 时 OpenList 照常可跑
      debugPrint('[OL-BOOT] ⚠️ 配置同步异常（不阻断启动）: $e');
    }
  }

  static Future<void> _startProcess() async {
    debugPrint('[OL-BOOT] 2/3 启动OpenList进程（端口5244）');

    try {
      final exePath = PathHelper.openlistExePath;
      final exeFile = File(exePath);

      if (!await exeFile.exists()) {
        debugPrint('[OL-BOOT] ❌ openlist.exe不存在于 ${PathHelper.openlistDir} 目录');
        return;
      }

      final args = [
        '--config',
        PathHelper.openlistConfigPath,
        '--data',
        PathHelper.openlistDataDir,
        'server'
      ];
      final cmdLine = '$exePath ${args.join(' ')}';
      debugPrint('[OL-BOOT]   启动命令: $cmdLine');

      _process = await Process.start(
        exePath,
        args,
        workingDirectory: PathHelper.openlistDir,
        mode: ProcessStartMode.detachedWithStdio,
      );

      _processPid = _process?.pid;
      _isRunning = true;
      debugPrint('[OL-BOOT] ✅ 启动成功 | PID: $_processPid | 监听: 127.0.0.1:5244');
    } catch (e) {
      debugPrint('[OL-BOOT] ❌ 启动失败: $e');
    }
  }

  static Future<void> _waitForReady() async {
    debugPrint('[OL-BOOT]   等待OpenList服务就绪（最长15秒）...');

    const checkUrl = 'http://127.0.0.1:5244/api/public/settings';
    bool ready = false;

    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 1));

      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = (uri) => 'DIRECT';

        final request = await client.getUrl(Uri.parse(checkUrl));
        final response = await request.close();
        final localPort = request.connectionInfo?.localPort ?? 0;

        debugPrint(
            '[OL-BOOT]   轮询检测[$i]: $checkUrl | 绑定端口: $localPort | 响应码: ${response.statusCode}');

        if (response.statusCode == 200) {
          ready = true;
          debugPrint(
              '[OL-BOOT] ✅ OpenList服务就绪 (HTTP 200, 端口5244, 耗时${i + 1}s)');
          client.close();
          break;
        }
        client.close();
      } catch (e) {
        debugPrint('[OL-BOOT]   轮询检测[$i]: 连接中... ($e)');
      }
    }

    if (!ready) {
      debugPrint('[OL-BOOT] ⚠️ 15秒内未就绪，OpenList可能启动失败或端口被占用');
    }
  }

  static Future<void> _login() async {
    debugPrint('[OL-AUTH] ═════════ 开始多策略登录尝试 ═════════');

    final loginUrl = 'http://127.0.0.1:5244/api/auth/login';

    List<Map<String, String>> credentialsList = [
      _readCredentialsFromConfig(),
      {'username': 'admin', 'password': 'admin'},
      {'username': 'admin', 'password': ''},
      {'username': '', 'password': ''},
    ];

    credentialsList = credentialsList.where((c) => c.isNotEmpty).toList();

    debugPrint('[OL-AUTH] 准备尝试 ${credentialsList.length} 组凭据');

    for (int i = 0; i < credentialsList.length; i++) {
      final credentials = credentialsList[i];
      final username = credentials['username'] ?? '(空)';
      final password = credentials['password'] ?? '';

      debugPrint(
          '[OL-AUTH] ── 尝试 ${i + 1}/${credentialsList.length}: 用户="$username" 密码="${password.isNotEmpty ? '*' * password.length : '(空)'}"');

      try {
        bool success = await _attemptLogin(loginUrl, credentials);

        if (success) {
          debugPrint('[OL-AUTH] ✅ 登录成功 (第${i + 1}次尝试)');
          return;
        } else {
          debugPrint('[OL-AUTH] ❌ 第${i + 1}次尝试失败');
        }
      } catch (e) {
        debugPrint('[OL-AUTH] ⚠️ 第${i + 1}次尝试异常: $e');
      }

      if (i < credentialsList.length - 1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    debugPrint('[OL-AUTH] ❌ 所有登录尝试均失败');
    debugPrint('[OL-AUTH]   Token状态: 未获取');
    debugPrint('[OL-AUTH]   可能原因:');
    debugPrint('     1. config.json中没有有效的用户配置');
    debugPrint('     2. data.db数据库损坏或不包含用户数据');
    debugPrint('     3. OpenList需要首次初始化设置');
    debugPrint('[OL-AUTH]   将尝试无Token访问（可能会被拒绝）');
    debugPrint('[OL-AUTH] ═════════ 登录尝试结束 ═════════');
  }

  static Future<bool> _attemptLogin(
      String loginUrl, Map<String, String> credentials) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = (uri) => 'DIRECT';

    try {
      final request = await client.postUrl(Uri.parse(loginUrl))
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(credentials));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      debugPrint(
          '[OL-AUTH]     HTTP ${response.statusCode} | Body: ${responseBody.length > 100 ? responseBody.substring(0, 100) + "..." : responseBody}');

      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody);
        final data = json['data'];
        if (data is Map<String, dynamic>) {
          _authToken = data['token']?.toString();
        }

        if (_authToken != null && _authToken!.isNotEmpty) {
          debugPrint('[OL-AUTH]     ✅ 获取Token成功 | 长度: ${_authToken!.length}');
          client.close();
          return true;
        } else {
          debugPrint('[OL-AUTH]     ⚠️ 响应200但无Token');
          client.close();
          return false;
        }
      } else {
        client.close();
        return false;
      }
    } catch (e) {
      client.close();
      rethrow;
    }
  }

  static Map<String, String> _readCredentialsFromConfig() {
    final configFile = File(PathHelper.openlistConfigPath);
    if (configFile.existsSync()) {
      try {
        final content = configFile.readAsStringSync();
        final config = jsonDecode(content) as Map<String, dynamic>;

        debugPrint('[OL-AUTH]   读取config.json:');
        debugPrint('     文件大小: ${content.length}字符');

        final users = config['users'];
        if (users is List && users.isNotEmpty) {
          debugPrint('     users字段: ✅ 存在 (${users.length}个用户)');

          final firstUser = users.first;
          if (firstUser is Map<String, dynamic>) {
            final username = firstUser['username']?.toString() ?? '';
            final password = firstUser['password']?.toString() ?? '';

            if (username.isNotEmpty) {
              debugPrint('     首用户: $username');
              return {'username': username, 'password': password};
            }
          }
        } else {
          debugPrint('     users字段: ❌ 不存在 或为空');
          debugPrint('     可用键: ${config.keys.toList()}');
        }
      } catch (e) {
        debugPrint('[OL-AUTH]   读取config.json失败: $e');
      }
    } else {
      debugPrint(
          '[OL-AUTH]   config.json不存在: ${PathHelper.openlistConfigPath}');
    }

    return {};
  }

  static Map<String, String> _readCredentials() {
    return _readCredentialsFromConfig().isNotEmpty
        ? _readCredentialsFromConfig()
        : {'username': 'admin', 'password': 'admin'};
  }

  static Future<String?> getGameDownloadUrl(String gamePath, {int retryCount = 0}) async {
    debugPrint('[OL-LINK] 收到游戏路径: $gamePath');

    // ★ 按需启动：如果 OpenList 未运行，自动启动
    if (!_isRunning) {
      debugPrint('[OL-LINK] OpenList未运行，按需启动...');
      await ensureRunning();
      if (!_isRunning) {
        debugPrint('[OL-LINK] ❌ 按需启动失败');
        return null;
      }
    }

    const requestUrl = 'http://127.0.0.1:5244/api/fs/get';
    debugPrint('[OL-LINK] 请求 OpenList 接口: $requestUrl');

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..findProxy = (uri) => 'DIRECT';

      if (_authToken != null && _authToken!.isNotEmpty) {
        debugPrint('[OL-LINK] 携带Authorization Token请求');
      } else {
        debugPrint('[OL-LINK] ⚠️ 无Token，尝试无认证请求');
      }

      final request = await client.postUrl(Uri.parse(requestUrl))
        ..headers.contentType = ContentType.json;

      if (_authToken != null && _authToken!.isNotEmpty) {
        request.headers.set('Authorization', _authToken!);
      }

      request.write(jsonEncode({'path': gamePath}));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      debugPrint(
          '[OL-LINK] HTTP ${response.statusCode} | 响应体: ${responseBody.length > 500 ? responseBody.substring(0, 500) + '...(截断)' : responseBody}');

      client.close();

      if (response.statusCode != 200) {
        if (response.statusCode == 401 && _authToken != null) {
          debugPrint('[OL-LINK] ❌ 401 Token失效，尝试重新登录...');
          _authToken = null;
          await _login();
          if (_authToken != null && retryCount < 2) {
            return getGameDownloadUrl(gamePath, retryCount: retryCount + 1);
          }
        }
        debugPrint('[OL-LINK] ❌ HTTP错误 (${response.statusCode})');
        return null;
      }

      final json = jsonDecode(responseBody);
      final innerData = json['data'];
      String rawUrl = '';

      if (innerData is Map<String, dynamic>) {
        rawUrl = innerData['raw_url'] ?? '';
      } else if (json['raw_url'] != null) {
        rawUrl = json['raw_url'].toString();
      }

      if (rawUrl.isNotEmpty) {
        debugPrint('[OL-LINK] ✅ 解析 raw_url 成功 (${rawUrl.length}字符)');
        _markUsed(); // 成功使用，重置空闲计时器
        return rawUrl;
      } else {
        debugPrint('[OL-LINK] 解析 raw_url 失败：字段不存在 / 为空');
        return null;
      }
    } catch (e) {
      debugPrint('[OL-LINK] ❌ 请求异常: $e');
      return null;
    }
  }

  static void stop() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_process != null) {
      _process!.kill();
      _process = null;
    }
    if (_processPid != null) {
      debugPrint('[OL-BOOT] 终止OpenList进程 PID=$_processPid');
      try {
        Process.runSync('taskkill', ['/PID', '$_processPid', '/F', '/T']);
      } catch (_) {}
      _processPid = null;
    }
    _isRunning = false;
    debugPrint('[OL-BOOT] OpenList进程已停止');
    // ★ 2026-10-16 自动更新：服务刚停 → 若此前因「运行中」挂起的配置更新
    //   现在可以安全落盘了（fire-and-forget，本地无 pending 时是一次
    //   极廉价的文件读取，不走网络）。
    unawaited(OpenListProvision.applyPendingConfig());
  }

  static Future<void> dispose() async {
    debugPrint('[OL-BOOT] ═══════════ 开始强制清理OpenList进程 ═══════════');

    _idleTimer?.cancel();
    _idleTimer = null;

    // 1. 通过 Process 引用直接 kill
    if (_process != null) {
      try {
        _process!.kill(ProcessSignal.sigkill);
      } catch (_) {}
      _process = null;
    }

    // 2. 通过 PID 强制终止（同步，不等待）
    if (_processPid != null) {
      debugPrint('[OL-BOOT] 终止OpenList进程 PID=$_processPid');
      try {
        Process.runSync('taskkill', ['/PID', '$_processPid', '/F', '/T']);
      } catch (_) {}
      _processPid = null;
    }

    // 3. 兜底：按名称强制杀死所有 openlist.exe（同步，不等待）
    try {
      Process.runSync('taskkill', ['/IM', 'openlist.exe', '/F', '/T']);
    } catch (_) {}

    _isRunning = false;
    _process = null;
    _processPid = null;
    _authToken = null;
    debugPrint('[OL-BOOT] ═══════════ OpenList清理完成 ═══════════');
  }
}
