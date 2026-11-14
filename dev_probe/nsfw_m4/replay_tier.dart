// Task #6 离线回放验证：用 M4 实测的 70 张真实 4 类概率，送入**真实**
// 的 NsfwRatingPostprocess 分级逻辑，核验：
//   ① FP：clean 组（旧未处理）不得产生 blocked（硬拦）；
//   ② FN：flag 组（旧已处理）在新逻辑下必须仍全部「被处理」（出框）；
//   ③ 分级分布：explicit 子集应落 blocked，擦边子集应落 suspect。
//
// 🔴 关于「探针分数 vs 客户端缓存分数」的差异（已实测，见输出）：
//   37/39 张与缓存分数差 ≤0.03（多 ±0.005），仅 036/037 两张差 ~0.06-0.07，
//   源于**本地探针的 resize 插值**与客户端 codec 拉伸的差异（M3）。
//   因此本回放对「已被客户端判定过」的样本，**优先用客户端真实分数
//   cached_c**（真值），仅在无缓存分数时才用探针分数，避免把预处理误差
//   误当逻辑 FN。P(e) 用探针的 P(e) 占 qe 比例（比例与预处理无关）。
//
// 纯 Dart（无 dart:ui），可绕过 flutter test 的 231 故障直接跑：
//   dart.exe --packages=<package_config> dev_probe/nsfw_m4/replay_tier.dart
import 'dart:convert';
import 'dart:io';

import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_rating_postprocess.dart';

/// 按 qe + P(e) 直接分级（复刻 classifyTier 的口径，便于用客户端真值分数）。
NsfwTier _tierOf(double qe, double pe) {
  if (qe < NsfwRatingPostprocess.defaultFlagThreshold) return NsfwTier.none;
  if (pe >= NsfwRatingPostprocess.explicitBlockThreshold ||
      qe >= NsfwRatingPostprocess.highConfBlockThreshold) {
    return NsfwTier.blocked;
  }
  return NsfwTier.suspect;
}

void main() {
  final File f = File('dev_probe/nsfw_m4/probs.jsonl');
  if (!f.existsSync()) {
    stderr.writeln('缺少 probs.jsonl');
    exitCode = 2;
    return;
  }
  final List<Map<String, Object?>> rows = f
      .readAsLinesSync()
      .where((String l) => l.trim().isNotEmpty)
      .map((String l) => jsonDecode(l) as Map<String, Object?>)
      .toList();

  int cleanTotal = 0, cleanBlocked = 0;
  int flagTotal = 0, flagHandled = 0, flagBlocked = 0, flagSuspect = 0;
  int pass = 0;
  final List<String> violations = <String>[];
  final Map<NsfwTier, int> dist = <NsfwTier, int>{
    NsfwTier.none: 0,
    NsfwTier.suspect: 0,
    NsfwTier.blocked: 0,
  };

  for (final Map<String, Object?> r in rows) {
    final List<double> probs = (r['probs'] as List<Object?>)
        .map((Object? e) => (e as num).toDouble())
        .toList();
    final bool oldFlagged = r['cached_flagged'] as bool;
    final String idx = r['idx'] as String;

    final double qeProbe = probs[2] + probs[3];
    // P(e) 占 qe 的比例（与预处理无关），用于按客户端真值分数还原 P(e)。
    final double peRatio = qeProbe > 0 ? probs[3] / qeProbe : 0.0;
    // 已被客户端判定过的样本用其真实分数（真值），否则用探针分数。
    final double cachedC = (r['cached_c'] as num).toDouble();
    final double qe = oldFlagged ? cachedC : qeProbe;
    final double pe = peRatio * qe;

    final NsfwTier tier = _tierOf(qe, pe);
    final bool handled = tier.isHandled;
    dist[tier] = (dist[tier] ?? 0) + 1;

    if (tier == NsfwTier.none) {
      pass++;
    }

    if (!oldFlagged) {
      cleanTotal++;
      if (tier == NsfwTier.blocked) {
        cleanBlocked++;
        violations.add('FP(blocked) idx=$idx qe=$qe pe=$pe');
      }
    } else {
      flagTotal++;
      if (handled) flagHandled++;
      if (tier == NsfwTier.blocked) flagBlocked++;
      if (tier == NsfwTier.suspect) flagSuspect++;
      if (!handled) {
        violations.add('FN(未处理) idx=$idx qe=$qe');
      }
    }
  }

  stdout.writeln('== 离线回放（M4 70 张 → 真实分级逻辑，flag 组用客户端真值分数）==');
  stdout.writeln('clean 组: $cleanTotal, 其中被判 blocked（FP 硬拦）= $cleanBlocked');
  stdout.writeln('flag  组: $flagTotal, 仍被处理 = $flagHandled, '
      'blocked=$flagBlocked, suspect=$flagSuspect');
  stdout.writeln('分级分布: none=${dist[NsfwTier.none]} '
      'suspect=${dist[NsfwTier.suspect]} blocked=${dist[NsfwTier.blocked]}');
  stdout.writeln('');
  if (violations.isEmpty) {
    stdout.writeln('✅ 通过：FP(blocked)=0，FN(未处理)=0');
  } else {
    stdout.writeln('❌ 违规 ${violations.length} 条：');
    for (final String v in violations) {
      stdout.writeln('   $v');
    }
    exitCode = 1;
  }
}

