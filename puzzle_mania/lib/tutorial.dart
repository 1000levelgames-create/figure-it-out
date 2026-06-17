import 'package:flutter/material.dart';

enum TutorialStep {
  dragPiece,
  hintButton,
  resetButton,
  complete,
}

class TutorialGuideOverlay extends StatelessWidget {
  const TutorialGuideOverlay({
    required this.step,
    required this.trayRect,
    required this.hintButtonRect,
    this.hideDragStepOverlay = false,
    super.key,
  });

  final TutorialStep step;
  final Rect? trayRect;
  final Rect? hintButtonRect;
  final bool hideDragStepOverlay;

  @override
  Widget build(BuildContext context) {
    if (step == TutorialStep.complete) {
      return const SizedBox.shrink();
    }
    if (step == TutorialStep.dragPiece && hideDragStepOverlay) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final targetRect = switch (step) {
            TutorialStep.dragPiece => trayRect ?? _fallbackTrayRect(size),
            TutorialStep.hintButton => hintButtonRect ?? _fallbackHintRect(size),
            TutorialStep.resetButton => null,
            TutorialStep.complete => null,
          };
          final calloutText = switch (step) {
            TutorialStep.dragPiece => 'drag a piece from the tray to the board.',
            TutorialStep.hintButton => 'press Hint when you get stuck.',
            TutorialStep.resetButton => 'press Reset to clear the board and try again.',
            TutorialStep.complete => '',
          };

          return Stack(
            children: [
              if (targetRect == null)
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.58)),
                )
              else
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SpotlightPainter(
                      rect: targetRect.inflate(10),
                      overlayColor: Colors.black.withValues(alpha: 0.58),
                      borderColor: const Color(0xfff7981d).withValues(alpha: 0.88),
                    ),
                  ),
                ),
              if (targetRect != null)
                _CalloutCard(
                  rect: targetRect,
                  text: calloutText,
                  bounds: size,
                ),
            ],
          );
        },
      ),
    );
  }
}

Rect _fallbackTrayRect(Size size) {
  final width = (size.width - 24).clamp(240.0, size.width).toDouble();
  const height = 184.0;
  final left = (size.width - width) / 2;
  final top = (size.height - height - 96).clamp(260.0, size.height - height - 24.0).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

Rect _fallbackHintRect(Size size) {
  const width = 96.0;
  const height = 96.0;
  final left = (size.width - width - 24).clamp(16.0, size.width - width - 16.0).toDouble();
  final top = 112.0;
  return Rect.fromLTWH(left, top, width, height);
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter({
    required this.rect,
    required this.overlayColor,
    required this.borderColor,
  });

  final Rect rect;
  final Color overlayColor;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final overlayPaint = Paint()..color = overlayColor;
    final holePath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(24)));
    canvas.drawPath(holePath, overlayPaint);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = borderColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      oldDelegate.rect != rect ||
      oldDelegate.overlayColor != overlayColor ||
      oldDelegate.borderColor != borderColor;
}

class _CalloutCard extends StatelessWidget {
  const _CalloutCard({
    required this.rect,
    required this.text,
    required this.bounds,
  });

  final Rect? rect;
  final String text;
  final Size bounds;

  @override
  Widget build(BuildContext context) {
    final target = rect;
    if (target == null) {
      return const SizedBox.shrink();
    }

    const cardWidth = 270.0;
    final left = (target.center.dx - cardWidth / 2).clamp(16.0, bounds.width - cardWidth - 16.0);
    final showAbove = target.top > 180;
    final top = showAbove ? target.top - 112 : target.bottom + 18;

    return Positioned(
      left: left,
      top: top,
      width: cardWidth,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xfffff7f0).withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xfff7981d).withValues(alpha: 0.28),
            width: 1.5,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xff8a5a3b),
            fontSize: 15,
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        ),
      ),
    );
  }
}
