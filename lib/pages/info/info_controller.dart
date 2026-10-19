import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/bangumi/bangumi_subject_detail.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/apis/main_episode_cache.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/modules/characters/character_item.dart';
import 'package:kazumi/modules/staff/staff_item.dart';

part 'info_controller.g.dart';

class InfoController = _InfoController with _$InfoController;

abstract class _InfoController with Store {
  _InfoController(this.collectController);

  final CollectController collectController;
  late BangumiItem bangumiItem;

  @observable
  bool isLoading = false;

  @observable
  var characterList = ObservableList<CharacterItem>();

  @observable
  var staffList = ObservableList<StaffFullItem>();

  @observable
  var relationList = ObservableList<BangumiRelation>();

  @observable
  bool relationsIsLoading = false;

  @observable
  bool relationsQueryTimeout = false;

  @observable
  bool relationsHasLoaded = false;

  int _relationRequestGeneration = 0;

  /// Returns the detail-page fields, or null when the request failed.
  Future<BangumiSubjectDetail?> queryBangumiInfoByID(int id,
      {String type = "init"}) async {
    isLoading = true;
    try {
      return await _updateBangumiInfoByID(id, type: type);
    } finally {
      isLoading = false;
    }
  }

  Future<BangumiSubjectDetail?> refreshBangumiInfoByID(int id) =>
      _updateBangumiInfoByID(id, type: "update");

  Future<BangumiSubjectDetail?> _updateBangumiInfoByID(int id,
      {required String type}) async {
    final result = await BangumiApi.getBangumiSubjectByID(id);
    if (result == null) {
      return null;
    }
    final (value, detail) = result;
    if (type == "init") {
      bangumiItem = value;
    } else {
      // The detail page of another subject may have taken over meanwhile.
      if (bangumiItem.id != id) return detail;
      bangumiItem.name = value.name;
      bangumiItem.nameCn = value.nameCn;
      bangumiItem.summary = value.summary;
      bangumiItem.tags = value.tags;
      bangumiItem.rank = value.rank;
      bangumiItem.airDate = value.airDate;
      bangumiItem.airWeekday = value.airWeekday;
      bangumiItem.alias = value.alias;
      bangumiItem.ratingScore = value.ratingScore;
      bangumiItem.votes = value.votes;
      bangumiItem.votesCount = value.votesCount;
    }
    await collectController.updateLocalCollect(bangumiItem);
    return detail;
  }

  /// Main episodes for the progress card; throws when the request fails.
  Future<List<EpisodeInfo>> queryBangumiMainEpisodesByID(int id) =>
      MainEpisodeCache.get(id);

  Future<void> queryBangumiCharactersByID(int id) async {
    characterList.clear();
    final value = await BangumiApi.getCharatersByBangumiID(id);
    if (bangumiItem.id != id) return;
    characterList.addAll(value.charactersList);
    Map<String, int> relationValue = {
      '主角': 1,
      '配角': 2,
      '客串': 3,
    };

    try {
      characterList.sort((a, b) {
        int valueA = relationValue[a.relation] ?? 4;
        int valueB = relationValue[b.relation] ?? 4;
        return valueA.compareTo(valueB);
      });
    } catch (e) {
      KazumiDialog.showToast(message: '$e');
    }
    KazumiLogger().i(
        'InfoController: loaded character list length ${characterList.length}');
  }

  Future<void> queryBangumiStaffsByID(int id) async {
    staffList.clear();
    final value = await BangumiApi.getBangumiStaffByID(id);
    if (bangumiItem.id != id) return;
    staffList.addAll(value.data);
    KazumiLogger()
        .i('InfoController: loaded staff list length ${staffList.length}');
  }

  @action
  void clearRelations() {
    _relationRequestGeneration++;
    relationList = ObservableList<BangumiRelation>();
    relationsIsLoading = false;
    relationsQueryTimeout = false;
    relationsHasLoaded = false;
  }

  bool get canLoadRelations =>
      !relationsHasLoaded && !relationsIsLoading && !relationsQueryTimeout;

  @action
  Future<void> queryBangumiRelationsByID(int id) async {
    if (relationsIsLoading) return;

    final requestGeneration = ++_relationRequestGeneration;
    relationsIsLoading = true;
    relationsQueryTimeout = false;
    relationsHasLoaded = false;
    try {
      final relations = await resolveRelatedAnimeChain(
        currentSubjectId: id,
        fetchRelations: BangumiApi.getBangumiRelationsByID,
      );
      if (!_isCurrentRelationRequest(requestGeneration, id)) {
        return;
      }
      relationList = ObservableList<BangumiRelation>.of(relations);
      relationsHasLoaded = true;
      KazumiLogger().i(
        'InfoController: loaded related anime list length ${relationList.length}',
      );
    } catch (_) {
      if (_isCurrentRelationRequest(requestGeneration, id)) {
        relationsQueryTimeout = true;
        rethrow;
      }
    } finally {
      if (_isCurrentRelationRequest(requestGeneration, id)) {
        relationsIsLoading = false;
      }
    }
  }

  bool _isCurrentRelationRequest(int requestGeneration, int subjectId) =>
      requestGeneration == _relationRequestGeneration &&
      bangumiItem.id == subjectId;
}
