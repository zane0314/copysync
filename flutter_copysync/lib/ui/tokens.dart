import 'package:flutter/material.dart';

/// 设计 token：按 docs/superpowers/specs/assets/2026-08-24-copysync-v3-ui-reference.png
/// （蓝色环境底、白色毛玻璃面板、低饱和蓝主色、藏青文字、圆角卡片）。
abstract final class AppColors {
  /// 主蓝（参考图高约 10% 饱和度的蓝）。
  static const primary = Color(0xFF2E7CE6);

  /// 主蓝浅底（激活导航/徽标底）。
  static const primarySoft = Color(0xFFDCECFD);

  /// 页面蓝色环境底。
  static const background = Color(0xFFE7EEF9);
  static const surface = Color(0xFFFFFFFF);

  /// 毛玻璃面板（半透明白 + 白色描边）。
  static const glass = Color(0x9EFFFFFF);
  static const glassStrong = Color(0xC7FFFFFF);
  static const glassBorder = Color(0xCCFFFFFF);

  /// 标题/品牌深藏青。
  static const ink = Color(0xFF14264E);
  static const textPrimary = Color(0xFF22355C);
  static const textSecondary = Color(0xFF5B7299);
  static const border = Color(0xFFE3EAF4);
  static const hairline = Color(0x143C5A8C);
  static const success = Color(0xFF34C9A3);
  static const danger = Color(0xFFE5484D);
  static const warning = Color(0xFFD9930D);

  /// 类型图标底色（低饱和区分 text/file/image）。
  static const kindText = Color(0xFF2E7CE6);
  static const kindFile = Color(0xFF7A66FB);
  static const kindImage = Color(0xFFF59E0B);
}

abstract final class AppRadii {
  static const panel = 18.0;
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

  /// 面板浮于蓝色环境底上的柔和投影。
  static const panel = [
    BoxShadow(
      color: Color(0x1A2E5DB2),
      blurRadius: 40,
      offset: Offset(0, 12),
    ),
  ];
}

/// 最小点击区（主设计 §8：44×44）。
const double kMinTapTarget = 44;
