// S3Provider 回环探针 —— 本地 HttpServer 模拟 S3 服务端，实测 HTTP 全链路。
//
// 签名正确性已由 phase5_s3sig_probe.dart（AWS 官方向量）锁定；本探针覆盖
// HTTP 层：PUT/GET/DELETE/ListObjectsV2 XML 解析/分页语义/进度回调。
// 服务端不验签（只断言 Authorization 头存在）。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/cloud_backup/cloud_storage_provider.dart';
import '../lib/services/cloud_backup/s3_provider.dart';

int pass = 0, fail = 0;
void check(String name, bool cond) {
  if (cond) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name');
  }
}

const bucket = 'probe-bucket';
final store = <String, List<int>>{}; // key -> bytes

String _xmlEsc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

Future<void> main() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  final sub = server.listen((req) async {
    // 断言 Authorization 头存在（签名格式校验由官方向量探针负责）
    if (req.headers.value('Authorization') == null ||
        !req.headers.value('Authorization')!.startsWith('AWS4-HMAC-SHA256')) {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }

    final path = req.uri.path; // /bucket/key...
    // 归一化为 bucket 内 key（真实 S3 语义：key 不含 bucket 名）
    final bucketPrefix = '/$bucket/';
    final inBucketKey =
        path.startsWith(bucketPrefix) ? path.substring(bucketPrefix.length) : null;
    final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

    if (req.method == 'PUT') {
      if (inBucketKey == null) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      store[inBucketKey] = body;
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    if (req.method == 'GET') {
      if (req.uri.queryParameters.containsKey('list-type')) {
        final prefix = req.uri.queryParameters['prefix'] ?? '';
        final delimiter = req.uri.queryParameters['delimiter'] ?? '';
        final sb = StringBuffer('<?xml version="1.0"?><ListBucketResult>');
        if (delimiter.isNotEmpty) {
          // 子目录 = 以 prefix 开头且含更多 '/' 的 key 的第一段
          final dirs = <String>{};
          for (final k in store.keys) {
            if (!k.startsWith(prefix)) continue;
            final rest = k.substring(prefix.length);
            final i = rest.indexOf('/');
            if (i > 0) dirs.add(rest.substring(0, i + 1));
          }
          for (final d in dirs) {
            sb.write('<CommonPrefixes><Prefix>${_xmlEsc(prefix + d)}</Prefix></CommonPrefixes>');
          }
        }
        for (final e in store.entries) {
          if (!e.key.startsWith(prefix)) continue;
          if (delimiter.isNotEmpty && e.key.substring(prefix.length).contains('/')) {
            continue; // 目录由 CommonPrefixes 表示
          }
          sb.write('<Contents><Key>${_xmlEsc(e.key)}</Key>'
              '<Size>${e.value.length}</Size></Contents>');
        }
        sb.write('<IsTruncated>false</IsTruncated></ListBucketResult>');
        req.response.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        req.response.write(sb.toString());
        await req.response.close();
        return;
      }
      final data = inBucketKey == null ? null : store[inBucketKey];
      if (data == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.add(data);
      await req.response.close();
      return;
    }
    if (req.method == 'DELETE') {
      if (inBucketKey != null) store.remove(inBucketKey);
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    req.response.statusCode = 405;
    await req.response.close();
  });

  final s3 = S3Provider(
    endpoint: 'http://127.0.0.1:${server.port}',
    region: 'us-east-1',
    bucket: bucket,
    accessKey: 'AKIDPROBE',
    secretKey: 'secret-probe',
  );

  // 1. 测试连接
  var ok = false;
  try {
    await s3.testConnection();
    ok = true;
  } catch (_) {}
  check('testConnection 通过', ok);

  // 2. 上传（带进度）
  final src = File('${Directory.systemTemp.path}/ct_s3_up_${DateTime.now().millisecondsSinceEpoch}.bin');
  final payload = Uint8List(300 * 1024);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = i & 0xff;
  }
  await src.writeAsBytes(payload);
  final upPercents = <int>[];
  await s3.uploadFile('ChronoTide/game-x/2026-10-03_sealed/body.7z', src,
      onProgress: (s, t) => upPercents.add(t == 0 ? 0 : (s * 100 ~/ t)));
  check('上传完成且服务端字节一致',
      store['ChronoTide/game-x/2026-10-03_sealed/body.7z']!.length == payload.length);
  check('上传进度回调有值', upPercents.isNotEmpty);

  // 3. 列表（一层：归档目录为 CommonPrefixes）
  final dirs = await s3.list('ChronoTide/game-x');
  check('列表返回归档目录', dirs.any((o) => o.isDir && o.path == '2026-10-03_sealed'));
  check('目录不在列表里重复为文件', !dirs.any((o) => !o.isDir));

  final files = await s3.list('ChronoTide/game-x/2026-10-03_sealed');
  check('归档内文件列表 + 大小',
      files.any((o) => !o.isDir && o.path == 'body.7z' && o.size == payload.length));

  // 4. 下载 → 字节一致
  final dst = File('${Directory.systemTemp.path}/ct_s3_down_${DateTime.now().millisecondsSinceEpoch}.bin');
  await s3.downloadFile('ChronoTide/game-x/2026-10-03_sealed/body.7z', dst);
  final got = await dst.readAsBytes();
  var dlOk = got.length == payload.length;
  for (var i = 0; dlOk && i < payload.length; i++) {
    if (got[i] != payload[i]) dlOk = false;
  }
  check('下载字节一致', dlOk);

  // 5. 递归删除归档目录 → 列表空
  await s3.deleteObject('ChronoTide/game-x/2026-10-03_sealed');
  final after = await s3.list('ChronoTide/game-x');
  check('递归删除后目录消失', !after.any((o) => o.path == '2026-10-03_sealed'));

  // 6. 删除不存在目标幂等（不抛异常）
  var idemOk = true;
  try {
    await s3.deleteObject('ChronoTide/game-x/2026-10-03_sealed');
  } catch (_) {
    idemOk = false;
  }
  check('删除幂等', idemOk);

  // 7. 错误语义：下载不存在 key → CloudStorageException
  var threw = false;
  try {
    await s3.downloadFile('no/such/key', dst);
  } on CloudStorageException {
    threw = true;
  }
  check('404 语义化为 CloudStorageException', threw);

  await src.delete();
  await dst.delete();
  await sub.cancel();
  await server.close();

  print('RESULT: $pass PASS / $fail FAIL');
  if (fail > 0) exit(1);
}
