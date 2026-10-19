import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:mobx/mobx.dart';

part 'popular_controller.g.dart';

class PopularController = _PopularController with _$PopularController;

abstract class _PopularController with Store {
  static const int _pageSize = 24;

  int _trendOffset = 0;

  /// The selected Bangumi 类型; empty for the trending list.
  @observable
  String currentTag = '';

  @observable
  ObservableList<BangumiItem> bangumiList = ObservableList.of([]);

  @observable
  ObservableList<BangumiItem> trendList = ObservableList.of([]);

  double scrollOffset = 0.0;

  @observable
  bool isLoadingMore = false;

  @observable
  bool isTimeOut = false;

  bool _tagExhausted = false;

  void setCurrentTag(String s) {
    currentTag = s;
  }

  void clearBangumiList() {
    bangumiList.clear();
    _tagExhausted = false;
  }

  // Async actions commit each segment between awaits as one transaction,
  // batching the completion writes into a single notification.
  @action
  Future<void> queryBangumiByTrend({String type = 'add'}) async {
    if (type == 'init') {
      trendList.clear();
      _trendOffset = 0;
    }
    isLoadingMore = true;
    final result = await BangumiApi.getBangumiTrendsList(
      limit: _pageSize,
      offset: _trendOffset,
    );
    if (result.isNotEmpty) {
      _trendOffset += _pageSize;
    }
    final existingIds = trendList.map((item) => item.id).toSet();
    trendList.addAll(result.where((item) => existingIds.add(item.id)));
    isLoadingMore = false;
    isTimeOut = trendList.isEmpty;
  }

  /// Pages through the anime carrying the official tag [currentTag].
  @action
  Future<void> queryBangumiByTag({String type = 'add'}) async {
    if (type == 'init') {
      bangumiList.clear();
      _tagExhausted = false;
    }
    if (_tagExhausted) return;
    isLoadingMore = true;
    final tag = currentTag;
    final result = await BangumiApi.getBangumiListByMetaTag(
      tag,
      limit: _pageSize,
      offset: bangumiList.length,
    );
    // A late page for a tag the user already left must not leak into the list.
    if (tag != currentTag) {
      isLoadingMore = false;
      return;
    }
    if (result.length < _pageSize) _tagExhausted = true;
    final existingIds = bangumiList.map((item) => item.id).toSet();
    bangumiList.addAll(result.where((item) => existingIds.add(item.id)));
    isLoadingMore = false;
    isTimeOut = bangumiList.isEmpty;
  }
}
