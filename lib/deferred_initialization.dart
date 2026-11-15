/// Shares concurrent initialization and permits retry after a failed attempt.
class DeferredInitialization {
  DeferredInitialization(this.initialize);
  final Future<void> Function() initialize;
  Future<void>? _pending;
  bool _ready = false;

  void markReady() => _ready = true;

  Future<void> ensureReady() {
    if (_ready) return Future.value();
    return _pending ??= Future.sync(initialize)
        .then((_) {
          _ready = true;
        })
        .whenComplete(() => _pending = null);
  }
}
