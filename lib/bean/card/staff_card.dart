import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/cast_tile.dart';
import 'package:kazumi/modules/staff/staff_item.dart';

class StaffCard extends StatelessWidget {
  const StaffCard({
    super.key,
    required this.staffFullItem,
  });

  final StaffFullItem staffFullItem;

  @override
  Widget build(BuildContext context) {
    final staff = staffFullItem.staff;
    final nameCn = staff.nameCN.trim();
    return CastTile(
      imageUrl: staff.images?.grid ?? '',
      name: staff.name,
      subtitle: nameCn.isNotEmpty && nameCn != staff.name.trim() ? nameCn : '',
      role: staffFullItem.relations.join('、'),
    );
  }
}
