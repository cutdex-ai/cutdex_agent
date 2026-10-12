import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

void main() {
  test('cancel propagates through the full linked tree before returning', () {
    final root = CancellationToken();
    final child = CancellationToken();
    final a = CancellationToken();
    final b = CancellationToken();
    root.linkChild(child);
    child.linkChild(a);
    child.linkChild(b);
    root.cancel();
    expect([root, child, a, b].every((t) => t.isCancelled), isTrue);
    root.cancel();
    expect(a.throwIfCancelled, throwsA(isA<AgentCancelled>()));
  });
  test('child cancellation does not propagate back to parent', () {
    final root = CancellationToken();
    final child = CancellationToken();
    root.linkChild(child);
    child.cancel();
    expect(root.isCancelled, isFalse);
  });
  test('unlink detaches a completed child and is idempotent', () {
    final root = CancellationToken();
    final child = CancellationToken();
    final unlink = root.linkChild(child);
    unlink();
    unlink();
    root.cancel();
    expect(child.isCancelled, isFalse);
  });
  test('duplicate owners retain a link until both detach', () {
    final root = CancellationToken();
    final child = CancellationToken();
    final first = root.linkChild(child);
    final second = root.linkChild(child);
    first();
    first();
    root.cancel();
    expect(child.isCancelled, isTrue);
    second();
    second();
  });
  test('linking after parent cancellation immediately cancels the child', () {
    final root = CancellationToken()..cancel();
    final child = CancellationToken();
    final unlink = root.linkChild(child);
    expect(child.isCancelled, isTrue);
    unlink();
    expect(() => root.linkChild(root), throwsArgumentError);
  });
}
