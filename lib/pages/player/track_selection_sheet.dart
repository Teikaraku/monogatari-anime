import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/pages/player/controller/track_choice.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/subscriptions/rss_widgets.dart';
import 'package:kazumi/utils/theme.dart';

void showTrackSelectionSheet(
  BuildContext context, {
  required PlayerController playerController,
}) {
  showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.8,
    builder: (_) => _TrackSheet(controller: playerController),
  );
}

class _TrackSheet extends StatefulWidget {
  const _TrackSheet({required this.controller});

  final PlayerController controller;

  @override
  State<_TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<_TrackSheet> {
  final _subscriptions = <StreamSubscription<Object?>>[];

  Player? get _player => widget.controller.playback.mediaPlayer;

  @override
  void initState() {
    super.initState();
    final player = _player;
    if (player != null) {
      void refresh(Object? _) {
        if (mounted) setState(() {});
      }

      _subscriptions
        ..add(player.stream.tracks.listen(refresh))
        ..add(player.stream.track.listen(refresh));
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _loadExternal() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ass', 'ssa', 'srt', 'vtt'],
      );
      final file = result?.files.singleOrNull;
      if (file?.path == null) return;
      await widget.controller.loadExternalSubtitle(
        file!.path!,
        title: file.name,
      );
    } catch (_) {
      KazumiDialog.showToast(message: '无法加载这个字幕文件');
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final colors = Theme.of(context).colorScheme;
    final palette = MonoPalette.of(context);
    final tracks = player?.state.tracks ?? const Tracks();
    final selected = player?.state.track ?? const Track();
    final subtitles = PlayerController.realSubtitleTracks(tracks);
    final audio = PlayerController.realAudioTracks(tracks);
    final external = selected.subtitle.uri || selected.subtitle.data;

    Widget check(bool on) => SizedBox(
      width: 24,
      child: on
          ? Icon(Icons.check_rounded, size: 20, color: colors.primary)
          : null,
    );

    TrackInfo subtitleInfo(SubtitleTrack t) =>
        (id: t.id, title: t.title, language: t.language);
    TrackInfo audioInfo(AudioTrack t) =>
        (id: t.id, title: t.title, language: t.language);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MaterialBottomSheetHeader(
          title: '字幕与音轨',
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              const RssCaption('字幕'),
              RssGroup(
                dividerIndent: 16 + 24 + 12,
                children: [
                  RssRow(
                    leading: check(selected.subtitle.id == 'no'),
                    title: '关闭',
                    titleMaxLines: 1,
                    onTap: player == null
                        ? null
                        : () => widget.controller.chooseSubtitleTrack(
                            SubtitleTrack.no(),
                          ),
                  ),
                  for (var i = 0; i < subtitles.length; i++)
                    RssRow(
                      leading: check(selected.subtitle.id == subtitles[i].id),
                      title: trackLabel(subtitleInfo(subtitles[i]), i, '字幕'),
                      subtitle: subtitles[i].codec,
                      titleMaxLines: 1,
                      onTap: () =>
                          widget.controller.chooseSubtitleTrack(subtitles[i]),
                    ),
                  if (external)
                    RssRow(
                      leading: check(true),
                      title: selected.subtitle.title ?? '外挂字幕',
                      subtitle: '外挂字幕',
                      titleMaxLines: 1,
                    ),
                  RssActionRow(
                    icon: Icons.file_open_outlined,
                    label: '加载外挂字幕…',
                    onTap: player == null ? null : _loadExternal,
                  ),
                ],
              ),
              if (audio.isNotEmpty) ...[
                const SizedBox(height: 20),
                const RssCaption('音轨'),
                RssGroup(
                  dividerIndent: 16 + 24 + 12,
                  children: [
                    for (var i = 0; i < audio.length; i++)
                      RssRow(
                        leading: check(
                          selected.audio.id == audio[i].id ||
                              (audio.length == 1 &&
                                  !isRealTrack(selected.audio.id)),
                        ),
                        title: trackLabel(audioInfo(audio[i]), i, '音轨'),
                        subtitle: [
                          if (audio[i].codec != null) audio[i].codec!,
                          if (audio[i].channels != null) audio[i].channels!,
                        ].join(' · '),
                        subtitleColor: palette.secondaryLabel,
                        titleMaxLines: 1,
                        onTap: () =>
                            widget.controller.chooseAudioTrack(audio[i]),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
