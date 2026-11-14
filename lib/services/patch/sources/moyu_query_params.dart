/// 鲲（NextMoe v2）接口的查询参数构造（**纯 Dart**：无 io、无 Flutter）。
///
/// ## 为什么单独拆成纯函数
///
/// `nsfw` 这个参数曾经**只存在于 `PatchQueryContext` 里，从没被传进源**：
/// 服务端按默认 SFW 过滤，`content_limit=nsfw` 的补丁条目被直接丢进响应的
/// `missing` 数组，而我们的映射层看到的是「items 为空」——
/// 于是「0 条」被当成「这部作品确实没补丁」，连 failures 都不进。
/// 这就是「鲲明明有十几个补丁，软件里一个都搜不到」的头号原因。
///
/// 参数表是纯数据，抽出来之后 `dev_probe/patch_station_probe.dart`（裸 Dart VM）
/// 直接断言「patch 列表请求必须带 nsfw」，不必为了一个 query 参数去搭
/// flutter_tester + 假 HttpClientAdapter。
library;

/// `GET /v2/moyu/patches` 的查询参数。
///
/// 🔴 [nsfw] 是**必填**（不是可选默认值）：漏传等于让服务端默认按 SFW 过滤，
/// R18 补丁整批消失。写成 required 后，任何调用方漏传都是编译错误，
/// 而不是一条只在 R18 作品上才暴露的静默数据丢失。
Map<String, String> buildMoyuPatchesQuery({
  required int workId,
  required bool nsfw,
  required int limit,
}) =>
    <String, String>{
      'refs': 'catalog:$workId',
      'limit': '$limit',
      'nsfw': nsfw ? 'true' : 'false',
    };

/// `GET /v2/moyu/patches/<patchId>/resources` 的查询参数。
///
/// ⚠️ 这里**刻意不加 nsfw**：资源列表按 patch id 直取，实测不带 nsfw 也返回
/// 完整列表（缘之空 11 条）；给不需要的端点多塞一个参数只是多一个失败面。
Map<String, String> buildMoyuResourcesQuery({required int limit}) =>
    <String, String>{'limit': '$limit'};
