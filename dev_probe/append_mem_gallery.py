# -*- coding: utf-8 -*-
import io
path = r'D:\CTLIB\.workbuddy\memory\2026-10-04.md'
text = '''

---

## 封面管理浮层（LunaBox 风格）——详情窗多封面查看/上传/切换（本轮）

- 详情窗封面加入口（查看态右下角/编辑态右上角）→ `cover_gallery_overlay.dart`：磨砂全屏 + 自由拖拽（InteractiveViewer + 无边界 margin）+ 中心锚点缩放预览 + 循环切换 + 工具条（上传/设竖/设横/删除/抓取）。
- 数据面：`listCoverGallery()`（canonical → `covers/` 自定义图），**不改 game.json schema**——「设为竖/横封面」= 复制为 cover.{ext}/banner.{ext} + updateGameJson + registry 同步 + 缓存失效；删除双守卫（covers/ 前缀 + isInsideAppStorage）；IMP-05 护栏沿用。
- 🔴 交互坑：浮层内「抓取」必须先关浮层——抓取结果面板只在编辑态渲染（game_detail_dialog.dart:2207），不关会被磨砂层压住；实现 = 浮层回调置 flag → pop → dialog 查看态自动 _enterEditMode() + _fetchMetadata()。
- 🔴 showGeneralDialog 的 pageBuilder 是**三参数**签名（BuildContext + 2×Animation），单参数 lambda 编译报 argument_type_not_assignable。
- 验证：analyze 0 error（新组件 0 issue）+ flutter test 4/4 PASS（**231 已缓解，原生 analyze/test 恢复可用**）；⏳ 未真机走查。遗留 P2：BPM 侧上传/管理入口（BPM 结构不变量，待拍板）、存量横幅回填。
'''
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(text)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    print('APPENDED+VERIFIED' if '封面管理浮层' in f.read() else 'VERIFY FAIL')
