// SigV4 签名 —— AWS 官方文档测试向量逐字节验证。
//
// 向量来源：AWS 文档「Authenticating Requests: Using the Authorization Header
// (AWS Signature Version 4)」S3 章节的 PUT Object 完整示例：
//   PUT /test%24file.text
//   Host: examplebucket.s3.amazonaws.com
//   x-amz-date: 20130524T000000Z
//   x-amz-storage-class: REDUCED_REDUNDANCY
//   x-amz-content-sha256: 44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
//   Authorization: ... Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd
//
// 签名错 = 云端全 403。逐字节锁定，签名核心任何改动必须先过本探针。

import 'dart:io';

import '../lib/services/cloud_backup/sha256_hmac.dart';
import '../lib/services/cloud_backup/sigv4.dart';

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

void main() {
  const secret = '<REDACTED>';
  const access = 'AKIAIOSFODNN7EXAMPLE';

  // ---- awsUriEncode ----
  check('uriEncode 保留 unreserved', awsUriEncode('test-file_1.0~a') == 'test-file_1.0~a');
  check(r'uriEncode $ → %24', awsUriEncode(r'test$file.txt') == r'test%24file.txt');
  check('uriEncode path 保留 /', awsUriEncode('game-id/2026-10-03_12-00-00_sealed/body.7z') ==
      'game-id/2026-10-03_12-00-00_sealed/body.7z');
  check('uriEncode query 编码 /', awsUriEncode('a/b', encodeSlash: true) == 'a%2Fb');
  check('uriEncode 空格 → %20（非 +）', awsUriEncode('my game') == 'my%20game');
  check('uriEncode 中文 UTF-8',
      awsUriEncode('游戏') == '%E6%B8%B8%E6%88%8F');

  // ---- 官方 PUT Object 向量（整条 Authorization 头逐字节比对）----
  final headers = {
    'host': 'examplebucket.s3.amazonaws.com',
    'x-amz-date': '20130524T000000Z',
    'x-amz-content-sha256':
        '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    'date': 'Fri, 24 May 2013 00:00:00 GMT',
    'x-amz-storage-class': 'REDUCED_REDUNDANCY',
  };
  final auth = SigV4.authorizationHeader(
    method: 'PUT',
    canonicalUri: '/test%24file.text',
    canonicalQuery: '',
    headers: headers,
    payloadHash:
        '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    accessKey: access,
    secretKey: secret,
    region: 'us-east-1',
    service: 's3',
    amzDate: '20130524T000000Z',
  );
  const expected =
      'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
      'SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, '
      'Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd';
  check('AWS 官方 PUT Object 向量（Authorization 全串）', auth == expected);
  if (auth != expected) {
    stdout.writeln('  期望: $expected');
    stdout.writeln('  实际: $auth');
  }

  // ---- signedHeaders 便捷封装自检（结构 + 确定性，无官方对照）----
  final now = DateTime.utc(2013, 5, 24);
  final h1 = SigV4.signedHeaders(
    method: 'GET',
    bucket: 'examplebucket',
    key: '',
    query: {'list-type': '2', 'max-keys': '1'},
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    accessKey: access,
    secretKey: secret,
    region: 'us-east-1',
    now: now,
  );
  check('signedHeaders 恒含 Authorization/x-amz-date/content-sha256',
      h1.containsKey('Authorization') &&
          h1['x-amz-date'] == '20130524T000000Z' &&
          h1['x-amz-content-sha256'] == 'UNSIGNED-PAYLOAD');
  final h2 = SigV4.signedHeaders(
    method: 'GET',
    bucket: 'examplebucket',
    key: '',
    query: {'list-type': '2', 'max-keys': '1'},
    endpoint: 'https://s3.us-east-1.amazonaws.com',
    accessKey: access,
    secretKey: secret,
    region: 'us-east-1',
    now: now,
  );
  check('signedHeaders 确定性（同输入同签名）', h1['Authorization'] == h2['Authorization']);

  stdout.writeln('RESULT: $pass PASS / $fail FAIL');
  if (fail > 0) exit(1);
}
