import 'dart:async';

import 'package:flutter/material.dart';

import '../debounce.dart';
import 'disposable_state.dart';

class DelayPainterModel {
  final String key;
  final _ready = StreamController();
  final _update = StreamController();
  final bool Function() show;

  /// Patched (open_maps): the tile's current zoom scale. Labels only need
  /// re-laying out when it changes; pans and rotations reuse the last
  /// painted pixels (the tile is a repaint boundary that the layer
  /// transform moves), so labels stay visible while the map moves.
  final double Function() zoomScale;

  DelayPainterModel(
      {required this.key, required this.show, required this.zoomScale});

  Stream<void> get readyStream => _ready.stream;
  Stream<void> get updateStream => _update.stream;

  void notifyReady() {
    _ready.add(null);
  }

  void notifyUpdate() {
    _update.add(null);
  }

  void dispose() {
    _ready.close();
    _update.close();
  }
}

// first paint and model changes cause rendering to occur with 0 opacity
// if state is ready and rendered with 0 opacity, new rendering is sheduled
// on a delay with fade to 1 opacity.
class DelayPainter extends StatefulWidget {
  final DelayPainterModel model;
  final CustomPainter delegate;

  const DelayPainter({super.key, required this.model, required this.delegate});

  @override
  State<StatefulWidget> createState() {
    return _DelayPainterState();
  }
}

class _DelayPainterState extends DisposableState<DelayPainter> {
  late final ScheduledDebounce debounce;
  var _render = false;
  var _nextPaintNoDelay = false;
  StreamSubscription? _updateSubscription;
  StreamSubscription? _readySubscription;

  double? _paintedZoomScale;

  bool get shouldPaint => _render && widget.model.show();

  _DelayPainterState() {
    // Patched (open_maps): maxAge 10 s -> 1.2 s so labels keep up with a
    // continuously moving camera (navigation) instead of going stale.
    debounce = ScheduledDebounce(_notifyUpdate,
        delay: const Duration(milliseconds: 500),
        jitter: const Duration(milliseconds: 50),
        maxAge: const Duration(milliseconds: 1200));
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void dispose() {
    super.dispose();
    _unsubscribe();
  }

  void _subscribe() {
    _unsubscribe();
    _updateSubscription = widget.model.updateStream.listen((event) {
      // Patched (open_maps): a pan or rotation keeps the painted labels;
      // only a zoom change schedules a re-layout.
      if (_render && _paintedZoomScale == widget.model.zoomScale()) return;
      debounce.update();
    });
    _readySubscription = widget.model.readyStream.listen((event) {
      scheduleMicrotask(_ready);
    });
  }

  void _unsubscribe() {
    _updateSubscription?.cancel();
    _readySubscription?.cancel();
  }

  void _ready() {
    _nextPaintNoDelay = true;
    _render = true;
    _schedulePaint();
  }

  void painted() {
    if (_render) {
      _paintedZoomScale = widget.model.zoomScale();
      if (_nextPaintNoDelay) {
        _nextPaintNoDelay = false;
      } else {
        _render = false;
      }
      _scheduleOne();
    } else {
      debounce.update();
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = RepaintBoundary(
        key: Key('boundary-${widget.model.key}'),
        child:
            CustomPaint(painter: _DelayCustomPainter(this, widget.delegate)));
    // Patched (open_maps): labels pop in instead of fading. The 500 ms
    // AnimatedOpacity put every symbol tile behind a saveLayer while it
    // faded (text can't take group opacity directly), and while navigating
    // (rotated camera, tiles re-laid out continuously, two symbol layers)
    // that allocated hundreds of MB of transient GPU textures per second:
    // graphics memory swung between 0.5 and 1.3 GB, the process peaked at
    // 3 GB and Vulkan reported a lost device. Hidden tiles are not painted
    // at all, as at opacity 0 before.
    return Visibility(
        key: Key('opacity-${widget.model.key}'),
        visible: widget.model.show() && _render,
        maintainState: true,
        child: child);
  }

  void _notifyUpdate() {
    if (!disposed) {
      if (!_paintQueue.contains(this)) {
        _paintQueue.add(this);
      }
      _scheduleOne();
    }
  }

  void _schedulePaint() {
    if (!disposed) {
      setState(() {
        _render = true;
      });
    }
  }

  void _scheduleOne() async {
    if (!_scheduled && _paintQueue.isNotEmpty) {
      _scheduled = true;
      await Future.delayed(const Duration(milliseconds: 10));
      _scheduled = false;
      if (_paintQueue.isNotEmpty) {
        _paintQueue.removeLast()._schedulePaint();
        _scheduleOne();
      }
    }
  }
}

class _DelayCustomPainter extends CustomPainter {
  final _DelayPainterState _state;
  final CustomPainter _delegate;

  _DelayCustomPainter(this._state, this._delegate);

  @override
  void paint(Canvas canvas, Size size) {
    if (_state.shouldPaint) {
      _delegate.paint(canvas, size);
    }
    _state.painted();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

final _paintQueue = <_DelayPainterState>[];
var _scheduled = false;
