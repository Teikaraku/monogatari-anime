import 'package:flutter/material.dart';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';

/// Edits the one-line personal note of [item].
Future<void> showSubjectNoteEditor(
  BuildContext context, {
  required BangumiItem item,
  required SubjectNotes notes,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _NoteDialog(initial: notes.noteFor(item.id) ?? ''),
  );
  if (result == null) return;
  await notes.setNote(item.id, result);
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial});

  final String initial;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备注'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: SubjectNotes.maxLength,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '比如：等完结再看'),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        if (widget.initial.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('清除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
