/// anime_dbrating 四级评分分类器后处理（v2.4 模型替换：YOLO 部位检测 → 全图评分）。
///
/// 模型：`deepghs/anime_dbrating` 的 `mobilenetv3_large_100_v0_ls0.2`
/// （16.8MB，ONNX，输入 [batch,3,384,384]，输出 [batch,4] **已是 softmax
/// 概率**——导出图内含 softmax 层，实测真 R18 封面 raw=[0.070,0.065,0.762,
/// 0.103]，min≥0、sum=1.000；标签顺序来自模型卡 meta.json：general /
/// sensitive / questionable / explicit）。
///
/// **判定分数 = P(questionable) + P(explicit)**：danbooru 语义里
/// questionable ≈ 擦边以上（性暗示姿势/体液等）、explicit ≈ R18 明确内容，
/// 两者相加即「用户标准下应打码的程度」。sensitive（内衣/泳装级擦边）
/// 计入健全侧，与用户「性感擦边 = 健全」的标准对齐。
///
/// **v2.6 分级判定（单一强度，双阈值 + explicit 硬门）：**
/// 单一分数无法区分「明确露点」与「擦边存疑」，导致两类问题并存：
/// 擦边封面被无差别硬拦（误判）、而 explicit 概率散的样本分数被压低（漏判）。
/// 现引入 [NsfwTier]：
/// - `score < 0.648` → none（健全，放行）；
/// - `P(explicit) ≥ 0.5` 或 `score ≥ 0.85` → **blocked**（硬拦，M4 实测
///   上下界 0.212/0.533，阈值极安全）；
/// - 其余过阈值样本 → **suspect**（擦边，**仍模糊** ⇒ 零漏判回归，
///   但带可揭示入口，把误判变成「用户可一键放行」）。
/// 「是否处理」的下限仍是 0.648，不降低 ⇒ 不引入新的漏判。
///
/// **为什么敏感时输出全图合成框而不是分数字段：**
/// v2.2 起渲染层已「敏感即整图模糊」（局部马赛克退役，见
/// `NsfwImage._buildCensored`），不再消费具体 bbox；`NsfwImage` 以
/// `_boxes.isEmpty` 作为敏感信号。合成框复用既有 NsfwDetection 存储/
/// 通知/签名失效链路，**零渲染层改动**即可承载分级——这是模型替换
/// 而不是存储层重构的关键取舍。
library;

import 'dart:math' as math;

import 'nsfw_box.dart';

class NsfwRatingPostprocess {
  NsfwRatingPostprocess._();

  /// 类别数，与 [NsfwBox.labelNames]（v2.4 起为 rating 标签）一致。
  static const int classCount = 4;

  /// 默认敏感判定阈值（唯一判定口径，v2.6 起为**双阈值**的「处理下限」）。
  ///
  /// **0.648 = 用户 69 张参考集分离间隙中点**（2026-09-07 实测，384 输入、
  /// half 归一化、分数 P(q)+P(e)，**P 为模型原始概率输出直加**——校准与
  /// 判定必须同口径，勿二次 softmax，见 [_normalize4] 的事故记录）：
  /// - 健全 43 张最高分 **0.6287**（泳装/性感擦边类全部放行）；
  /// - 敏感 26 张次低分 **0.6680**（最低 0.2165 为 1 张结构性漏检，
  ///   "全裸但无露点"类，现役 YOLO 检测器同样检不出）；
  /// - T=0.648：**误报 0/43，召回 25/26**；
  /// - 对比旧口径（censor_detect_v1.0_n @0.360）：误报 1→0、召回 22→25，
  ///   且抓到旧模型完全漏掉的明确 R18 封面（实测库内 0.02 → 0.87）。
  /// - 库内 42 张封面实测：拦 6（真敏感 4 + 误拦 2；误拦为"内裤擦边封面"
  ///   与"强抱截图封面"，用户标准边界样本，阈值无法在不砍召回的情况下排除）。
  ///
  /// **不要再无数据调阈值**：往上走砍召回（0.65+ 开始丢敏感参考图），
  /// 往下走多误报（0.63 会拦健全参考图）。
  ///
  /// v2.6 起该值 = **suspect 下限**（超过即处理，不低于旧口径 ⇒ 不漏判）。
  static const double defaultFlagThreshold = 0.648;

  /// explicit 单项硬门（v2.6 新增）：`P(explicit) ≥ 此值 → blocked（硬拦）`。
  ///
  /// **0.5 为 2026-10-15 M4 实测确定**（70 张分层抽样，`probs.jsonl`）：
  /// - 未处理（clean）组 P(e) 最大值 = **0.212**；
  /// - 已处理组中明确露点子集 P(e) 最小值 = **0.533**；
  /// - 0.212 ~ 0.533 之间是**无人区**，取 0.5 极安全；
  /// - montage 目视：`P(e)≥0.5` 的 16 张**全部**为真露点/性行为。
  /// 详见 `docs/DEV/features/nsfw_purity_mode_optimization_plan.md` §9。
  static const double explicitBlockThreshold = 0.5;

  /// suspect 转 blocked 的「分数高置信」辅助门（v2.6）。
  ///
  /// 在 P(e) 未过硬门、但整图分数极高（≥ 此值 ⇒ 强烈指示敏感）时仍判 blocked。
  /// 取 **0.85**（旧缓存实测分数 p75=0.862、max=0.884，≥0.85 组目视
  /// 全部为真露点）——这类样本 P(e) 普遍也 ≥0.75，本门主要兜住
  /// 「explicit 概率分散到 questionable」的结构性样本。
  static const double highConfBlockThreshold = 0.85;

  /// 判定分数：softmax 后 questionable + explicit 两列之和。
  static double scoreOf(List<double> probs) => probs[2] + probs[3];

  /// 按「双阈值 + explicit 硬门」给出分级（v2.6）。
  ///
  /// 入参 [probs] 为**已归一化**的 4 类概率（经 [_normalize4]）。
  /// 判定顺序（fail-closed：宁可多拦不可漏拦）：
  /// 1. `score < [suspectThreshold]` → [NsfwTier.none]（健全）；
  /// 2. `P(e) ≥ [explicitBlockThreshold]` 或 `score ≥ [highConfBlockThreshold]`
  ///    → [NsfwTier.blocked]（明确露点/高置信）；
  /// 3. 其余（过阈值但 explicit 不足）→ [NsfwTier.suspect]（擦边，仍模糊）。
  static NsfwTier classifyTier(
    List<double> probs, {
    double suspectThreshold = defaultFlagThreshold,
    double explicitThreshold = explicitBlockThreshold,
    double highConfThreshold = highConfBlockThreshold,
  }) {
    final double score = scoreOf(probs);
    if (score < suspectThreshold) return NsfwTier.none;
    if (probs[3] >= explicitThreshold || score >= highConfThreshold) {
      return NsfwTier.blocked;
    }
    return NsfwTier.suspect;
  }

  /// 数值稳定版 softmax（减最大值防溢出）。
  static List<double> softmax(List<double> values) {
    if (values.length != classCount) {
      throw ArgumentError(
        '模型输出应为 $classCount 个 logits（general/sensitive/questionable/'
        'explicit），实际 ${values.length} 个。',
      );
    }
    final double m = values.reduce(math.max);
    final List<double> exps = values
        .map((double v) => math.exp(v - m))
        .toList(growable: false);
    final double sum = exps.fold(0.0, (double a, double b) => a + b);
    if (sum <= 0 || sum.isNaN) {
      throw StateError('softmax 分母异常: $sum');
    }
    return exps.map((double e) => e / sum).toList(growable: false);
  }

  /// 输出归一化：**先做概率自检，绝不一律 softmax**。
  ///
  /// deepghs 的 ONNX 导出图内已烧 softmax，输出直接是 4 类概率；若误对概率
  /// 再做一次 softmax，分布会被压平（实测真敏感图 q+e 0.86 → 0.60），全量
  /// 跌破阈值 0.648 —— 这正是 v2.1.12「NSFW 完全不工作」（缓存 403 条全部
  /// 错判健康、0 条带框）的根因。校准阈值 0.648 本就是按"概率直用"口径
  /// 测得的分离间隙中点，两者必须同口径。
  ///
  /// 兼容规则（与 python 校准脚本同口径）：全部 ≥0 且和≈1（±0.02）视为
  /// 概率直用；否则按 logits 过 softmax（兼容图内未烧 softmax 的导出变体）。
  static List<double> _normalize4(List<double> values) {
    final double sum = values.fold(0.0, (double a, double b) => a + b);
    final bool alreadyProb = values.every((double e) => e >= 0) &&
        (sum - 1.0).abs() <= 0.02;
    return alreadyProb ? values : softmax(values);
  }

  /// 从 ORT 输出解析分类分数并生成判定框列表。
  ///
  /// ORT 返回形状 [1,1,4] 或 [1,4] 的嵌套 List（概率或 logits，见
  /// [_normalize4]）；分数 ≥ [threshold] 时返回**单个全图合成框**
  /// （label=2 questionable 占位，conf=判定分数，tier=分级），
  /// 健全/入参异常尺寸返回空列表。
  ///
  /// v2.6：框上带 [NsfwTier]（blocked / suspect），供渲染层区分「硬拦」
  /// 与「擦边可揭示」。判定「是否处理」的下限仍是 [threshold]，不低于旧
  /// 口径 ⇒ 不引入漏判回归。
  static List<NsfwBox> decodeFromOrtValue(
    Object? value, {
    required double threshold,
    required int imgW,
    required int imgH,
    double explicitThreshold = explicitBlockThreshold,
    double highConfThreshold = highConfBlockThreshold,
  }) {
    final List<double>? logits = _flatten4(value);
    if (logits == null) {
      throw ArgumentError('模型输出不是预期的 [1, 4] logits：${value?.runtimeType}');
    }
    if (imgW <= 0 || imgH <= 0) return const <NsfwBox>[];
    final List<double> probs = _normalize4(logits);
    final double score = scoreOf(probs);
    if (score < threshold) return const <NsfwBox>[];
    final NsfwTier tier = classifyTier(
      probs,
      suspectThreshold: threshold,
      explicitThreshold: explicitThreshold,
      highConfThreshold: highConfThreshold,
    );
    // 全图合成框：渲染层只看"框列表是否为空"，坐标与 label 均不参与绘制。
    return <NsfwBox>[
      NsfwBox(
        x0: 0,
        y0: 0,
        x1: imgW,
        y1: imgH,
        label: 2,
        conf: score,
        tier: tier,
      ),
    ];
  }

  /// 把 ORT 嵌套 List 折叠成长度 4 的 logits（兼容 [1,1,4] / [1,4] / [4]）。
  static List<double>? _flatten4(Object? value) {
    Object? cur = value;
    while (cur is List && cur.isNotEmpty && cur.first is List) {
      cur = cur.first;
    }
    if (cur is List &&
        cur.length == classCount &&
        cur.every((Object? e) => e is num)) {
      return cur.map((Object? e) => (e as num).toDouble()).toList(
            growable: false,
          );
    }
    return null;
  }
}
