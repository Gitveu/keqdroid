import 'package:flutter/widgets.dart';

import '../../platform/platform_bootstrap.dart';

abstract final class WindowBreakpoints {
  static const double expanded = 840;

  // по ширине окна: разделённый экран и складной телефон меняют класс так же, как поворот
  static bool isExpandedMobile(BuildContext context) =>
      !PlatformBootstrap.isDesktop &&
      MediaQuery.sizeOf(context).width >= expanded;
}
