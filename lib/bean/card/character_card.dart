import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/cast_tile.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/modules/characters/character_item.dart';
import 'package:kazumi/pages/info/character_page.dart';

class CharacterCard extends StatelessWidget {
  const CharacterCard({
    super.key,
    required this.characterItem,
  });

  final CharacterItem characterItem;

  @override
  Widget build(BuildContext context) {
    final actors = characterItem.actorList
        .map((actor) => actor.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    return CastTile(
      imageUrl: characterItem.avator.grid,
      name: characterItem.name,
      subtitle: actors.isEmpty ? '' : 'CV ${actors.join('、')}',
      role: characterItem.relation,
      roleAccent: characterItem.relation == '主角',
      onTap: () {
        showAdaptiveBottomSheet<void>(
          context: context,
          builder: (context) {
            return CharacterPage(
              characterID: characterItem.id,
              characterName: characterItem.name,
              characterRelation: characterItem.relation,
              actorNames: actors,
            );
          },
        );
      },
    );
  }
}
