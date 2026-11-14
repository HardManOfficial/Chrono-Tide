import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/widgets/game_detail/publish_game_dialog.dart';

/// 发布窗「元数据抓取结果择优 + 字段级补齐」的回归测试。
///
/// 背景（2026-10-06）：发布窗的元数据回填此前**只取 `list.first` 且完全没用
/// `cover_url` / `banner_url` / `screenshot_urls`**，导致封面、横幅、截图
/// 永远填不进来；单源缺字段时连文本也缺。
/// 这里锁住修复后的行为：MIX 优先、按完整度择优、**同作品**字段级补齐。
///
/// 2026-10-07 补身份过滤：跨作品补齐会把《千恋＊万花》的英文名
/// 填进《缘之空》（真机踩坑），现只从 `publishSameWork` 为真的候选补。
void main() {
  Map<String, dynamic> src(
    String platform, {
    String cover = '',
    String banner = '',
    List<String> shots = const [],
    String summary = '',
    String developer = '',
    String release = '',
    num? rating,
    List<String> tags = const [],
    String originalTitle = '',
    String title = '',
  }) =>
      {
        'platform': platform,
        'cover_url': cover,
        'banner_url': banner,
        'screenshot_urls': shots,
        'summary': summary,
        'developer': developer,
        'release_date': release,
        'rating': rating,
        'tags': tags,
        'original_title': originalTitle,
        'title': title,
      };

  test('MIX 条目优先（即使另一个源字段看起来也全）', () {
    final vndb = src('VNDB', cover: 'https://a/1.jpg', summary: '简介');
    final mix = src('MIX源', cover: 'https://m/1.jpg');
    final best = pickPublishBestResult([vndb, mix]);
    expect(best['platform'], 'MIX源');
  });

  test('无 MIX 时按完整度打分（图片权重更高）', () {
    final rich = src('VNDB',
        cover: 'https://a/1.jpg',
        banner: 'https://a/b.jpg',
        shots: ['https://a/s1.jpg']);
    final poor = src('Steam', summary: '只有简介');
    expect(publishCompletenessScore(rich) > publishCompletenessScore(poor),
        isTrue);
    expect(pickPublishBestResult([poor, rich])['platform'], 'VNDB');
  });

  test('字段级补齐：最佳结果缺的字段从**同作品**其他源取', () {
    final best = src('VNDB',
        cover: 'https://a/1.jpg',
        rating: 8.0,
        originalTitle: 'ヨスガノソラ');
    final other = src('NextMoe',
        summary: '同作品源有简介',
        developer: 'Sphere',
        release: '2015-07-24',
        banner: 'https://b/banner.jpg',
        originalTitle: 'ヨスガノソラ');
    final merged = mergeForPublishMetadata([best, other]);

    expect(merged['cover_url'], 'https://a/1.jpg'); // 保留最佳结果的
    expect(merged['summary'], '同作品源有简介'); // 补齐
    expect(merged['developer'], 'Sphere');
    expect(merged['release_date'], '2015-07-24');
    expect(merged['banner_url'], 'https://b/banner.jpg');
    expect(merged['rating'], 8.0); // 已有的不被覆盖
  });

  test('异身份候选一律不补（真机踩坑：缘之空混入千恋＊万花）', () {
    final yosuga = src('VNDB',
        cover: 'https://a/yosuga.jpg',
        originalTitle: 'ヨスガノソラ',
        title: '缘之空');
    final senren = src('BGMS',
        title: '千恋＊万花',
        originalTitle: '千恋＊万花',
        banner: 'https://s/senren_banner.jpg',
        summary: '千恋万花的简介',
        developer: 'YUZUSOFT',
        shots: ['https://s/senren_shot.jpg'],
        tags: ['千恋万花']);

    // 无身份锚（文档化的旧行为）：字段最全的陌生作品赢得主结果
    expect(pickPublishBestResult([yosuga, senren])['platform'], 'BGMS');

    // 传入检索词后，身份锚锁定主结果；异身份字段宁缺勿抄
    final merged =
        mergeForPublishMetadata([yosuga, senren], queryHint: '缘之空');
    expect(merged['platform'], 'VNDB');
    // 缺的横幅/简介/开发商/截图/标签宁缺，也不能抄别的作品的
    expect(merged['banner_url'], '');
    expect(merged['summary'], '');
    expect(merged['developer'], '');
    expect((merged['screenshot_urls'] as List), isEmpty);
    expect((merged['tags'] as List), isEmpty);
    expect(merged['cover_url'], 'https://a/yosuga.jpg'); // 自己的保留
  });

  test('同作品判定：original_title 缺失时回退 title；都无法归一化则不补', () {
    // title 相同 → 同作品
    final a = src('A', title: 'Ginko Fic', cover: 'https://a/c.jpg');
    final b = src('B', title: 'ginko  fic', summary: '同作品的简介');
    final m1 = mergeForPublishMetadata([a, b]);
    expect(m1['summary'], '同作品的简介');

    // 双方都没有任何可归一化的名字 → 宁缺勿错
    final c = src('C', summary: '无名字源的简介');
    final d = src('D', cover: 'https://d/c.jpg');
    final m2 = mergeForPublishMetadata([c, d]);
    expect(m2['summary'], ''); // 不补
  });

  test('异身份候选不污染截图与标签', () {
    final best = src('VNDB',
        originalTitle: 'はつゆきさくら',
        shots: ['https://a/s1.jpg']);
    final stranger =
        src('KunGal', title: '紫影のソナーニル', shots: ['https://x/s1.jpg']);
    final merged =
        mergeForPublishMetadata([best, stranger], maxScreenshots: 6);
    expect((merged['screenshot_urls'] as List), ['https://a/s1.jpg']);
  });

  test('截图跨源补齐但不超过上限（同作品）', () {
    final best = src('VNDB',
        originalTitle: 'サクラノ詩',
        shots: ['https://a/s1.jpg']);
    final other = src('KunGal',
        originalTitle: 'サクラノ詩',
        shots: ['https://b/s1.jpg', 'https://b/s2.jpg']);
    final merged = mergeForPublishMetadata([best, other], maxScreenshots: 6);
    final shots = (merged['screenshot_urls'] as List).cast<String>();
    expect(shots, [
      'https://a/s1.jpg',
      'https://b/s1.jpg',
      'https://b/s2.jpg',
    ]);

    // 上限生效
    final many = src('A',
        originalTitle: 'わたしの ぽこった',
        shots: List.generate(10, (i) => 'https://x/$i.jpg'));
    final capped = mergeForPublishMetadata([many], maxScreenshots: 6);
    expect((capped['screenshot_urls'] as List).length, 6);

    // 去重（同作品）
    final dup = mergeForPublishMetadata(
        [
          many,
          src('B',
              originalTitle: 'わたしの ぽこった',
              shots: ['https://x/0.jpg', 'https://x/1.jpg'])
        ],
        maxScreenshots: 6);
    final dupList = (dup['screenshot_urls'] as List).cast<String>();
    expect(dupList.toSet().length, dupList.length);
  });

  test('非 http 的截图 URL 不收（脏数据兜底）', () {
    final m = src('VNDB', shots: ['', 'ftp://x/y.jpg', 'https://a/s1.jpg']);
    final merged = mergeForPublishMetadata([m]);
    expect(merged['screenshot_urls'], ['https://a/s1.jpg']);
  });

  test('空输入不炸', () {
    expect(mergeForPublishMetadata([]), isEmpty);
    expect(pickPublishBestResult([]), isEmpty);
  });

  test('base 参数：用户点选的来源优先于自动择优（2026-10-07 候选选择模式）', () {
    // 自动择优会选字段最全的 senren（完整度更高），但用户点选的是 yosuga
    final yosuga = src('VNDB',
        cover: 'https://a/yosuga.jpg',
        originalTitle: 'ヨスガノソラ',
        title: '缘之空');
    final senren = src('BGMS',
        title: '千恋＊万花',
        originalTitle: '千恋＊万花',
        cover: 'https://s/senren.jpg',
        summary: '千恋万花的简介',
        developer: 'YUZUSOFT',
        rating: 9.0);

    // 不传 base：自动择优（身份锚缺省时完整度最高者胜）
    final auto = mergeForPublishMetadata([yosuga, senren]);
    expect(auto['platform'], 'BGMS');

    // 传 base：以用户点选的 yosuga 为底；异身份字段宁缺勿抄
    final picked = mergeForPublishMetadata(
      [yosuga, senren],
      base: yosuga,
    );
    expect(picked['platform'], 'VNDB');
    expect(picked['cover_url'], 'https://a/yosuga.jpg');
    expect(picked['summary'], '');
    expect(picked['developer'], '');
    expect(picked['rating'], null);
  });
}
