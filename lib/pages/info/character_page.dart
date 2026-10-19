import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/modules/character/character_full_item.dart';
import 'package:kazumi/pages/info/character_info_view.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';

class CharacterPage extends StatefulWidget {
  const CharacterPage({
    super.key,
    required this.characterID,
    required this.characterName,
    required this.characterRelation,
    this.actorNames = const [],
  });

  final int characterID;
  final String characterName;
  final String characterRelation;
  final List<String> actorNames;

  @override
  State<CharacterPage> createState() => _CharacterPageState();
}

class _CharacterPageState extends State<CharacterPage> {
  CharacterFullItem? _character;

  Future<void> _loadCharacter() async {
    setState(() {
      _character = null;
    });
    final character =
        await BangumiApi.getCharacterByCharacterID(widget.characterID);
    if (mounted) {
      setState(() {
        _character = character;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadCharacter();
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.characterName.trim();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          MaterialBottomSheetHeader(
            title: name.isEmpty ? '人物' : name,
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(child: _characterInfoBody),
        ],
      ),
    );
  }

  Widget get _characterInfoBody {
    final character = _character;
    if (character != null && character.id == 0) {
      return GeneralErrorWidget(
        title: '人物资料加载失败',
        errMsg: '请检查网络连接后重试。',
        onRetry: _loadCharacter,
      );
    }

    if (character == null) {
      return const SingleChildScrollView(
        padding: materialBottomSheetContentPadding,
        child: Skeletonizer.zone(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Bone(height: 300, width: double.infinity, uniRadius: 14),
            SizedBox(height: 24),
            Bone.multiText(lines: 5),
          ],
        )),
      );
    }
    return CharacterInfoView(
      character: character,
      characterName: widget.characterName,
      characterRelation: widget.characterRelation,
      actorNames: widget.actorNames,
    );
  }
}
