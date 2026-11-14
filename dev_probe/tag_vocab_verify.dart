// 纯 Dart 探针：验证扩充后的 tag_vocabulary.json / tag_dimensions.json
// 与 Dart 端 TagVocabularyStore.parse/normalizeTag 逻辑自洽（本环境 flutter test
// 跑不了，此探针为 test/services/tag_vocabulary_test.dart「随包数据完整性」的替身）。
// 运行：flutter/bin/cache/dart-sdk/bin/dart.exe dev_probe/tag_vocab_verify.dart
import 'dart:convert';
import 'dart:io';

String normalizeTag(String raw) {
  const fwStart = 0xFF01, fwEnd = 0xFF5E, fwOffset = 0xFEE0;
  const noise = {
    0x20, 0x09, 0x0A, 0x0D, 0x3000, 0xB7, 0x30FB, 0x2C, 0x3001, 0x3002,
    0x2E, 0x21, 0x3F, 0x7E, 0x2D, 0x2010, 0x2013, 0x2014, 0x2015, 0x5F,
    0x28, 0x29, 0x3014, 0x3015, 0x3010, 0x3011, 0x5B, 0x5D, 0x7B, 0x7D,
    0x300C, 0x300D, 0x300E, 0x300F, 0x22, 0x27, 0x3A, 0x3B, 0x2A, 0x23,
    0x40, 0x26, 0x2F, 0x5C, 0x7C,
  };
  final sb = StringBuffer();
  for (final rune in raw.trim().runes) {
    var c = rune;
    if (c >= fwStart && c <= fwEnd) c -= fwOffset;
    if (noise.contains(c)) continue;
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    sb.writeCharCode(c);
  }
  return sb.toString();
}

void expect(bool cond, String label) {
  final mark = cond ? 'PASS' : 'FAIL';
  print('[$mark] $label');
  if (!cond) exitCode = 1;
}

void main() {
  final dimsRaw = File('assets/data/tag_dimensions.json').readAsStringSync();
  final vocabRaw = File('assets/data/tag_vocabulary.json').readAsStringSync();

  final dimsDoc = jsonDecode(dimsRaw) as Map<String, dynamic>;
  final vocabDoc = jsonDecode(vocabRaw) as Map<String, dynamic>;

  // 1. 版本
  expect((dimsDoc['format_version'] as int) <= 1, '维度表版本 ≤1');
  expect((vocabDoc['format_version'] as int) <= 1, '词表版本 ≤1');

  // 2. 维度注册
  final dims = (dimsDoc['dimensions'] as List)
      .map((e) => e as Map<String, dynamic>)
      .toList();
  expect(dims.length == 9, '维度数 = 9 (实际 ${dims.length})');
  expect(dims.last['id'] == 'adult', '末位维度 = adult');
  final dimIds = dims.map((d) => d['id'] as String).toSet();

  // 3. 概念与别名（复刻 parse：维度未注册跳过 / id 重复跳过 / 先到先得）
  final concepts =
      (vocabDoc['concepts'] as List).map((e) => e as Map<String, dynamic>).toList();
  expect(concepts.length >= 400, '概念数 ≥400 (实际 ${concepts.length})');

  final aliasIndex = <String, String>{};
  var skippedDim = 0, dupId = 0, aliasCount = 0;
  for (final c in concepts) {
    final id = (c['id'] as String).trim();
    final dim = (c['dim'] as String).trim();
    if (!dimIds.contains(dim)) {
      skippedDim++;
      continue;
    }
    if (aliasIndex.containsValue(id)) dupId++; // 粗查：id 已出现过
    for (final a in <String>[c['name'] as String, ...((c['aliases'] as List?) ?? const [])
        .map((e) => e.toString())]) {
      final n = normalizeTag(a);
      if (n.isEmpty) continue;
      aliasCount++;
      aliasIndex.putIfAbsent(n, () => id);
    }
  }
  expect(skippedDim == 0, '无未注册维度的概念 (实际 $skippedDim)');
  expect(dupId == 0, '无重复概念 id');

  // 4. 跨概念冲突 = 0（先到先得注册后，重数一遍真实冲突）
  var conflicts = 0;
  final owner = <String, String>{};
  for (final c in concepts) {
    final id = c['id'] as String;
    for (final a in <String>[c['name'] as String, ...((c['aliases'] as List?) ?? const [])
        .map((e) => e.toString())]) {
      final n = normalizeTag(a);
      if (n.isEmpty) continue;
      if (owner.containsKey(n) && owner[n] != id) conflicts++;
      owner.putIfAbsent(n, () => id);
    }
  }
  expect(conflicts == 0, '跨概念别名冲突 = 0 (实际 $conflicts)');

  // 5. 解析抽查（含 adult / 迁移 / 组合式 / 归一化路径）
  String? resolve(String t) {
    final n = normalizeTag(t);
    return aliasIndex[n];
  }

  expect(resolve('3P做爱') == 'ad.threesome', '解析 3P做爱 → ad.threesome');
  expect(resolve('ふたなり') == 'ad.futanari', '解析 ふたなり → ad.futanari');
  expect(resolve('寝取られ') == 'th.ntr', '解析 寝取られ → NTR 概念');
  expect(resolve('吸血鬼')!.startsWith('ch.'), '吸血鬼已迁至 character 维');
  expect(resolve('不存在的标签xyz') == null, '未命中输入返回 null');
  expect(resolve('ＢａｄＥｎｄ') == 'ps.bad_end', '全角+大小写归一化 → Bad End');
  expect(resolve('护士女主角')!.startsWith('ch.nurse'), '组合式「护士女主角」→ 护士');
  expect(resolve('NEET女主角') == 'ch.neet', '组合式「NEET女主角」→ 家里蹲NEET');
  expect(resolve('人妻') == 'ch.housewife', '人妻已迁至独立概念');
  expect(resolve('魔物娘') == 'ch.monster_girl', '魔物娘承接自神话超自然迁移');

  // 5b. 探索页截图「未归类」标签回归（2026-10-03 ROUND4 定点归位）
  final shotTags = <String>[
    'Meta', '穿越第四面墙', '打破第四面墙', '三角', '三角恋', '乐队', '人生',
    '伦理', '修罗场', '医院', '救赎', '十二神器', '十二魔器',
  ];
  for (final t in shotTags) {
    final id = resolve(t);
    expect(id != null, '截图标签「$t」已归类 (→ ${id ?? "未归类"})');
  }

  // 6. 维度分布统计
  final byDim = <String, int>{};
  for (final c in concepts) {
    byDim[c['dim']] = (byDim[c['dim']] ?? 0) + 1;
  }
  print('维度分布: $byDim');
  print('总别名键: ${aliasIndex.length} / 总别名+规范名: $aliasCount');
  print(exitCode == 0 ? '=== 全部通过 ===' : '=== 存在失败 ===');
}
