import 'dart:io';

import 'package:ai_assistant/app/theme/app_colors.dart';
import 'package:ai_assistant/app/theme/app_spacing.dart';
import 'package:flutter/material.dart';

/// The pending-image preview shown above the composer field (R6, Principle X). Monochrome: a
/// hairline-bordered thumbnail (no shadow), a monochrome remove "×" (NOT the red accent — a minor
/// remove, not a destructive confirmation), and tap-to-replace on the thumbnail. The remove control
/// meets the 48dp floor (Principle VI).
class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({
    super.key,
    required this.path,
    required this.onRemove,
    this.onReplace,
  });

  /// The pending image's (temp) file path.
  final String path;

  /// Remove the pending attachment (FR-003).
  final VoidCallback onRemove;

  /// Replace it by picking another (FR-003); null disables tap-to-replace.
  final VoidCallback? onReplace;

  static const Key removeKey = Key('attachment-preview-remove');
  static const Key thumbnailKey = Key('attachment-preview-thumbnail');
  static const double _thumbSize = 56;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Semantics(
            label: 'attached image',
            button: onReplace != null,
            child: GestureDetector(
              key: AttachmentPreview.thumbnailKey,
              onTap: onReplace,
              child: Container(
                width: _thumbSize,
                height: _thumbSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusControl),
                  border: Border.all(
                    color: colors.outline,
                    width: AppSpacing.hairline,
                  ),
                  color: colors.surfaceContainerHigh,
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  // Decode at thumbnail size — the picker temp file is up to 1536px, a ~12 MB
                  // texture for a 56dp thumb that janks the composer/keyboard relayout.
                  cacheWidth:
                      (_thumbSize * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                  errorBuilder: (context, error, stack) => Icon(
                    Icons.broken_image_outlined,
                    color: colors.textSecondary,
                    size: AppSpacing.s24,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: AttachmentPreview.removeKey,
            tooltip: 'remove image',
            onPressed: onRemove,
            icon: Icon(Icons.close, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
