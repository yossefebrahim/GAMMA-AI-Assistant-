import 'dart:async';

import 'package:ai_assistant/data/repositories/drift_memory_repository.dart';
import 'package:ai_assistant/domain/entities/memory.dart';
import 'package:ai_assistant/domain/repositories/memory_repository.dart';

/// Lightweight in-memory [MemoryRepository] for handler / composer / controller tests (contract:
/// memory_repository.md "Fakes / tests"). Mirrors [DriftMemoryRepository]'s observable behavior —
/// reactive stream, category→recency ordering, dedupe/supersede/cap, soft-delete — without SQLite.
/// The cap + supersede threshold are reused from the real repo so the two cannot drift apart; the
/// normalize/Jaccard helpers are re-stated here (kept identical to the drift repo).
class FakeMemoryRepository implements MemoryRepository {
  /// All facts ever seen, active and soft-deleted (inactive rows are retained for fidelity with the
  /// real soft-delete, but never injected or listed).
  final List<Memory> _all = <Memory>[];
  int _seq = 0;

  // Broadcast controller that carries future mutation events. Initial snapshot is delivered
  // synchronously at subscription time by [watchActive] via Stream.multi (not this controller),
  // which avoids the onListen timing hazard with Riverpod's StreamProvider in widget tests.
  final StreamController<List<Memory>> _controller =
      StreamController<List<Memory>>.broadcast();

  static const int maxActiveFacts = DriftMemoryRepository.maxActiveFacts;
  static const double supersedeThreshold =
      DriftMemoryRepository.supersedeThreshold;
  static const Set<String> _stopWords = {'a', 'an', 'the'};

  static DateTime _now() => DateTime.now().toUtc();

  /// Test convenience — preload a fixed active set (e.g. for injection/controller tests). Bypasses
  /// dedupe; ids must be unique.
  void seed(List<Memory> facts) {
    _all
      ..clear()
      ..addAll(facts);
    _seq = facts.fold(0, (m, f) => f.id > m ? f.id : m);
    _emit();
  }

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Set<String> _contentWords(String normalized) => normalized
      .split(' ')
      .where((w) => w.isNotEmpty && !_stopWords.contains(w))
      .toSet();

  double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }

  List<Memory> _orderedActive() {
    final list = _all.where((m) => m.active).toList();
    list.sort((a, b) {
      final byCategory = a.category.index.compareTo(b.category.index);
      if (byCategory != 0) return byCategory;
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return b.id.compareTo(a.id);
    });
    return list;
  }

  void _emit() => _controller.add(_orderedActive());

  void _replace(Memory m) {
    final i = _all.indexWhere((f) => f.id == m.id);
    if (i >= 0) {
      _all[i] = m;
    } else {
      _all.add(m);
    }
  }

  @override
  Stream<List<Memory>> watchActive() {
    // Returns a new single-subscription synchronous stream per call. Using sync:true means
    // controller.add() inside onListen delivers the snapshot SYNCHRONOUSLY to the subscriber —
    // which is critical for widget tests: Riverpod's StreamProvider receives AsyncData([]) during
    // the same frame build, so no extra pump() is needed to resolve the initial state.
    final controller = StreamController<List<Memory>>(sync: true);
    controller.onListen = () {
      // Subscriber is now registered — deliver current snapshot synchronously.
      controller.add(_orderedActive());
      // Forward future mutations from the shared broadcast channel.
      final sub = _controller.stream.listen((data) {
        if (!controller.isClosed) controller.add(data);
      }, onDone: controller.close);
      // Cancel broadcast subscription when this stream is cancelled.
      controller.onCancel = sub.cancel;
    };
    return controller.stream;
  }

  @override
  Future<List<Memory>> listActive() async => _orderedActive();

  @override
  Future<UpsertResult> upsert({
    required String fact,
    required MemoryCategory category,
    int? sourceConversationId,
  }) async {
    final trimmed = fact.trim();
    final normalizedIncoming = _normalize(trimmed);
    final actives = _orderedActive()
        .where((m) => m.category == category)
        .toList();

    // 1. Exact restatement → unchanged, refresh updatedAt.
    for (final a in actives) {
      if (_normalize(a.fact) == normalizedIncoming) {
        final updated = a.copyWith(updatedAt: _now());
        _replace(updated);
        _emit();
        return UpsertUnchanged(updated);
      }
    }

    // 2. Near-duplicate / conflict (Jaccard ≥ threshold) → supersede in place.
    final incomingWords = _contentWords(normalizedIncoming);
    for (final a in actives) {
      if (_jaccard(incomingWords, _contentWords(_normalize(a.fact))) >=
          supersedeThreshold) {
        final updated = a.copyWith(fact: trimmed, updatedAt: _now());
        _replace(updated);
        _emit();
        return UpsertSuperseded(updated);
      }
    }

    // 3. Insert a new active fact, then enforce the cap.
    final now = _now();
    final created = Memory(
      id: ++_seq,
      fact: trimmed,
      category: category,
      createdAt: now,
      updatedAt: now,
      sourceConversationId: sourceConversationId,
    );
    _all.add(created);
    _enforceCap();
    _emit();
    return UpsertCreated(created);
  }

  void _enforceCap() {
    final active = _orderedActive(); // category→recency; recency is secondary
    final byRecency = active.toList()
      ..sort((a, b) {
        final byUpdated = b.updatedAt.compareTo(a.updatedAt);
        return byUpdated != 0 ? byUpdated : b.id.compareTo(a.id);
      });
    if (byRecency.length <= maxActiveFacts) return;
    for (final m in byRecency.skip(maxActiveFacts)) {
      _replace(m.copyWith(active: false));
    }
  }

  @override
  Future<bool> softDeleteById(int id) async {
    final i = _all.indexWhere((m) => m.id == id && m.active);
    if (i < 0) return false;
    _all[i] = _all[i].copyWith(active: false);
    _emit();
    return true;
  }

  @override
  Future<void> editFact(int id, String fact, MemoryCategory category) async {
    final i = _all.indexWhere((m) => m.id == id && m.active);
    if (i < 0) return;
    _all[i] = _all[i].copyWith(
      fact: fact.trim(),
      category: category,
      updatedAt: _now(),
    );
    _emit();
  }

  @override
  Future<void> clearAll() async {
    for (var i = 0; i < _all.length; i++) {
      if (_all[i].active) _all[i] = _all[i].copyWith(active: false);
    }
    _emit();
  }

  @override
  Future<int> activeCount() async => _orderedActive().length;

  /// Release the broadcast controller (call from `tearDown` when a test subscribes).
  Future<void> dispose() => _controller.close();
}
