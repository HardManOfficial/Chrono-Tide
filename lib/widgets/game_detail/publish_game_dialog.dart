import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/path_helper.dart';
import '../../core/portable_image_cache_manager.dart';
import '../../models/game_model.dart';
import '../../pages/join/widgets/platform_badge.dart';
import '../../services/cover_download_service.dart';
import '../../services/game_publish_service.dart';
import '../../services/game_resource_service.dart';
import '../../services/metadata_fetcher.dart';
import '../../utils/title_cleaner.dart';
import '../app_snack_bar.dart';
import 'dark_surface.dart';
import 'upload_resource_dialog.dart';

/// 「发布 Galgame」窗口 —— 发布三步中的**第 2 步（游戏资料）+ 第 3 步（上传资源）**，
/// 按开发者要求做成**同一窗口内分页**（方案 §8.10-决策 5）。
///
/// ## 与「上传」的关系（方案 §8.7①）
///
/// | 类型 | 前提 | 入口 | 写入 |
/// |---|---|---|---|
/// | 资源投稿 | 作品**已存在**于探索库 | 探索详情页 →【上传】 | 仅 `game_resources` |
/// | **作品发布** | 作品**不存在**于探索库 | 探索大厅 → 文档板块 →【发布】 | 先 `games`，再 `game_resources` |
///
/// 第 2 步的字段与「添加页」一致，可选**一键抓取元数据**回填；
/// 第 3 步直接复用 [UploadResourceDialog]（`embedded: true`），
/// 即「B 的第三步 = 探索详情页上传」这条需求原话的实现方式。
///
/// ## 提交顺序（方案 §8.7②）
///
/// ```
/// 1) POST games          origin=user / owner=<uid> / review_status=pending
/// 2) POST game_resources createCommunityResource(game: <上一步返回的 id>)
/// ```
/// ⚠️ 第 2 步失败**不回滚**作品 —— PB 无跨集合事务，且「作品在、资源待补」是
/// 合法状态（与官方作品可以有作品无资源同构），回滚反而会丢掉用户填好的整份资料。
class PublishGameDialog extends StatefulWidget {
  const PublishGameDialog({
    super.key,
    required this.initialTitle,
    this.onClose,
    this.editing,
  });

  /// 第 1 步（文档板块内联判重）传入的游戏名，作为 `title` 初值
  final String initialTitle;

  final VoidCallback? onClose;

  /// **编辑模式**：预填该作品的资料，底部改为「保存修改」，提交走
  /// [GamePublishService.updateMyGame]（服务端规则：`review_status != "approved"`
  /// 才可编辑，满足时 PB 返 **404**；调用方须先用 [GameModel.canEditAsOwner] 预判）。
  final GameModel? editing;

  /// 弹出窗口。返回 `true` 表示已成功提交（调用方据此刷新列表）。
  static Future<bool?> show({
    required BuildContext context,
    required String initialTitle,
  }) {
    return showDarkCenteredDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PublishGameDialog(
        initialTitle: initialTitle,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  /// 编辑既有作品（【我的】→ 我发布的游戏 → 编辑资料）
  static Future<bool?> showEdit({
    required BuildContext context,
    required GameModel game,
  }) {
    return showDarkCenteredDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PublishGameDialog(
        initialTitle: game.title,
        editing: game,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  @override
  State<PublishGameDialog> createState() => _PublishGameDialogState();
}

/// ============================================================================
/// 元数据抓取结果的择优与字段级补齐（发布窗专用）
///
/// 2026-10-06：发布窗此前只回填文本、且只取 `list.first`，导致封面/横幅/截图
/// 永远填不进来、单源缺失时文本也缺。这里做两件事：
/// 1. 择优：MIX 整合条目优先，否则按关键字段完整度打分（图片权重更高）；
/// 2. 补齐：最佳结果缺的字段，从其余数据源结果里取第一个非空。
///
/// 抽成文件级函数（而非私有 static）是为了能直接写单元测试。
/// ============================================================================

// ==================== 抓取结果择优与补齐 ====================

/// 候选结果的「身份名字集」：原名与标题**分别**归一化（去空去重）。
///
/// 不能只取单键——用户输入的检索词（如「缘之空」）往往等于候选的
/// title 而不等于原名（ヨスガノソラ），单键会让身份锚永远失配。
/// 空集表示无可判定身份。
Set<String> publishIdentityKeysOf(Map<String, dynamic> m) {
  final keys = <String>{};
  final ot = (m['original_title'] as String?)?.trim() ?? '';
  final t = (m['title'] as String?)?.trim() ?? '';
  if (ot.isNotEmpty) keys.add(TitleCleaner.normalizeForCompare(ot));
  if (t.isNotEmpty) keys.add(TitleCleaner.normalizeForCompare(t));
  keys.remove('');
  return keys;
}

/// 判断两条抓取结果是否指向**同一部作品**。
///
/// 名字集（[publishIdentityKeysOf]）有交集即同作品；任一无名字视为异身份
/// （2026-10-07 拍板：宁缺勿错——跨作品补字段会把《千恋＊万花》的
/// 英文名填进《缘之空》，实机已踩）。
bool publishSameWork(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ka = publishIdentityKeysOf(a);
  final kb = publishIdentityKeysOf(b);
  if (ka.isEmpty || kb.isEmpty) return false;
  return ka.intersection(kb).isNotEmpty;
}

/// 检索词是否命中至少一条候选（名字集含归一化后的检索词即命中）。
///
/// 用于抓取前的守门（2026-10-07 实机踩：搜「YOU」，返回的候选里没有
/// 任何作品名字能对上，旧逻辑仍按完整度择优填了《千恋＊万花》的原名/
/// 简介——用户视角就是「填了别的游戏」）。检索词无法归一化时放行
/// （无法判定就不拦，保持旧行为）。
bool publishAnchorMatches(
    List<Map<String, dynamic>> results, String query) {
  final q = TitleCleaner.normalizeForCompare(query);
  if (q.isEmpty) return true;
  for (final r in results) {
    if (publishIdentityKeysOf(r).contains(q)) return true;
  }
  return false;
}

/// 抓取结果择优：MIX 整合条目优先（字段级整合，缺失率最低），
/// 否则按关键字段完整度打分。
///
/// [queryHint]（用户输入的检索词）作为身份锚：无 MIX 时优先在
/// 「与检索词同身份」的候选里择优，避免字段更全的**陌生作品**抢走主结果
/// （真机踩坑：搜《缘之空》，完整度最高的却是《千恋＊万花》）。
/// 无同身份候选时回退全量择优（与修复前行为一致，不比之前更差）。
Map<String, dynamic> pickPublishBestResult(
    List<Map<String, dynamic>> results,
    {String? queryHint}) {
  if (results.isEmpty) return const {};
  if (results.length == 1) return results.first;

  // MIX 条目由 MetadataFetcher 生成，platform 固定为 'MIX源'
  for (final r in results) {
    if ((r['platform'] as String?) == 'MIX源') return r;
  }

  // 身份锚：限定在与检索词共享任一名字的候选子集里择优
  if (queryHint != null) {
    final key = TitleCleaner.normalizeForCompare(queryHint);
    if (key.isNotEmpty) {
      final same = results
          .where((r) => publishIdentityKeysOf(r).contains(key))
          .toList();
      if (same.isNotEmpty) {
        var best = same.first;
        var bestScore = publishCompletenessScore(best);
        for (final r in same.skip(1)) {
          final s = publishCompletenessScore(r);
          if (s > bestScore) {
            best = r;
            bestScore = s;
          }
        }
        return best;
      }
    }
  }

  var best = results.first;
  var bestScore = publishCompletenessScore(best);
  for (final r in results.skip(1)) {
    final s = publishCompletenessScore(r);
    if (s > bestScore) {
      best = r;
      bestScore = s;
    }
  }
  return best;
}

/// 关键字段完整度打分（图片权重更高——本次修复的重点）
int publishCompletenessScore(Map<String, dynamic> m) {
  var s = 0;
  if ((m['cover_url'] as String? ?? '').startsWith('http')) s += 3;
  if ((m['banner_url'] as String? ?? '').startsWith('http')) s += 2;
  final shots = m['screenshot_urls'];
  if (shots is List && shots.isNotEmpty) s += 2;
  if ((m['summary'] as String? ?? '').trim().isNotEmpty) s += 1;
  if ((m['developer'] as String? ?? '').trim().isNotEmpty) s += 1;
  if ((m['release_date'] as String? ?? '').trim().isNotEmpty) s += 1;
  final rating = m['rating'];
  if (rating is num && rating > 0) s += 1;
  final tags = m['tags'];
  if (tags is List && tags.isNotEmpty) s += 1;
  return s;
}

/// 以 [base]（用户在候选卡片里点选的来源）为底，空缺字段从其余结果补齐
/// （发布窗专用）。
///
/// 未传 [base] 时按 [pickPublishBestResult] 自动择优（兼容旧测试）。
///
/// **只从同作品候选补**（[publishSameWork]）：搜索结果列表常混入同关键字
/// 的其它作品，跨作品补齐就是把别的游戏封面/英文名抄进来（实机已踩）。
/// 只补「这个源没有、别的源有」的字段，不做无意义覆盖；
/// 截图不足 [maxScreenshots] 张时才从其他源补（同一作品，多几张更利于展示）。
Map<String, dynamic> mergeForPublishMetadata(
  List<Map<String, dynamic>> results, {
  int maxScreenshots = 6,
  String? queryHint,
  Map<String, dynamic>? base,
}) {
  if (results.isEmpty) return const {};
  final bestRef = base ??
      pickPublishBestResult(results, queryHint: queryHint);
  final merged = Map<String, dynamic>.from(bestRef);
  final others = results
      .where((r) => r != bestRef && publishSameWork(r, bestRef))
      .toList();

  String? firstText(String key) {
    final v = merged[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    for (final r in others) {
      final x = r[key];
      if (x is String && x.trim().isNotEmpty) return x.trim();
    }
    return null;
  }

  for (final k in const [
    'cover_url',
    'banner_url',
    'summary',
    'developer',
    'release_date',
    'original_title',
    'platform',
  ]) {
    final v = firstText(k);
    if (v != null) merged[k] = v;
  }

  num? firstNum(String key) {
    final v = merged[key];
    if (v is num && v > 0) return v;
    for (final r in others) {
      final x = r[key];
      if (x is num && x > 0) return x;
    }
    return null;
  }

  final rating = firstNum('rating');
  if (rating != null) merged['rating'] = rating;
  final votes = firstNum('vote_count');
  if (votes != null) merged['vote_count'] = votes;

  // 标签：仅在最佳结果没有标签时才用其他源（避免标签膨胀）
  final bestTags = merged['tags'];
  if (bestTags is! List || bestTags.isEmpty) {
    for (final r in others) {
      final t = r['tags'];
      if (t is List && t.isNotEmpty) {
        merged['tags'] = t;
        break;
      }
    }
  }

  // 截图：最佳结果优先，不足上限时从其他源补（去重，只收 http）
  final shots = <String>[];
  void collect(Object? v) {
    if (v is! List) return;
    for (final u in v) {
      final s = u.toString().trim();
      if (s.startsWith('http') && !shots.contains(s)) shots.add(s);
    }
  }

  collect(merged['screenshot_urls']);
  for (final r in others) {
    if (shots.length >= maxScreenshots) break;
    collect(r['screenshot_urls']);
  }
  merged['screenshot_urls'] = shots.take(maxScreenshots).toList();

  return merged;
}

class _PublishGameDialogState extends State<PublishGameDialog> {
  final _resKey = GlobalKey<UploadResourceDialogState>();

  /// 一键抓取返回的候选结果（添加页同款交互：抓取后列出各数据源的
  /// 结果卡片，由用户点选要采用哪个来源，点选后才回填表单与图片）。
  /// 按相关度排序：命中检索词身份的候选在前。
  List<Map<String, dynamic>> _scrapeResults = [];

  /// 用户点选的候选下标（-1 = 尚未选择）
  int _selectedResultIndex = -1;

  /// 正在应用所选候选（下载图片中），期间禁止切换卡片
  bool _applyingResult = false;

  /// 候选板块是否展开
  bool _resultsExpanded = true;

  final _titleCtrl = TextEditingController();
  final _jpCtrl = TextEditingController();
  final _enCtrl = TextEditingController();
  final _tcCtrl = TextEditingController();
  final _devCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _ratingCtrl = TextEditingController();
  final _voteCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  /// 上次抓取自动填充过的文本字段（键：jp/desc/dev/date/rating/votes），
  /// 再次抓取时允许覆盖（否则上次填错的值永远无法被纠正，2026-10-07 实机踩）
  final Set<String> _autoFilledFields = {};
  /// 用户手动编辑过的字段——抓取永不覆盖
  final Set<String> _humanEditedFields = {};
  /// 抓取填充进行中：抑制 controller listener 把自动填充误标为人工编辑
  /// （TextEditingController 的 listener 对程序赋值同样触发）
  bool _autoFilling = false;

  /// 给全部可抓取填充的文本框挂人工编辑监听。
  /// 只在 [installHumanEditListeners] 里记录， dispose 随 controller 销毁。
  void _installHumanEditListeners() {
    void mark(String key) {
      if (_autoFilling) return;
      _humanEditedFields.add(key);
      _autoFilledFields.remove(key);
    }

    _jpCtrl.addListener(() => mark('jp'));
    _descCtrl.addListener(() => mark('desc'));
    _devCtrl.addListener(() => mark('dev'));
    _dateCtrl.addListener(() => mark('date'));
    _ratingCtrl.addListener(() => mark('rating'));
    _voteCtrl.addListener(() => mark('votes'));
  }

  final Set<String> _tags = {};
  String? _coverPath;

  /// 横幅封面（可选，2026-10-05）：横向高清封面，用于大图场景
  /// （下载入库后作 BPM 背景/主页大图；探索库数据层 bannerUrl）
  String? _bannerPath;
  final List<String> _screenshots = [];
  String _metaSource = '';

  /// 0 = 游戏资料，1 = 上传资源
  int _step = 0;
  bool _fetching = false;

  /// 抓取/下载阶段的进度文案（图片下载较慢，按钮上直接显示进度）
  String _fetchStage = '';

  /// 本窗口上一轮抓取下载的临时图片目录（重复抓取时清理，避免 tmp 堆积）
  String? _lastMetaImageDir;

  bool _submitting = false;
  String? _error;

  /// 内置常用标签——**仅作兜底**：云端词表拉取失败时用。
  ///
  /// 2026-10-06 起不再作为硬编码白名单使用：`games.tags` 虽然是 PB select 字段，
  /// 但服务端 `tags_autovalues.pb.js` 会在提交时把新标签自动登记进集合取值表，
  /// 因此用户可以自由输入新标签；候选列表改由 `GamePublishService.fetchCloudTags`
  /// 从服务端 `/api/ct/game-tags` 动态拉取。
  static const List<String> _tagOptions = [
    '恋爱', '后宫', '纯爱', '拔作', '悬疑', '日常', '校园', 'key社', 'yuzi社',
    '废萌', '推理', '科幻', '催泪', '视觉小说', '轮回', '致郁', '猎奇', '胃痛',
    'NTR', '燃作', '鬼畜', '策略', '电波', '哲学', '艺术', '粉丝向', '人生',
    '恐怖', '惊悚', '末日', '虚无', '悲剧', '囚禁', '独立游戏', '模拟经营',
    '暴力', '奇幻', '黑色幽默', '黑暗', '乐队', '解密', '冒险', '十二神器',
    '伪娘', '重口味', 'Meta', '女仆', '高甜度', '竞技', '萌拔', '师生', '泣系',
    '都市', '青春', '萝莉', 'R18', '乡村', 'RPG', 'ACT', 'SLG', '像素', '医院',
    '家庭', '百合', '西式', '童话', '王道', '十二魔器', '友情', '同居', '血腥',
    '全年龄', '古典', '强奸', '中二', '剧情', '兄妹', '古代', '三国题材',
    '日本战国题材', '狂气', '治愈', '救赎', '民俗', '宿命', '甜恋', '妹系',
    '三角', '抉择', '伦理', '旅行', '修罗场', '青梅',
  ];

  /// 云端 `games.tags` 的当前合法取值，开窗时异步拉取（见 [_loadCloudTags]）。
  ///
  /// 服务端会在提交时把新标签自动登记进词表，所以这份列表只是**候选**，
  /// 不再是"只能从这里选"的硬约束。
  final List<String> _cloudTags = [];

  /// 标签候选 = 云端词表 + 内置兜底（去重）
  List<String> get _effectiveTagOptions =>
      <String>{..._cloudTags, ..._tagOptions}.toList();

  /// 拉取云端标签词表。
  ///
  /// 失败**静默**：回退到内置 [_tagOptions]，不阻断发布。
  Future<void> _loadCloudTags() async {
    final tags = await GamePublishService.fetchCloudTags();
    if (!mounted || tags.isEmpty) return;
    setState(() {
      _cloudTags
        ..clear()
        ..addAll(tags);
    });
  }

  static const int _maxScreenshots = 6;

  /// 标签上限（与云端 `games.tags` 的 maxSelect=14 对齐）
  static const int _maxTags = 14;

  /// 元数据截图并发下载数（一次抓 6 张时避免把连接池打满）
  static const int _metaImageConcurrency = 3;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _loadCloudTags();
    _installHumanEditListeners();
    final g = widget.editing;
    if (g == null) {
      _titleCtrl.text = widget.initialTitle;
      return;
    }
    _titleCtrl.text = g.title;
    _jpCtrl.text = g.originalTitle;
    _enCtrl.text = g.englishTitle;
    _tcCtrl.text = g.traditionalChineseTitle;
    _devCtrl.text = g.developer;
    _dateCtrl.text = g.releaseDate;
    _descCtrl.text = g.description;
    _metaSource = g.metaSource;
    if (g.rating != null && g.rating! > 0) {
      _ratingCtrl.text = g.rating!.toStringAsFixed(1);
    }
    if (g.voteCount != null && g.voteCount! > 0) {
      _voteCtrl.text = g.voteCount!.toString();
    }
    // 服务端会在提交时自动登记新标签，故不再按本地白名单过滤
    // （历史数据里已存在、但内置表没收录的标签也要原样回填）
    _tags.addAll(g.tags.take(14));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _jpCtrl.dispose();
    _enCtrl.dispose();
    _tcCtrl.dispose();
    _devCtrl.dispose();
    _dateCtrl.dispose();
    _ratingCtrl.dispose();
    _voteCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ==================== 骨架 ====================

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height - 96;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: DarkPalette.uploadWidth,
        maxHeight: height.clamp(320.0, 2400.0),
      ),
      child: DarkShell(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              Flexible(
                child: _step == 0
                    ? SingleChildScrollView(
                        clipBehavior: Clip.hardEdge,
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                        child: _buildGameForm(),
                      )
                    : SingleChildScrollView(
                        clipBehavior: Clip.hardEdge,
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                        child: UploadResourceDialog(
                          key: _resKey,
                          embedded: true,
                          gameTitle: _titleCtrl.text.trim(),
                          onSubmit: _doPublish,
                        ),
                      ),
              ),
              _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 18, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? '编辑作品资料' : '发布 Galgame',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE2E2E7),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isEditing
                      ? '修改后重新进入审核队列。已通过审核的作品不能再修改。'
                      : '探索库中还没有这部作品，提交后将连同资源一起送审，通过后进入探索库。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DarkPalette.textMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (!_isEditing)
                  Row(
                    children: [
                      _stepPill(0, '① 游戏资料'),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right_rounded,
                          size: 15, color: DarkPalette.textDim),
                      const SizedBox(width: 6),
                      _stepPill(1, '② 上传资源'),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DarkCloseButton(onTap: _handleClose, size: 26),
        ],
      ),
    );
  }

  Widget _stepPill(int index, String label) {
    final active = _step == index;
    final done = _step > index;
    final color = active
        ? DarkPalette.primaryBlue
        : (done ? DarkPalette.green : DarkPalette.textDim);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(active ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(active ? 0.5 : 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color: color,
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
      child: Row(
        children: [
          DarkGhostButton(
            label: '取消',
            onTap: _submitting ? null : _handleClose,
            foreground: const Color(0xFFD5D5DC),
            fontSize: 13,
          ),
          const Spacer(),
          if (_isEditing)
            DarkPrimaryButton(
              label: '保存修改',
              busy: _submitting,
              onTap: _saveEdit,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            )
          else if (_step == 0) ...[
            DarkPrimaryButton(
              label: '下一步',
              onTap: _handleNext,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            ),
          ] else ...[
            DarkGhostButton(
              label: '上一步',
              onTap: _submitting ? null : () => setState(() => _step = 0),
              foreground: const Color(0xFFD5D5DC),
              fontSize: 13,
            ),
            const SizedBox(width: 6),
            DarkGhostButton(
              label: '仅提交作品',
              onTap: _submitting ? null : _publishGameOnly,
              foreground: DarkPalette.textMuted,
              fontSize: 12,
            ),
            const SizedBox(width: 6),
            DarkPrimaryButton(
              label: '提交发布',
              busy: _submitting,
              onTap: _submitResource,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            ),
          ],
        ],
      ),
    );
  }

  // ==================== 第 2 步：游戏资料 ====================

  Widget _buildGameForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        _metaBar(),
        const SizedBox(height: 12),
        // 候选数据源板块（添加页同款交互）：一键抓取后列出各数据源结果，
        // 用户点选后才回填表单与图片（2026-10-07 重构，替代旧的自动择优填充）
        _buildScrapeSection(),
        const SizedBox(height: 14),
        // 2026-10-02 UI 优化（二次调整，用户拍板）：左侧封面 + 右侧「游戏名
        // 输入区」整体 —— 主名 / 日语原名 / 英语名 / 繁中名同属游戏名，归组
        // 为一个竖排输入区（原日/英/繁散在封面下方两行，视觉割裂）；封面
        // 高度随输入区撑满，加大预览面积。点击卡片选图 → 直接预览 → 右上角
        // 删除；封面**必选**（新建模式；编辑模式不强制、未重选则保留原封面）。
        // ⚠️ 2026-10-07：移除 IntrinsicHeight（封面改固定高 280）。诊断快照
        // 证实多行 TextField 内容被画到表单顶部（局部重绘 damage 错位），
        // IntrinsicHeight + 同帧文本变更的组合是主要嫌疑，改用固定高度规避。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _coverPickerCard(),
            const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    DarkField(
                      label: '游戏名称',
                      required: true,
                      helper: '即探索库卡片上的中文标题',
                      child: DarkTextInput(controller: _titleCtrl, hint: '例如 千恋＊万花'),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '日语原名（可选）',
                      // hint 留空：此前用「千恋＊万花」当示例，灰色 hint 与
                      // 真实填充值在截图里无法区分，误导排障（2026-10-07）
                      child: DarkTextInput(controller: _jpCtrl, hint: ''),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '英语名（可选）',
                      child: DarkTextInput(controller: _enCtrl, hint: ''),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '繁中名（可选）',
                      child: DarkTextInput(controller: _tcCtrl, hint: ''),
                    ),
                  ],
                ),
              ),
          ],
        ),
        // 横幅封面（可选，2026-10-05）：横向高清封面，下载入库后用于
        // BPM 背景 / 主页大图等横版场景；缺失时那些场景自动回退竖封面。
        _bannerPickerCard(),
        const SizedBox(height: 18),
        DarkField(
          label: '游戏简介（可选）',
          helper: '支持 Markdown',
          child: DarkTextInput(controller: _descCtrl, hint: '', maxLines: 4),
        ),
        const SizedBox(height: 18),
        DarkField(
          label: '会社（可选）',
          child: DarkTextInput(controller: _devCtrl, hint: '例如 YUZUSOFT'),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DarkField(
                label: '评分（可选）',
                helper: '0 – 10',
                child: DarkTextInput(controller: _ratingCtrl, hint: '8.6'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DarkField(
                label: '评分人数（可选）',
                child: DarkTextInput(controller: _voteCtrl, hint: '1234'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        DarkField(
          label: '发售日期（可选）',
          helper: '格式 YYYY-MM-DD，例如 2016-07-29',
          child: DarkTextInput(controller: _dateCtrl, hint: '2016-07-29'),
        ),
        const SizedBox(height: 18),
        DarkMultiSelectField(
          label: '标签（可选，最多 14 个，可自定义）',
          options: _effectiveTagOptions,
          selected: _tags,
          allowCustom: true,
          customHint: '输入新标签，回车添加',
          onCustomAdded: (s) {
            if (!_cloudTags.contains(s)) setState(() => _cloudTags.add(s));
          },
          onChanged: (v) => setState(() {
            _tags
              ..clear()
              ..addAll(v.length > 14 ? v.take(14) : v);
          }),
        ),
        const SizedBox(height: 18),
        // 封面的「选择文件」行已由上方预览卡取代（点击卡片即选图）；
        // 截图保留在最底部，选中后立即缩略图预览（与「添加」页一致）。
        _filePicker(
          label: '游戏截图（可选）',
          helper: '最多 $_maxScreenshots 张',
          value: _screenshots.isEmpty ? '未选择' : '已选 ${_screenshots.length} 张',
          onTap: _pickScreenshots,
          onClear: _screenshots.isEmpty
              ? null
              : () => setState(_screenshots.clear),
        ),
        if (_screenshots.isNotEmpty) ...[
          const SizedBox(height: 10),
          _screenshotPreviewStrip(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 18),
          _errorBox(),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  /// 图片文件失效时的显式占位（此前静默空白，无法诊断——2026-10-07 实机踩）
  Widget _imageLoadFailed() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined,
              size: 20, color: DarkPalette.textDim),
          const SizedBox(height: 4),
          Text('图片加载失败',
              style: TextStyle(fontSize: 10, color: DarkPalette.textDim)),
        ],
      ),
    );
  }

  /// 封面预览卡（宽 148，高度随右侧名字输入区撑满 —— 2026-10-02 用户拍板
  /// 加大预览面积；配色适配本窗口的深色面 base）：未选图 = 「添加封面（必选）」
  /// 占位；已选 = 直接预览 + 右上角删除按钮。
  Widget _coverPickerCard() {
    final has = _coverPath != null;
    return GestureDetector(
      onTap: _pickCover,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 148,
          // 固定高度（原为 IntrinsicHeight 撑满右侧名字列，2026-10-07 改固定
          // 值规避多行输入框重排引发的渲染错位，约等于四行名字字段的高度）
          height: 280,
          decoration: BoxDecoration(
            color: const Color(0xFF23232A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (has)
                // 2026-10-07：改回普通 Image.file（原用 NsfwImage）。
                // 原因①抓取下载的新图必然「未判定」，按 fail-closed 规则立即
                // 进 ImageFiltered 模糊层，预览自己的图被打码反而无法核对；
                // 原因②模糊合成层 + 同帧多 TextField 填文本在 Windows 上
                // 实测出现下层内容错位绘制（真机截图，见 features 档案）。
                // 上传后的展示端打码由探索库自身负责，与发布预览无关。
                Image.file(
                  File(_coverPath!),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 320,
                  errorBuilder: (_, __, ___) => _imageLoadFailed(),
                )
              else
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          size: 22, color: DarkPalette.textDim),
                      const SizedBox(height: 6),
                      Text(
                        '添加封面',
                        style: const TextStyle(
                          fontSize: 11,
                          color: DarkPalette.textDim,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '（必选）',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: DarkPalette.yellow.withOpacity(0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              if (has)
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => setState(() => _coverPath = null),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 13, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横幅封面选择卡（2026-10-05）：全宽横版卡（高 88，约 2.2:1），
  /// 交互语言与 [_coverPickerCard] 一致——点击选图、已选直接预览、
  /// 右上角删除。可选字段，不填则下载入库后大图场景回退竖封面。
  Widget _bannerPickerCard() {
    final has = _bannerPath != null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GestureDetector(
        onTap: _pickBanner,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: 88,
            decoration: BoxDecoration(
              color: const Color(0xFF23232A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (has)
                  // 2026-10-07：与封面卡同理由改回普通 Image.file（见上方注释）
                  Image.file(
                    File(_bannerPath!),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    cacheWidth: 640,
                    errorBuilder: (_, __, ___) => _imageLoadFailed(),
                  )
                else
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.panorama_wide_angle_outlined,
                            size: 20, color: DarkPalette.textDim),
                        const SizedBox(width: 8),
                        Text(
                          '添加横幅封面（可选）',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: DarkPalette.textDim,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '横版大图，用于 BPM 背景 / 主页大图',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: DarkPalette.textDim.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (has)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => setState(() => _bannerPath = null),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 13, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 截图缩略图预览条：每张 96×54（16:9），右上角单张删除
  Widget _screenshotPreviewStrip() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < _screenshots.length; i++)
          _screenshotThumb(i),
      ],
    );
  }

  Widget _screenshotThumb(int index) {
    final path = _screenshots[index];
    return Container(
      width: 96,
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFF23232A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 2026-10-07：与封面卡同理由改回普通 Image.file（预览自己的
          // 临时截图无需 NSFW 防护，且避开模糊合成层错位问题）
          Image.file(
            File(path),
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            cacheWidth: 192,
            errorBuilder: (_, __, ___) => _imageLoadFailed(),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => setState(() => _screenshots.removeAt(index)),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.close_rounded,
                    size: 11, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaBar() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            '可先一键抓取：抓取后从下方来源卡片中选择数据，文字与图片会自动填入。',
            style: TextStyle(
              fontSize: 11.5,
              color: DarkPalette.textDim.withOpacity(0.95),
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(width: 10),
        DarkPrimaryButton(
          label: _fetching ? (_fetchStage.isEmpty ? '抓取中…' : _fetchStage)
              : '一键抓取元数据',
          busy: _fetching,
          onTap: _fetchMetadata,
          background: const Color(0xFF23232A),
          foreground: DarkPalette.textSecondary,
          icon: const Icon(Icons.auto_awesome_rounded),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          radius: 9,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ],
    );
  }

  Widget _filePicker({
    required String label,
    required String helper,
    required String value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return DarkField(
      label: label,
      helper: helper,
      trailing: onClear == null
          ? null
          : GestureDetector(
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.close_rounded,
                    size: 13, color: DarkPalette.textDim),
              ),
            ),
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DarkPalette.radiusField),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_open_rounded,
                    size: 14, color: DarkPalette.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: value == '未选择'
                          ? DarkPalette.placeholder
                          : DarkPalette.textPrimary,
                    ),
                  ),
                ),
                const Text(
                  '选择文件',
                  style: TextStyle(fontSize: 11, color: DarkPalette.textDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: DarkPalette.tipCardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DarkPalette.tipCardBorder, width: 0.8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 14, color: DarkPalette.tipCardBorder),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFFFFB3C8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 交互 ====================

  void _handleClose() => widget.onClose?.call();

  /// 编辑模式：保存修改（`updateMyGame` 只发用户可写字段，
  /// `origin` / `owner` / `has_official` 一律不传）。
  /// 「编辑中/已驳回」状态保存时一并重新提交审核（服务端 v6 白名单放行）。
  Future<void> _saveEdit() async {
    final g = widget.editing;
    if (g == null || _submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await GamePublishService.updateMyGame(
        g.id,
        title: _titleCtrl.text,
        originalTitle: _jpCtrl.text,
        englishTitle: _enCtrl.text,
        traditionalChineseTitle: _tcCtrl.text,
        description: _descCtrl.text,
        developer: _devCtrl.text,
        rating: double.tryParse(_ratingCtrl.text.trim()),
        voteCount: int.tryParse(_voteCtrl.text.trim()),
        releaseDate: _dateCtrl.text,
        tags: _tags.toList(),
        metaSource: _metaSource,
        resubmit: g.isReviewEditing || g.isReviewRejected,
        // 编辑模式：重选了横幅才传（不传即保留线上原横幅，同封面的语义）
        bannerFilePath: _bannerPath,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String? _validateGameForm() {
    if (_titleCtrl.text.trim().isEmpty) return '请填写游戏名称';
    // 封面必选（2026-10-02）：仅新建发布强制；编辑模式未重选封面时
    // 保留线上原封面（updateMyGame 不传 coverFilePath 即不改）。
    if (!_isEditing && _coverPath == null) return '请上传封面图';
    final d = _dateCtrl.text.trim();
    if (d.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) {
      return '发售日期格式应为 YYYY-MM-DD';
    }
    final r = _ratingCtrl.text.trim();
    if (r.isNotEmpty) {
      final v = double.tryParse(r);
      if (v == null || v < 0 || v > 10) return '评分需为 0 – 10 之间的数字';
    }
    final n = _voteCtrl.text.trim();
    if (n.isNotEmpty && int.tryParse(n) == null) return '评分人数需为整数';
    return null;
  }

  void _handleNext() {
    final err = _validateGameForm();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  Future<void> _pickCover() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final p = res?.files.isNotEmpty == true ? res!.files.first.path : null;
      if (p != null && mounted) setState(() => _coverPath = p);
    } catch (e) {
      if (mounted) setState(() => _error = '选择封面失败：$e');
    }
  }

  Future<void> _pickBanner() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final p = res?.files.isNotEmpty == true ? res!.files.first.path : null;
      if (p != null && mounted) setState(() => _bannerPath = p);
    } catch (e) {
      if (mounted) setState(() => _error = '选择横幅封面失败：$e');
    }
  }

  Future<void> _pickScreenshots() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (res == null || !mounted) return;
      setState(() {
        for (final f in res.files) {
          if (f.path == null) continue;
          if (_screenshots.length >= _maxScreenshots) break;
          if (!_screenshots.contains(f.path)) _screenshots.add(f.path!);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '选择截图失败：$e');
    }
  }

  /// 一键抓取元数据（复用「添加页」同一入口 [MetadataFetcher.fetchGame]）
  ///
  /// 2026-10-07 重构为「候选数据源选择」模式（与添加页一致）：抓取**不再
  /// 自动填充**，而是把各数据源的结果排好序列出，由用户点选采用哪个来源。
  /// 抓取时只做检索，图片下载移到点选后（见 [_selectCandidate]）。
  Future<void> _fetchMetadata() async {
    final name = _titleCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请先填写游戏名称，再抓取元数据');
      return;
    }
    setState(() {
      _fetching = true;
      _fetchStage = '检索中…';
      _error = null;
    });
    try {
      final list = await MetadataFetcher.fetchGame(name);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _fetching = false;
          _fetchStage = '';
          _error = '未找到匹配的元数据，可手动填写';
        });
        return;
      }
      // 相关度排序：命中检索词身份（名字集含归一化检索词）的候选在前，
      // 同组内按字段完整度降序，用户第一眼看到的就是最可能的目标。
      final key = TitleCleaner.normalizeForCompare(name);
      int score(Map<String, dynamic> r) =>
          (publishIdentityKeysOf(r).contains(key) ? 100 : 0) +
          publishCompletenessScore(r);
      final sorted = [...list]..sort((a, b) => score(b).compareTo(score(a)));
      setState(() {
        _fetching = false;
        _fetchStage = '';
        _scrapeResults = sorted;
        _selectedResultIndex = -1;
        _resultsExpanded = true;
      });
      AppSnackBar.success(
        context,
        '已找到 ${sorted.length} 条结果，请点击卡片选择要采用的数据源',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _fetchStage = '';
        _error = '元数据抓取失败：$e';
      });
    }
  }

  /// 用户点选了某个候选数据源卡片 → 采用该来源回填。
  ///
  /// 与添加页 [selectScrapeResult] 同语义：以所选结果为主，同作品的其它
  /// 来源只补缺失字段（[mergeForPublishMetadata] 的 `base` 参数）。
  /// 拆帧纪律：选中态先渲染一帧 → 文本赋值（无 setState）→ 标签/来源单独
  /// setState → 图片逐段下载逐帧 setState，避免同帧大改引发重排错乱。
  Future<void> _selectCandidate(int index) async {
    if (_applyingResult ||
        index < 0 ||
        index >= _scrapeResults.length) {
      return;
    }
    final selected = _scrapeResults[index];
    setState(() {
      _selectedResultIndex = index;
      _applyingResult = true;
      _error = null;
    });
    // 等选中态这一帧画完再开始填内容
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final merged = mergeForPublishMetadata(
      _scrapeResults,
      maxScreenshots: _maxScreenshots,
      base: selected,
    );
    final filled = _applyMetadata(merged);
    if (!mounted) return;
    _setStage('下载图片…');
    final (imgFilled, imgMissing) = await _applyMetadataImages(merged);
    if (!mounted) return;
    setState(() {
      _applyingResult = false;
      _fetchStage = '';
    });

    final all = <String>[...filled, ...imgFilled];
    final msg = StringBuffer();
    if (all.isNotEmpty) msg.write('已填充：${all.join('、')}');
    if (imgMissing.isNotEmpty) {
      if (msg.isNotEmpty) msg.write('；');
      msg.write('未获取到：${imgMissing.join('、')}');
    }
    AppSnackBar.success(
      context,
      msg.isEmpty ? '已采用该来源数据，请核对后继续' : msg.toString(),
    );
  }

  /// 候选数据源板块：抓取后显示，点卡片采用对应来源
  Widget _buildScrapeSection() {
    if (_scrapeResults.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D23),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DarkPalette.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.source_outlined,
                  size: 14, color: DarkPalette.textMuted),
              const SizedBox(width: 6),
              Text(
                '元数据来源（${_scrapeResults.length}）',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: DarkPalette.textLabel,
                ),
              ),
              if (_applyingResult) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        DarkPalette.primaryBlue),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _fetchStage.isEmpty ? '应用中…' : _fetchStage,
                  style: const TextStyle(
                      fontSize: 10.5, color: DarkPalette.textMuted),
                ),
              ],
              const Spacer(),
              InkWell(
                onTap: () =>
                    setState(() => _resultsExpanded = !_resultsExpanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    _resultsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: DarkPalette.textMuted,
                  ),
                ),
              ),
            ],
          ),
          if (_resultsExpanded) ...[
            const SizedBox(height: 6),
            Text(
              '点击卡片采用该来源：文字自动填入下方表单，封面 / 横幅 / 截图下载后进入预览区。'
              '换选其它卡片会覆盖上次自动填充的内容（手动编辑过的字段不受影响）。',
              style: TextStyle(
                fontSize: 10.5,
                color: DarkPalette.textDim.withOpacity(0.9),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            // 自适应多列（窄 1 列 / 宽 2 列），与添加页元数据匹配区同思路
            LayoutBuilder(builder: (context, c) {
              const gap = 8.0;
              const minCardWidth = 280.0;
              final columns =
                  (c.maxWidth / (minCardWidth + gap)).floor().clamp(1, 3);
              final cardWidth = (c.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < _scrapeResults.length; i++)
                    SizedBox(
                        width: cardWidth, child: _buildCandidateCard(i)),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }

  /// 单张候选数据源卡片（平台徽章 + 封面缩略 + 标题 + 发售日）
  Widget _buildCandidateCard(int index) {
    final r = _scrapeResults[index];
    final selected = index == _selectedResultIndex;
    final busy = selected && _applyingResult;
    final title = (r['game_name'] ?? r['title'] ?? '未知作品').toString();
    final ot = (r['original_title'] as String?)?.trim() ?? '';
    final date = (r['release_date'] as String?)?.trim() ?? '';
    final badge = resolvePlatformBadge(r['platform']);
    final pid = (r['platform_id'] ?? '').toString();

    return GestureDetector(
      onTap: _applyingResult ? null : () => _selectCandidate(index),
      child: MouseRegion(
        cursor: _applyingResult ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? DarkPalette.primaryBlue.withOpacity(0.08)
                : const Color(0xFF23232A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? DarkPalette.primaryBlue : DarkPalette.fieldBorder,
              width: selected ? 1.4 : 0.8,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCandidateThumb(r),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        PlatformBadgeWidget(badge: badge),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            pid,
                            style: const TextStyle(
                              fontSize: 10,
                              color: DarkPalette.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: DarkPalette.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (ot.isNotEmpty && ot != title)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          ot,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: DarkPalette.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      date.isNotEmpty ? '$date 发行' : '发售日未知',
                      style: TextStyle(
                        fontSize: 10,
                        color: DarkPalette.textMuted.withOpacity(0.85),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(4),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          DarkPalette.primaryBlue),
                    ),
                  ),
                )
              else if (selected)
                const Icon(Icons.check_circle_rounded,
                    size: 15, color: DarkPalette.green),
            ],
          ),
        ),
      ),
    );
  }

  /// 候选封面缩略（网络 URL 直接渲染，缩到 46×62；不用 NsfwImage——
  /// 其 ImageFiltered 模糊层在本窗口实测会诱发合成错位，见封面卡注释）
  Widget _buildCandidateThumb(Map<String, dynamic> r) {
    final url = ((r['cover_url'] as String?) ?? '').trim();
    return Container(
      width: 46,
      height: 62,
      decoration: BoxDecoration(
        color: const Color(0xFF23232A),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.startsWith('http')
          ? CachedNetworkImage(
              cacheManager: PortableImageCacheManager(),
              imageUrl: url,
              width: 46,
              height: 62,
              fit: BoxFit.cover,
              memCacheWidth: 92,
              memCacheHeight: 124,
              placeholder: (context, url) => const Center(
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        DarkPalette.textMuted),
                  ),
                ),
              ),
              errorWidget: (context, url, error) => const Center(
                child: Icon(Icons.image_outlined,
                    size: 14, color: DarkPalette.textMuted),
              ),
            )
          : const Center(
              child: Icon(Icons.image_outlined,
                  size: 14, color: DarkPalette.textMuted),
            ),
    );
  }

  /// 回填文本字段：**只填空**（已手写的保留，2026-10-06 拍板）。
  ///
  /// 返回本次实际填上的字段名，供结果提示使用。
  ///
  /// 2026-10-07 拆帧：TextField 自行监听 controller，文本赋值**不需要**也
  /// 不应包进 setState——此前 6 个 controller 同帧批量赋值 + 表单结构重建
  /// + IntrinsicHeight 全表单重排挤在一帧，是抓取后渲染错乱的诱因之一。
  List<String> _applyMetadata(Map<String, dynamic> m) {
    final filled = <String>[];

    // ---- 文本：直接赋 controller（无 setState，TextField 自行重绘）----
    // 可填充 = 该框当前为空 || 上次也是抓取填的（可覆盖纠正）；
    // 用户手动编辑过的字段永不覆盖（_humanEditedFields）。
    bool canFill(String key, TextEditingController c) {
      if (_humanEditedFields.contains(key)) return false;
      return c.text.trim().isEmpty || _autoFilledFields.contains(key);
    }

    _autoFilling = true;
    try {
      final jp = (m['original_title'] as String?)?.trim() ?? '';
      if (jp.isNotEmpty && canFill('jp', _jpCtrl)) {
        _jpCtrl.text = jp;
        _autoFilledFields.add('jp');
        filled.add('原名');
      }

      final summary = (m['summary'] as String?)?.trim() ?? '';
      if (summary.isNotEmpty && canFill('desc', _descCtrl)) {
        _descCtrl.text = summary;
        _autoFilledFields.add('desc');
        filled.add('简介');
      }

      final dev = (m['developer'] as String?)?.trim() ?? '';
      if (dev.isNotEmpty && canFill('dev', _devCtrl)) {
        _devCtrl.text = dev;
        _autoFilledFields.add('dev');
        filled.add('开发商');
      }

      final rd = (m['release_date'] as String?)?.trim() ?? '';
      final norm = _normalizeDate(rd);
      if (norm.isNotEmpty && canFill('date', _dateCtrl)) {
        _dateCtrl.text = norm;
        _autoFilledFields.add('date');
        filled.add('发售日');
      }

      final rating = m['rating'];
      if (rating is num &&
          rating > 0 &&
          canFill('rating', _ratingCtrl)) {
        _ratingCtrl.text = rating.toDouble().toStringAsFixed(1);
        _autoFilledFields.add('rating');
        filled.add('评分');
      }
      final votes = m['vote_count'];
      if (votes is num && votes > 0 && canFill('votes', _voteCtrl)) {
        _voteCtrl.text = votes.toInt().toString();
        _autoFilledFields.add('votes');
        filled.add('投票数');
      }
    } finally {
      _autoFilling = false;
    }

    // ---- 状态：标签与来源字段影响表单结构，单独一帧 setState ----
    var tagsChanged = false;
    // 标签只在用户一个都没选时填（避免抓取结果冲掉手动挑选的标签）
    final rawTags = m['tags'];
    if (rawTags is List && _tags.isEmpty) {
      for (final t in rawTags) {
        if (_tags.length >= _maxTags) break;
        final s = t.toString().trim();
        // 服务端会在提交时自动登记新标签，无需再按本地白名单过滤；
        // 但空串必须丢掉（此前没判空，会往选中集里塞一个空标签）
        if (s.isNotEmpty) _tags.add(s);
      }
      tagsChanged = _tags.isNotEmpty;
      if (tagsChanged) filled.add('标签 ${_tags.length} 个');
    }
    final source = (m['platform'] as String?)?.trim() ?? '';
    if (source.isNotEmpty && source != _metaSource) {
      _metaSource = source;
      tagsChanged = true; // 复用同一个 setState
    }
    if (tagsChanged) setState(() {});
    return filled;
  }

  /// 下载封面 / 横幅 / 截图到临时目录并回填本地路径。
  ///
  /// 发布上传只接受本地文件路径，而抓取结果是网络 URL，因此必须先落盘。
  /// 复用统一服务 [CoverDownloadService]（缓存优先 + 重试 + 扩展名识别），
  /// 与「添加页」`game_detail_dialog._downloadCoverFromUrl` 同一口径。
  ///
  /// 返回 `(已填充, 未获取到)`。
  Future<(List<String>, List<String>)> _applyMetadataImages(
      Map<String, dynamic> m) async {
    final filled = <String>[];
    final missing = <String>[];

    final coverUrl = (m['cover_url'] as String?)?.trim() ?? '';
    final bannerUrl = (m['banner_url'] as String?)?.trim() ?? '';
    final shots = (m['screenshot_urls'] as List? ?? [])
        .map((e) => e.toString().trim())
        .where((s) => s.startsWith('http'))
        .take(_maxScreenshots)
        .toList();

    if (!coverUrl.startsWith('http') &&
        !bannerUrl.startsWith('http') &&
        shots.isEmpty) {
      return (filled, missing);
    }

    // 每轮抓取一个独立子目录。🔴 旧目录**不能现在删**：旧图此刻还在界面
    // 上显示（_coverPath 等仍指向旧目录），删了之后到新图 setState 之间的
    // 数秒下载窗口里，任何重建都会让 Image.file 重新加载已删除的文件 →
    // 图片区空白/加载失败（2026-10-07 实机踩）。改为本次下载完成、新路径
    // 生效之后（本函数尾部）再清理旧目录。
    final oldDir = _lastMetaImageDir;
    final dir = Directory(
        '${PathHelper.portableTmpDir}/publish_meta_${DateTime.now().millisecondsSinceEpoch}');
    try {
      await dir.create(recursive: true);
    } catch (e) {
      debugPrint('[PUBLISH] ⚠️ 临时目录创建失败: $e');
      return (filled, missing);
    }

    // ---- 封面（覆盖式：抓取的图像数据是用户主动要的）----
    if (coverUrl.startsWith('http')) {
      _setStage('下载封面…');
      final saved = await CoverDownloadService.instance.downloadCover(
        targetDir: dir.path,
        coverUrl: coverUrl,
        fileName: 'publish_cover',
      );
      if (saved != null) {
        if (mounted) setState(() => _coverPath = '${dir.path}/$saved');
        filled.add('封面');
      } else {
        missing.add('封面');
      }
    } else {
      missing.add('封面');
    }

    // ---- 横幅（可选；downloadBanner 内含 ≥1.15 宽高比校验，假横幅会被拒收）----
    if (bannerUrl.startsWith('http')) {
      _setStage('下载横幅…');
      final saved = await CoverDownloadService.instance.downloadBanner(
        targetDir: dir.path,
        bannerUrl: bannerUrl,
      );
      if (saved != null) {
        if (mounted) setState(() => _bannerPath = '${dir.path}/$saved');
        filled.add('横幅');
      } else {
        missing.add('横幅');
      }
    } else {
      missing.add('横幅');
    }

    // ---- 截图（并发 3，最多 [_maxScreenshots] 张）----
    if (shots.isNotEmpty) {
      final paths = <String>[];
      for (var i = 0; i < shots.length; i += _metaImageConcurrency) {
        final batch = shots.skip(i).take(_metaImageConcurrency).toList();
        _setStage('下载截图 ${i + 1}/${shots.length}…');
        final saved = await Future.wait(batch.map((u) =>
            CoverDownloadService.instance.downloadCover(
                targetDir: dir.path,
                coverUrl: u,
                fileName: 'publish_shot')));
        for (final n in saved) {
          if (n != null) paths.add('${dir.path}/$n');
        }
      }
      if (paths.isNotEmpty) {
        if (mounted) {
          setState(() {
            _screenshots
              ..clear()
              ..addAll(paths);
          });
        }
        filled.add('截图 ${paths.length} 张');
      } else {
        missing.add('截图');
      }
    } else {
      missing.add('截图');
    }

    // ---- 收尾：新图路径已生效，此刻才能安全处理旧目录 ----
    final gotAny = filled.isNotEmpty;
    if (gotAny) {
      // 显示已切到新目录 → 删旧目录不伤及界面
      await _cleanupMetaDir(oldDir);
      _lastMetaImageDir = dir.path;
    } else {
      // 一张都没下成：保留旧图显示（旧目录继续持有），只删本次新建的空目录
      await _cleanupMetaDir(dir.path);
      _lastMetaImageDir = oldDir;
    }
    return (filled, missing);
  }

  void _setStage(String s) {
    if (mounted) setState(() => _fetchStage = s);
  }

  /// 清理抓取图片临时目录（仅在新图路径生效后调用，见 [_applyMetadataImages]）。
  ///
  /// 🔴 双重护栏：目录必须在 app storage 内（[PathHelper.isInsideAppStorage]，
  /// ADR-007），且路径必须带本窗口自己的 `publish_meta_` 标记，否则不动。
  Future<void> _cleanupMetaDir(String? d) async {
    if (d == null || d.isEmpty) return;
    if (!d.contains('publish_meta_')) return;
    if (!PathHelper.isInsideAppStorage(d)) return;
    try {
      final dir = Directory(d);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[PUBLISH] ⚠️ 临时目录清理失败: $e');
    }
  }


  /// 各数据源的日期格式不统一，统一成 `YYYY-MM-DD`（PB 字段是 text）
  static String _normalizeDate(String raw) {
    if (raw.isEmpty) return '';
    final m = RegExp(r'(\d{4})\D?(\d{1,2})?\D?(\d{1,2})?').firstMatch(raw);
    if (m == null) return '';
    final y = m.group(1)!;
    final mo = m.group(2);
    final d = m.group(3);
    if (mo == null) return y;
    final mm = mo.padLeft(2, '0');
    if (d == null) return '$y-$mm';
    return '$y-$mm-${d.padLeft(2, '0')}';
  }

  // ==================== 提交 ====================

  /// 第 3 步「提交发布」：先校验第 2 步，再把控制权交给资源表单
  /// （由它的 [UploadResourceDialogState.submit] 走统一校验与错误展示）
  Future<void> _submitResource() async {
    if (_submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() {
        _step = 0;
        _error = err;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _resKey.currentState?.submit();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 「仅提交作品」：作品先入库，资源稍后在【我的】补传（合法状态）
  Future<void> _publishGameOnly() async {
    if (_submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() {
        _step = 0;
        _error = err;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _createGame();
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.maybePop(true);
      AppSnackBar.success(context, '作品已提交，可在【我的】中继续补传资源');
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// 真正落库：`games` → `game_resources`
  Future<void> _doPublish(ResourceDraft draft) async {
    final game = await _createGame();

    try {
      await GameResourceService.createCommunityResource(
        gameId: game.id,
        url: draft.url,
        title: draft.title,
        fileSize: draft.fileSize,
        version: draft.version,
        linkType: draft.linkType,
        netdiskProvider: draft.netdiskProvider,
        extractCode: draft.extractCode,
        unzipCode: draft.unzipCode,
        note: draft.note,
        resourceTypes: draft.resourceTypes,
        languages: draft.languages,
        platforms: draft.platforms,
      );
    } catch (e) {
      // 不回滚作品：与官方作品「有作品无资源」同构，属合法状态
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.maybePop(true);
      AppSnackBar.warning(context, '作品已提交，但资源上传失败，可在【我的】中补传');
      return;
    }

    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.maybePop(true);
    AppSnackBar.success(context, '发布成功，审核通过后将进入探索库');
  }

  Future<GameModel> _createGame() {
    return GamePublishService.publishGame(
      title: _titleCtrl.text,
      originalTitle: _jpCtrl.text,
      englishTitle: _enCtrl.text,
      traditionalChineseTitle: _tcCtrl.text,
      description: _descCtrl.text,
      developer: _devCtrl.text,
      rating: double.tryParse(_ratingCtrl.text.trim()),
      voteCount: int.tryParse(_voteCtrl.text.trim()),
      releaseDate: _dateCtrl.text,
      tags: _tags.toList(),
      metaSource: _metaSource,
      coverFilePath: _coverPath,
      bannerFilePath: _bannerPath,
      screenshotPaths: List<String>.from(_screenshots),
    );
  }
}
