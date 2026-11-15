import 'dart:async';

import 'package:flutter/foundation.dart';

/// A wall-clock timer: pausing playback does not extend the chosen deadline.
class ListeningSleepTimer extends ChangeNotifier {
  ListeningSleepTimer(this.onExpire, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final VoidCallback onExpire;
  final DateTime Function() _now;
  Timer? _ticker;
  DateTime? _deadline;
  int? section;
  bool get active => _deadline != null || section != null;
  bool get atSectionEnd => section != null;
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final value = deadline.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  void setDuration(Duration duration) {
    if (duration <= Duration.zero) throw ArgumentError.value(duration);
    _reset();
    _deadline = _now().add(duration);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => check());
    notifyListeners();
  }

  void setSectionEnd(int currentSection) {
    _reset();
    section = currentSection;
    notifyListeners();
  }

  void check() {
    if (_deadline != null && remaining == Duration.zero) {
      cancel();
      onExpire();
    } else if (_deadline != null) {
      notifyListeners();
    }
  }

  void reachedSectionEnd(int completedSection) {
    if (section != completedSection) return;
    cancel();
    onExpire();
  }

  void cancel() {
    if (!active) return;
    _reset();
    notifyListeners();
  }

  void _reset() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    section = null;
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }
}
