# -*- coding: utf-8 -*-
"""ROUND4：以 NextMoe 全量标签目录（3328 个，六源对齐）为基准语料的归类扩充。

本模块只提供「数据 + 吸收逻辑」，由 gen_tag_vocabulary.py 在管线末尾调用。
设计纪律（沿用前几轮）：
  - 运行时代码零改动：产出仍是「概念 + 别名」倒排，无运行时模糊匹配；
  - 生成期吸收：规则只用于**生成显式别名**，命中即写死为别名；
  - 保守：语义不清，或归一化后撞到别的概念，一律跳过，绝不强并。

三类数据：
  NEW4    新增概念（id, 规范名, 维度, 别名列表）
  EXTRA4  给既有概念追加别名（按规范名匹配）
  RULES   有序规则 (正则, 概念 id)：对 NextMoe 未命中标签按序首命中
  EXACT   精确映射 {标签: 概念 id}：规则之外的核心标签兜底（优先于规则）
"""
import re

# =========================================================================
# 1) 新增概念
# =========================================================================
NEW4 = [
    # ---------------- adult（成人内容） ----------------
    ('ad.position', '体位', 'adult', ['后背位', '后入体位', '传教士体位', '站立性爱', '侧卧位', '背向座位', '对面座位']),
    ('ad.fingering', '指交', 'adult', ['指插', '手指插入', '肛门指交']),
    ('ad.fisting', '拳交', 'adult', ['Fisting', 'フィスティング']),
    ('ad.dilation', '扩张', 'adult', ['扩张play', '内部扩张', '巨大插入', '乳房扩张']),
    ('ad.urination', '放尿排尿', 'adult', ['放尿', '排尿', '饮尿', '小便play', '尿play', '尿道play', '体内小便']),
    ('ad.scat', '脱粪', 'adult', ['排便', '排泄物', '粪便play', '大便play']),
    ('ad.enema', '灌肠', 'adult', ['浣肠', '灌肠play']),
    ('ad.bestiality', '兽交', 'adult', ['獣姦', '兽奸', '人兽']),
    ('ad.monster_sex', '怪物性爱', 'adult', ['异种奸', '异种X', '魔物性爱', '机械X']),
    ('ad.oviposition', '产卵', 'adult', ['産卵', '排卵']),
    ('ad.vore', '吞食', 'adult', ['丸吞', '胎内回归', '丸呑']),
    ('ad.necrophilia', '恋尸癖', 'adult', ['奸尸']),
    ('ad.amputee', '截肢', 'adult', ['四肢切断', '断肢']),
    ('ad.body_mod', '人体改造', 'adult', ['肉体改造', '身体改造']),
    ('ad.torture', '拷问', 'adult', ['酷刑', '拷问室', '火刑', '拷问刑具']),
    ('ad.tickling', '搔痒', 'adult', ['挠痒痒', '搔痒折磨', '腋窝搔痒']),
    ('ad.uncensored', '无修正', 'adult', ['步兵', '无码', '去码']),
    ('ad.censored', '有修正', 'adult', ['骑兵', '有码', '马赛克']),
    ('ad.spanking', '打屁股', 'adult', ['Spanking', '臀击']),
    ('ad.facesitting', '颜骑', 'adult', ['坐脸', '骑脸']),
    ('ad.rimming', '舔肛', 'adult', ['舔菊', '毒龙钻', '舔肛手交']),
    ('ad.armpit', '腋交', 'adult', ['腋窝性交', '腋下性交', '舔腋窝']),
    ('ad.sexual_slavery', '性奴', 'adult', ['性奴役', '肉便器', '性奴隶', '肉奴隶']),
    ('ad.foot_worship', '恋足', 'adult', ['舔脚', '恋足癖', '足部崇拜']),
    ('ad.squirting', '潮吹', 'adult', ['吹潮', '潮噴']),
    ('ad.prostate', '前列腺开发', 'adult', ['前列腺刺激']),
    ('ad.urination_others', '排泄羞辱', 'adult', ['对他人尿尿', '拉在其他人身上']),
    ('ad.gokkun2', '饮精', 'adult', ['食物吃精', '射在食物上']),
    ('ad.milking', '榨精', 'adult', ['挤奶', '榨乳']),
    # ---------------- character：亲属关系 ----------------
    ('ch.sister', '姐妹', 'character', ['姐姐', '妹妹', '姊', '姐', '妹', '兄弟姐妹']),
    ('ch.brother', '兄弟', 'character', ['哥哥', '弟弟', '兄', '哥', '弟']),
    ('ch.daughter', '女儿', 'character', ['女儿型']),
    ('ch.son', '儿子', 'character', ['儿子型']),
    ('ch.grandmother', '祖母', 'character', ['奶奶', '外祖母', '姥姥']),
    ('ch.grandfather', '祖父', 'character', ['爷爷', '外祖父']),
    ('ch.aunt', '姑姑阿姨', 'character', ['姑姑', '姨母', '姨妈', '婶婶', '小姨', '姑妈']),
    ('ch.uncle', '叔叔舅舅', 'character', ['叔叔', '舅舅', '伯伯', '叔父']),
    ('ch.niece', '侄女外甥女', 'character', ['侄女', '外甥女']),
    ('ch.nephew', '侄子外甥', 'character', ['侄子', '外甥']),
    ('ch.cousin', '堂表亲', 'character', ['表哥', '表妹', '表姐', '表弟', '堂姐', '堂妹', '堂兄', '堂弟', '堂表亲']),
    ('ch.sister_in_law', '嫂子弟媳', 'character', ['嫂子', '弟妹', '弟媳']),
    ('ch.in_law', '姻亲长辈', 'character', ['岳父', '岳母', '公公', '婆婆']),
    ('ch.fiancee', '未婚夫妻', 'character', ['未婚妻', '未婚夫', '婚约者']),
    ('ch.ex_lover', '前任', 'character', ['前女友', '前男友', '旧情人']),
    ('ch.spouse', '配偶', 'character', ['妻子', '丈夫', '老婆', '老公']),
    # ---------------- character：职业补充 ----------------
    ('ch.waiter', '服务业店员', 'character', ['服务员', '店员', '服务生', '女招待', '售货员', '销售员']),
    ('ch.secretary', '秘书', 'character', ['助理']),
    ('ch.programmer', '程序员', 'character', ['工程师', '码农']),
    ('ch.baker', '面包师', 'character', ['糕点师', '甜点师']),
    ('ch.fisherman', '渔夫', 'character', ['渔师']),
    ('ch.actor', '演员艺人', 'character', ['演员', '艺人', '女演员', '男演员']),
    ('ch.dancer', '舞者', 'character', ['舞女', '芭蕾舞者']),
    ('ch.librarian', '图书管理员', 'character', ['图书馆员']),
    ('ch.announcer', '播音员', 'character', ['主播', '主持人']),
    ('ch.bartender', '酒保', 'character', ['调酒师']),
    ('ch.flight_attendant', '空乘', 'character', ['空姐', '乘务员']),
    ('ch.caretaker', '护理看护', 'character', ['看护', '护理员', '保姆']),
    ('ch.cleaner', '清洁工', 'character', ['环卫工', '家政']),
    ('ch.boss', '上司', 'character', ['老板', '上司', '经理', '社长', '高管']),
    # ---------------- character：种族 / 能力补充 ----------------
    ('ch.catgirl', '猫娘', 'character', ['猫耳娘', '猫又']),
    ('ch.foxgirl', '狐妖', 'character', ['狐娘', '九尾狐', '妖狐']),
    ('ch.snow_woman', '雪女', 'character', ['雪女妖怪']),
    ('ch.plant_girl', '植物娘', 'character', ['花妖', '树精']),
    ('ch.machine_girl', '机娘', 'character', ['机械娘', '机甲少女']),
    ('ch.oni', '鬼族', 'character', ['鬼娘', '鬼']),
    ('ch.esper', '超能力者', 'character', ['异能者', '超能者', '灵能力者']),
    ('ch.archer', '弓箭手', 'character', ['弓手', '弓兵']),
    ('ch.sniper', '狙击手', 'character', ['狙击兵']),
    ('ch.monster', '怪物', 'character', ['怪兽', '魔物', '怪物娘']),
    ('ch.half_human', '半人类', 'character', ['半人半兽', '半兽人', '亚人']),
    # ---------------- character：身体 / 外貌 ----------------
    ('ch.dark_skin', '深色肌肤', 'character', ['黑皮', '褐色皮肤', '古铜色肌肤', '黑皮角色']),
    ('ch.freckles', '雀斑', 'character', ['雀斑脸']),
    ('ch.scar', '伤疤', 'character', ['疤痕', '刀疤']),
    ('ch.mole', '美人痣', 'character', ['泪痣']),
    ('ch.tan_line', '晒痕', 'character', ['日晒痕迹']),
    # ---------------- character：状态 ----------------
    ('ch.married', '已婚', 'character', ['已婚者']),
    ('ch.divorced', '离异', 'character', ['离婚', '离异者', '寡妇鳏夫']),
    ('ch.pregnant_woman', '孕妇', 'character', ['怀胎女性']),
    ('ch.virgin_male', '童贞男', 'character', ['处男', '童贞']),
    ('ch.poor', '贫穷', 'character', ['穷人', '贫困']),
    ('ch.rich', '富有', 'character', ['富豪', '富人', '有钱人']),
    ('ch.disability', '残疾', 'character', ['残障', '身体障碍', '跛脚']),
    ('ch.mental_illness', '心理疾病', 'character', ['精神疾病', '心理问题', '抑郁症', '自闭症']),
    # ---------------- character：性格补充 ----------------
    ('ch.clumsy', '笨拙', 'character', ['废柴', '不器用']),
    ('ch.kuudere', '三无属性', 'character', ['三无', '无表情', '面无表情', '无口属性']),
    ('ch.hikikomori', '宅家', 'character', ['居家不出']),
    # ---------------- setting：地点 ----------------
    ('set.hospital', '医院', 'setting', ['病院', '诊所', '病房']),
    ('set.office', '公司职场', 'setting', ['办公室', '职场', '会社', '公司']),
    ('set.cafe', '咖啡厅', 'setting', ['咖啡馆', '喫茶店', '餐厅']),
    ('set.bar', '酒吧', 'setting', ['酒馆', '居酒屋', '夜店']),
    ('set.library', '图书馆', 'setting', ['图书室']),
    ('set.church', '教堂', 'setting', ['教会', '大教堂', '基督教堂']),
    ('set.temple', '寺庙神社', 'setting', ['寺庙', '神社', '寺院', '祠堂', '宗教场所']),
    ('set.laboratory', '实验室', 'setting', ['研究所', '研究室']),
    ('set.amusement_park', '游乐园', 'setting', ['游园地', '主题公园', '马戏团']),
    ('set.aquarium', '水族馆', 'setting', ['海洋馆']),
    ('set.beach', '海滩', 'setting', ['海滨', '沙滩', '海岸']),
    ('set.forest', '森林', 'setting', ['树林', '丛林']),
    ('set.desert', '沙漠', 'setting', ['荒漠']),
    ('set.space_station', '空间站', 'setting', ['太空站', '宇宙飞船', '潜水艇', '飞艇']),
    ('set.ruins', '废墟遗迹', 'setting', ['遗迹', '废墟', '古代遗迹']),
    ('set.train', '列车电车', 'setting', ['电车', '火车', '新干线']),
    ('set.hotel', '旅馆酒店', 'setting', ['旅馆', '酒店', '度假村', '爱情旅馆', '度假小屋']),
    ('set.casino', '赌场会所', 'setting', ['赌场', 'カジノ']),
    ('set.onsen', '温泉浴场', 'setting', ['温泉', '温泉旅馆', '浴场', '澡堂']),
    ('set.museum', '博物馆', 'setting', ['美术馆', '展览馆']),
    ('set.castle', '城堡宫殿', 'setting', ['城堡', '宫殿', '庄园']),
    ('set.slum', '贫民窟', 'setting', ['贫民区', '棚户区']),
    ('set.otherworld', '架空世界', 'setting', ['虚构世界', '虚构大陆']),
    # ---------------- setting：国家 / 地区 ----------------
    ('set.korea', '韩国', 'setting', ['朝鲜']),
    ('set.russia', '俄罗斯', 'setting', ['俄国']),
    ('set.ussr', '苏联', 'setting', ['苏维埃']),
    ('set.germany', '德国', 'setting', ['德意志']),
    ('set.france', '法国', 'setting', ['法兰西']),
    ('set.italy', '意大利', 'setting', ['意国']),
    ('set.uk', '英国', 'setting', ['不列颠', '英格兰']),
    ('set.usa', '美国', 'setting', ['美利坚', '合众国']),
    ('set.middle_east', '中东', 'setting', ['阿拉伯', '波斯']),
    ('set.india', '印度', 'setting', []),
    ('set.australia', '澳大利亚', 'setting', ['澳洲']),
    ('set.south_america', '南美', 'setting', ['拉丁美洲', '中美洲']),
    ('set.europe', '欧洲', 'setting', ['欧罗巴']),
    ('set.sea', '东南亚', 'setting', ['菲律宾', '印度尼西亚', '越南', '泰国']),
    ('set.africa', '非洲', 'setting', ['埃及地区']),
    # ---------------- setting：时代 ----------------
    ('set.showa', '昭和时代', 'setting', ['昭和']),
    ('set.heisei', '平成时代', 'setting', ['平成']),
    ('set.reiwa', '令和时代', 'setting', ['令和']),
    ('set.postwar', '战后', 'setting', ['战后时期', '战后日本']),
    ('set.future', '未来世界', 'setting', ['近未来', '未来', '未来都市', '未来地球']),
    ('set.steampunk', '蒸汽朋克', 'setting', ['スチームパンク', 'Steampunk']),
    ('set.hard_scifi', '硬科幻', 'setting', ['硬核科幻']),
    ('set.modern_fantasy', '现代奇幻', 'setting', ['都市奇幻', '都市幻想']),
    # ---------------- tone ----------------
    ('tone.psych_horror', '心理恐怖', 'tone', ['精神恐怖', '心理惊悚']),
    ('tone.black_comedy', '黑色喜剧', 'tone', ['黑色幽默', 'ダークコメディ']),
    ('tone.satire', '讽刺', 'tone', ['諷刺', '社会讽刺']),
    ('tone.surreal', '超现实主义', 'tone', ['超现实', 'シュルレアリスム']),
    ('tone.atmosphere', '氛围作', 'tone', ['氛围游戏', '雰囲気ゲー', '空气系']),
    ('tone.serious', '严肃沉重', 'tone', ['严肃', '沉重', 'シリアス']),
    ('tone.romantic', '浪漫', 'tone', ['罗曼蒂克', '浪漫主义']),
    ('tone.cute', '可爱', 'tone', ['かわいい']),
    ('tone.guro', '暴力血腥', 'tone', ['猎奇血腥', '血腥暴力', '血腥', '暴力描写']),
    ('tone.nihilism', '虚无', 'tone', ['虚无主义', '虚无感', '存在主义']),
    # ---------------- theme ----------------
    ('th.redemption', '救赎', 'theme', ['贖罪', '救赎主题']),
    ('th.ethics', '伦理', 'theme', ['道德伦理', '伦理学']),
    ('th.life', '人生', 'theme', ['人生主题', '人生百态']),
    ('th.sacrifice', '牺牲', 'theme', ['献身', '自我牺牲']),
    ('th.betrayal', '背叛', 'theme', ['背信', '出卖']),
    ('th.self_discovery', '自我认同', 'theme', ['身份认同', '自我探索']),
    ('th.shuraba', '修罗场', 'theme', ['修羅場']),
    ('th.family_love', '家庭伦理', 'theme', ['家庭剧', '家庭生活剧']),
    ('th.war_crime', '战争罪行', 'theme', ['战犯', '战争暴行']),
    ('th.trauma', '心理创伤', 'theme', ['创伤', '心理阴影', '心灵创伤']),
    ('th.travel', '旅行', 'theme', ['旅程', '旅游', '旅途', '公路旅行', '旅行题材']),
    # ---------------- element：死亡 ----------------
    ('el.death', '死亡', 'element', ['死亡结局', '角色死亡', '死亡路线', '死亡描写']),
    # ---------------- element ----------------
    ('el.superpower', '超能力', 'element', ['异能', '超能力战斗', 'ESP', '超感知能力']),
    ('el.exorcism', '驱魔', 'element', ['退魔', '除魔', '祓魔']),
    ('el.summoning', '召唤', 'element', ['召喚', '召唤术']),
    ('el.alchemy', '炼金术', 'element', ['錬金術', 'Alchemy']),
    ('el.urban_legend', '都市传说', 'element', ['都市伝説', '校园怪谈', '学园七大不思议']),
    ('el.episodic', '单元剧', 'element', ['单元故事', '单元事件', '短片集']),
    ('el.ensemble', '群像叙事', 'element', ['群像剧', '群像', '多主角']),
    ('el.multi_perspective', '多视点', 'element', ['多视角', '多视点叙事', '群像视角']),
    ('el.unreliable_narrator', '叙述性诡计', 'element', ['不可靠叙述者', '叙述诡计']),
    ('el.metafiction', '元叙事', 'element', ['Meta', '元小说', '打破第四面墙', '穿越第四面墙', '第四面墙', 'Meta小说', '元游戏', '元叙事手法']),
    ('el.epistolary', '书信体', 'element', ['书信叙事', '日记体']),
    ('el.nonlinear', '非线性叙事', 'element', ['倒叙', '插叙', '预叙', '时间跳跃']),
    ('el.suicide', '自杀', 'element', ['自尽', '寻死']),
    ('el.murder', '谋杀', 'element', ['凶杀', '杀人事件', '杀人']),
    ('el.crime', '犯罪', 'element', ['犯罪题材', '刑事案件', '犯罪情节']),
    ('el.kidnapping', '绑架', 'element', ['诱拐', '人质', '人质危机']),
    ('el.cooking', '料理美食', 'element', ['美食', '料理', '烹饪', '美食讨论']),
    ('el.music', '音乐主题', 'element', ['乐队', '摇滚', '乐队题材']),
    ('el.sakura', '樱花', 'element', ['桜', '赏樱']),
    ('el.tarot', '塔罗牌', 'element', ['塔罗', '占卜', '算命']),
    ('el.mahjong_game', '麻将', 'element', ['麻雀', '麻将作为故事要素']),
    ('el.hanafuda', '花札', 'element', ['花牌', '花札游戏']),
    ('el.school_festival', '学园祭典', 'element', ['学园祭', '文化祭', '学校节日', '体育节', '运动会']),
    ('el.graduation', '毕业', 'element', ['毕业典礼']),
    ('el.funeral', '葬礼', 'element', ['葬仪', '告别式', '哀悼']),
    ('el.ritual', '仪式典礼', 'element', ['加冕', '典礼']),
    ('el.secret_organization', '秘密组织', 'element', ['秘密结社', '神秘组织']),
    ('el.cult', '邪教', 'element', ['邪教组织', '新兴宗教', '宗教组织']),
    ('el.royal_intrigue', '宫廷斗争', 'element', ['宫斗', '皇位争夺', '王位继承']),
    ('el.festival', '节日庆典', 'element', ['祭典', '节庆']),
    ('el.season', '季节', 'element', ['四季', '季节变迁']),
    # ---------------- playstyle ----------------
    ('ps.fighting', '格斗', 'playstyle', ['格斗游戏', '対戦格闘', 'Fighting']),
    ('ps.racing', '竞速', 'playstyle', ['赛车', '竞速游戏', 'Racing', '竞速比赛']),
    ('ps.typing', '打字游戏', 'playstyle', ['打字练习', 'Typing']),
    ('ps.puzzle', '益智解谜', 'playstyle', ['益智游戏', '解谜游戏', 'パズル', 'Puzzle']),
    ('ps.rhythm', '音乐节奏', 'playstyle', ['音游', '节奏游戏', 'リズムゲーム']),
    ('ps.sports', '体育运动', 'playstyle', ['体育', '运动游戏', 'スポーツ', '竞技', '球类', '排球', '篮球', '足球', '网球', '棒球', '游泳']),
    ('ps.board_game', '棋牌桌游', 'playstyle', ['桌游', '棋牌', '桌面游戏', '扑克游戏', '花札']),
    ('ps.quiz', '问答游戏', 'playstyle', ['知识问答', 'クイズ']),
    ('ps.clicker', '点击放置', 'playstyle', ['点击游戏', '放置游戏', 'クリッカー']),
    ('ps.gacha', '扭蛋抽卡', 'playstyle', ['抽卡', '扭蛋游戏', 'ガチャ']),
    ('ps.indie', '独立游戏', 'playstyle', ['独立制作', 'Indie']),
    ('ps.os_sim', '操作系统模拟', 'playstyle', ['界面模拟', 'OS模拟']),
    ('ps.raising_sim', '抚养模拟', 'playstyle', ['育儿模拟', '育儿']),
    # ---------------- art ----------------
    ('art.2d', '2D画面', 'art', ['2D', '平面2D']),
    ('art.monochrome', '黑白风格', 'art', ['黑白', '单色', 'モノクロ']),
    ('art.cross_section', '断面图', 'art', ['透视断面', '内部描写']),
    ('art.silhouette', '轮廓剪影', 'art', ['剪影', 'シルエット']),
    ('art.western_style', '西式画风', 'art', ['西洋风格', '西式']),
    ('art.indie_style', '手绘风格', 'art', ['手绘', '绘本风']),
]

# =========================================================================
# 2) 既有概念追加别名（按规范名匹配）
# =========================================================================
EXTRA4 = {
    '三角恋': ['三角'],
    # adult
    '强迫': ['强X', '强奸', '凌辱剧情', '大量强奸内容', '少量强奸', '强奸未遂', '胁迫', '勒索强奸', '欺诈强奸', '被冤枉'],
    '群交': ['淫乱', '滥交', '银趴', '滥淫', '交配'],
    '多重插入': ['两穴磨枪', '双插'],
    '自慰': ['相互手淫', '阴道自慰', '阴蒂自慰', '阴蒂刺激', '阴茎自慰', '肛门自慰', '公共场合自慰', '观众面前自慰', '隐蔽自慰', '自我恋爱', '桌角自慰'],
    'SM': ['BDSM', '虐恋'],
    '拘束捆绑': ['紧缚', '捆绑', '束缚', '拘束', '绳索捆绑', '胶带捆绑', '皮革捆绑', '金属捆绑', '枷锁', '锁链', '手铐', '项圈', '口塞', '眼罩', '蒙眼', '性爱蒙眼', '拘束服', '贞操带', '感官剥夺', '捆绑重物', '悬挂捆绑'],
    '调教': ['性奴调教', '奴役', '放置Play'],
    '成人玩具': ['假阴茎', '假阳具', '飞机杯', '电动棒', '跳蛋', '按摩棒', '振动器', '双头假阳具', '钻头假阳具', '情趣道具', '道具异物', '物体插入', '性玩具'],
    '催眠洗脑': ['洗脑', '精神控制', '常识改变', '记忆改变', '精神控制做爱', '非情色心灵控制'],
    '睡奸': ['睡眠性爱', '昏睡'],
    '催情药物': ['药物', '药物使用', '药物性交', '春药', '涉及毒品的自愿性行为'],
    '怀孕': ['孕妇', '西瓜肚', '受孕', '受精怀孕', '生产', '分娩', '生育', '全妊娠', '人类分娩', '产后'],
    '孕交': ['受孕选择', '产子'],
    '母乳': ['泌乳', '做爱时泌乳', '母乳play', '乳液游戏'],
    '露出': ['走光', '当众暴露'],
    '偷拍盗撮': ['盗摄', '偷窥', '窥视'],
    '痴汉': ['痴女', '性骚扰', '公共场所性骚扰'],
    '啊嘿颜': ['阿黑颜', '高潮脸'],
    '恶堕': ['堕落', '雌堕', '性堕落', '角色崩坏'],
    '重口': ['鬼畜', '过激内容'],
    '监禁': ['限制自由', '囚禁play', '软禁'],
    '特殊场所性爱': ['车内性爱', '教室性爱', '学校做爱', '校内性爱', '屋顶做爱', '公园做爱', '沙滩做爱', '水中做爱', '野外性爱', '野战', '公开场合隐奸', '观众面前做爱'],
    '浴室场景': ['洗澡', '泡澡', '淋浴', '泡泡浴'],
    '乳交': ['胸部摩擦', '穿衣乳交'],
    '素股腿交': ['腿交', '股交', '腿间性行为'],
    '口交': ['舔阴', '舔穴', '嘴交'],
    '肛交': ['肛门插入', '肛门性交'],
    '中出': ['内射'],
    '颜射': ['自己颜射'],
    '时间停止': ['时间静止'],
    '女性主导': ['女攻', '女上位'],
    '男性主导': ['男攻', '男上位'],
    '交换伴侣': ['换妻', '多边恋', '开放关系'],
    '失禁': ['漏尿'],
    # theme / element
    '后宫': ['真后宫', '可解锁后宫结局', '具有主题的后宫结局'],
    '卖淫风俗': ['卖春', '援交', '风俗', '枕营业', '红灯区', '风俗娘', '妓院'],
    '一夜情': ['约炮', '猎艳搭讪'],
    '主仆恋': ['主从', '主仆'],
    '婚外情': ['通奸', '不伦', '出轨外遇', '婚外恋'],
    '师生恋': ['师生'],
    '忘年恋': ['年龄差恋爱'],
    '同性恋': ['GAY', '男同', '男同性恋'],
    '百合': ['蕾丝边', '女性之间做爱', '仅女同性爱', '女同'],
    'BL': ['蔷薇向', '耽美向', '男男', '男同恋爱'],
    '乙女': ['女性向', '乙女向游戏', '女性向け'],
    '近亲': ['乱伦恋情', '禁断之恋', '骨科', '兄妹', '姐弟', '母女', '父子', '母子'],
    '人外恋': ['跨种族恋情', '异族恋', '跨种族'],
    '重逢': ['再会', '久别重逢', '同窗会', '校友回归'],
    '离别': ['分别', '告别'],
    '羁绊': ['缘分', '纽带', '异族羁绊'],
    '失忆': ['记忆丧失', '遗忘'],
    '复仇': ['报复', '复仇剧'],
    '战争': ['军事', '战记', '战役', '第二次世界大战', '战争题材'],
    '政治斗争': ['政治', '权力斗争', '阴谋诡计', '政治腐败'],
    '死亡游戏': ['死亡竞赛', '杀戮游戏'],
    '成长': ['成长剧', '角色成长', '剧烈的角色成长'],
    '变身': ['变身英雄', '魔法变身'],
    '诅咒': ['咒术', '诅咒之力'],
    '梦境': ['梦中世界', '清醒梦', '噩梦'],
    '多重人格': ['双重人格', '解离性身份障碍'],
    '命运': ['宿命', '命中注定'],
    '死亡': ['死亡结局', '角色死亡', '死亡路线'],
    # setting
    '校园': ['学园', '学校', '学生生活', '学校生活'],
    '都市现代': ['现代社会', '当代都市'],
    '和风历史': ['日本战国题材', '战国题材', '幕末题材', '江户题材', '新撰组'],
    '中世纪': ['中世纪奇幻', '中世纪欧洲', '中世纪地球'],
    '古代中国': ['三国题材', '三国'],
    '田园乡村': ['乡下', '农村', '田园'],
    '孤岛': ['离岛', '无人岛', '岛屿'],
    '洋馆宅邸': ['大宅', '公馆'],
    '学校宿舍': ['学生宿舍', '宿舍'],
    '监狱': ['收容所', '牢狱'],
    '神话超自然': ['取材自神话传说', '民俗', '民间传说', '民间宗教', '超自然现象', '灵异现象', '超常现象', '通灵'],
    '日本神话': ['日本神话传说', '和风神话'],
    '末世': ['末日', '世界末日', '社会崩溃'],
    # tone
    '郁系致郁': ['虐心', '致郁系', '灰暗系', '压抑'],
    '搞笑': ['喜剧', '欢乐', '搞笑剧情'],
    '悬疑推理': ['推理', '侦探', '探案'],
    '恐怖惊悚': ['恐怖', '惊悚'],
    '热血': ['战斗热血', '热血燃'],
    '王道': ['王道展开'],
    '泣系': ['催泪'],
    '轻松': ['休闲', '治愈轻松'],
    '青春': ['青春校园', '学园青春'],
    # character
    '御姐': ['大姐姐', '年上'],
    '辣妹': ['黑皮角色'],
    '伪娘': ['男娘', '可爱的男孩子'],
    '跨性别': ['性别非二元', '非二元性别', '性别认同', '性别转换者'],
    '女主人公': ['女性主人公', '女主角可攻略'],
    '男性主人公': ['男主人公', '单男主角', '可选男性主人公'],
    '大小姐': ['千金'],
    '教师': ['女教师', '教师角色'],
    '护士': ['护理员'],
    '学生': ['学校学生', '女学生', '男学生'],
    '音乐家': ['乐器演奏家', '器乐演奏家'],
    '运动员': ['体育选手'],
    '科学家': ['疯狂科学家', '研究者'],
    '记者': ['记者角色'],
    '模特': ['写真模特'],
    '僧侣': ['牧师', '神父', '神职人员'],
    '精灵': ['妖精', 'エルフ', '仙子'],
    '兽人': ['兽耳族', '福瑞', '獣人', '兽娘'],
    '吸血鬼': ['血族'],
    '僵尸': ['丧尸', '活尸', '不死系'],
    '幽灵': ['亡灵', '鬼魂'],
    '人工智能': ['AI', 'AI角色'],
    '机器人': ['安卓', '机械人'],
    '外星人': ['宇宙人'],
    '天使': ['天使族', '半天使'],
    '恶魔': ['恶魔族', '魔族', '半恶魔'],
    '萝莉': ['幼女'],
    '正太': ['少年'],
    # art
    '动漫风格': ['动画风格', '动画', '日系'],
    '高质量CG': ['画风美', '精美CG'],
    '动态CG': ['动态', '动态立绘'],
    '写实风格': ['逼真的3D', '真实风'],
    '全语音': ['全配音'],
    '无语音': ['无配音'],
}

# =========================================================================
# 3) 生成期吸收规则（有序；对 NextMoe 未命中标签首命中即吸收为显式别名）
#    仅用于「生成别名」，运行时仍是纯倒排，无模糊匹配。
# =========================================================================
RULES = [
    # ---- 先处理与既有概念冲突的专有词组 ----
    (r'黑帮|极道|黑社会|黑手党|帮派|yakuza', 'ch.yakuza'),
    (r'猫|狗|猫咪|狗狗|兔子|蜘蛛|恐龙|动物|宠物|两栖|爬行|鱼类|鲨鱼|章鱼|昆虫|蝴蝶', 'ch.animal'),
    (r'日本|和风|日式|新撰组|幕末|江户', 'set.japan'),
    (r'现代|当代|都市|东京|涩谷|秋叶原|大都市', 'set.city'),
    (r'异装|女装|男装|cosplay|情趣角色扮演|角色扮演|换装', 'el.dressup'),
    (r'涉及卖淫|卖淫|性交易', 'th.prostitution'),
    (r'虚拟主播|VTuber|Vtuber|虚拟偶像', 'ch.virtual_youtuber'),
    (r'欺凌|霸凌', 'el.bullying'),
    (r'跟踪|尾随|纠缠', 'el.stalking'),
    (r'窒息', 'ad.bondage'),
    (r'疾病|绝症|顽疾|不治之症', 'ch.sickly'),
    (r'魔女|女巫|魔法师|魔法使', 'ch.witch'),
    (r'吸血|血族', 'ch.vampire'),
    (r'僵尸|丧尸|活尸', 'ch.zombie'),
    (r'神明|女神|神灵', 'ch.god'),
    (r'魔王|魔君', 'ch.maou'),
    (r'龙族|巨龙|ドラゴン', 'ch.dragon'),
    (r'恶魔族|魔族|魔鬼', 'ch.demon'),
    (r'天使族|翼人', 'ch.angel'),
    (r'死亡游戏|杀戮游戏|生存游戏', 'el.death_game'),
    (r'死亡', 'el.death'),
    (r'社团|俱乐部|委员会', 'el.school_club'),
    (r'内裤|内衣|胸罩|尿布', 'ch.lingerie'),
    (r'安全套|避孕套|避孕药', 'ad.toys'),
    (r'恐龙|兔子|蜘蛛|两栖|爬行类|鸟类|鱼类|鲨鱼|章鱼|灵长类|昆虫|蝴蝶|动物|宠物', 'ch.animal'),
    (r'^69', 'ad.69'),
    (r'时间停止|时间静止', 'ad.time_stop'),
    (r'触手', 'ad.tentacle'),
    (r'群交|轮交|乱交|银趴|多人运动|多P|多p', 'ad.groupsex'),
    (r'双重插入|两穴|双插', 'ad.dp'),
    (r'乳交', 'ad.paizuri'),
    (r'足交|足コキ|鞋交', 'ad.footjob'),
    (r'手交|手コキ', 'ad.handjob'),
    (r'口交|フェラ|深喉|口内射精|口爆|舔阴|舔穴', 'ad.oral'),
    (r'肛|后庭|アナル', 'ad.anal'),
    (r'素股|腿交|股交|胯下', 'ad.sumata'),
    (r'中出|内射|膣内', 'ad.nakadashi'),
    (r'颜射|精液|吞精|饮精|榨精|大量汁|精液浴', 'ad.facial'),
    (r'自慰|手淫|自交', 'ad.masturbation'),
    (r'3[pP]|三人行|姐妹丼|母女丼|母娘丼|亲子丼|双飞', 'ad.threesome'),
    (r'调教|奴役|性奴|肉便器|肉奴隶', 'ad.sexual_slavery'),
    (r'捆绑|束缚|紧缚|拘束|枷锁|锁链|项圈|手铐|口塞|眼罩|蒙眼|贞操|拘束服|感官剥夺|身体束缚', 'ad.bondage'),
    (r'BDSM|S&M|SM|虐恋|滴蜡|鞭打|鞭子|捆绑SM', 'ad.sm'),
    (r'玩具|假阳|飞机杯|跳蛋|按摩棒|振动器|情趣道具|尿道|拉珠', 'ad.toys'),
    (r'催眠|洗脑|精神控制|常识改变|记忆改变', 'ad.hypnosis'),
    (r'睡眠性爱|睡奸|昏睡|睡眠中', 'ad.sleep_rape'),
    (r'强奸|强X|迷奸|轮奸|胁迫|凌辱|无理矢理', 'ad.rape'),
    (r'催情|春药|媚药|药物', 'ad.aphrodisiac'),
    (r'怀孕|妊娠|受孕|孕妇|西瓜肚|生育|分娩|出产|产后|胎动', 'ad.pregnant'),
    (r'母乳|泌乳|挤奶|哺乳|乳汁', 'ad.lactation'),
    (r'处女|破处|破瓜|处子', 'ad.virgin'),
    (r'扶她|ふたなり|双性人', 'ad.futanari'),
    (r'浴室|泡澡|淋浴|温泉|澡堂', 'ad.bath'),
    (r'露出|走光|当众|公开场合|观众面前|旁观下|窥视', 'ad.exhibitionism'),
    (r'偷拍|盗摄|偷窥|窥视欲', 'ad.voyeurism'),
    (r'野外|户外|车内|教室|屋顶|公园|沙滩做爱|水中做爱|电车性|公共', 'ad.public_sex'),
    (r'女上位|女性主导|女攻|逆推|女上', 'ad.femdom'),
    (r'男上位|男性主导|男攻', 'ad.maledom'),
    (r'换妻|多边恋|开放关系|交换伴侣', 'ad.swinging'),
    (r'痴汉|痴女|性骚扰|电车痴', 'ad.molestation'),
    (r'失禁|漏尿|失禁play', 'ad.incontinence'),
    (r'恶堕|堕落|雌堕|性堕落|角色崩坏', 'ad.corruption'),
    (r'重口|过激|鬼畜|guro|グロ', 'ad.extreme'),
    (r'监禁|囚禁|限制自由|软禁|拘禁', 'ad.confinement'),
    (r'阿黑颜|啊嘿颜|高潮脸|颜艺|アヘ顔', 'ad.ahogao'),
    (r'放尿|排尿|饮尿|小便|尿play|尿道P', 'ad.urination'),
    (r'粪便|排泄|脱粪|大便|灌肠|浣肠', 'ad.scat'),
    (r'兽交|獣姦|与动物性交|昆虫性交|仅与动物|人兽', 'ad.bestiality'),
    (r'怪物|异种|魔物|史莱姆|植物性交|机械X', 'ad.monster_sex'),
    (r'产卵|産卵', 'ad.oviposition'),
    (r'丸吞|吞食|胎内回归', 'ad.vore'),
    (r'恋尸', 'ad.necrophilia'),
    (r'截肢|切断', 'ad.amputee'),
    (r'人体改造|肉体改造|身体改造', 'ad.body_mod'),
    (r'拷问|酷刑', 'ad.torture'),
    (r'搔痒|挠痒|腋窝', 'ad.tickling'),
    (r'步兵|无修正|无码|去码', 'ad.uncensored'),
    (r'骑兵|有码|马赛克', 'ad.censored'),
    (r'打屁股|spanking|spank', 'ad.spanking'),
    (r'坐脸|骑脸|颜骑', 'ad.facesitting'),
    (r'舔肛|舔菊|毒龙', 'ad.rimming'),
    (r'体位|后背位|后入|传教士|站立式|女上位体|男上位体|狗交式|打桩机|侧入|座り|座位', 'ad.position'),
    (r'指交|指插|手指插入', 'ad.fingering'),
    (r'拳交|fisting', 'ad.fisting'),
    (r'扩张', 'ad.dilation'),
    (r'恋足|舔脚|足部崇拜', 'ad.foot_worship'),
    (r'潮吹|吹潮', 'ad.squirting'),
    (r'前列腺', 'ad.prostate'),
    (r'榨精|挤奶', 'ad.milking'),
    # ---- theme ----
    (r'NTR|寝取|ntr|黄毛|绿帽|牛头人', 'th.ntr'),
    (r'百合|女女|女性同士|蕾丝', 'th.yuri'),
    (r'BL|男同|男男|耽美|蔷薇向', 'th.bl'),
    (r'乱伦|近亲|血缘|背德|骨科|义理|禁断', 'th.incest'),
    (r'后宫|ハーレム|harem', 'th.harem'),
    (r'恋爱|恋愛|爱情', 'th.romance'),
    (r'卖春|援交|风俗|妓|枕营业|红灯区', 'th.prostitution'),
    (r'三角恋|三角关系|修罗场', 'th.triangle'),
    (r'纯爱|纯情|纯愛', 'th.vanilla'),
    (r'乙女|女性向', 'th.otome'),
    (r'同性恋|男同|GAY', 'th.gay'),
    (r'人外|异种族|跨种族|异种恋', 'th.nonhuman_love'),
    (r'亲情|家族爱|家庭爱|家族羁绊', 'th.family'),
    (r'友情|友谊', 'th.friendship'),
    (r'师生恋|师生', 'th.teacher_love'),
    (r'婚外情|出轨|不伦|通奸', 'th.affair'),
    (r'救赎|贖罪', 'th.redemption'),
    (r'伦理|道德', 'th.ethics'),
    (r'人生', 'th.life'),
    (r'牺牲|献身', 'th.sacrifice'),
    (r'背叛|背信', 'th.betrayal'),
    (r'自我认同|身份认同', 'th.self_discovery'),
    (r'修罗场', 'th.shuraba'),
    (r'修罗场|腥风血雨', 'th.shuraba'),
    # ---- element ----
    (r'轮回|转生|转世|重生|异世界转生', 'el.reincarnation'),
    (r'穿越|时间旅行|时光', 'el.timetravel'),
    (r'平行世界|平行宇宙|多元宇宙|跨次元', 'el.parallel'),
    (r'性别转换|性转|女体化|男体化|身体交换', 'el.genderbender'),
    (r'失忆|记忆丧失|记忆改变|记忆操作', 'el.amnesia'),
    (r'复仇|报复', 'el.revenge'),
    (r'梦境|梦中|白日梦', 'el.dream'),
    (r'幻觉|妄想|幻听', 'el.hallucination'),
    (r'多重人格|双重人格|解离', 'el.multiple_personality'),
    (r'附身|凭依', 'el.possession'),
    (r'诅咒|咒术', 'el.curse'),
    (r'契约|合同|恶魔契约', 'el.contract'),
    (r'误会|误解', 'el.misunderstanding'),
    (r'死亡游戏|杀戮游戏|生存游戏', 'el.death_game'),
    (r'逃亡|逃亡者|追捕', 'el.escape'),
    (r'成长|蜕变', 'el.growth'),
    (r'战争|军事冲突|战记|战役|海战|战场', 'el.war'),
    (r'政治|权力斗争|阴谋|政变|谋反|叛乱', 'el.politics'),
    (r'寻宝|财宝|宝藏', 'el.treasure_hunt'),
    (r'复活|死而复生', 'el.resurrection'),
    (r'克隆|复制人', 'el.clone'),
    (r'命运|宿命', 'el.fate'),
    (r'决斗|对决|单挑', 'el.duel'),
    (r'壁咚|壁ドン', 'el.kabedon'),
    (r'夏天|夏季|盛夏|夏祭', 'el.summer'),
    (r'冬天|冬季|严冬|雪景', 'el.winter'),
    (r'圣诞', 'el.christmas'),
    (r'情人节|バレンタイン', 'el.valentine'),
    (r'万圣节|ハロウィン', 'el.halloween'),
    (r'七夕|たなばた', 'el.tanabata'),
    (r'婚礼|结婚典礼', 'el.wedding'),
    (r'赌博|赌局|赌场|麻将赌', 'el.gamble'),
    (r'不死|永生|不老不死', 'el.undead'),
    (r'七宗罪', 'el.seven_deadly_sins'),
    (r'亲吻|接吻|キス|kiss', 'el.kiss'),
    (r'同居|同棲', 'el.cohabitation'),
    (r'闪回|回忆|回想', 'el.flashback'),
    (r'战斗|バトル|战乙女|搏斗', 'el.battle'),
    (r'超能力|异能|超能力战斗|ESP|超感知', 'el.superpower'),
    (r'驱魔|退魔|除魔|祓魔|魔女猎人|吸血鬼猎人', 'el.exorcism'),
    (r'召唤|召喚', 'el.summoning'),
    (r'炼金术|錬金術', 'el.alchemy'),
    (r'都市传说|都市伝説|怪谈|七大不思议|都市怪谈', 'el.urban_legend'),
    (r'单元剧|单元故事|单元事件|短片集', 'el.episodic'),
    (r'群像', 'el.ensemble'),
    (r'多视点|多视角|多视点叙事', 'el.multi_perspective'),
    (r'叙述性诡计|不可靠叙述者|叙述诡计|第三人称|第二人称|第一人称', 'el.unreliable_narrator'),
    (r'Meta|元小说|元叙事|第四面墙|元宇宙|元游戏|meta', 'el.metafiction'),
    (r'书信|日记体|手记', 'el.epistolary'),
    (r'倒叙|插叙|预叙|非线性|时间跳跃', 'el.nonlinear'),
    (r'自杀|自尽|寻死|自杀未遂', 'el.suicide'),
    (r'谋杀|凶杀|杀人|杀人事|连环杀', 'el.murder'),
    (r'犯罪|刑事案件|诈骗|抢劫|敲诈|绑票', 'el.crime'),
    (r'绑架|诱拐|人质', 'el.kidnapping'),
    (r'料理|美食|烹饪|食戟|吃饭|餐厅剧', 'el.cooking'),
    (r'音乐|乐队|摇滚|演奏|乐器', 'el.music'),
    (r'樱花|桜|赏樱', 'el.sakura'),
    (r'塔罗|占卜|算命', 'el.tarot'),
    (r'麻将|麻雀', 'el.mahjong_game'),
    (r'花札|花牌', 'el.hanafuda'),
    (r'学园祭|文化祭|学校节日|体育节|运动会|校园活动', 'el.school_festival'),
    (r'毕业', 'el.graduation'),
    (r'葬礼|葬仪|告别式|哀悼|守灵', 'el.funeral'),
    (r'秘密组织|秘密结社|神秘组织', 'el.secret_organization'),
    (r'邪教|新兴宗教|宗教组织|崇拜', 'el.cult'),
    (r'宫斗|王位继承|皇位|加冕|宫廷', 'el.royal_intrigue'),
    (r'祭典|节庆|节日|庙会', 'el.festival'),
    # ---- setting ----
    (r'医院|病院|诊所|病房|医疗', 'set.hospital'),
    (r'办公室|职场|会社|公司|上班族|OL', 'set.office'),
    (r'咖啡|咖啡馆|喫茶|餐厅', 'set.cafe'),
    (r'酒吧|酒馆|居酒屋|夜店', 'set.bar'),
    (r'图书馆|图书室', 'set.library'),
    (r'教堂|教会|大教堂', 'set.church'),
    (r'寺庙|神社|寺院|祠堂', 'set.temple'),
    (r'实验室|研究所|研究室', 'set.laboratory'),
    (r'游乐园|游园地|主题公园|马戏团', 'set.amusement_park'),
    (r'水族馆', 'set.aquarium'),
    (r'海滩|海滨|沙滩|海岸|海边', 'set.beach'),
    (r'森林|树林|丛林', 'set.forest'),
    (r'沙漠|荒漠', 'set.desert'),
    (r'空间站|太空站|宇宙飞船|潜水艇', 'set.space_station'),
    (r'废墟|遗迹|遗址', 'set.ruins'),
    (r'电车|火车|列车|新干线', 'set.train'),
    (r'旅馆|酒店|度假村|爱情旅馆|民宿', 'set.hotel'),
    (r'赌场|カジノ', 'set.casino'),
    (r'温泉|浴场|澡堂', 'set.onsen'),
    (r'博物馆|美术馆|展览馆|水族馆', 'set.museum'),
    (r'城堡|宫殿|庄园|宅邸|公馆', 'set.castle'),
    (r'贫民窟|贫民区|棚户区', 'set.slum'),
    (r'架空世界|虚构世界|虚构大陆', 'set.otherworld'),
    (r'美国|美利坚|合众国|纽约|洛杉矶', 'set.usa'),
    (r'英国|不列颠|英格兰|伦敦', 'set.uk'),
    (r'法国|法兰西|巴黎', 'set.france'),
    (r'德国|德意志', 'set.germany'),
    (r'意大利|罗马|威尼斯', 'set.italy'),
    (r'俄罗斯|俄国|莫斯科', 'set.russia'),
    (r'苏联|苏维埃', 'set.ussr'),
    (r'韩国|首尔|朝鲜', 'set.korea'),
    (r'印度|印度尼西亚|菲律宾|泰国|越南|东南亚', 'set.sea'),
    (r'中东|阿拉伯|波斯|伊斯兰', 'set.middle_east'),
    (r'澳大利亚|澳洲', 'set.australia'),
    (r'南美|拉丁美洲|中美洲|巴西', 'set.south_america'),
    (r'欧洲|欧罗巴', 'set.europe'),
    (r'昭和', 'set.showa'),
    (r'平成', 'set.heisei'),
    (r'令和', 'set.reiwa'),
    (r'战后', 'set.postwar'),
    (r'未来|近未来', 'set.future'),
    (r'蒸汽朋克|スチームパンク|steampunk', 'set.steampunk'),
    (r'硬科幻|硬核科幻', 'set.hard_scifi'),
    (r'现代奇幻|都市奇幻|都市幻想', 'set.modern_fantasy'),
    (r'赛博朋克|サイバーパンク|cyberpunk', 'set.cyberpunk'),
    (r'末世|末日|废土|后启示录', 'set.apocalypse'),
    (r'异世界|転生|转生|转世', 'set.isekai'),
    (r'校园|学园|学校|学園', 'set.school'),
    (r'中世纪|骑士团', 'set.medieval'),
    (r'古代中国|三国|中华|武侠|仙侠', 'set.ancient_china'),
    (r'战国|幕末|江户|新撰组|和风|忍者|武士|刀剑', 'set.japan'),
    (r'乡村|田园|农村|乡下|田园生活', 'set.countryside'),
    (r'监狱|收容所|牢狱', 'set.prison'),
    (r'宿舍|学生宿舍|寄宿', 'set.dorm'),
    (r'公寓|民居|住所', 'set.apartment'),
    (r'神话|传说|民俗', 'set.supernatural'),
    # ---- tone ----
    (r'心理恐怖|精神恐怖|心理惊悚', 'tone.psych_horror'),
    (r'黑色喜剧|黑色幽默|ダークコメディ', 'tone.black_comedy'),
    (r'讽刺|諷刺|社会讽刺', 'tone.satire'),
    (r'超现实|シュルレアリスム', 'tone.surreal'),
    (r'氛围作|雰囲気ゲー|空气系', 'tone.atmosphere'),
    (r'严肃|沉重|シリアス', 'tone.serious'),
    (r'浪漫|罗曼蒂克', 'tone.romantic'),
    (r'可爱|かわいい', 'tone.cute'),
    (r'猎奇|血腥|グロ|グロテスク', 'tone.grotesque'),
    (r'虚无|虚无主义|存在主义', 'tone.nihilism'),
    (r'拔作|ヌキゲー|抜きゲー', 'tone.nukige'),
    (r'萌系|废萌|萌え|萌作|萌ゲー', 'tone.moe'),
    (r'泣系|泣き|催泪|感人|感人泪下', 'tone.nakige'),
    (r'郁系|致郁|阴暗|阴郁', 'tone.utsu'),
    (r'治愈|癒し|暖心', 'tone.healing'),
    (r'搞笑|喜剧|コメディ|comedy', 'tone.comedy'),
    (r'悬疑|推理|ミステリ|mystery|探案', 'tone.mystery'),
    (r'恐怖|惊悚|ホラー|horror', 'tone.horror'),
    (r'黑暗|ダーク|dark', 'tone.dark'),
    (r'热血|熱血|燃|hot.?blood', 'tone.hot_blooded'),
    (r'温馨|ほのぼの|heartwarming', 'tone.heartwarming'),
    (r'轻松|休闲|light', 'tone.light'),
    (r'荒诞|不条理|absurd', 'tone.absurd'),
    (r'青春', 'tone.youth'),
    (r'电波|電波|denpa', 'tone.denpa'),
    (r'王道', 'tone.oudou'),
    (r'悲剧|悲劇|tragedy|惨剧', 'tone.tragedy'),
    # ---- playstyle ----
    (r'格斗|対戦格闘|fighting|拳击|摔跤', 'ps.fighting'),
    (r'竞速|赛车|racing', 'ps.racing'),
    (r'打字|typing', 'ps.typing'),
    (r'益智|解谜|パズル|puzzle|拼图', 'ps.puzzle'),
    (r'音游|节奏游戏|リズムゲーム|rhythm', 'ps.rhythm'),
    (r'体育|运动游戏|スポーツ|竞技|球类|排球|篮球|足球|网球|棒球|游泳|滑雪|滑冰', 'ps.sports'),
    (r'桌游|棋牌|桌面游戏|扑克|花札游戏|麻将游戏', 'ps.board_game'),
    (r'问答|クイズ|quiz', 'ps.quiz'),
    (r'点击|放置|クリッカー|clicker', 'ps.clicker'),
    (r'扭蛋|抽卡|ガチャ|gacha', 'ps.gacha'),
    (r'独立游戏|独立制作|indie|同人游戏', 'ps.indie'),
    (r'操作系统模拟|OS模拟|界面模拟', 'ps.os_sim'),
    (r'抚养|育儿|育児', 'ps.raising_sim'),
    (r'卡牌|カードゲーム|card.?game', 'ps.card_game'),
    (r'回合制|ターン制|turn.?based', 'ps.turn_based'),
    (r'生存|サバイバル|survival', 'ps.survival'),
    (r'沙盒|开放世界|オープンワールド|open.?world', 'ps.sandbox'),
    (r'地牢|迷宫|迷宮|地下城|ダンジョン', 'ps.dungeon'),
    (r'动作游戏|アクション|action', 'ps.action'),
    (r'射击|shooting|fps|tps', 'ps.shooting'),
    (r'养成|育成', 'ps.nurture'),
    (r'经营|経営|模拟经营|城市建设', 'ps.business'),
    (r'策略|戦略|strategy|战略', 'ps.slg'),
    # ---- art ----
    (r'2D|平面2D', 'art.2d'),
    (r'黑白|单色|モノクロ|monochrome', 'art.monochrome'),
    (r'断面图|透视图|内部描写', 'art.cross_section'),
    (r'剪影|シルエット|silhouette', 'art.silhouette'),
    (r'像素|ドット絵|pixel', 'art.pixel'),
    (r'动态CG|动态立绘|アニメーション|e-mote|emote', 'art.animated'),
    (r'Live2D|live2d', 'art.live2d'),
    (r'3D画面|逼真的3D|实时3D|非实时渲染3D', 'art.3d'),
    (r'全语音|全配音|フルボイス', 'art.fullvoice'),
    (r'无语音|无配音', 'art.novoice'),
    (r'部分语音|パートボイス', 'art.partvoice'),
    (r'ASMR|バイノーラル|双耳', 'art.asmr'),
    (r'Q版|SD原画|ちびキャラ|SDキャラ', 'art.chibi'),
    (r'AI生成|ai绘画|AI绘画', 'art.ai_generated'),
    (r'插入歌|挿入歌', 'art.insert_song'),
    (r'主题曲|オープニング|OP曲|ED曲', 'art.themesong'),
    (r'原创音乐|サウンドトラック|OST', 'art.ost'),
    (r'高质量CG|精美CG|画风美|美丽原画', 'art.highcg'),
    (r'写实|真实风|リアル', 'art.realistic'),
    (r'动漫风格|アニメ調|anime', 'art.anime'),
    (r'立绘|立ち絵|差分', 'art.tachie'),
    # ---- BATCH3：NextMoe core 残留规则 ----
    (r'下克上|下剋上|以下克上', 'th.gekokujo'),
    (r'天文学|天文观测|星象|观星', 'el.astronomy'),
    (r'环保主义|环境保护|生态保护', 'th.environmentalism'),
    (r'偷偷摸摸|潜伏|暗中行动|秘密行动|隐蔽行动', 'el.stealth'),
    (r'纯文学|文艺向|文学风格', 'art.literary'),
    (r'无插入|无正戏|无性场面', 'ad.no_penetration'),
    (r'补魔|做爱充能|魔力补充', 'ad.mana_recharge'),
    (r'萝莉性爱|幼女性爱', 'ad.loli'),
    (r'女主角(?:和|与).*非主人公|与非主角有关系的女主角', 'th.ntr'),
]

# 规则之外的核心标签精确兜底（优先于 RULES 之外的一般规则；运行时无影响）
EXACT = {
    '2D': 'art.2d',
    'ABO世界观': None,   # 暂不建概念（语义窄），保留未归类
    '乙女类游戏': 'th.otome',
    '交互式AVG': 'ps.adv',
    '视觉小说(无选项)': 'ps.nvl',
    '同人小说': 'ps.indie',
    '游戏竞赛中开发': None,
    '非日语配音': None,
    '纯文字色情内容': 'ps.nvl',
    '只有纯文字色情内容': 'ps.nvl',
    '只有声音的部分': None,
    '打字游戏': 'ps.typing',
    '扑克游戏': 'ps.board_game',
    '花札游戏': 'ps.board_game',
    '麻将作为故事要素': 'el.mahjong_game',
    '作为游戏要素的麻将': 'el.mahjong_game',
    '操作系统模拟': 'ps.os_sim',
    '扭蛋游戏': 'ps.gacha',
    '养成': 'ps.nurture',
    '益智游戏': 'ps.puzzle',
    '策略游戏': 'ps.slg',
    '格斗': 'ps.fighting',
    '竞速比赛': 'ps.racing',
    '体育': 'ps.sports',
    '排球': 'ps.sports',
    '猜拳': 'ps.board_game',
    '俄罗斯方块': 'ps.puzzle',
    '独立游戏': 'ps.indie',
    '医院': 'set.hospital',
    '办公室': 'set.office',
    '旅行': 'th.travel',
    '旅程': 'th.travel',
    '公路旅行': 'th.travel',
    '旅游': 'th.travel',
    '救赎': 'th.redemption',
    '伦理': 'th.ethics',
    '人生': 'th.life',
    '修罗场': 'th.shuraba',
    '三角': 'th.triangle',
    '师生': 'th.teacher_love',
    '乐队': 'el.music',
    '民俗': 'set.supernatural',
    '日本战国题材': 'set.japan',
    '战国时期': 'set.sengoku',
    '幕末时代': 'set.bakumatsu',
    '昭和时代': 'set.showa',
    '西式': 'art.western_style',
    '艺术': 'art.highcg',
    'Meta': 'el.metafiction',
    '打破第四面墙': 'el.metafiction',
    '竞技': 'ps.sports',
    '虚无': 'tone.nihilism',
    '可爱': 'tone.cute',
    '萌': 'tone.cute',
    '文学': None,
    '文本': None,
    '教育意义': None,
    '方言': None,
    '无分支': 'ps.linear',
    '无恋爱剧情': None,
    '无插入/无正戏': None,
    '无标题界面': None,
    '素描': None,
    '日系': 'art.anime',
}


# =========================================================================
# BATCH2：剩余 core 标签定点补充
# =========================================================================
NEW5 = [
    # adult
    ('ad.nipple', '乳头交', 'adult', ['乳头刺激', '乳头插入', '吸吮乳头']),
    ('ad.big_penis', '巨根', 'adult', ['巨大阴茎', '巨屌']),
    ('ad.fetish', '性癖', 'adult', ['癖好', '性趣', '恋物癖']),
    ('ad.humiliation', '羞辱', 'adult', ['羞耻', '耻辱', '言语刺激', '强迫色情羞辱']),
    ('ad.touching', '爱抚', 'adult', ['抚摸', '触摸', '前戏']),
    ('ad.massage', '按摩', 'adult', ['按摩店', '色情按摩']),
    ('ad.visible_insert', '可见插入', 'adult', ['可见子宫颈插入', '内部可见']),
    ('ad.stamina', '体力性爱', 'adult', ['剧烈性爱', '长性交场景', '连续高潮']),
    # character
    ('ch.animal', '动物', 'character', ['昆虫', '蝴蝶', '鸟类', '鱼类', '爬行动物', '灵长类']),
    ('ch.foreigner', '外国人', 'character', ['异国人', '外国籍']),
    ('ch.adult', '成年人', 'character', ['成人主人公', '仅有成年女主角', '成年男主角', '成年角色']),
    ('ch.lingerie', '内衣', 'character', ['内衣物', '胸罩']),
    ('ch.latex', '胶衣', 'character', ['乳胶衣', '紧身胶衣']),
    ('ch.body_hair', '体毛', 'character', ['阴毛', '腋毛', '肛毛', '身体毛发']),
    ('ch.zettai_ryouiki', '绝对领域美学', 'character', ['绝对领域', '过膝袜与短裙间隙']),
    ('ch.bl_role', '攻受', 'character', ['总受', '总攻', '男性受', '可攻可受', '高冷攻', '高冷受', '诱受', '年下攻', '攻受互换']),
    ('ch.teenager', '青少年', 'character', ['少女', '少年', '青年']),
    ('ch.robot_hero', '超级英雄', 'character', ['超级女英雄', '超级英雄主人公']),
    # element / theme
    ('el.anthropomorphism', '拟人化', 'element', ['拟人化生物', '拟人化物品']),
    ('el.hero_team', '战队英雄', 'element', ['战队', '特摄战队', '变身英雄团队']),
    ('el.dressup', '换装', 'element', ['换装play', '变装']),
    ('el.fairy_tale', '童话', 'element', ['童话故事', '安徒生童话', '格林童话']),
    ('el.religion', '宗教', 'element', ['信仰', '宗教题材']),
    ('el.invisibility', '隐形', 'element', ['透明化', '隐身']),
    ('el.battle_of_wits', '智斗', 'element', ['头脑战', '心理博弈']),
    ('el.elopement', '私奔', 'element', ['私奔出走']),
    ('el.crossover', '跨界联动', 'element', ['联动', '跨界合作', '联名']),
    ('el.adaptation', '改编作品', 'element', ['改编', '基于动画改编', '基于漫画改编', '基于轻小说改编', '基于小说改编', '基于游戏改编', '多媒体改编']),
    ('el.remake', '复刻重制', 'element', ['复刻版', '重制版', 'Remaster', 'HD重制']),
    ('el.series_work', '系列作品', 'element', ['系列', '系列作', '续作系列']),
    ('el.clothing_damage', '爆衣', 'element', ['衣服伤害', '衣装破坏', '爆衣play']),
    ('el.female_pov', '女性视角', 'element', ['女主角视角', '女性视点']),
    ('el.abo_world', 'ABO世界观', 'element', ['ABO', 'AlphaBetaOmega', '哨兵向导']),
    ('el.manipulation', '阴谋操控', 'element', ['操纵人心', '洗脑布局']),
    ('el.school_club', '社团活动', 'element', ['社团', '学生社团', '社团成员', '社团主席', '社团领导', '课外活动']),
    ('el.divorce_parent', '家庭变故', 'element', ['包办婚姻', '债务', '家庭暴力', '孤儿院', '托儿所']),
    ('el.bullying', '欺凌霸凌', 'element', ['欺凌', '霸凌', '校园霸凌', '校园欺凌']),
    ('el.stalking', '跟踪骚扰', 'element', ['跟踪狂', '纠缠', '尾随']),
    ('el.twelve_weapons', '十二神器魔器', 'element', ['十二神器', '十二魔器']),
    ('ch.virtual_youtuber', '虚拟主播', 'character', ['VTuber', 'Vtuber', '虚拟偶像']),
    # playstyle
    ('ps.derivative', '二创同人', 'playstyle', ['同人二创', '二次创作', '同人作品']),
    ('ps.multiple_protagonist', '多主人公', 'playstyle', ['可选择多主人公', '多主角可选', '双男主', '双女主']),
    # tone / setting / art
    ('tone.softcore', '软色情', 'tone', ['轻度情色', '擦边']),
    ('set.western_film', '西部题材', 'setting', ['西部片', '牛仔', '开拓时代']),
    ('art.manga_style', '漫画风', 'art', ['少年漫画风', '漫画风格']),
    # ===== BATCH3：NextMoe core 残留定点补充 =====
    ('th.gekokujo', '下克上', 'theme', ['以下克上', '下剋上', '下犯上']),
    ('el.astronomy', '天文学', 'element', ['天文', '星象', '观星', '天文观测', '占星']),
    ('th.environmentalism', '环保主义', 'theme', ['环境保护', '生态保护', '环保题材', '环境问题']),
    ('el.stealth', '隐蔽行动', 'element', ['偷偷摸摸', '潜伏', '隐蔽', '暗中行动', '秘密行动', '偷情密会']),
    ('art.literary', '文学风格', 'art', ['文学', '纯文学', '文艺向', '文艺风格']),
    ('ad.no_penetration', '无插入', 'adult', ['无正戏', '无插入无正戏', '无性行为', '无性场面']),
    ('ad.mana_recharge', '补魔', 'adult', ['做爱充能', '魔力补充', '魔力补给']),
    ('ad.loli', '萝莉性爱', 'adult', ['萝莉性爱和主题', '萝莉性爱和主题正常性取向', '幼女性爱']),
]

EXTRA5 = {
    '不良': ['混混', '不良少年', '小混混'],
    '义妹': ['义姐', '义理姐妹', '义理兄弟'],
    '跨性别': ['人妖', '人妖女主角'],
    '王族': ['王子', '王子系', '王子殿下'],
    '连裤袜': ['裤袜'],
    '丝袜': ['长袜', '短袜'],
    '大屁股': ['臀部', '屁股', '臀'],
    '巨乳': ['胸部', '奶子'],
    '淫乱': ['有过性经验的女主角', '沉迷于性的女主角', '痴迷', '痴迷于性'],
    '拔作': ['大量色情内容', '纯拔', '生H', '甜拔'],
    '猎奇': ['流血场景', '虐待', 'ryona', '血腥暴力', '肉体恐怖'],
    '变身': ['变身女主', '变身场景', '巨大化', '石化', '兽化', '女体化'],
    '仆人': ['奴仆', '侍从'],
    '恐怖惊悚': ['惊悚恐怖', '恐怖场景'],
    '搞笑': ['滑稽', '诙谐'],
    '科学家': ['研究员'],
    '僧侣': ['牧师', '神父'],
    '末世': ['废土', '末日世界'],
    '神话超自然': ['宗教', '信仰'],
    '监狱': ['牢狱', '拘留所'],
    '异世界': ['异世界转生', '转生异世界'],
    '时间停止': ['时间停止play'],
    '睡奸': ['睡眠中'],
    '怀孕': ['怀孕结局', '怀孕好结局', '怀孕坏结局', '西瓜肚孕妇'],
    '调教': ['奴役调教'],
    '催眠洗脑': ['洗脑催眠'],
    '痴汉': ['电车痴汉', '痴汉行为'],
    '特殊场所性爱': ['校内', '教室内', '浴室内'],
    '中出': ['阴道内射精', '体内射精'],
    '病弱': ['体弱', '体弱多病', '虚弱', '绝症', '身患绝症', '致命疾病', '疾病'],
    '贫乳': ['平胸', '飞机场', '微乳', '贫乳微乳'],
    '深色肌肤': ['褐皮', '晒痕', '古铜色肌肤'],
    '大屁股': ['巨臀'],
    '兽耳': ['兽耳族'],
    '银发': ['白发', '白毛'],
    '褐发': ['棕发', '茶发'],
    '傲娇': ['古典傲娇', 'ツンデレ'],
    '天然': ['天然呆', '傻白甜'],
    '无口': ['三无', '冷娇', '沉默寡言'],
    '害羞': ['内向', '怕生'],
    '温柔': ['和善', '善良'],
    '冷酷': ['无情', '冷漠'],
    '占有欲强': ['病态执着', '执着攻'],
    '单恋': ['单相思', '暗恋'],
    '初恋': ['初体验', '第一次'],
    '重逢': ['再会', '重逢剧情'],
    '非人类': ['虚构物种', '人造生物', '元素生物', '共生体'],
    '图书馆': ['图书室'],
    '社团活动': ['俱乐部', '社团'],
    '中国神话': ['中华神话'],
    '日本神话': ['和风神话'],
    '僵尸': ['丧尸', '僵尸末日', '僵尸危机'],
    '吸血鬼': ['血族', '吸血症'],
    '同性恋': ['女同性恋主导', '男同主导', '磨豆腐'],
    '女主人公': ['核心女主角', '女主角'],
    '男性主人公': ['核心男主角', '男主角'],
    '青梅竹马': ['童年约定', '幼驯染'],
    '义母': ['继母', '继父', '义父'],
    # ===== BATCH3 =====
    'NTR': ['女主角和非主人公做爱', '与非主角有关系的女主角', '女主角与和非主人公做爱', '女主角被别人夺走'],
    '萝莉': ['萝'],
}

EXACT5 = {
    # 成人
    '乳头交': 'ad.nipple', '巨根': 'ad.big_penis', '癖好/性趣': 'ad.fetish',
    '羞耻/耻辱': 'ad.humiliation', '羞辱': 'ad.humiliation',
    '触摸/抚摸': 'ad.touching', '按摩': 'ad.massage', '连续高潮': 'ad.stamina',
    '小马': 'ad.bestiality', '虫X': 'ad.bestiality', '人妖女主角': 'ch.transgender',
    '雌小鬼': 'ad.corruption', '淫纹': 'ad.body_mod', '穿孔': 'ad.body_mod',
    '有阴毛的女主角': 'ch.body_hair', '身体毛发选项': 'ch.body_hair',
    # 角色
    '不良/混混': 'ch.delinquent', '奴仆': 'ch.servant', '外国人': 'ch.foreigner',
    '仅有成年女主角': 'ch.adult', '成人主人公': 'ch.adult', '成年': 'ch.adult',
    '内衣': 'ch.lingerie', '胶衣': 'ch.latex', '少女': 'ch.teenager',
    '动物': 'ch.animal', '昆虫': 'ch.animal', '蝴蝶': 'ch.animal',
    '已婚女主角': 'ch.married', '童贞/处男': 'ch.virgin_male',
    '总受': 'ch.bl_role', '男性受': 'ch.bl_role', '男性对男性的性行为': 'th.bl',
    '王子殿下/王子系': 'ch.royal', '胸部/奶子': 'ch.oppai', '臀部/屁股': 'ch.big_ass',
    '偏执狂': 'ch.mental_illness', '疯狂': 'ch.mental_illness',
    '有过性经验的女主角': 'ch.nymphomaniac', '沉迷于性的女主角': 'ch.nymphomaniac',
    '贫乳女主角(非萝莉)': 'ch.petite', '裤袜': 'ch.pantyhose', '长袜': 'ch.stockings',
    # 主题 / 元素
    'BSS': 'th.ntr', 'NTL': 'th.ntr', '主从/主仆': 'th.master_servant',
    '仅女性与女性的恋情': 'th.yuri',
    '仅男性与男性的恋情': 'th.bl', '仅男性与男性的性爱': 'th.bl',
    '变身女主': 'el.transformation', '巨大化': 'el.transformation', '石化': 'el.transformation',
    '战队': 'el.hero_team', '拟人化': 'el.anthropomorphism', '换装': 'el.dressup',
    '童话故事': 'el.fairy_tale', '宗教': 'el.religion', '隐形': 'el.invisibility',
    '智斗': 'el.battle_of_wits', '私奔': 'el.elopement', '考古': 'set.ruins',
    '衣服伤害/爆衣': 'el.clothing_damage', '女性视角': 'el.female_pov',
    'ABO世界观': 'el.abo_world', '联动': 'el.crossover',
    '基于动画改编': 'el.adaptation', '基于漫画改编': 'el.adaptation',
    '基于轻小说改编': 'el.adaptation', '改编': 'el.adaptation',
    '复刻版': 'el.remake', '系列作品': 'el.series_work',
    '软色情': 'tone.softcore', '西部片': 'set.western_film',
    '大量色情内容': 'tone.nukige',
    # 二次元 IP（标记「二创自某作品」）
    'Free!': 'ps.derivative', 'VOCALOID': 'ps.derivative', '偶像大师': 'ps.derivative',
    '凉宫春日': 'ps.derivative', '出包王女': 'ps.derivative', '勇者斗恶龙': 'ps.derivative',
    '原神': 'ps.derivative', '最终幻想': 'ps.derivative', '轻音少女': 'ps.derivative',
    '魔法少女奈叶': 'ps.derivative', '魔法少女小圆': 'ps.derivative',
    '东方Project': 'ps.derivative', '海贼王': 'ps.derivative',
    '新世纪福音战士': 'ps.derivative', '极乐迪斯科': 'ps.derivative',
    '福尔摩斯': 'ps.derivative', '刺猬索尼克': 'ps.derivative',
    '虎与兔': 'ps.derivative', '美少女战士': 'ps.derivative',
    '仙境传说': 'ps.derivative', '可选择多主人公': 'ps.multiple_protagonist',
    # 明确不收（技术/平台/无检索价值）
    '文本': None, '教育意义': None, '无标题界面': None,
    '做爱的音效': None, '射精位置选择': None,
    '少量色情内容': None, '故事早期主人公已有亲密关系': None,
    'AI汉化': None, '补丁': None, '仅有成年女主角(非成人向)': None,
    # 斜杠复合核心标签
    '虐待/ryona': 'tone.guro', '愚人节': 'el.festival', '亲热/甜蜜': 'th.vanilla',
    '放尿/小便': 'ad.urination', '平胸/飞机场': 'ch.petite',
    '绝症/身患绝症/致命疾病': 'ch.sickly', '褐皮/晒痕': 'ch.dark_skin',
    '贫乳/微乳': 'ch.petite', '禁忌之爱': 'th.incest', '单相思': 'th.one_sided',
    '虚拟主播': 'ch.virtual_youtuber', '科幻奇幻': 'set.scifi', '秘密身份': 'el.secret',
    '疾病': 'ch.sickly', '十二神器': 'el.twelve_weapons', '十二魔器': 'el.twelve_weapons',
    '高达': 'ps.derivative', '过去日本': 'set.japan', '过去的中国': 'set.china',
    '现代东京': 'set.city', '现代地球': 'set.city', '猫': 'ch.animal', '狗': 'ch.animal',
    '磨豆腐': 'th.yuri', '女同性恋主导': 'th.yuri', '男同主导': 'th.bl',
    '早安咬/交': 'ad.oral', '排尿性爱': 'ad.urination', '外射': 'ad.nakadashi',
    '狗交式体位': 'ad.position', '尾交': 'ad.anal', '发交': 'ad.oral',
    '体交': 'ad.sumata', '肚皮性交': 'ad.sumata', '腿间性行为': 'ad.sumata',
}


def apply(concepts, idx, norm, nextmoe_tags, log=print):
    """并入 ROUND4 数据。返回统计。"""
    stats = {'new_concepts': 0, 'extra_aliases': 0, 'absorbed': 0, 'rule_skipped': 0}

    existing_ids = {c['id'] for c in concepts}
    by_name = {c['name']: c for c in concepts}
    by_id = {c['id']: c for c in concepts}

    def add_alias(c, a):
        na = norm(a)
        if not na:
            return False
        if na in idx and idx[na] is not c:
            return False
        if a in c.setdefault('aliases', []):
            return False
        c['aliases'].append(a)
        idx[na] = c
        return True

    # a) 新概念
    for cid, name, dim, aliases in NEW4 + NEW5:
        if cid in existing_ids:
            log(f'[ROUND4 跳过] id 已存在: {cid}')
            continue
        n = norm(name)
        owner = by_name.get(name) or (idx.get(n) if n else None)
        if owner is not None:
            # 规范名已被既有概念占用 → 不新建，别名并入既有概念（避免丢覆盖）
            for a in aliases:
                if add_alias(owner, a):
                    stats['extra_aliases'] += 1
            continue
        c = {'id': cid, 'name': name, 'dim': dim, 'aliases': []}
        idx[n] = c
        for a in aliases:
            add_alias(c, a)
        concepts.append(c)
        by_name[name] = c
        by_id[cid] = c
        existing_ids.add(cid)
        stats['new_concepts'] += 1

    # b) 既有概念追加别名（EXTRA4 与 EXTRA5 同键时拼接，不丢弃）
    merged_extra = {}
    for src in (EXTRA4, EXTRA5):
        for k, v in src.items():
            merged_extra.setdefault(k, []).extend(v)
    for name, adds in merged_extra.items():
        c = by_name.get(name)
        if c is None:
            log(f'[ROUND4 警告] EXTRA4 目标不存在: {name}')
            continue
        for a in adds:
            if add_alias(c, a):
                stats['extra_aliases'] += 1

    # c) EXACT 精确兜底（先于 RULES）
    for tag, cid in {**EXACT, **EXACT5}.items():
        if cid is None:
            continue
        c = by_id.get(cid)
        if c is None:
            log(f'[ROUND4 警告] EXACT 目标不存在: {tag} -> {cid}')
            continue
        if norm(tag) in idx:
            continue
        if add_alias(c, tag):
            stats['absorbed'] += 1

    # d) RULES 有序吸收（仅 content 标签；meta/平台标签由 SDK 层过滤，不入词表）
    content_tags = [t.get('display_name') for t in nextmoe_tags
                    if isinstance(t, dict) and t.get('tag_kind') == 'content'
                    and t.get('display_name')]
    compiled = [(re.compile(p, re.I), cid) for p, cid in RULES]
    for name in content_tags:
        n = norm(name)
        if not n or n in idx:
            continue
        for rx, cid in compiled:
            if rx.search(name):
                c = by_id.get(cid)
                if c is None:
                    break
                if add_alias(c, name):
                    stats['absorbed'] += 1
                break

    # e) 组合式兜底：剥离角色后缀/前缀，解析基名概念（生成期展开，运行时仍纯倒排）
    keys_by_len = sorted(
        [(norm(k), c) for c in concepts for k in [c['name']] + c.get('aliases', [])
         if norm(k) and len(norm(k)) >= 2],
        key=lambda kv: -len(kv[0]))
    role_suffix = re.compile(
        r'^(.+?)(女主人公|男主人公|女主角|男主角|女主|男主|女配角|男配角|女角色|男角色|配角|主人公)$')
    combo = re.compile(
        r'^主人公的?(.+?)(?:作为|为|担任)(?:另?一?名?)?(女主角|男主角|女主人公|男主人公|配角|主人公)$')
    mods = ['非血亲', '血亲', '同父同母', '同父母异母父', '同父异母', '同母异父', '孪生', '堂表',
            '实姐实妹', '実', '亲', '实', '义', '继', '养', '型', '系', '属性', '的']
    mods_n = [norm(x) for x in mods if norm(x)]

    def resolve_fragment(s):
        n = norm(s)
        if not n:
            return None
        c = idx.get(n)
        if c is not None:
            return c
        for pre in mods_n:
            if n.startswith(pre) and len(n) > len(pre):
                c = idx.get(n[len(pre):])
                if c is not None:
                    return c
            if n.endswith(pre) and len(n) > len(pre):
                c = idx.get(n[:-len(pre)])
                if c is not None:
                    return c
        for k, c in keys_by_len:
            if k in n:
                return c
        return None

    combo_added = 0
    for name in content_tags:
        n = norm(name)
        if not n or n in idx:
            continue
        m = combo.match(name.strip())
        if m:
            c = resolve_fragment(m.group(1))
            if c is not None and add_alias(c, name):
                combo_added += 1
                continue
        m = role_suffix.match(name.strip())
        if m and m.group(1):
            c = resolve_fragment(m.group(1))
            if c is not None and add_alias(c, name):
                combo_added += 1
    stats['absorbed'] += combo_added
    stats['combo'] = combo_added

    return stats
