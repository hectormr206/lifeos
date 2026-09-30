import 'package:flutter/material.dart';

import '../../theme/lifeos_palette.dart';
import '../../theme/lifeos_tokens.dart';
import 'grouped_list.dart';

/// A lazily built [GroupedList]: one visual group whose rows are created on
/// demand, for collections that can grow without bound.
class GroupedListView extends StatelessWidget {
  const GroupedListView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
    this.physics,
    this.controller,
    this.header,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;
  final ScrollController? controller;

  /// Scrolls with the list, above the group.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = LifeOSPalette.of(context);
    final insets = padding ??
        EdgeInsets.fromLTRB(
          kPageGutter,
          Space.sm,
          kPageGutter,
          Space.xxxl + MediaQuery.paddingOf(context).bottom,
        );
    final offset = header == null ? 0 : 1;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
        child: ListView.builder(
          controller: controller,
          physics: physics,
          padding: insets,
          itemCount: itemCount + offset,
          itemBuilder: (context, index) {
            if (header != null && index == 0) return header!;
            final i = index - offset;
            final row = itemBuilder(context, i);
            final isLast = i == itemCount - 1;
            return Material(
              color: groupedFill(scheme),
              shape: _SegmentBorder(
                isFirst: i == 0,
                isLast: isLast,
                side: scheme.brightness == Brightness.dark
                    ? BorderSide.none
                    : BorderSide(color: palette.hairline),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  row,
                  if (!isLast)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: groupedDividerColor(scheme, palette),
                      indent: groupedDividerIndent(row),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One slice of the [GroupedList] outline: corners are rounded only on the
/// group's outer edges and the hairline is open where slices meet.
class _SegmentBorder extends ShapeBorder {
  const _SegmentBorder({
    required this.isFirst,
    required this.isLast,
    required this.side,
  });

  final bool isFirst;
  final bool isLast;
  final BorderSide side;

  static const _radius = Radius.circular(Radii.card);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  RRect _rrect(Rect rect) => RRect.fromRectAndCorners(
        rect,
        topLeft: isFirst ? _radius : Radius.zero,
        topRight: isFirst ? _radius : Radius.zero,
        bottomLeft: isLast ? _radius : Radius.zero,
        bottomRight: isLast ? _radius : Radius.zero,
      );

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_rrect(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final r = _rrect(rect.deflate(side.width / 2));
    final path = Path();
    if (isFirst) {
      path
        ..moveTo(r.left, r.top + r.tlRadiusY)
        ..arcToPoint(Offset(r.left + r.tlRadiusX, r.top), radius: _radius)
        ..lineTo(r.right - r.trRadiusX, r.top)
        ..arcToPoint(Offset(r.right, r.top + r.trRadiusY), radius: _radius);
    } else {
      path.moveTo(r.right, r.top);
    }
    path.lineTo(r.right, r.bottom - r.brRadiusY);
    if (isLast) {
      path
        ..arcToPoint(Offset(r.right - r.brRadiusX, r.bottom), radius: _radius)
        ..lineTo(r.left + r.blRadiusX, r.bottom)
        ..arcToPoint(Offset(r.left, r.bottom - r.blRadiusY), radius: _radius);
    } else {
      path.lineTo(r.right, r.bottom);
      path.moveTo(r.left, r.bottom);
    }
    path.lineTo(r.left, r.top + r.tlRadiusY);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..color = side.color,
    );
  }

  @override
  ShapeBorder scale(double t) => this;
}
