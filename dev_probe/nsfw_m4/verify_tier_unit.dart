// 纯 Dart 断言 harness：复刻 rating_postprocess_test.dart 新增用例，
// 在 flutter test 不可用（231）时证明分级逻辑正确。
//   dart.exe --packages=<package_config> dev_probe/nsfw_m4/verify_tier_unit.dart
// 注意：decodeFromOrtValue 走 _normalize4 —— 输入必须 sum≈1 才按概率直用，
// 否则过 softmax。本 harness 的向量均构造成 sum=1。
import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_rating_postprocess.dart';

int _fail = 0;
void check(String name, bool ok) {
  if (ok) {
    print('  PASS  $name');
  } else {
    _fail++;
    print('  FAIL  $name');
  }
}

List<double> p(double g, double s, double q, double e) => <double>[g, s, q, e];

/// 构造 sum=1 的向量，给定 qe 与 pe（g=s 均分余量）。
List<double> mk(double qe, double pe) {
  final double q = qe - pe;
  final double rest = 1.0 - qe;
  return <double>[rest / 2, rest / 2, q, pe];
}

void main() {
  print('== 常量 ==');
  check('defaultFlagThreshold==0.648', NsfwRatingPostprocess.defaultFlagThreshold == 0.648);
  check('explicitBlockThreshold==0.5', NsfwRatingPostprocess.explicitBlockThreshold == 0.5);
  check('highConfBlockThreshold==0.85', NsfwRatingPostprocess.highConfBlockThreshold == 0.85);

  print('== classifyTier（直接喂概率）==');
  check('低于阈值->none', NsfwRatingPostprocess.classifyTier(p(0.2, 0.2, 0.3, 0.3)) == NsfwTier.none);
  check('P(e)>=0.5->blocked', NsfwRatingPostprocess.classifyTier(p(0.057, 0.059, 0.079, 0.805)) == NsfwTier.blocked);
  check('qe=0.90 且 e=0.10->blocked(高置信门)', NsfwRatingPostprocess.classifyTier(p(0.05, 0.05, 0.80, 0.10)) == NsfwTier.blocked);
  check('qe=0.826 e=0.097->suspect', NsfwRatingPostprocess.classifyTier(p(0.056, 0.119, 0.729, 0.097)) == NsfwTier.suspect);
  check('clean 带 e=0.212 qe=0.586->none', NsfwRatingPostprocess.classifyTier(p(0.066, 0.348, 0.374, 0.212)) == NsfwTier.none);
  // qe=0.70(<0.85) e=0.212(<0.5) -> suspect
  check('qe=0.70 e=0.212->suspect(非blocked)', NsfwRatingPostprocess.classifyTier(mk(0.70, 0.212)) == NsfwTier.suspect);

  print('== decodeFromOrtValue 分级（向量 sum=1）==');
  final List<NsfwBox> dx = NsfwRatingPostprocess.decodeFromOrtValue(mk(0.884, 0.805), threshold: 0.648, imgW: 100, imgH: 100);
  check('explicit->blocked', dx.length == 1 && dx.first.tier == NsfwTier.blocked);
  final List<NsfwBox> ds = NsfwRatingPostprocess.decodeFromOrtValue(mk(0.826, 0.097), threshold: 0.648, imgW: 100, imgH: 100);
  check('擦边->suspect 且出框(不漏)', ds.length == 1 && ds.first.tier == NsfwTier.suspect);
  final List<NsfwBox> dn = NsfwRatingPostprocess.decodeFromOrtValue(mk(0.50, 0.10), threshold: 0.648, imgW: 100, imgH: 100);
  check('低于阈值->空', dn.isEmpty);

  print('== fail-closed 守卫：过阈值(0.70)必出框 ==');
  for (final double e in <double>[0.0, 0.1, 0.3, 0.49, 0.5, 0.69]) {
    final List<NsfwBox> b = NsfwRatingPostprocess.decodeFromOrtValue(mk(0.70, e), threshold: 0.648, imgW: 10, imgH: 10);
    check('e=$e 过阈值出框且 isHandled', b.length == 1 && b.first.tier.isHandled);
  }

  print('== NsfwBox tier 向后兼容 ==');
  final NsfwBox? legacy = NsfwBox.fromJson(<String, dynamic>{'x0': 0, 'y0': 0, 'x1': 5, 'y1': 5, 'l': 2, 'c': 0.9});
  check('旧格式无 t -> blocked', legacy != null && legacy.tier == NsfwTier.blocked);
  const NsfwBox sus = NsfwBox(x0: 0, y0: 0, x1: 5, y1: 5, label: 2, conf: 0.7, tier: NsfwTier.suspect);
  check('suspect toJson 含 t=1', (sus.toJson()['t'] as int?) == 1);
  const NsfwBox blk = NsfwBox(x0: 0, y0: 0, x1: 5, y1: 5, label: 2, conf: 0.9);
  check('blocked(默认) toJson 省略 t', !blk.toJson().containsKey('t'));
  final NsfwBox? round = NsfwBox.fromJson(sus.toJson());
  check('suspect 往返保真', round != null && round.tier == NsfwTier.suspect);
  check('NsfwTier.isHandled 语义', NsfwTier.none.isHandled == false && NsfwTier.suspect.isHandled && NsfwTier.blocked.isHandled);

  print('');
  if (_fail == 0) {
    print('✅ 全部通过');
  } else {
    print('❌ $_fail 项失败');
  }
}
