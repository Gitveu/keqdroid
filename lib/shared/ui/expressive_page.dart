library;

import 'package:flutter/material.dart';

import 'package:keqdroid/shared/ui/expressive.dart';
import 'package:keqdroid/shared/ui/scrolled_under.dart';
import 'package:keqdroid/shared/ui/smooth_scroll.dart';

class ExpressivePage extends StatelessWidget {
  final String title;

  final List<Widget> children;

  final List<Widget>? actions;

  final EdgeInsets padding;

  final Widget? floatingActionButton;

  final ScrollPhysics? physics;

  final bool? largeTitle;

  static const double _largeTitleMinHeight = 600;

  const ExpressivePage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.padding = const EdgeInsets.fromLTRB(
      ExpressiveSpacing.large,
      ExpressiveSpacing.none,
      ExpressiveSpacing.large,
      ExpressiveSpacing.extraLarge,
    ),
    this.floatingActionButton,
    this.physics,
    this.largeTitle,
  });

  @override
  Widget build(BuildContext context) {
    final useLarge =
        largeTitle ?? MediaQuery.sizeOf(context).height >= _largeTitleMinHeight;
    final titleText = Text(title);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      floatingActionButton: floatingActionButton,
      body: SmoothScroll(
        builder: (context, controller) => CustomScrollView(
          controller: controller,
          physics: physics,
          slivers: [
            // заливку задаём сами: из темы она переключилась бы рывком, а animateColor у SliverAppBar нет
            ExpressiveScrolledUnderBuilder(
              builder: (context, background) => useLarge
                  ? SliverAppBar.large(
                      title: titleText,
                      actions: actions,
                      backgroundColor: background,
                    )
                  : SliverAppBar(
                      title: titleText,
                      actions: actions,
                      pinned: true,
                      backgroundColor: background,
                    ),
            ),
            SliverPadding(
              padding: padding,
              sliver: SliverList.list(children: children),
            ),
          ],
        ),
      ),
    );
  }
}
