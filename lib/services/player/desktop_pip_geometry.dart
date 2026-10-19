import 'dart:math' as math;
import 'dart:ui';

/// Places the desktop PiP window within the screens' work areas, all in
/// logical pixels.
class DesktopPipGeometry {
  static const double defaultWidth = 480;
  static const double minWidth = 240;
  static const double margin = 24;

  /// The first PiP bounds: the remembered `[left, top, width]` while it is
  /// still on a screen, otherwise the bottom-right corner of the screen
  /// [window] is on.
  static Rect initial({
    required double aspectRatio,
    required Rect window,
    required List<Rect> workAreas,
    List<dynamic> saved = const [],
  }) {
    if (saved.length == 3 && saved.every((value) => value is num)) {
      final width = math.max(minWidth, (saved[2] as num).toDouble());
      final rect = Rect.fromLTWH((saved[0] as num).toDouble(),
          (saved[1] as num).toDouble(), width, width / aspectRatio);
      for (final area in workAreas) {
        if (area.contains(rect.center)) return fit(rect, area);
      }
    }
    final area = workAreaFor(window.center, workAreas);
    const width = defaultWidth;
    final height = width / aspectRatio;
    if (area == null) {
      return Rect.fromLTWH(window.left, window.top, width, height);
    }
    return fit(
      Rect.fromLTWH(area.right - margin - width, area.bottom - margin - height,
          width, height),
      area,
    );
  }

  /// The work area that holds [point], or the nearest one.
  static Rect? workAreaFor(Offset point, List<Rect> workAreas) {
    Rect? nearest;
    var nearestDistance = double.infinity;
    for (final area in workAreas) {
      if (area.contains(point)) return area;
      final dx = point.dx - point.dx.clamp(area.left, area.right);
      final dy = point.dy - point.dy.clamp(area.top, area.bottom);
      final distance = dx * dx + dy * dy;
      if (distance < nearestDistance) {
        nearest = area;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// Shrinks [bounds] at its aspect ratio until it fits [area], then moves it
  /// fully inside.
  static Rect fit(Rect bounds, Rect area) {
    final ratio = bounds.width / bounds.height;
    var width = math.min(bounds.width, area.width - 2 * margin);
    var height = width / ratio;
    final maxHeight = area.height - 2 * margin;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * ratio;
    }
    if (width <= 0 || height <= 0) return bounds;
    final left = bounds.left.clamp(area.left, area.right - width);
    final top = bounds.top.clamp(area.top, area.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }
}
