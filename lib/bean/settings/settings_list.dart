import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/utils/theme.dart';

enum _TileKind { plain, toggle, radio }

/// Width of settings-style grouped pages on wide windows, side padding included.
const double settingsReadableWidth = 752;

/// A grouped page: grey backdrop with raised inset groups, centred and capped
/// on wide windows.
class SettingsList extends StatelessWidget {
  const SettingsList({
    super.key,
    required this.sections,
    this.maxWidth = settingsReadableWidth,
  });

  final List<Widget> sections;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MonoPalette.of(context).groupedBackground,
      child: MonoGroupedScope(
        grouped: true,
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 10, bottom: 24),
          itemCount: sections.length,
          itemBuilder: (context, index) => Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: sections[index],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.tiles,
    this.title,
    this.bottomInfo,
    this.margin,
  });

  final List<Widget> tiles;
  final Widget? title;
  final Widget? bottomInfo;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: margin ?? const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: SectionHeader(title: title!),
            ),
          SplitListGroup(children: tiles),
          if (bottomInfo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: DefaultTextStyle.merge(
                style: textTheme.bodySmall?.copyWith(
                  fontSize: 13,
                  height: 1.4,
                  color: colorScheme.onSurfaceVariant,
                ),
                child: bottomInfo!,
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsRadioSection<T> extends StatelessWidget {
  const SettingsRadioSection({
    super.key,
    required this.groupValue,
    required this.onChanged,
    required this.tiles,
    this.title,
  });

  final T? groupValue;
  final ValueChanged<T?> onChanged;
  final List<Widget> tiles;
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<T>(
      groupValue: groupValue,
      onChanged: onChanged,
      child: SettingsSection(title: title, tiles: tiles),
    );
  }
}

Color _disabledOn(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38);

/// Leading symbol of a settings row: tinted with the accent like the action
/// rows of the Monogatari sheets.
const double _leadingIconSize = 22;
const double _leadingGap = 14;

class _TileLabel extends StatelessWidget {
  const _TileLabel({
    required this.title,
    this.leading,
    this.description,
    this.enabled = true,
  });

  final Widget title;
  final IconData? leading;
  final Widget? description;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final disabled = enabled ? null : _disabledOn(context);
    final foreground = disabled ?? colorScheme.onSurface;
    final secondary = disabled ?? colorScheme.onSurfaceVariant;

    return Row(
      children: [
        if (leading != null) ...[
          Icon(leading, size: _leadingIconSize, color: disabled ?? colorScheme.primary),
          const SizedBox(width: _leadingGap),
        ],
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: textTheme.bodyLarge
                    ?.copyWith(fontSize: 16, color: foreground),
                child: title,
              ),
              if (description != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    height: 1.45,
                    color: secondary,
                  ),
                  child: description!,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// iOS-style symbol tile: a white glyph on a rounded colour square.
class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile({
    super.key,
    required this.icon,
    this.color,
    this.size = 29,
  });

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      child: Icon(icon, size: size * 0.66, color: Colors.white),
    );
  }
}

class SettingsCategoryTile extends StatelessWidget
    implements SplitListDividerInset {
  const SettingsCategoryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.color,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  /// Tile colour; the accent when null.
  final Color? color;

  /// Marks the open page when the list serves as a sidebar.
  final bool selected;

  @override
  double get dividerInset => 16 + 29 + 12;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      onHighlightChanged: SplitListRow.pressReporterOf(context),
      child: Ink(
        color: selected
            ? colorScheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            SettingsIconTile(icon: icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      color: selected ? colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      description,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: selected
                  ? colorScheme.primary
                  : MonoPalette.of(context).tertiaryLabel,
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class SettingsSliderTile extends StatelessWidget
    implements SplitListDividerInset {
  const SettingsSliderTile({
    super.key,
    required this.title,
    required this.value,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.leading,
    this.description,
  });

  final Widget title;
  final IconData? leading;
  final Widget? description;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  double get dividerInset =>
      leading == null ? 16 : 16 + _leadingIconSize + _leadingGap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _TileLabel(
                  title: title,
                  leading: leading,
                  description: description,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                valueLabel,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            showValueIndicator: ShowValueIndicator.never,
            padding: EdgeInsets.zero,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class SettingsTile<T> extends StatelessWidget implements SplitListDividerInset {
  const SettingsTile({
    super.key,
    required this.title,
    this.leading,
    this.description,
    this.trailing,
    this.value,
    this.onPressed,
    this.enabled = true,
  })  : _kind = _TileKind.plain,
        onToggle = null,
        initialValue = null,
        radioValue = null;

  /// Row taps pass null to [onToggle]; switch gestures pass the new value.
  const SettingsTile.switchTile({
    super.key,
    required this.title,
    required this.initialValue,
    required this.onToggle,
    this.leading,
    this.description,
    this.enabled = true,
  })  : _kind = _TileKind.toggle,
        trailing = null,
        value = null,
        onPressed = null,
        radioValue = null;

  const SettingsTile.radioTile({
    super.key,
    required this.title,
    required T this.radioValue,
    this.leading,
    this.description,
    this.enabled = true,
  })  : _kind = _TileKind.radio,
        trailing = null,
        value = null,
        onPressed = null,
        onToggle = null,
        initialValue = null;

  final Widget title;

  final IconData? leading;
  final Widget? description;
  final Widget? trailing;
  final Widget? value;
  final void Function(BuildContext context)? onPressed;
  final void Function(bool? value)? onToggle;
  final bool? initialValue;
  final T? radioValue;
  final bool enabled;
  final _TileKind _kind;

  @override
  double get dividerInset =>
      leading == null ? 16 : 16 + _leadingIconSize + _leadingGap;

  VoidCallback? _tapHandler(BuildContext context) {
    if (!enabled) {
      return null;
    }
    switch (_kind) {
      case _TileKind.plain:
        return onPressed == null ? null : () => onPressed!(context);
      case _TileKind.toggle:
        return onToggle == null ? null : () => onToggle!(null);
      case _TileKind.radio:
        final registry = RadioGroup.maybeOf<T>(context);
        return registry == null ? null : () => registry.onChanged(radioValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final secondary =
        enabled ? colorScheme.onSurfaceVariant : _disabledOn(context);
    final navigates =
        _kind == _TileKind.plain && onPressed != null && trailing == null;

    return InkWell(
      onTap: _tapHandler(context),
      onHighlightChanged: SplitListRow.pressReporterOf(context),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, navigates ? 10 : 16, 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 30),
          child: Row(
            children: [
              Expanded(
                child: _TileLabel(
                  title: title,
                  leading: leading,
                  description: description,
                  enabled: enabled,
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: DefaultTextStyle.merge(
                    style: textTheme.bodyMedium?.copyWith(color: secondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: value!,
                  ),
                ),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 8),
                IconTheme.merge(
                  data: IconThemeData(color: secondary),
                  child: trailing!,
                ),
              ],
              if (navigates) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: MonoPalette.of(context).tertiaryLabel,
                ),
              ],
              if (_kind == _TileKind.toggle) ...[
                const SizedBox(width: 12),
                Switch(
                  value: initialValue ?? false,
                  onChanged: enabled ? onToggle : null,
                ),
              ],
              if (_kind == _TileKind.radio) ...[
                const SizedBox(width: 12),
                _RadioCheck<T>(value: radioValue as T, enabled: enabled),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS picker rows mark the current choice with a trailing check instead of a
/// radio button.
class _RadioCheck<T> extends StatelessWidget {
  const _RadioCheck({required this.value, required this.enabled});

  final T value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final registry = RadioGroup.maybeOf<T>(context);
    final selected = registry?.groupValue == value;
    return SizedBox(
      width: 24,
      height: 24,
      child: selected
          ? Icon(
              Icons.check_rounded,
              size: 22,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : _disabledOn(context),
            )
          : null,
    );
  }
}
