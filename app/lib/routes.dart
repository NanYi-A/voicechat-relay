import 'package:flutter/material.dart';

/// M4 · 纯平移转场（禁 ScaleTransition）
class SlideRoute extends PageRouteBuilder {
  SlideRoute(this.page)
      : super(
          pageBuilder: (ctx, anim, secAnim) => page,
          transitionsBuilder: (ctx, anim, secAnim, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0.0),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            );
          },
        );

  final Widget page;
}
