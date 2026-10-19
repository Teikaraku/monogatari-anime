import 'package:flutter/material.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';

class UpdateSettingsPage extends StatelessWidget {
  const UpdateSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsDetailScaffold(
    title: Text('更新设置'),
    body: SettingsList(
      sections: [
        SettingsSection(
          title: Text('应用更新'),
          tiles: [
            SettingsTile(
              leading: Icons.update_rounded,
              title: Text('启动时检查更新'),
              description: Text('每次启动检查一次 GitHub 新版本，有更新时弹窗提醒。'),
            ),
          ],
        ),
      ],
    ),
  );
}
