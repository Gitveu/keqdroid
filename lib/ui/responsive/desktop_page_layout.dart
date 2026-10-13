import 'package:flutter/material.dart';

import '../../platform/platform_bootstrap.dart';
import 'window_breakpoints.dart';

const double mobileTabHorizontalInset = 16;

double tabContentHorizontalInset() =>
    PlatformBootstrap.isDesktop ? 0 : mobileTabHorizontalInset;

class DesktopPageLayout extends StatelessWidget {
  const DesktopPageLayout({
    super.key,
    required this.child,
    this.maxWidth = 960,
    this.padding = const EdgeInsets.symmetric(horizontal: 24),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final isDesktop = PlatformBootstrap.isDesktop;
    if (!isDesktop && !WindowBreakpoints.isExpandedMobile(context)) {
      return child;
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: isDesktop ? Padding(padding: padding, child: child) : child,
      ),
    );
  }
}

class DesktopBreakpoints {
  static const sidebarWide = 900.0;
  static const serversContentMaxWidth = 900.0;
  static const settingsTwoColumn = 880.0;
}
