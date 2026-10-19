import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/subject/subject_local_store.dart';
import 'package:kazumi/utils/app_brand.dart';
import 'package:kazumi/utils/device.dart';

/// Opens the poster preview of [item] with 分享 and 保存图片.
Future<void> showSubjectPoster(
  BuildContext context, {
  required BangumiItem item,
}) {
  return showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.94,
    builder: (_) => _PosterSheet(item: item),
  );
}

String _coverUrl(BangumiItem item) => ['large', 'common', 'medium']
    .map((size) => item.images[size]?.trim() ?? '')
    .firstWhere((url) => url.isNotEmpty, orElse: () => '');

String subjectLink(BangumiItem item) => 'https://bgm.tv/subject/${item.id}';

class _PosterSheet extends StatefulWidget {
  const _PosterSheet({required this.item});

  final BangumiItem item;

  @override
  State<_PosterSheet> createState() => _PosterSheetState();
}

class _PosterSheetState extends State<_PosterSheet> {
  final _boundary = GlobalKey();
  final _shareButton = GlobalKey();
  late final String? _note = inject<SubjectNotes>().noteFor(widget.item.id);
  bool _ready = false;
  bool _busy = false;

  // Built once: toggling the buttons never rebuilds or repaints the poster.
  late final Widget _poster = RepaintBoundary(
    key: _boundary,
    child: SubjectPoster(item: widget.item, note: _note),
  );

  String get _title =>
      widget.item.nameCn.isNotEmpty ? widget.item.nameCn : widget.item.name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_ready) _prepare();
  }

  // Both covers must be decoded before the poster is captured.
  Future<void> _prepare() async {
    final url = _coverUrl(widget.item);
    if (url.isNotEmpty) {
      final provider = CachedNetworkImageProvider(url);
      try {
        await Future.wait([
          precacheImage(
            ResizeImage(provider, width: SubjectPoster.coverPixels),
            context,
          ),
          precacheImage(
            ResizeImage(provider, width: SubjectPoster.blurPixels),
            context,
          ),
        ]);
      } catch (error) {
        KazumiLogger().w('Poster: cover unavailable', error: error);
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<List<int>?> _render() async {
    final boundary =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(
      pixelRatio: SubjectPoster.exportWidth / SubjectPoster.size.width,
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  String get _fileName =>
      'monogatari-${widget.item.id}-${DateTime.now().millisecondsSinceEpoch}.png';

  Future<void> _run(Future<void> Function(List<int> bytes) action) async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      final bytes = await _render();
      if (bytes == null) throw StateError('Poster not laid out');
      await action(bytes);
    } catch (error) {
      KazumiLogger().w('Poster: export failed', error: error);
      KazumiDialog.showToast(message: '海报生成失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() => _run((bytes) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$_fileName');
    await file.writeAsBytes(bytes, flush: true);
    final box = _shareButton.currentContext?.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: '《$_title》 ${subjectLink(widget.item)}',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  });

  Future<void> _save() => _run((bytes) async {
    final data = Uint8List.fromList(bytes);
    if (isDesktop()) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存海报',
        fileName: _fileName,
        type: FileType.custom,
        allowedExtensions: const ['png'],
        bytes: data,
        lockParentWindow: true,
      );
      if (path != null) KazumiDialog.showToast(message: '海报已保存');
      return;
    }
    final result = await SaverGallery.saveImage(
      data,
      fileName: _fileName,
      skipIfExists: false,
    );
    if (!result.isSuccess) {
      throw StateError(result.errorMessage ?? 'Gallery save failed');
    }
    KazumiDialog.showToast(message: '已保存到相册');
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MaterialBottomSheetHeader(
          title: '分享海报',
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
              child: AspectRatio(
                aspectRatio: SubjectPoster.size.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: FittedBox(child: _poster),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _ready && !_busy ? _save : null,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('保存图片'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: _shareButton,
                  onPressed: _ready && !_busy ? _share : null,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: const Text('分享'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A fixed-size, theme-independent poster: blurred cover, title, rating,
/// tags, the user's note and a QR code of the Bangumi page.
class SubjectPoster extends StatelessWidget {
  const SubjectPoster({super.key, required this.item, this.note});

  static const size = Size(360, 640);
  static const exportWidth = 1080.0;

  /// Decode widths: the cover at export resolution, the backdrop tiny since
  /// it is blurred anyway.
  static const coverPixels = 600;
  static const blurPixels = 72;

  final BangumiItem item;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final url = _coverUrl(item);
    final provider = url.isEmpty ? null : CachedNetworkImageProvider(url);
    final title = item.nameCn.isNotEmpty ? item.nameCn : item.name;
    final original = item.nameCn.isNotEmpty && item.name != item.nameCn
        ? item.name
        : null;
    final airDate = DateTime.tryParse(item.airDate);
    final facts = [
      if (airDate != null) '${airDate.year} 年 ${airDate.month} 月',
      if (item.rank > 0) '排名 #${item.rank}',
    ];
    final tags = item.tags.take(4).map((tag) => tag.name).toList();
    const white = Colors.white;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: SizedBox.fromSize(
        size: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF15151A)),
            if (provider != null)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Image(
                  image: ResizeImage(provider, width: blurPixels),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                  gaplessPlayback: true,
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66000000), Color(0xE6000000)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
              child: Column(
                children: [
                  Container(
                    width: 196,
                    height: 277,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: const Color(0xFF2A2A30),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x80000000),
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: provider == null
                        ? null
                        : Image(
                            image: ResizeImage(provider, width: coverPixels),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: white,
                      fontSize: 23,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (original != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      original,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (item.ratingScore > 0) ...[
                        _RatingPill(score: item.ratingScore),
                        if (facts.isNotEmpty) const SizedBox(width: 10),
                      ],
                      if (facts.isNotEmpty)
                        Flexible(
                          child: Text(
                            facts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xCCFFFFFF),
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final tag in tags) _Tag(tag)],
                    ),
                  ],
                  const Spacer(),
                  if (note != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x1FFFFFFF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '“$note”',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: white,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              AppBrand.name,
                              style: TextStyle(
                                color: white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '开源番剧应用',
                              style: TextStyle(
                                color: Color(0x99FFFFFF),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SizedBox.square(
                          dimension: 62,
                          child: _QrCode(data: subjectLink(item)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '★ ${score.toStringAsFixed(1)}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0x26FFFFFF),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 12),
    ),
  );
}

/// The QR modules are computed once per poster and painted as one path.
class _QrCode extends StatefulWidget {
  const _QrCode({required this.data});

  final String data;

  @override
  State<_QrCode> createState() => _QrCodeState();
}

class _QrCodeState extends State<_QrCode> {
  late final _painter = _QrPainter(
    QrImage(
      QrCode(
        payload: QrPayload.fromString(widget.data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _painter);
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    final cell = size.width / count;
    final path = Path();
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (image.isDark(row, col)) {
          // A hairline overlap hides seams between modules.
          path.addRect(
            Rect.fromLTWH(col * cell, row * cell, cell + 0.3, cell + 0.3),
          );
        }
      }
    }
    canvas.drawPath(path, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.image.moduleCount != image.moduleCount;
}
