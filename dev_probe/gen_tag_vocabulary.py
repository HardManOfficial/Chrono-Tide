# -*- coding: utf-8 -*-
"""
标签受控词表扩充生成器（P0 数据工程，一次性脚本）。
依据 docs/DEV/features/tag_vocabulary_expansion_plan.md 批准方案：
  1. 现有 97 概念原样保留（顺序/id/dim 不动），允许追加别名（VNDB 英文原名对齐）；
  2. 新增概念定义表（人工审阅：语义清晰、有检索价值才收，保守纪律）；
  3. 组合式吸收：「基名+主人公/男主角/女主角/配角」整标签并入基名概念（生成期展开，
     运行时仍是纯别名倒排，零模糊匹配）；
  4. 冲突断言：全部规范名+别名归一化后跨概念冲突必须为 0（对应 tag_vocabulary_test
     的数据自检）。
输出：覆盖 D:/CTLIB/assets/data/tag_vocabulary.json + 统计报告。
"""
import json, re, sys

ROOT = 'D:/CTLIB'
VOCAB = ROOT + '/assets/data/tag_vocabulary.json'
DIMS = ROOT + '/assets/data/tag_dimensions.json'
# VNDB 翻译表仅作生成器输入（瘦身 16c67f3 已从 assets 删除「零引用」资源，
# 现存档于 dev_probe/，运行时不引用）；tag_vocabulary.json 才是随包数据。
VNDB = ROOT + '/dev_probe/vndb_tags_zh_cn.json'
# NextMoe 全量标签目录（ROUND4 基准语料），由 fetch_nextmoe_tags.py 拉取存档
NEXTMOE = ROOT + '/dev_probe/nextmoe_tags_full.json'
TRANSLATOR = ROOT + '/lib/packages/luna_metadata_sdk/lib/services/tag_translator.dart'
REPORT = ROOT + '/dev_probe/vocab_expand_report.json'

# ---- 复刻 Dart normalizeTag（tag_vocabulary_store.dart:148-160）----
NOISE = {0x20,0x09,0x0A,0x0D,0x3000,0xB7,0x30FB,0x2C,0x3001,0x3002,0x2E,0x21,
         0x3F,0x7E,0x2D,0x2010,0x2013,0x2014,0x2015,0x5F,0x28,0x29,0x3014,
         0x3015,0x3010,0x3011,0x5B,0x5D,0x7B,0x7D,0x300C,0x300D,0x300E,0x300F,
         0x22,0x27,0x3A,0x3B,0x2A,0x23,0x40,0x26,0x2F,0x5C,0x7C}
def norm(s):
    out = []
    for ch in s.strip():
        c = ord(ch)
        if 0xFF01 <= c <= 0xFF5E: c -= 0xFEE0
        if c in NOISE: continue
        if 0x41 <= c <= 0x5A: c += 0x20
        out.append(chr(c))
    return ''.join(out)

# =========================================================================
# 新增概念定义表（人工审阅：候选池实标 + VNDB/DLsite 主流体系；宁缺毋滥）
# 格式: (id, 规范名, dim, [别名])
# =========================================================================
NEW = [
    # ---------------- adult（第 9 维：成人内容，与 age 正交） ----------------
    ('ad.paizuri', '乳交', 'adult', ['パイズリ', 'Paizuri', 'Titjob', '单人乳交', '双女性乳交']),
    ('ad.footjob', '足交', 'adult', ['足コキ', 'Footjob', '单人足交']),
    ('ad.handjob', '手交', 'adult', ['手コキ', 'Handjob', '单人手交', '双人手交', '哺乳手交']),
    ('ad.oral', '口交', 'adult', ['フェラチオ', 'フェラ', 'Fellatio', 'Blowjob', 'Oral Sex', 'クンニリングス', '舔阴', '口内射精', '单人阴茎口交', '口内射精口爆', '口爆', 'イラマチオ', 'Deepthroat']),
    ('ad.anal', '肛交', 'adult', ['アナルセックス', 'Anal Sex', 'アナル']),
    ('ad.sumata', '素股腿交', 'adult', ['素股', '腿交', '臀交', '尻コキ']),
    ('ad.nakadashi', '中出', 'adult', ['中出し', '膣内射精', 'Creampie', '内射', '内射中出']),
    ('ad.facial', '颜射', 'adult', ['顔射', 'Facial']),
    ('ad.gokkun', '吞精', 'adult', ['ゴックン', 'Swallowing Semen']),
    ('ad.masturbation', '自慰', 'adult', ['オナニー', '手淫', 'Masturbation']),
    ('ad.69', '69式', 'adult', ['69', '六九式']),
    ('ad.threesome', '3P', 'adult', ['3p做爱', '三人行', '三人做爱', '姐妹丼', '亲子丼', '母女丼', '母娘丼', 'Threesome', '双飞']),
    ('ad.groupsex', '群交', 'adult', ['乱交', 'Group Sex', '多人性行为']),
    ('ad.dp', '多重插入', 'adult', ['双重插入', '二穴挿入', '二穴同時挿入', 'DP']),
    ('ad.sm', 'SM', 'adult', ['BDSM', '虐恋', 'サディズム']),
    ('ad.bondage', '拘束捆绑', 'adult', ['拘束', '拘束具', '捆绑', 'ボンデージ', 'Bondage', '项圈', '奴隶项圈', '宠物项圈', '首輪']),
    ('ad.training', '调教', 'adult', ['調教', 'Training']),
    ('ad.toys', '成人玩具', 'adult', ['玩具', '跳蛋', '假阳具', '振动棒', ' Sex Toy', 'オナホール']),
    ('ad.tentacle', '触手', 'adult', ['触手', 'Tentacle', '触手奸']),
    ('ad.exhibitionism', '露出', 'adult', ['露出癖', 'Exhibitionism', '野外暴露', '露天']),
    ('ad.voyeurism', '偷拍盗撮', 'adult', ['盗撮', '偷拍', '偷窥', '窥视', 'Voyeurism']),
    ('ad.hypnosis', '催眠洗脑', 'adult', ['催眠', '洗脑', '洗脳', '催眠術', 'Mind Control', '精神控制']),
    ('ad.time_stop', '时间停止', 'adult', ['時間停止', '时间暂停', 'Time Stop']),
    ('ad.sleep_rape', '睡奸', 'adult', ['睡眠姦', 'Sleep Sex']),
    ('ad.rape', '强迫', 'adult', ['無理矢理', '强奸', '轮奸', '輪姦', 'レイプ', 'Rape', '逆强奸', '反向强奸', '凌辱', '侵犯']),
    ('ad.aphrodisiac', '催情药物', 'adult', ['媚药', '媚薬', '下药', '催情剂']),
    ('ad.ahogao', '啊嘿颜', 'adult', ['アヘ顔', 'あへ顔']),
    ('ad.pregnant', '怀孕', 'adult', ['妊娠', '分娩', '出産', '孕肚', 'ぼて腹']),
    ('ad.impregnation', '孕交', 'adult', ['孕ませ', '让怀孕']),
    ('ad.lactation', '母乳', 'adult', ['哺乳', '泌乳', '授乳', 'Lactation']),
    ('ad.virgin', '处女', 'adult', ['処女', 'Virgin', '破处', '全处女主角', '処女喪失']),
    ('ad.futanari', '扶她', 'adult', ['ふたなり', 'Futanari', '扶他']),
    ('ad.bath', '浴室场景', 'adult', ['浴室', '風呂', '共浴', '入浴', '洗澡', '浴室做爱']),
    ('ad.public_sex', '特殊场所性爱', 'adult', ['公共场所做爱', '野外做爱', '办公室做爱', '图书馆做爱', '交通工具内做爱', '卫生间做爱', '学校里做爱', '公园里做爱', '室外做爱', '坐姿做爱']),
    # ---------------- playstyle ----------------
    ('ps.action', '动作', 'playstyle', ['动作游戏', 'アクション', 'Action', 'アクションゲーム', 'ACT']),
    ('ps.shooting', '射击', 'playstyle', ['射击游戏', 'シューティング', 'Shooting', '弹幕']),
    ('ps.card_game', '卡牌', 'playstyle', ['カードゲーム', 'Card Game', '卡牌游戏']),
    ('ps.turn_based', '回合制战术', 'playstyle', ['回合制战术游戏']),
    ('ps.nurture', '养成育成', 'playstyle', ['育成', '養成', '育成ゲーム', '育成シミュレーション', '养成模拟', 'Raising Simulation']),
    ('ps.business', '经营模拟', 'playstyle', ['经营', '経営', '城市建设', '都市開発', '模拟经营']),
    ('ps.dating_sim', '恋爱模拟', 'playstyle', ['恋愛シミュレーション', '恋爱养成']),
    ('ps.survival', '生存', 'playstyle', ['サバイバル', 'Survival', '大逃杀', 'バトルロイヤル', 'Battle Royale']),
    ('ps.sandbox', '沙盒', 'playstyle', ['サンドボックス', 'Sandbox', '开放世界', 'オープンワールド', 'Open World']),
    ('ps.dungeon', '地牢迷宫', 'playstyle', ['地牢', '迷宮', '迷宫', '地下城', 'ダンジョン', 'ダンジョン探索']),
    ('ps.multiplayer', '多人游戏', 'playstyle', ['多人', 'マルチプレイ', 'Multiplayer', '联机']),
    ('ps.fmv', '互动电影', 'playstyle', ['交互式电影', 'Interactive Movie', 'FMV']),
    ('ps.bad_end', 'Bad End', 'playstyle', ['バッドエンド', 'BadEnd', '坏结局', 'BadEnd有剧情', 'Bad Ending']),
    ('ps.good_end', 'Good End', 'playstyle', ['グッドエンド', 'GoodEnd', '好结局', 'Good Ending']),
    ('ps.true_end', 'True End', 'playstyle', ['トゥルーエンド', 'TrueEnd', '真结局', '唯一真结局']),
    ('ps.game_over', 'GameOver', 'playstyle', ['ゲームオーバー', '游戏结束', 'GameOver结局']),
    ('ps.newgame_plus', '二周目', 'playstyle', ['二周目要素', '多周目', 'New Game+']),
    ('ps.flowchart', '流程图', 'playstyle', ['内置流程图', 'フローチャート', 'Flowchart', '路线图']),
    # ---------------- setting ----------------
    ('set.medieval', '中世纪', 'setting', ['中世', '中世纪欧洲', 'Medieval']),
    ('set.ancient_china', '古代中国', 'setting', ['中国古代', '三国时期', '三国']),
    ('set.sengoku', '战国时代', 'setting', ['戦国時代', '战国']),
    ('set.edo', '江户时代', 'setting', ['江戸時代', '江户', '幕府']),
    ('set.heian', '平安时代', 'setting', ['平安時代', '平安京']),
    ('set.bakumatsu', '幕末', 'setting', ['幕末维新']),
    ('set.taisho', '大正时代', 'setting', ['大正時代', '大正']),
    ('set.meiji', '明治时代', 'setting', ['明治時代', '明治']),
    ('set.19c', '19世纪', 'setting', ['19世紀', '19th Century']),
    ('set.20c', '20世纪', 'setting', ['20世紀', '20th Century', '1900年代', '1990年代']),
    ('set.21c', '21世纪', 'setting', ['21世紀', '2000年代', '2010年代', '2020年代']),
    ('set.roman', '古罗马', 'setting', ['ローマ', 'Ancient Rome', '罗马时代']),
    ('set.space', '宇宙太空', 'setting', ['宇宙', '太空', '宇宙飞船', '星际', '外太空', 'Space']),
    ('set.cyberpunk', '赛博朋克', 'setting', ['サイバーパンク', 'Cyberpunk']),
    ('set.virtual', '虚拟网络世界', 'setting', ['虚拟世界', '仮想世界', '网络世界', '互联网', '赛博空间']),
    ('set.prison', '监狱', 'setting', ['牢獄', '刑務所', '牢房']),
    ('set.mansion', '洋馆宅邸', 'setting', ['洋館', '宅邸', '庄园', '古堡', '城堡', '公館']),
    ('set.apartment', '公寓', 'setting', ['公寓楼', 'アパート', '集合住宅', '合租公寓']),
    ('set.dorm', '学校宿舍', 'setting', ['寄宿学校', '寄宿舍', '学生宿舍', '学生寮']),
    ('set.myth_china', '中国神话', 'setting', ['中国神話']),
    ('set.myth_japanese', '日本神话', 'setting', ['日本神話', '神道']),
    ('set.myth_greek', '希腊神话', 'setting', ['ギリシャ神話', 'オリンポス']),
    ('set.myth_norse', '北欧神话', 'setting', ['北欧神話', 'Norse']),
    ('set.myth_egypt', '埃及神话', 'setting', ['エジプト神話']),
    ('set.myth_cthulhu', '克苏鲁神话', 'setting', ['クトゥルフ神話', 'Cthulhu']),
    ('set.myth_celtic', '凯尔特神话', 'setting', ['ケルト神話']),
    ('set.myth_buddhist', '佛教神话', 'setting', ['仏教神話']),
    ('set.myth_christian', '基督教神话', 'setting', ['キリスト教神話']),
    # ---------------- tone ----------------
    ('tone.hot_blooded', '热血', 'tone', ['熱血', 'Hot-blooded', '燃作', '燃', '燃え', '燃系']),
    ('tone.heartwarming', '温馨', 'tone', ['ほのぼの', '暖心', 'Heartwarming']),
    ('tone.light', '轻松', 'tone', ['轻松愉快']),
    ('tone.grotesque', '猎奇', 'tone', ['グロテスク', 'グロ', 'Grotesque', '残酷描写', '血腥', 'R-18G', '血腥暴力', '暴力', '暴力描写']),
    ('tone.absurd', '荒诞', 'tone', ['不条理', 'Absurd']),
    ('tone.youth', '青春', 'tone', ['青年期']),
    # ---------------- theme ----------------
    ('th.love_comedy', '恋爱喜剧', 'theme', ['ラブコメ', 'Romantic Comedy', '恋爱闹剧']),
    ('th.teacher_love', '师生恋', 'theme', ['教师与学生恋爱']),
    ('th.master_servant', '主仆恋', 'theme', ['主仆', '主从关系', '主従']),
    ('th.marriage', '婚恋', 'theme', ['结婚', '結婚', '夫妇', '夫妻', '新婚', '婚姻', '再婚', '婚约']),
    ('th.age_gap', '忘年恋', 'theme', ['年の差', '年龄差', '年の差恋愛']),
    ('th.nonhuman_love', '人外恋', 'theme', ['异种恋', '跨种族恋爱', '异种族婚', '人外恋爱', '异种', '异种奸']),
    ('th.affair', '婚外情', 'theme', ['不倫', '出轨', '浮気', '外遇']),
    ('th.prostitution', '卖淫风俗', 'theme', ['風俗', '卖淫', '売春', '妓女', '援交', '包养', 'パパ活']),
    ('th.one_sided', '单恋', 'theme', ['片思い', '暗恋', '一见钟情']),
    ('th.first_love', '初恋', 'theme', ['初戀']),
    ('th.reunion', '重逢', 'theme', ['再会', '久别重逢']),
    ('th.parting', '离别', 'theme', ['別れ', '失恋', '分手']),
    ('th.bond', '羁绊', 'theme', ['絆', '情谊']),
    ('th.gay', '同性恋', 'theme', ['同性愛', '同志', '同性恋爱', 'LGBT', 'LGBTQ问题', '性少数']),
    ('th.bisexual', '双性恋', 'theme', ['两性恋', 'Bisexual']),
    # ---------------- element ----------------
    ('el.dream', '梦境', 'element', ['夢', '梦中世界', '白日梦', '一切只是梦境']),
    ('el.hallucination', '幻觉妄想', 'element', ['幻觉', '妄想', '幻覚', '错觉']),
    ('el.multiple_personality', '多重人格', 'element', ['分裂人格', '人格交换', '人格切换', '共享身体']),
    ('el.possession', '附身', 'element', ['憑依', '凭依', '被附身']),
    ('el.curse', '诅咒', 'element', ['呪い', '咒术', '诅咒']),
    ('el.contract', '契约', 'element', ['契約', '契约者']),
    ('el.misunderstanding', '误会', 'element', ['误解', '错过', 'すれ違い']),
    ('el.death_game', '死亡游戏', 'element', ['デスゲーム', '自相残杀']),
    ('el.escape', '逃亡', 'element', ['逃走', '被追杀', '追逃']),
    ('el.growth', '成长', 'element', ['成長']),
    ('el.war', '战争', 'element', ['戦争', '战火', '内战']),
    ('el.politics', '政治斗争', 'element', ['政治', '权力斗争', '陰謀', '政变']),
    ('el.family_feud', '家族纷争', 'element', ['财产纷争', '遗产继承', '遺産相続', '家庭间纷争']),
    ('el.treasure_hunt', '寻宝', 'element', ['宝探し', '财宝']),
    ('el.resurrection', '复活', 'element', ['復活', '起死回生']),
    ('el.transformation', '变身', 'element', ['変身', '变形', 'Transformation']),
    ('el.clone', '克隆', 'element', ['クローン', '克隆人', '复制人']),
    ('el.fate', '命运', 'element', ['運命', '宿命']),
    ('el.duel', '决斗', 'element', ['決闘', '对决']),
    ('el.kabedon', '壁咚', 'element', ['壁ドン']),
    ('el.summer', '夏天', 'element', ['夏', '夏季', '盛夏']),
    ('el.winter', '冬天', 'element', ['冬', '冬季', '大雪']),
    ('el.christmas', '圣诞节', 'element', ['クリスマス', 'Christmas']),
    ('el.valentine', '情人节', 'element', ['バレンタイン', 'Valentine']),
    ('el.halloween', '万圣节', 'element', ['ハロウィン', 'Halloween']),
    ('el.tanabata', '七夕', 'element', ['七夕节', 'タナバタ']),
    ('el.wedding', '婚礼', 'element', ['結婚式', '结婚典礼', '逃婚']),
    ('el.gamble', '赌博', 'element', ['ギャンブル', '赌局', '赌场', 'Casino']),
    ('el.undead', '不死', 'element', ['不老不死', '不死人', 'Undead']),
    # ---------------- character：发色（银发/金发已有） ----------------
    ('ch.black_hair', '黑发', 'character', ['黒髪', 'Black Hair']),
    ('ch.brown_hair', '褐发', 'character', ['茶髪', '棕发', 'Brown Hair']),
    ('ch.red_hair', '红发', 'character', ['赤髪', 'Red Hair']),
    ('ch.blue_hair', '蓝发', 'character', ['青髪', 'Blue Hair']),
    ('ch.pink_hair', '粉发', 'character', ['桃色髪', '粉红发', 'ピンク髪', 'Pink Hair']),
    ('ch.purple_hair', '紫发', 'character', ['紫髪', 'Purple Hair']),
    ('ch.green_hair', '绿发', 'character', ['緑髪', 'Green Hair']),
    # ---------------- character：发型（双马尾已有） ----------------
    ('ch.long_hair', '长发', 'character', ['长髪', 'Long Hair', '及地长发']),
    ('ch.short_hair', '短发', 'character', ['短髪', 'Short Hair', '波波头']),
    ('ch.ponytail', '马尾', 'character', ['ポニーテール', 'Ponytail', '单马尾']),
    ('ch.side_tail', '侧马尾', 'character', ['サイドテール', '侧单马尾']),
    ('ch.braid', '麻花辫', 'character', ['お下げ', '三つ編み', '辫子', '三股辫']),
    ('ch.curly_hair', '卷发', 'character', ['巻き髪', '波浪发', 'Curly Hair']),
    ('ch.hime_cut', '姬发式', 'character', ['姫カット', '公主切']),
    ('ch.ahoge', '呆毛', 'character', ['アホ毛', 'Ahoge']),
    ('ch.bun_hair', '发髻', 'character', ['お団子', '团子头', '双发髻']),
    # ---------------- character：眼/身体（巨乳/贫乳已有） ----------------
    ('ch.heterochromia', '异色瞳', 'character', ['オッドアイ', 'Heterochromia']),
    ('ch.blue_eyes', '蓝瞳', 'character', ['蓝色眼睛', '青い目']),
    ('ch.red_eyes', '红瞳', 'character', ['红色眼睛', '赤い目']),
    ('ch.golden_eyes', '金瞳', 'character', ['金色眼睛']),
    ('ch.bakunyuu', '爆乳', 'character', ['超巨乳', '巨大乳房', '爆乳主人公', '超乳', '超乳主人公', '超乳女主角']),
    ('ch.big_ass', '大屁股', 'character', ['デカ尻', '美臀', '丰臀']),
    ('ch.tall', '高挑', 'character', ['背が高い', '长腿', '高个子']),
    ('ch.small_stature', '娇小', 'character', ['小柄', '小只']),
    ('ch.muscular', '肌肉', 'character', ['筋肉', '肌肉女', '健美']),
    # ---------------- character：服饰 ----------------
    ('ch.seifuku', '水手服', 'character', ['セーラー服']),
    ('ch.gym_uniform', '体操服', 'character', ['ブルマ', '布鲁马', '运动服', '体育服', 'ジャージ']),
    ('ch.sukumizu', '学校泳衣', 'character', ['スク水', 'スクール水着', '竞泳泳衣']),
    ('ch.swimsuit', '泳装', 'character', ['水着', '泳衣', '比基尼', 'ビキニ']),
    ('ch.china_dress', '旗袍', 'character', ['チャイナドレス', '中华装']),
    ('ch.kimono', '和服', 'character', ['着物', '浴衣', '日式服装']),
    ('ch.gothic_lolita', '哥特萝莉', 'character', ['ゴスロリ', 'Gothic Lolita', '哥特风']),
    ('ch.lolita_fashion', '洛丽塔', 'character', ['ロリータファッション', 'Lolita Fashion']),
    ('ch.bunny_girl', '兔女郎', 'character', ['バニーガール', 'Bunny Girl']),
    ('ch.apron', '围裙', 'character', ['エプロン', '裸围裙', '裸エプロン', '裸体围裙女主角']),
    ('ch.wedding_dress', '婚纱', 'character', ['ウェディングドレス', '花嫁', '结婚礼服']),
    ('ch.military_uniform', '军装', 'character', ['軍服', '军服', '迷彩服']),
    ('ch.suit', '西装', 'character', ['スーツ', '正装', 'Suit']),
    ('ch.cheerleader', '啦啦队服', 'character', ['チアガール', '啦啦队']),
    ('ch.uniform', '制服', 'character', ['着衣']),
    ('ch.knee_socks', '过膝袜', 'character', ['ニーソックス', '及膝袜', '绝对领域', '絶対領域', 'ニーハイ']),
    ('ch.pantyhose', '连裤袜', 'character', ['パンスト', 'パンティストッキング']),
    ('ch.garter_belt', '吊带袜', 'character', ['ガーターベルト', '袜带']),
    ('ch.stockings', '丝袜', 'character', ['ストッキング', '白丝', '黑丝', '全身丝袜']),
    ('ch.ribbons', '丝带发饰', 'character', ['丝带', '发带', '蝴蝶结', 'リボン']),
    ('ch.headband', '头带', 'character', ['发箍', 'カチューア']),
    ('ch.hat', '帽子', 'character', ['草帽', '贝雷帽', '太阳帽']),
    # ---------------- character：身份/关系（女仆/巫女/学生/教师/护士/大小姐/公主/骑士/魔法少女/修女/妹系/青梅竹马/双胞胎/御姐/萝莉/正太已有） ----------------
    ('ch.housewife', '人妻', 'character', ['主妇', '家庭主妇', '已婚女性']),
    ('ch.widow', '寡妇', 'character', ['未亡人', 'Widow']),
    ('ch.step_sister', '义妹', 'character', ['继妹', '義妹']),
    ('ch.step_brother', '义兄', 'character', ['继兄', '義兄']),
    ('ch.step_mother', '义母', 'character', ['继母', '後妈', '義母']),
    ('ch.mother', '母亲', 'character', ['母親', '妈妈', 'お母さん', '主人公的血亲母亲作为女主角', '主人公的非血亲母亲作为女主角', '有孩子的女主角']),
    ('ch.father', '父亲', 'character', ['父親', '爸爸']),
    ('ch.brocon', '兄控', 'character', ['弟控']),
    ('ch.siscon', '妹控', 'character', []),
    ('ch.anecon', '姐控', 'character', []),
    ('ch.middle_schooler', '初中生', 'character', ['中学生']),
    ('ch.college_student', '大学生', 'character', []),
    ('ch.kaichou', '学生会', 'character', ['学生会主席', '学生会长', '学生会长', '会长', '学生会成员']),
    ('ch.iinchou', '委员长', 'character', ['委員長', '班长', '风纪委员']),
    ('ch.honors_student', '优等生', 'character', ['模范生']),
    ('ch.transfer_student', '转学生', 'character', ['転校生']),
    ('ch.senpai', '前辈后辈', 'character', ['先輩', '後輩', '学长', '学姐', '学妹', '学弟', '后辈', '主人公的学姐前辈女主角']),
    ('ch.classmate', '同级生', 'character', ['同級生', '同班同学', '同校同学', '同窗']),
    ('ch.landlord', '房东管理员', 'character', ['房东', '管理人', '宿舍管理员']),
    ('ch.orphan', '孤儿', 'character', ['孤児']),
    ('ch.neet', '家里蹲NEET', 'character', ['NEET', 'ニート', '引きこもり', '家里蹲', '蛰居']),
    ('ch.delinquent', '不良', 'character', ['不良少年', '不良少女', 'ヤンキー', '太妹', '前不良少年']),
    ('ch.otaku', '宅', 'character', ['オタク', '宅男', '宅女', '御宅族']),
    ('ch.gyaru', '辣妹', 'character', ['ギャル', 'ガングロ', 'Ganguro', 'Ganguro风格', '黑皮', '黑皮女主角']),
    ('ch.otokonoko', '伪娘', 'character', ['男の娘', '男娘', '偽娘']),
    ('ch.prisoner', '囚犯', 'character', ['囚人', '犯人', '罪犯']),
    ('ch.slave', '奴隶', 'character', ['奴隷']),
    ('ch.ol', '上班族', 'character', ['OL', '会社員', '社畜', '白领', '公司职员']),
    ('ch.doctor', '医生', 'character', ['医者', '医师', '女医生', '兽医', '医学生']),
    ('ch.police', '警察', 'character', ['警察官', '女警', '警官', '刑事']),
    ('ch.soldier', '士兵', 'character', ['兵士', '军人', '軍人']),
    ('ch.mercenary', '佣兵', 'character', ['傭兵', '雇佣兵']),
    ('ch.assassin', '刺客', 'character', ['暗殺者', '杀手']),
    ('ch.ninja', '忍者', 'character', ['女忍者', 'くノ一']),
    ('ch.samurai', '武士', 'character', ['侍']),
    ('ch.swordsman', '剑士', 'character', ['剣士', '剑客']),
    ('ch.hero', '勇者', 'character', ['英雄', 'ヒーロー']),
    ('ch.maou', '魔王', 'character', ['魔族']),
    ('ch.royal', '王族', 'character', ['王子', '国王', '女帝', '皇帝', '皇族', '君主']),
    ('ch.noble', '贵族', 'character', ['伯爵', '公爵', '大名']),
    ('ch.bocchama', '少爷', 'character', ['大少爷', '坊ちゃん']),
    ('ch.adventurer', '冒险者', 'character', ['冒险家', '探索者']),
    ('ch.merchant', '商人', 'character', ['店主']),
    ('ch.cook', '厨师', 'character', ['料理人']),
    ('ch.butler', '管家执事', 'character', ['執事', '管家']),
    ('ch.servant', '仆人', 'character', ['使用人', '侍从', '佣人']),
    ('ch.bodyguard', '保镖', 'character', ['ボディーガード', '护卫']),
    ('ch.scientist', '科学家', 'character', ['科学者', '博士', '研究员']),
    ('ch.inventor', '发明家', 'character', ['発明家', '工程师']),
    ('ch.writer', '作家', 'character', ['小说家', '漫画家']),
    ('ch.artist', '画家', 'character', ['絵師', '画师', '艺术家']),
    ('ch.musician', '音乐家', 'character', ['乐手', '歌手', '乐队成员']),
    ('ch.voice_actor', '声优', 'character', ['声優', '配音演员']),
    ('ch.streamer', '主播', 'character', ['配信者', 'Vtuber', '网络主播', '写真偶像']),
    ('ch.monk', '僧侣', 'character', ['神父', '和尚', '神职者']),
    ('ch.priestess', '祭司', 'character', ['神官', '女神官']),
    ('ch.witch', '魔女', 'character', ['女巫', '魔法使', '魔法师', '法师']),
    ('ch.alchemist', '炼金术士', 'character', ['錬金術師']),
    ('ch.succubus', '魅魔', 'character', ['サキュバス', '淫魔']),
    ('ch.demon', '恶魔', 'character', ['悪魔', '堕天使']),
    ('ch.angel', '天使', 'character', ['Angel', '大天使']),
    ('ch.vampire', '吸血鬼', 'character', ['Vampire', '血族']),
    ('ch.ghost', '幽灵', 'character', ['幽霊', '亡灵', '地缚灵']),
    ('ch.zombie', '僵尸', 'character', ['ゾンビ', '丧尸', 'Zombie']),
    ('ch.android', '机器人', 'character', ['人造人', '仿生人', 'アンドロイド', '机器人女主角']),
    ('ch.ai', '人工智能', 'character', ['人工知能', 'AI']),
    ('ch.alien', '外星人', 'character', ['宇宙人', 'エイリアン', 'Alien']),
    ('ch.youkai', '妖怪', 'character', ['化け物', '物の怪']),
    ('ch.god', '神明', 'character', ['神様', '女神', '神']),
    ('ch.shinigami', '死神', 'character', []),
    ('ch.slime', '史莱姆', 'character', ['スライム', 'Slime']),
    ('ch.goblin', '哥布林', 'character', ['ゴブリン', 'Goblin']),
    ('ch.kemono', '兽人', 'character', ['獣人', 'ケモノ', 'Furry', '福瑞']),
    ('ch.elf', '精灵', 'character', ['エルフ', 'Elf', '妖精', 'Fairy', '仙子']),
    ('ch.monster_girl', '魔物娘', 'character', ['モンスター娘', 'Monster Girl']),
    ('ch.mermaid', '人鱼', 'character', ['人魚', 'Mermaid']),
    ('ch.valkyrie', '女武神', 'character', ['ワルキューレ', 'Valkyrie']),
    ('ch.dragon', '龙', 'character', ['竜', 'ドラゴン', 'Dragon']),
    ('ch.chunibyou', '中二病', 'character', ['中二']),
    # ---------------- character：性格（傲娇/病娇/元气/大和抚子/天然(element)已有） ----------------
    ('ch.fujoshi', '腐女', 'character', ['腐女子', 'BL爱好者']),
    ('ch.sadistic', '抖S', 'character', ['サディスト', 'S属性', '施虐狂', '虐待狂']),
    ('ch.masochist', '抖M', 'character', ['マゾヒスト', 'M属性', '受虐狂']),
    ('ch.hentai', '变态', 'character', ['好色', 'スケベ', 'Hentai', '色情狂', '狂气']),
    ('ch.sharp_tongue', '毒舌', 'character', ['说话毒辣']),
    ('ch.black_hearted', '腹黑', 'character', ['腹黒い']),
    ('ch.kind', '温柔', 'character', ['優しい', '善良', '温和']),
    ('ch.cold', '冷酷', 'character', ['クール', '冷淡']),
    ('ch.serious', '认真', 'character', ['真面目', '严谨', '勤奋']),
    ('ch.prideful', '傲慢', 'character', ['高慢', '自大', '高飞车']),
    ('ch.boyish', '假小子', 'character', ['ボーイッシュ', '男孩气', '中性']),
    ('ch.childish', '孩子气', 'character', ['幼稚', '子供っぽい']),
    ('ch.mature', '成熟', 'character', ['大人っぽい']),
    ('ch.crybaby', '爱哭', 'character', ['泣き虫', '爱哭鬼']),
    ('ch.shy', '害羞', 'character', ['照れ屋', '怕生', '腼腆']),
    ('ch.stubborn', '固执', 'character', ['頑固', '倔强', '顽固']),
    ('ch.bookworm', '书虫', 'character', ['本好き', '书呆子']),
    ('ch.genius', '天才', 'character', ['精英', 'エリート']),
    ('ch.sickly', '病弱', 'character', ['体弱多病', '虚弱']),
    ('ch.possessive', '占有欲强', 'character', ['独占欲', '嫉妒', '嫉妬']),
    # ---------------- art ----------------
    ('art.chibi', 'Q版SD', 'art', ['SD原画', 'Q版立绘', 'Q版画风CG', 'ちびキャラ', 'SDキャラ', 'Q版', 'q版cg']),
    ('art.ai_generated', 'AI生成', 'art', ['AI生成的图像', 'AI生成的音乐', 'AI生成的故事']),
    ('art.insert_song', '插入歌', 'art', ['挿入歌']),
    # ---------------- 第二批：候选池高频基名（组合吸收的基名承接） ----------------
    ('ch.elementary_schooler', '小学生', 'character', ['小学生']),
    ('ch.tsukkomi', '吐槽役', 'character', ['ツッコミ', '吐槽']),
    ('ch.farmer', '农民', 'character', ['農家', '农家']),
    ('ch.driver', '司机', 'character', ['運転手', '驾驶员']),
    ('ch.coworker', '同事', 'character', ['同僚', '职场同事']),
    ('ch.lawyer', '律师', 'character', ['弁護士']),
    ('ch.technician', '技术员', 'character', ['技術者', '技师']),
    ('ch.photographer', '摄影师', 'character', ['写真家']),
    ('ch.politician', '政治家', 'character', ['政客']),
    ('ch.coach', '教练', 'character', ['監督', '监督']),
    ('ch.principal', '校长', 'character', ['校長', '园长']),
    ('ch.model', '模特', 'character', ['モデル']),
    ('ch.martial_artist', '武术家', 'character', ['武闘家', '格斗家']),
    ('ch.pirate', '海盗', 'character', ['海賊']),
    ('ch.hunter', '猎人', 'character', ['狩人', '怪物猎人']),
    ('ch.thief', '盗贼', 'character', ['盗賊', '怪盗', '小偷']),
    ('ch.journalist', '记者', 'character', ['記者']),
    ('ch.athlete', '运动员', 'character', ['運動選手', '选手']),
    ('ch.spy', '间谍', 'character', ['スパイ', '特工']),
    ('ch.onmyoji', '阴阳师', 'character', ['陰陽師']),
    ('ch.werewolf', '狼人', 'character', ['狼男', '人狼']),
    ('ch.nonhuman', '非人类', 'character', ['人外', '半人类女主角']),
    ('ch.transgender', '跨性别', 'character', ['トランスジェンダー']),
    ('ch.tattoo', '纹身', 'character', ['入れ墨', '刺青']),
    ('ch.lolicon', '萝莉控', 'character', ['ロリコン']),
    ('ch.shotacon', '正太控', 'character', ['ショタコン']),
    ('ch.nymphomaniac', '淫乱', 'character', ['性瘾']),
    ('ch.yakuza', '极道', 'character', ['ヤクザ', '黑帮', 'マフィア', '黑手党', '三合会']),
    ('ch.cosplay', 'Cosplay', 'character', ['コスプレ']),
    ('ad.femdom', '女性主导', 'adult', ['女王様']),
    ('ad.maledom', '男性主导', 'adult', []),
    ('ad.swinging', '交换伴侣', 'adult', ['スワッピング']),
    ('ad.molestation', '痴汉', 'adult', ['痴漢', '咸猪手']),
    ('ad.incontinence', '失禁', 'adult', ['放尿', 'お漏らし']),
    ('el.seven_deadly_sins', '七宗罪', 'element', ['七つの大罪']),
    ('th.one_night', '一夜情', 'theme', []),
    ('set.china', '中国', 'setting', ['中華', '三国', '三国题材', '三国志']),
    # ---------------- 第三批（ROUND2）：实库真实标签定点补充（2026-10-03 收官） ----------------
    ('el.kiss', '亲吻', 'element', ['キス', '接吻', 'Kiss', '初吻', 'ファーストキス']),
    ('el.cohabitation', '同居', 'element', ['同棲', '同居生活', 'Living Together']),
    ('el.flashback', '回忆闪回', 'element', ['倒叙', '闪回', '回忆倒叙', 'フラッシュバック', 'Flashback', '过去篇']),
    ('el.battle', '战斗', 'element', ['戦闘', '战斗场面', 'Battle']),
    ('ps.short_form', '短篇', 'playstyle', ['短編', 'Short', '短篇作品']),
    ('ps.side_scroller', '横版', 'playstyle', ['横板', '横向卷轴', '横版卷轴', 'サイドスクロール', 'Side Scrolling']),
    ('ps.metroidvania', '银河城', 'playstyle', ['银河恶魔城', '类银河战士恶魔城', '银河战士恶魔城', '恶魔城', 'Metroidvania', 'メトロイドヴァニア']),
    ('ps.doujin', '同人', 'playstyle', ['同人游戏', '同人作品', '同人ゲー', 'Doujin']),
    ('ch.koakuma', '小恶魔', 'character', ['小悪魔', 'Koakuma']),
    ('ch.male_protagonist', '男性主人公', 'character', ['Male Protagonist']),
    ('ch.female_protagonist', '女主人公', 'character', ['Female Protagonist']),
    ('ad.corruption', '恶堕', 'adult', ['悪堕ち', '堕落', 'Corruption']),
    ('ad.extreme', '重口', 'adult', ['重口味', '过激', '過激', '鬼畜']),
    # ---------------- 第四批（ROUND3）：探索页云端未归类收编（2026-10-03） ----------------
    # 注：燃作/燃 已并入上方 ROUND1 的 tone.hot_blooded（热血）条目，勿重复建概念。
    ('ps.fandisc', '粉丝向', 'playstyle', ['FD', 'ファンディスク', 'Fandisc', 'Fan Disc']),
    ('tone.denpa', '电波系', 'tone', ['电波', '電波', '電波系', 'Denpa']),
    ('tone.oudou', '王道', 'tone', ['王道展开', '王道剧情', '王道展開']),
    ('tone.tragedy', '悲剧', 'tone', ['悲劇', '悲剧结局', '惨剧']),
    ('ad.confinement', '监禁', 'adult', ['監禁', '囚禁']),
]

# =========================================================================
# 现有概念追加别名（EXTRA）：按现有概念「规范名」匹配
# =========================================================================
EXTRA = {
    'NTR': ['寝取られ', '寝取り', '寝取り（偷走对象）'],
    '近亲': ['乱伦', '近親相姦', 'Incest', '兄弟乱伦', '姐妹乱伦', '双胞胎乱伦', '叔侄乱伦', '兄妹乱伦',
            '兄弟姐妹恋情', '血亲兄弟姐妹乱伦', '兄弟姐妹间做爱'],
    '穿越时空': ['时间旅行', 'タイムトラベル', 'Time Travel', '时空跳跃'],
    '轮回': ['转世'],
    '银发': ['白发', '白髪', 'White Hair', '白毛', '银发教会'],
    'Live2D': ['E-mote', '动态立绘', '動く立ち絵'],
    'ASMR音声': ['双耳音频', 'バイノーラル', 'Dummy Head'],
    '大小姐': ['大小姐お嬢様'],
    '郁系致郁': ['阴郁', '压抑', '沉重', '陰鬱', '抑郁', '胃痛', '胃疼'],
    '悬疑推理': ['探案', '悬疑', '解密'],
    '教师': ['大学教师', '体育老师', '助教', '家庭教师'],
    '护士': ['学校护士'],
    '巨乳': ['大胸', '巨乳爆乳'],
    '双胞胎': ['三胞胎', '多胞胎'],
    '青梅竹马': ['幼馴染', '竹马', '主人公的幼驯染女主角', '青梅'],
    '拔作': ['ヌキゲー', '萌拔'],
    '后宫': ['ハーレムもの', '后宫结局', 'ハーレムエンド', 'Harem Ending'],
    '校园': ['学園もの', '学校生活'],
    '巫女': ['神主'],
    '百合': ['GL', '百合作', '女女恋爱', '女性同士'],
    'BL': ['BL作', '耽美'],
    '多结局': ['多分支结局', '多于七个结局', '多个真结局'],
    '单线': ['单结局'],
    'RPG': ['JRPG', '肉鸽'],
    '搞笑': ['コメディ', 'Comedy', '黑色幽默'],
    '治愈': ['癒し', '疗愈'],
    '都市现代': ['现代', '現代', '当代'],
    '奇幻': ['異世界ファンタジー'],
    '神话超自然': ['超自然', 'オカルト', '灵异'],
    '恋爱': ['恋愛', '爱情'],
    '亲情家族': ['家族', '亲情'],
    '友情': ['友谊'],
    '女仆': ['メイドさん'],
    'SLG策略模拟': ['塔防游戏', 'タワーディフェンス', 'Tower Defense'],
    '无口': ['冷娇'],
    '性别转换': ['女扮男装', '男扮女装'],
    '校园': ['学园祭', '学園祭', '校园活动', '学校节日庆典'],
    '科幻近未来': ['VR头盔支持', 'VR対応', 'Virtual Reality', '仮想現実'],
    # ---------------- ROUND2：实库真实标签定点承接（2026-10-03）。
    # 仅指向「备份既有概念」；指向 ROUND1 新概念的别名已直接并入 NEW 表条目
    #（EXTRA 先于新概念注册执行，指新概念会空转——两次踩同一坑，已记入经验）。
    '泣系': ['催泪弹', '暖人心田泣', '泣き', '泣き系', 'Tearjerker'],
    '萌系废萌': ['废萌', '萌えゲー', 'Moege'],
    '纯爱': ['甜作', '糖', '甘々', 'あまあま', '纯爱故事', '高甜度', '高甜', '甜恋'],
    '三角恋': ['戏剧性的三角恋'],
    '妹系': ['实妹', '実妹', '主人公的妹妹女主角', '主人公的同父同母的妹妹女主角',
            '主人公同父母异母父姐妹作为女主角', '主人公有非血缘姐姐妹妹'],
    '病娇': ['黑化'],
    '御姐': ['只有年长女主角', '成人女主角'],
    '末世': ['末日后的地球'],
    'R18': ['黄油'],
}

# 既有别名迁移（先于 EXTRA 执行）：语义错置的别名迁往新概念（新概念规范名/别名承接）。
# 裁决依据：①「人物属性优先于舞台」（同「巫女→character」先例）；
# ② 大杂烩概念（SLG/科幻/和风/萌系/双马尾/巨乳/御姐）中的独立检索词拆出。
MIGRATE = {
    '神话超自然': ['妖怪', '幽灵', '幽霊', 'Ghost', '恶魔', '悪魔', 'Demon',
                 '天使', 'Angel', '吸血鬼', 'Vampire', '人鱼', '人魚',
                 '精灵', 'エルフ', 'Elf', '龙', 'ドラゴン', 'Dragon',
                 '不死系', '丧尸', '魔物娘', 'Monster Girl'],
    'SLG策略模拟': ['经营模拟', 'Management Simulation', '养成模拟', 'Raising Simulation'],
    '科幻近未来': ['赛博朋克', 'サイバーパンク', 'Cyberpunk', '机器人', 'ロボット',
                '机器人主人公', '机器人女主', '机器人女主角', '机器人男主角',
                '宇宙', '太空'],
    '和风历史': ['幕末', '江戸時代', '江户时代', '戦国時代', '战国时代',
               '和服', '和服主人公', '和服女主角', '和服男主角', '中世纪'],
    '萌系废萌': ['轻松', 'ほのぼの', '温馨'],
    '恐怖惊悚': ['猎奇', 'グロ'],
    '恋爱': ['恋爱喜剧', 'Romantic Comedy', 'ラブコメ'],
    '御姐': ['人妻', '人妻女主'],
    '巨乳': ['爆乳', '爆乳主人公', '超乳', '超乳主人公', '超乳女主角'],
    '双马尾': ['马尾', 'ポニーテール', '长发', '短发', '马尾女主角', '马尾男主角'],
}

def main():
    dims = json.load(open(DIMS, encoding='utf-8'))
    dim_ids = {d['id'] for d in dims['dimensions']}
    vocab = json.load(open(VOCAB, encoding='utf-8'))
    concepts = vocab['concepts']
    n_before = len(concepts)

    # 内部结构
    idx = {}   # norm -> concept dict
    def reg(c):
        keys = [c['name']] + list(c.get('aliases', []))
        for k in keys:
            n = norm(k)
            if not n: continue
            if n in idx:
                if idx[n] is c: continue
                print(f'[冲突] {k!r} -> {idx[n]["id"]} 与 {c["id"]}', file=sys.stderr)
                sys.exit(1)
            idx[n] = c
        return c

    for c in concepts: reg(c)

    # 0) MIGRATE：从指定概念移除别名（迁往新概念，由新概念表自带别名承接）
    by_name = {c['name']: c for c in concepts}
    migrated = 0
    for name, drops in MIGRATE.items():
        c = by_name.get(name)
        if c is None:
            print(f'[警告] MIGRATE 目标概念不存在: {name}')
            continue
        for d in drops:
            n = norm(d)
            if n in idx and idx[n] is c:
                del idx[n]; migrated += 1
        c['aliases'] = [a for a in c.get('aliases', []) if a not in drops]

    # 1) EXTRA 别名
    extra_added = 0
    for name, adds in EXTRA.items():
        c = by_name.get(name)
        if c is None:
            print(f'[警告] EXTRA 目标概念不存在: {name}')
            continue
        al = c.setdefault('aliases', [])
        for a in adds:
            n = norm(a)
            if not n: continue
            if n in idx and idx[n] is not c:
                continue  # 已被其他概念占用，跳过
            if a not in al:
                al.append(a); idx[n] = c; extra_added += 1

    # 2) 新概念
    new_added = 0
    existing_ids = {c['id'] for c in concepts}
    for cid, name, dim, aliases in NEW:
        assert cid not in existing_ids, f'id 重复: {cid}'
        assert dim in dim_ids, f'维度未注册: {cid} -> {dim}'
        c = {'id': cid, 'name': name, 'dim': dim, 'aliases': []}
        reg(c)  # 先注册规范名（冲突即退）
        for a in aliases:
            n = norm(a)
            if n in idx and idx[n] is not c: continue
            if a not in c['aliases']:
                c['aliases'].append(a); idx[n] = c
        concepts.append(c); new_added += 1

    # 3) VNDB 翻译表对齐（英文名收进命中概念）
    vndb = json.load(open(VNDB, encoding='utf-8'))
    vndb_added = 0
    for en, zh in vndb.items():
        if en.startswith('_') or not isinstance(en, str) or not isinstance(zh, str): continue
        for form in (zh, en):
            c = idx.get(norm(form))
            if c is not None:
                other = en if form == zh else zh
                n = norm(other)
                if n and n not in idx and other not in c['aliases'] and other != c['name']:
                    c['aliases'].append(other); idx[n] = c; vndb_added += 1
                break

    # 4) 内置日→中表反向：日文原名收进命中概念（仅 1:1 明确映射）
    src = open(TRANSLATOR, encoding='utf-8').read()
    def extract(map_name):
        m = re.search(r'Map<String, String> ' + map_name + r' = \{(.*?)\n  \};', src, re.S)
        out = {}
        for k, v in re.findall(r"'((?:[^'\\]|\\.)+)'\s*:\s*'((?:[^'\\]|\\.)+)'", m.group(1)):
            out[k.replace("\\'", "'")] = v.replace("\\'", "'")
        return out
    ja_added = 0
    zh2ja = {}
    for ja, zh in extract('jaToZh').items():
        zh2ja.setdefault(norm(zh), []).append(ja)
    for c in concepts:
        for form in [c['name']] + c.get('aliases', []):
            for ja in zh2ja.get(norm(form), []):
                n = norm(ja)
                if n and n not in idx and ja not in c.get('aliases', []):
                    c.setdefault('aliases', []).append(ja); idx[n] = c; ja_added += 1

    # 5) 组合式吸收：基名+人物后缀 → 并入基名概念
    suf = re.compile(r'^(.+?)(男主人公|女主人公|主人公|男主角|女主角|男主|女主|男配角|女配角|配角)$')
    comb_added = 0; comb_samples = []
    # 候选来源：清洗后的 VNDB 中文译名
    UI_NOISE = re.compile(r'通知我|选择|评分|添加|删除|列表|设置|过滤器|保存|请用|评论|剧透|'
                          r'版本|由你|更新|页面|搜索|筛选|标签|投票|移植|登录|注册|收藏|购买|'
                          r'下载|链接|论坛|讨论|积分|勋章')
    zh_pool = {v for k, v in vndb.items()
               if not k.startswith('_') and isinstance(k, str) and isinstance(v, str)
               and 1 <= len(v) <= 20 and not UI_NOISE.search(v)}
    for tag in sorted(zh_pool):
        m = suf.match(tag.strip())
        if not m: continue
        base_c = idx.get(norm(m.group(1)))
        if base_c is None: continue
        n = norm(tag)
        if n in idx: continue
        base_c.setdefault('aliases', []).append(tag.strip())
        idx[n] = base_c; comb_added += 1
        if len(comb_samples) < 400: comb_samples.append((tag.strip(), base_c['id']))

    # 5.5) ROUND4：NextMoe 全量标签目录吸收（新增概念 + 既有概念别名 + 规则生成期吸收）
    sys.path.insert(0, ROOT + '/dev_probe')
    import round4_data
    nextmoe_tags = json.load(open(NEXTMOE, encoding='utf-8'))
    r4 = round4_data.apply(concepts, idx, norm, nextmoe_tags)

    # 6) 最终冲突断言（全键唯一 + 概念 id 唯一）
    seen = {}
    for c in concepts:
        for k in [c['name']] + c.get('aliases', []):
            n = norm(k)
            if not n: continue
            if n in seen and seen[n] is not c:
                print(f'[最终冲突] {k!r}: {seen[n]["id"]} vs {c["id"]}', file=sys.stderr)
                sys.exit(1)
            seen[n] = c
    seen_ids = {}
    for c in concepts:
        if c['id'] in seen_ids:
            print(f'[最终冲突] 概念 id 重复: {c["id"]} '
                  f'({seen_ids[c["id"]]["name"]} vs {c["name"]})', file=sys.stderr)
            sys.exit(1)
        seen_ids[c['id']] = c

    # 输出 JSON（保持字段顺序 format_version/_comment/concepts）
    out = {'format_version': vocab['format_version'],
           '_comment': vocab.get('_comment', ''),
           'concepts': concepts}
    with open(VOCAB, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write('\n')

    # 统计
    after = len(concepts)
    alias_total = sum(len(c.get('aliases', [])) for c in concepts)
    covered = sum(1 for t in zh_pool if norm(t) in idx)
    print(f'概念: {n_before} -> {after} (新增 {new_added}, EXTRA 别名 +{extra_added})')
    print(f'别名: VNDB对齐 +{vndb_added} / 日文反向 +{ja_added} / 组合吸收 +{comb_added}')
    print(f'ROUND4(NextMoe): 新概念 +{r4["new_concepts"]} / 既有别名 +{r4["extra_aliases"]} / 规则吸收 +{r4["absorbed"]}')
    print(f'总别名键: {len(idx)}')
    print(f'清洗后主流标签池 {len(zh_pool)} 命中 {covered} = {covered/len(zh_pool)*100:.1f}%')
    nm_total = len(nextmoe_tags)
    nm_content = [t for t in nextmoe_tags if isinstance(t, dict) and t.get('tag_kind') == 'content']
    nm_chit = sum(1 for t in nm_content if norm(t.get('display_name') or '') in idx)
    nm_core = [t for t in nm_content if t.get('tier') == 'core']
    nm_core_hit = sum(1 for t in nm_core if norm(t.get('display_name') or '') in idx)
    print(f'★ NextMoe content {len(nm_content)} 命中 {nm_chit} = {nm_chit/len(nm_content)*100:.1f}%'
          f' | core {len(nm_core)} 命中 {nm_core_hit} = {nm_core_hit/max(len(nm_core),1)*100:.1f}%'
          f' | 全量 {nm_total}')
    json.dump({'comb_samples': comb_samples, 'round4': r4},
              open(REPORT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

if __name__ == '__main__':
    main()
