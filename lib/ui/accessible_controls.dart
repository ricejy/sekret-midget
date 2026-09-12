import 'package:flutter/cupertino.dart';

/// Keeps short choices native and compact, while giving large text room to wrap.
/// The non-sliding form also avoids thumb motion when Reduce Motion is enabled.
class AccessibleChoice<T extends Object> extends StatelessWidget {
  const AccessibleChoice({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final style = CupertinoTheme.of(context).textTheme.textStyle;
      var widest = 0.0;
      for (final label in labels.values) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout();
        if (painter.width > widest) widest = painter.width;
        painter.dispose();
      }
      final stacked = (widest + 48) * labels.length > constraints.maxWidth;
      if (!stacked && !MediaQuery.disableAnimationsOf(context)) {
        return CupertinoSlidingSegmentedControl<T>(
          groupValue: value,
          children: {
            for (final entry in labels.entries)
              entry.key: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Center(child: Text(entry.value)),
              ),
          },
          onValueChanged: (next) {
            if (next != null) onChanged(next);
          },
        );
      }
      final choices = [
        for (final entry in labels.entries)
          Semantics(
            selected: value == entry.key,
            inMutuallyExclusiveGroup: true,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: value == entry.key
                  ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
                  : null,
              onPressed: () => onChanged(entry.key),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.value,
                      style: TextStyle(
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExcludeSemantics(
                    child: Icon(
                      value == entry.key
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ];
      return stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: choices,
            )
          : Row(
              children: [for (final choice in choices) Expanded(child: choice)],
            );
    },
  );
}

/// A toolbar must not crowd its scrollable content off screen when the keyboard,
/// landscape layout, or accessibility text sizes leave little vertical space.
class PanelAndContent extends StatelessWidget {
  const PanelAndContent({
    super.key,
    required this.panel,
    required this.content,
    this.panelAtBottom = false,
  });
  final Widget panel;
  final Widget content;
  final bool panelAtBottom;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final controls = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
        child: SingleChildScrollView(child: panel),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!panelAtBottom) controls,
          Expanded(child: content),
          if (panelAtBottom) controls,
        ],
      );
    },
  );
}

/// Unlike CupertinoListTile, the title and supporting text are not one-line.
class WrappingListAction extends StatelessWidget {
  const WrappingListAction({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    alignment: Alignment.centerLeft,
    onPressed: onPressed,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    ),
  );
}
