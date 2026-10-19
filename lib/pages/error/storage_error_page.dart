import 'dart:io';

import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';

class StorageErrorPage extends StatelessWidget {
  const StorageErrorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('内部错误')),
      body: GeneralErrorWidget(
        title: '无法初始化本地存储',
        icon: Icons.storage_rounded,
        errMsg: '',
        actions: [
          StateActionButton(
            onPressed: () => exit(0),
            text: '退出程序',
            icon: Icons.close_rounded,
          ),
        ],
      ),
    );
  }
}
