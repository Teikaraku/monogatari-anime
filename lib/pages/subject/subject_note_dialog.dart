import 'package:flutter/material.dart';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';

/// Edits the one-line personal note of [item].
Future<void> showSubjectNoteEditor(
  BuildContext context, {
  required BangumiItem item,
  required SubjectNotes notes,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) => _NoteDialog(
      initial: notes.noteFor(item.id) ?? '',
      onSave: (text) => notes.setNote(item.id, text),
    ),
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial, required this.onSave});

  final String initial;
  final Future<void> Function(String) onSave;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save([String? replacement]) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.onSave(replacement ?? _controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备注'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          enabled: !_saving,
          autofocus: true,
          maxLength: SubjectNotes.maxLength,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(errorText: _saveFailed ? '保存失败' : null),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        if (widget.initial.isNotEmpty)
          TextButton(
            onPressed: _saving ? null : () => _save(''),
            child: const Text('清除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
