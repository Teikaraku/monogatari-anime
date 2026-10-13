import 'package:flutter/services.dart' show appBuildName;

class ApiEndpoints {
  /// 当前版本
  static const String version = appBuildName ?? '0.0.0';

  /// 规则API级别
  static const int apiLevel = 8;

  /// 物语源代码
  static const String sourceUrl =
      "https://github.com/Teikaraku/monogatari-anime";

  /// 上游项目 Kazumi（GPL-3.0），物语基于它二次开发
  static const String upstreamSourceUrl = "https://github.com/Predidit/Kazumi";

  /// 规则仓库
  static const String pluginShop =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/';

  /// 规则仓库镜像（物语中转）
  static const String pluginShopMirror = '$bangumiMirrorDomain/rules/';

  /// 最新版本的发布页（更新信息没有附带链接时打开）
  static const String latestApp = '$sourceUrl/releases/latest';

  /// 更新只查询本项目的 GitHub Releases；没有公开发行版时返回暂无更新。
  static const String latestAppApi =
      'https://api.github.com/repos/Teikaraku/monogatari-anime/releases/latest';

  /// 物语中转：Bangumi 接口、图片与规则仓库
  static const String bangumiMirrorDomain = 'https://bgm.monogatari.top';

  /// 番剧播出时间（由服务器每天从 bangumi-data 生成）
  static const String bangumiAirtime =
      '$bangumiMirrorDomain/meta/airtime.json';

  /// 弹弹官网
  static const String dandanIndex = 'https://www.dandanplay.com/';

  /// Bangumi 官网
  static const String bangumiIndex = 'https://bangumi.tv/';

  /// bangumi API
  static const String bangumiAPIDomain = 'https://api.bgm.tv';

  /// Bangumi 鉴权 API（经物语中转，不缓存带令牌的请求）
  static const String bangumiAuthAPIMirrorDomain = bangumiMirrorDomain;

  /// 番剧信息
  static const String bangumiInfoByID = '/v0/subjects/{0}';

  /// 条目关联信息
  static const String bangumiRelationsByID = '/v0/subjects/{0}/subjects';

  /// 条目搜索
  static const String bangumiRankSearch =
      '/v0/search/subjects?limit={0}&offset={1}';

  /// 从条目ID获取角色信息
  static const String bangumiCharacterByID = '/v0/subjects/{0}/characters';

  /// 从条目ID获取工作人员信息
  static const String bangumiStaffByID = '/v0/subjects/{0}/persons';

  /// 从条目ID获取剧集ID
  static const String bangumiEpisodeByID = '/v0/episodes';

  /// 返回当前 Access Token 对应的用户信息
  static const String bangumiUsernameByToken = '/v0/me';

  /// 新增或修改用户单个条目收藏
  static const String bangumiSetCollection = '/v0/users/-/collections/{0}';

  /// 修改用户条目收藏下的章节状态
  static const String bangumiSetEpisodesCollection =
      '/v0/users/-/collections/{0}/episodes';

  /// 获取用户全部收藏（不限类型）。用户名，分页参数1(limit)，分页参数2(offset)
  static const String bangumiGetAllCollections =
      '/v0/users/{0}/collections?subject_type=2&limit={1}&offset={2}';

  /// Bangumi Next API Domain
  static const String bangumiAPINextDomain = 'https://next.bgm.tv';

  static const bangumiPublicApiHosts = {'api.bgm.tv', 'next.bgm.tv'};

  /// 每日放送
  static const String bangumiCalendar = '/p1/calendar';

  /// 番剧趋势
  static const String bangumiTrendsNext = '/p1/trending/subjects';

  /// 番剧信息
  static const String bangumiInfoByIDNext = '/p1/subjects/{0}';

  /// 番剧剧集评论
  static const String bangumiEpisodeCommentsByIDNext =
      '/p1/episodes/{0}/comments';

  /// 番剧角色信息
  static const String bangumiCharacterInfoByCharacterIDNext =
      '/p1/characters/{0}';

  /// 弹弹play 开放弹幕网络（经物语中转，凭据只保存在服务器）
  static const String dandanAPIDomain = '$bangumiMirrorDomain/dandan';

  /// 获取弹幕
  static const String dandanAPIComment = "/api/v2/comment/";

  /// 检索弹弹番剧元数据
  static const String dandanAPISearchEpisodes = "/api/v2/search/episodes";

  /// 获取弹弹番剧元数据
  static const String dandanAPIInfo = "/api/v2/bangumi/";

  /// 获取弹弹番剧元数据（通过BGM番剧ID）
  static const String dandanAPIInfoByBgmBangumiId = "/api/v2/bangumi/bgmtv/{0}";

  /// 图片识别番剧
  static const String traceApi = 'https://api.trace.moe/search';

  static String formatUrl(String url, List<dynamic> params) {
    for (int i = 0; i < params.length; i++) {
      url = url.replaceAll('{$i}', params[i].toString());
    }
    return url;
  }
}
