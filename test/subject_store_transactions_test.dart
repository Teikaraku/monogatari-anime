import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/subject/subject_note_dialog.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';

void main() {
  test('notes remain unchanged until save completes', () async {
    Map<dynamic, dynamic> stored = {'1': 'old'};
    final entered = Completer<void>(), gate = Completer<void>();
    final notes = SubjectNotes(
      read: () => stored,
      write: (next) async {
        entered.complete();
        await gate.future;
        stored = next;
      },
    );
    addTearDown(notes.dispose);
    var notifications = 0;
    notes.addListener(() => notifications++);
    final saving = notes.setNote(1, 'new');
    await entered.future;
    expect(notes.noteFor(1), 'old');
    expect(notifications, 0);
    gate.complete();
    await saving;
    expect(notes.noteFor(1), 'new');
    expect(stored['1'], 'new');
    expect(notifications, 1);
  });

  for (final next in ['new', '']) {
    test(
      'failed note ${next.isEmpty ? 'deletion' : 'edit'} preserves saved value and can retry',
      () async {
        Map<dynamic, dynamic> stored = {'1': 'old'};
        var fail = true;
        final notes = SubjectNotes(
          read: () => stored,
          write: (value) async {
            if (fail) throw const FileSystemException('disk full');
            stored = value;
          },
        );
        addTearDown(notes.dispose);
        var notifications = 0;
        notes.addListener(() => notifications++);
        await expectLater(
          notes.setNote(1, next),
          throwsA(isA<FileSystemException>()),
        );
        expect(notes.noteFor(1), 'old');
        expect(stored['1'], 'old');
        expect(notifications, 0);
        fail = false;
        await notes.setNote(1, next);
        expect(notes.noteFor(1), next.isEmpty ? null : next);
        expect(stored['1'], next.isEmpty ? null : next);
        expect(notifications, 1);
      },
    );
  }

  test(
    'concurrent episode marks merge against the last committed value',
    () async {
      Map<dynamic, dynamic> stored = {};
      final entered = Completer<void>(), gate = Completer<void>();
      final marks = EpisodeMarks(
        read: () => stored,
        write: (next) async {
          if (!entered.isCompleted) entered.complete();
          await gate.future;
          stored = next;
        },
      );
      addTearDown(marks.dispose);
      final first = marks.mark(1, [1], watched: true);
      await entered.future;
      final second = marks.mark(1, [2], watched: true);
      final third = marks.mark(1, [1], watched: false);
      expect(marks.marksFor(1), isEmpty);
      gate.complete();
      await Future.wait([first, second, third]);
      expect(marks.marksFor(1), {1: false, 2: true});
      final reopened = EpisodeMarks(read: () => stored);
      addTearDown(reopened.dispose);
      expect(reopened.marksFor(1), {1: false, 2: true});
      expect(() => marks.marksFor(1)[3] = true, throwsUnsupportedError);
      expect(() => reopened.marksFor(1)[3] = true, throwsUnsupportedError);
    },
  );

  test(
    'failed episode mark does not enter a subsequent saved update',
    () async {
      Map<dynamic, dynamic> stored = {};
      var fail = true;
      final marks = EpisodeMarks(
        read: () => stored,
        write: (next) async {
          if (fail) throw const FileSystemException('disk full');
          stored = next;
        },
      );
      addTearDown(marks.dispose);
      await expectLater(
        marks.mark(1, [1], watched: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(marks.marksFor(1), isEmpty);
      fail = false;
      await marks.mark(1, [2], watched: true);
      expect(marks.marksFor(1), {2: true});
      expect(stored['1'], {'2': true});
    },
  );

  for (final failFirst in [false, true]) {
    test(
      'concurrent player choices preserve successful fields, first failure: $failFirst',
      () async {
        Map<dynamic, dynamic> stored = {};
        final entered = Completer<void>(), gate = Completer<void>();
        var writes = 0;
        final choices = SubjectPlayerChoices(
          read: () => stored,
          write: (next) async {
            final first = ++writes == 1;
            if (first) entered.complete();
            await gate.future;
            if (first && failFirst) {
              throw const FileSystemException('disk full');
            }
            stored = next;
          },
        );
        addTearDown(choices.dispose);
        final speed = choices.update(1, speed: 1.5);
        final speedCheck = failFirst
            ? expectLater(speed, throwsA(isA<FileSystemException>()))
            : speed;
        await entered.future;
        final subtitle = choices.update(
          1,
          subtitle: const TrackChoice(language: 'chs'),
        );
        final audio = choices.update(
          1,
          audio: const TrackChoice(language: 'jpn'),
        );
        expect(choices.choicesFor(1).isEmpty, true);
        gate.complete();
        await Future.wait([speedCheck, subtitle, audio]);
        final reopened = SubjectPlayerChoices(read: () => stored);
        addTearDown(reopened.dispose);
        for (final state in [choices.choicesFor(1), reopened.choicesFor(1)]) {
          expect(state.speed, failFirst ? null : 1.5);
          expect(state.subtitle?.language, 'chs');
          expect(state.audio?.language, 'jpn');
        }
      },
    );
  }

  test(
    'disposing during a write avoids notifications after disposal',
    () async {
      final entered = Completer<void>(), gate = Completer<void>();
      Map<dynamic, dynamic> stored = {};
      final notes = SubjectNotes(
        read: () => stored,
        write: (next) async {
          entered.complete();
          await gate.future;
          stored = next;
        },
      );
      final saving = notes.setNote(1, 'new');
      await entered.future;
      notes.dispose();
      gate.complete();
      await saving;
      expect(stored['1'], 'new');
      await expectLater(notes.setNote(1, 'later'), throwsStateError);
    },
  );

  testWidgets(
    'note editor retains the draft on failure and closes after a successful retry',
    (tester) async {
      Map<dynamic, dynamic> stored = {'1': 'old'};
      var fail = true;
      final notes = SubjectNotes(
        read: () => stored,
        write: (next) async {
          if (fail) throw const FileSystemException('disk full');
          stored = next;
        },
      );
      addTearDown(notes.dispose);
      final subject = BangumiItem.fromJson({
        'id': 1,
        'name': 'Test',
        'rating': {},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showSubjectNoteEditor(context, item: subject, notes: notes),
                child: const Text('edit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'draft',
      );
      expect(notes.noteFor(1), 'old');
      fail = false;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(notes.noteFor(1), 'draft');
      expect(stored['1'], 'draft');
    },
  );
}
