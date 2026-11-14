// WebDAV Provider 探针：本地 HttpServer 模拟 WebDAV 服务器，全链路实测
// （MKCOL/PUT/GET/PROPFIND/DELETE + Basic Auth + 进度回调 + 404 幂等）。
// 运行：flutter/bin/cache/dart-sdk/bin/dart.exe dev_probe/phase5_webdav_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/services/cloud_backup/cloud_storage_provider.dart';
import '../lib/services/cloud_backup/webdav_provider.dart';

Future<void> main() async {
  var pass = 0, fail = 0;
  void check(String name, bool cond) {
    if (cond) {
      pass++;
      print('PASS  $name');
    } else {
      fail++;
      print('FAIL  $name');
    }
  }

  // ============ 迷你 WebDAV 服务器（落到临时目录） ============
  final store = await Directory.systemTemp.createTemp('ct_dav_store_');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  const user = 'tester';
  const passW = 'secret123';
  final authOk =
      'Basic ${base64Encode(utf8.encode('$user:$passW'))}';

  // 记录收到的 PROPFIND Depth 头（验证请求构造正确性）
  var lastDepth = '';

  HttpServer _bindLater(HttpServer s) => s; // 便于阅读
  _bindLater(server);

  server.listen((req) async {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != authOk) {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    if (req.headers.value('Depth') != null) lastDepth = req.headers.value('Depth')!;

    final path = Uri.decodeComponent(req.uri.path);
    final fsPath = '${store.path}$path'.replaceAll('/', Platform.pathSeparator);

    switch (req.method) {
      case 'MKCOL':
        final d = Directory(fsPath);
        if (await d.exists()) {
          req.response.statusCode = 405;
        } else {
          await d.create(recursive: true);
          req.response.statusCode = 201;
        }
        await req.response.close();
        break;

      case 'PUT':
        final f = File(fsPath);
        await f.parent.create(recursive: true);
        final bytes = <int>[];
        await for (final c in req) {
          bytes.addAll(c);
        }
        await f.writeAsBytes(bytes, flush: true);
        req.response.statusCode = 201;
        await req.response.close();
        break;

      case 'GET':
        final f = File(fsPath);
        if (!await f.exists()) {
          req.response.statusCode = 404;
          await req.response.close();
          break;
        }
        req.response.add(await f.readAsBytes());
        await req.response.close();
        break;

      case 'DELETE':
        final e = File(fsPath).existsSync()
            ? File(fsPath)
            : (Directory(fsPath).existsSync() ? Directory(fsPath) : null);
        if (e == null) {
          req.response.statusCode = 404;
        } else {
          await e.delete(recursive: true);
          req.response.statusCode = 204;
        }
        await req.response.close();
        break;

      case 'PROPFIND':
        final dir = Directory(fsPath);
        if (!await dir.exists()) {
          req.response.statusCode = 404;
          await req.response.close();
          break;
        }
        final depth = req.headers.value('Depth') ?? '0';
        final sb = StringBuffer();
        sb.write('<?xml version="1.0"?><D:multistatus>');
        void emit(String href, bool isDir, int size) {
          sb.write('<D:response><D:href>$href</D:href><D:propstat>'
              '<D:prop>${isDir ? "<D:collection/>" : "<D:getcontentlength>$size</D:getcontentlength>"}'
              '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
        }

        emit(path.endsWith('/') ? path : '$path/', true, 0);
        if (depth == '1') {
          await for (final e
              in dir.list(followLinks: false)) {
            final name = e.path
                .split(Platform.pathSeparator)
                .where((s) => s.isNotEmpty)
                .last;
            final href = '${path.endsWith('/') ? path : '$path/'}$name';
            if (e is Directory) {
              emit(href, true, 0);
            } else if (e is File) {
              emit(href, false, await e.length());
            }
          }
        }
        sb.write('</D:multistatus>');
        req.response.statusCode = 207;
        req.response.headers.contentType = ContentType('application', 'xml');
        req.response.add(utf8.encode(sb.toString()));
        await req.response.close();
        break;

      default:
        req.response.statusCode = 405;
        await req.response.close();
    }
  });

  final dav = WebDavProvider(
    baseUrl: 'http://127.0.0.1:${server.port}/dav',
    username: user,
    password: passW,
  );

  // 🔴 Uint8List == 是引用比较（不重载），逐字节比内容
  bool bytesEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // 模拟真实服务器：baseUrl 根目录（/dav/）必然存在（如坚果云固定根）
  await Directory('${store.path}/dav').create();

  // ============ 1. 测试连接 ============
  var threw = false;
  try {
    await dav.testConnection();
  } catch (e) {
    threw = true;
    print('  testConnection err: $e');
  }
  check('testConnection（207 PROPFIND Depth:0）', !threw && lastDepth == '0');

  // ============ 2. 错误密码 → 401 语义化 ============
  final badDav = WebDavProvider(
      baseUrl: 'http://127.0.0.1:${server.port}/dav',
      username: user,
      password: 'wrong');
  var msg401 = '';
  try {
    await badDav.testConnection();
  } on CloudStorageException catch (e) {
    msg401 = e.toString();
  }
  check('401 语义化: $msg401', msg401.contains('鉴权失败') && msg401.contains('401'));

  // ============ 3. ensureDir 递归 ============
  await dav.ensureDir('ChronoTide/game-abc/2026-10-03_12-00-00_sealed');
  check('ensureDir 递归创建',
      await Directory('${store.path}/dav/ChronoTide/game-abc/2026-10-03_12-00-00_sealed')
          .exists());

  // ============ 4. 上传 + 进度 ============
  final src = File('${store.path}/local_saves.7z');
  final payload = utf8.encode('A' * 700000); // 多块，验证分块进度
  await src.writeAsBytes(payload, flush: true);
  var progressCalls = 0;
  var lastSent = 0;
  await dav.uploadFile(
      'ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z', src,
      onProgress: (sent, total) {
    progressCalls++;
    lastSent = sent;
  });
  check('上传字节一致',
      bytesEq(await File('${store.path}/dav/ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z')
              .readAsBytes(),
          payload));
  check('进度回调多次且到满额: calls=$progressCalls last=$lastSent',
      progressCalls > 1 && lastSent == payload.length);

  // ============ 5. 列目录 + PROPFIND 解析 ============
  final objs = await dav.list('ChronoTide/game-abc/2026-10-03_12-00-00_sealed');
  check('list 解析: ${objs.map((o) => "${o.name}:${o.isDir}:${o.size}").join(", ")}',
      objs.length == 1 && objs.first.name == 'saves.7z' && !objs.first.isDir && objs.first.size == payload.length);

  // ============ 6. 下载往返 ============
  final dst = File('${store.path}/downloaded.7z');
  var dlProgress = 0;
  await dav.downloadFile(
      'ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z', dst,
      onProgress: (r, t) => dlProgress = r);
  check('下载往返一致', bytesEq(await dst.readAsBytes(), payload));
  check('下载进度到满额: $dlProgress', dlProgress == payload.length);

  // ============ 7. 删除 + 404 幂等 ============
  await dav.deleteObject('ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z');
  check('删除生效',
      !await File('${store.path}/dav/ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z')
          .exists());
  var del404Threw = false;
  try {
    await dav.deleteObject('ChronoTide/game-abc/2026-10-03_12-00-00_sealed/saves.7z');
  } catch (_) {
    del404Threw = true;
  }
  check('404 幂等不抛', !del404Threw);

  await server.close(force: true);
  await store.delete(recursive: true);
  print('\nRESULT: $pass PASS / $fail FAIL');
  if (fail > 0) throw StateError('probe failed');
}
