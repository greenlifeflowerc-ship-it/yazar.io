import 'package:flutter/material.dart';

class SpatialGrid<T> {
  SpatialGrid(this.cellSize);
  final double cellSize;
  final Map<int, List<T>> _grid = {};

  int _key(int gx, int gy) => (gx + 1024) * 100000 + (gy + 1024);

  void insert(T item, Offset pos) {
    final gx = (pos.dx / cellSize).floor();
    final gy = (pos.dy / cellSize).floor();
    _grid.putIfAbsent(_key(gx, gy), () => <T>[]).add(item);
  }

  List<T> queryRadius(Offset center, double radius) {
    final result = <T>[];
    final minGx = ((center.dx - radius) / cellSize).floor();
    final maxGx = ((center.dx + radius) / cellSize).floor();
    final minGy = ((center.dy - radius) / cellSize).floor();
    final maxGy = ((center.dy + radius) / cellSize).floor();
    for (int gx = minGx; gx <= maxGx; gx++) {
      for (int gy = minGy; gy <= maxGy; gy++) {
        final bucket = _grid[_key(gx, gy)];
        if (bucket != null) result.addAll(bucket);
      }
    }
    return result;
  }

  /// Collect every entity whose grid bucket overlaps [rect]. May include
  /// entities slightly outside [rect] (bucket boundaries), so callers should
  /// still check `rect.contains(position)` if they need an exact answer.
  List<T> queryRect(Rect rect) {
    final result = <T>[];
    final minGx = (rect.left / cellSize).floor();
    final maxGx = (rect.right / cellSize).floor();
    final minGy = (rect.top / cellSize).floor();
    final maxGy = (rect.bottom / cellSize).floor();
    for (int gx = minGx; gx <= maxGx; gx++) {
      for (int gy = minGy; gy <= maxGy; gy++) {
        final bucket = _grid[_key(gx, gy)];
        if (bucket != null) result.addAll(bucket);
      }
    }
    return result;
  }

  void clear() => _grid.clear();
}
