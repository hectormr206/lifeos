import 'package:flutter/material.dart';

import '../../theme/lifeos_tokens.dart';

/// Centered, readable page content; scrolls lazily by default.
class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.children,
    this.scrollable = true,
    this.padding,
    this.controller,
  });

  final List<Widget> children;
  final bool scrollable;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final insets = padding ?? EdgeInsets.fromLTRB(
      kPageGutter,
      Space.sm,
      kPageGutter,
      Space.xxxl + MediaQuery.paddingOf(context).bottom,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
        child: scrollable
            ? ListView(
                controller: controller,
                padding: insets,
                children: children,
              )
            : Padding(
                padding: insets,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
      ),
    );
  }
}
