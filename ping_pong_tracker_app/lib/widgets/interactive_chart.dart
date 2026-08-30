import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Where the value readout appears when hovering a graph.
/// follow = tracks the hovered point; left/right = pinned corner;
/// adaptive = opposite the finger.
enum HoverReadoutPos { follow, left, right, adaptive }

/// Dependency-free line chart: the given series plotted against a shared time
/// axis, with an auto-scaled y-axis covering just those series.
class _ChartPainter extends CustomPainter {
  final Float64List t;
  final List<Float32List> series;
  final int count;
  final List<Color> colors;
  final double? forcedMin; // if set, pin the y-axis bottom here (no auto-scale)
  final String? cornerText; // optional label drawn in the top-right corner
  final bool centerZero; // if true, y-axis is symmetric about 0 (0 centered)
  final List<double> hitTimes; // detected ball-hit times (s) -> vertical lines
  final int? touchIndex; // sample under the finger -> crosshair + dots

  // Plot insets, shared with InteractiveChart so a touch x maps to the same
  // axis the painter draws.
  static const double padL = 46, padR = 10, padT = 10, padB = 22;

  _ChartPainter(
    this.t,
    this.series,
    this.count,
    this.colors, {
    this.forcedMin,
    this.cornerText,
    this.centerZero = false,
    this.hitTimes = const [],
    this.touchIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFAFAFA),
    );

    final plot = Rect.fromLTRB(
      padL,
      padT,
      size.width - padR,
      size.height - padB,
    );
    canvas.drawRect(
      plot,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black26
        ..strokeWidth = 1,
    );

    if (count < 2 || series.isEmpty) {
      _text(
        canvas,
        "No data",
        plot.center - const Offset(24, 8),
        Colors.black45,
      );
      return;
    }

    double tMin = t[0];
    double tMax = t[count - 1];
    if (tMax <= tMin) tMax = tMin + 1e-3;

    const int maxPts = 800;
    final int step = (count / maxPts).ceil().clamp(1, count);

    double vMin = double.infinity, vMax = -double.infinity;
    for (int a = 0; a < series.length; a++) {
      final col = series[a];
      for (int i = 0; i < count; i += step) {
        final v = col[i];
        if (v < vMin) vMin = v;
        if (v > vMax) vMax = v;
      }
    }
    if (!vMin.isFinite || !vMax.isFinite) {
      vMin = -1;
      vMax = 1;
    }
    if (forcedMin != null) {
      // Pin the bottom (e.g. 0 for speed); only pad/auto-scale the top.
      vMin = forcedMin!;
      if (vMax <= vMin) vMax = vMin + 1;
      vMax += (vMax - vMin) * 0.08;
    } else if (centerZero) {
      // Symmetric about 0 so 0.0 sits exactly in the middle; autoscale extent.
      final double av = vMin.abs(), bv = vMax.abs();
      double mag = av > bv ? av : bv;
      if (mag <= 0) mag = 1;
      mag *= 1.05; // padding
      vMin = -mag;
      vMax = mag;
    } else {
      if (vMax <= vMin) vMax = vMin + 1;
      final vpad = (vMax - vMin) * 0.05;
      vMin -= vpad;
      vMax += vpad;
    }

    double xOf(double tt) =>
        plot.left + (tt - tMin) / (tMax - tMin) * plot.width;
    double yOf(double vv) =>
        plot.bottom - (vv - vMin) / (vMax - vMin) * plot.height;

    final gridPaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;

    void hline(double v) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(
        canvas,
        v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
        Offset(2, y - 6),
        Colors.black54,
        size: 9,
      );
    }

    // Horizontal grid lines with value labels (4 even divisions).
    for (int k = 0; k <= 4; k++) {
      hline(vMin + (vMax - vMin) * k / 4);
    }
    // Emphasize the zero line when the range crosses it.
    if (vMin < 0 && vMax > 0) {
      final y = yOf(0);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = Colors.black38
          ..strokeWidth = 1,
      );
    }

    for (int k = 0; k <= 4; k++) {
      final tt = tMin + (tMax - tMin) * k / 4;
      final x = xOf(tt);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      _text(
        canvas,
        tt.toStringAsFixed(1),
        Offset(x - 8, plot.bottom + 4),
        Colors.black54,
        size: 9,
      );
    }

    for (int a = 0; a < series.length; a++) {
      final col = series[a];
      final paint = Paint()
        ..color = colors[a]
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final path = Path();
      bool first = true;
      for (int i = 0; i < count; i += step) {
        final x = xOf(t[i]);
        final y = yOf(col[i]);
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    // Ball-hit markers: a clear vertical line at each detected hit time.
    if (hitTimes.isNotEmpty) {
      final hitPaint = Paint()
        ..color =
            const Color(0xFFE91E63) // magenta — distinct from all traces
        ..strokeWidth = 2.0
        ..isAntiAlias = true;
      for (final ht in hitTimes) {
        if (ht < tMin || ht > tMax) continue;
        final x = xOf(ht);
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), hitPaint);
      }
    }

    // Touch crosshair + a dot on each trace at the hovered sample.
    if (touchIndex != null && touchIndex! >= 0 && touchIndex! < count) {
      final int ti = touchIndex!;
      final double cx = xOf(t[ti]);
      canvas.drawLine(
        Offset(cx, plot.top),
        Offset(cx, plot.bottom),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1,
      );
      for (int a = 0; a < series.length; a++) {
        final double cy = yOf(series[a][ti]);
        canvas.drawCircle(Offset(cx, cy), 3.5, Paint()..color = colors[a]);
        canvas.drawCircle(
          Offset(cx, cy),
          3.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white
            ..strokeWidth = 1.2,
        );
      }
    }

    // Optional corner label (e.g. max speed), top-right inside the plot.
    if (cornerText != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: cornerText,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.right - tp.width - 6, plot.top + 4));
    }
  }

  void _text(Canvas c, String s, Offset o, Color color, {double size = 10}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.count != count ||
      old.t != t ||
      old.colors != colors ||
      old.forcedMin != forcedMin ||
      old.cornerText != cornerText ||
      old.centerZero != centerZero ||
      old.hitTimes != hitTimes ||
      old.touchIndex != touchIndex;
}

/// Wraps a [_ChartPainter] with touch tracking: dragging horizontally (or
/// pressing and holding) shows a crosshair at the nearest sample plus a readout
/// of the exact value(s). Vertical drags fall through to the enclosing scroll
/// view, so the detail page still scrolls normally.
class InteractiveChart extends StatefulWidget {
  final Float64List t;
  final List<Float32List> series;
  final int count;
  final List<Color> colors;
  final List<String>? labels;
  final String unit;
  final int decimals;
  final double? forcedMin;
  final String? cornerText;
  final bool centerZero;
  final List<double> hitTimes;
  final bool persist; // keep the readout after the finger lifts
  final HoverReadoutPos pos; // which side the readout box sits on
  final String Function(double) timeLabel; // formats a sample time for readout

  const InteractiveChart({
    super.key,
    required this.t,
    required this.series,
    required this.count,
    required this.colors,
    required this.labels,
    required this.unit,
    required this.decimals,
    required this.forcedMin,
    required this.cornerText,
    required this.centerZero,
    required this.hitTimes,
    required this.persist,
    required this.pos,
    required this.timeLabel,
  });

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart> {
  int? _touchIndex;

  // Map an x within the plot to the nearest sample index (samples are ~uniform).
  void _updateFromX(double dx, double width) {
    final int n = widget.count;
    if (n < 2) return;
    final double plotLeft = _ChartPainter.padL;
    final double plotW = width - _ChartPainter.padR - plotLeft;
    if (plotW <= 0) return;
    final double frac = ((dx - plotLeft) / plotW).clamp(0.0, 1.0);
    final int idx = (frac * (n - 1)).round().clamp(0, n - 1);
    if (idx != _touchIndex) setState(() => _touchIndex = idx);
  }

  void _clear() {
    if (_touchIndex != null) setState(() => _touchIndex = null);
  }

  // On finger-lift: keep the readout when "persist" is on, else clear it.
  void _onEnd() {
    if (!widget.persist) _clear();
  }

  @override
  void didUpdateWidget(InteractiveChart old) {
    super.didUpdateWidget(old);
    // Turning persist off drops any pinned crosshair on the next rebuild.
    if (old.persist && !widget.persist) _touchIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Horizontal drag = scrub; long-press = pin. Vertical drags are left
          // to the scroll view (neither recognizer claims them).
          onHorizontalDragStart: (d) => _updateFromX(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) =>
              _updateFromX(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _onEnd(),
          onHorizontalDragCancel: _onEnd,
          onLongPressStart: (d) => _updateFromX(d.localPosition.dx, width),
          onLongPressMoveUpdate: (d) => _updateFromX(d.localPosition.dx, width),
          onLongPressEnd: (_) => _onEnd(),
          child: Stack(
            children: [
              CustomPaint(
                painter: _ChartPainter(
                  widget.t,
                  widget.series,
                  widget.count,
                  widget.colors,
                  forcedMin: widget.forcedMin,
                  cornerText: widget.cornerText,
                  centerZero: widget.centerZero,
                  hitTimes: widget.hitTimes,
                  touchIndex: _touchIndex,
                ),
                child: const SizedBox.expand(),
              ),
              if (_touchIndex != null) _readout(width),
            ],
          ),
        );
      },
    );
  }

  Widget _readout(double width) {
    final int ti = _touchIndex!;
    // A dismiss control only makes sense for a pinned (persistent) readout.
    final bool showClose = widget.persist;
    final children = <Widget>[
      Text(
        "t = ${widget.timeLabel(widget.t[ti])}",
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      for (int a = 0; a < widget.series.length; a++)
        Text(
          "${_label(a)}: "
          "${widget.series[a][ti].toStringAsFixed(widget.decimals)}"
          "${widget.unit.isEmpty ? "" : " ${widget.unit}"}",
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: widget.colors[a],
          ),
        ),
    ];
    final Widget box = Stack(
      clipBehavior: Clip.none,
      children: [
        // The box passes touches through, so you can keep scrubbing under it…
        IgnorePointer(
          child: Container(
            // Reserve room on the right for the close button so it never sits
            // over a value.
            padding: EdgeInsets.fromLTRB(8, 6, showClose ? 26 : 8, 6),
            decoration: BoxDecoration(
              color: const Color(0xF2FFFFFF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
        // …except the close button, which stays tappable to clear the pin.
        if (showClose)
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _clear,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );

    // Follow mode: the box tracks the crosshair's x, centered above it and
    // clamped to the chart by Align (it never runs off either edge).
    if (widget.pos == HoverReadoutPos.follow) {
      final double tMin = widget.t[0];
      final double tMax = widget.count > 1
          ? widget.t[widget.count - 1]
          : tMin + 1e-3;
      final double denom = (tMax - tMin).abs() < 1e-9 ? 1e-3 : (tMax - tMin);
      final double plotLeft = _ChartPainter.padL;
      final double plotW = width - _ChartPainter.padR - plotLeft;
      double alignX = 0;
      if (plotW > 0) {
        final double cx =
            plotLeft + ((widget.t[ti] - tMin) / denom).clamp(0.0, 1.0) * plotW;
        alignX = ((cx / width) * 2 - 1).clamp(-1.0, 1.0);
      }
      return Positioned(
        top: 6,
        left: 0,
        right: 0,
        child: Align(alignment: Alignment(alignX, -1), child: box),
      );
    }

    // Fixed corner (left/right) or adaptive (opposite the finger).
    final bool boxOnLeft;
    switch (widget.pos) {
      case HoverReadoutPos.left:
        boxOnLeft = true;
        break;
      case HoverReadoutPos.right:
        boxOnLeft = false;
        break;
      case HoverReadoutPos.adaptive:
        final double frac = widget.count > 1 ? ti / (widget.count - 1) : 0.0;
        boxOnLeft = frac >= 0.5; // finger on the right -> box on the left
        break;
      case HoverReadoutPos.follow:
        boxOnLeft = false; // handled above
        break;
    }
    return Positioned(
      top: 6,
      left: boxOnLeft ? 6 : null,
      right: boxOnLeft ? null : 6,
      child: box,
    );
  }

  String _label(int a) {
    final labels = widget.labels;
    if (labels != null && a < labels.length) return labels[a];
    return "v$a";
  }
}
