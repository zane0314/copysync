import 'package:flutter/material.dart';

/// 设计 token：按 docs/superpowers/specs/assets/2026-08-24-copysync-v3-ui-reference.png
/// （浅蓝白毛玻璃、低饱和蓝主色、中性灰文字、圆角卡片）。
abstract final class AppColors {
  /// 主蓝（参考图高约 10% 饱和度的蓝）。
  static const primary = Color(0xFF2E7CE6);
  static const primarySoft = Color(0xFFE8F1FD);
  static const background = Color(0xFFF2F5FA);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF1F2937);
  static const textSecondary = Color(0xFF6B7280);
  static const border = Color(0xFFE3E9F2);
  static const success = Color(0xFF34A853);
  static const danger = Color(0xFFE5484D);
  static const warning = Color(0xFFF59E0B);

  /// 类型图标底色（低饱和区分 text/file/image）。
  static const kindText = Color(0xFF2E7CE6);
  static const kindFile = Color(0xFF7C6FF0);
  static const kindImage = Color(0xFFF59E0B);
}

abstract final class AppRadii {
  static const card = 16.0;
  static const tile = 12.0;
  static const pill = 20.0;
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}

abstract final class AppShadows {
  static const card = [
    BoxShadow(
      color: Color(0x0F1F2937),
      blurRadius: 12,
      offset: Offset(0, 2),
    ),
  ];
}

/// 最小点击区（主设计 §8：44×44）。
const double kMinTapTarget = 44;
