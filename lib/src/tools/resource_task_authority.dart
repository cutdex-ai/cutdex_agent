import '../session/snapshot.dart';

/// An acknowledged external write authority for one runtime activation.
abstract interface class ResourceTaskLease {
  /// Revokes or otherwise confirms stopped writes at the resource authority.
  ///
  /// Finite leases may use durably confirmed expiration after a revoke timeout.
  /// If stopped writes cannot be proved, safe implementations keep this Future
  /// pending rather than acknowledging cancellation from a local timeout.
  Future<void> revoke();
}

/// An external lease with synchronous admission closure before cancel waits.
abstract interface class ResourceTaskAdmissionLease
    implements ResourceTaskLease {
  /// Closes new commit admissions for this scope and all its descendants.
  void stopAdmission();
}

/// A finite resource lease whose renewal admission closes synchronously.
abstract interface class RenewableResourceTaskLease
    implements ResourceTaskLease {
  /// Stops issuing renewal requests before asynchronous cancellation begins.
  void stopRenewal();
}

/// Binds runtime lifecycle to a durable or remote resource authority.
///
/// Activation must finish before model or tool work begins. Revocation must be
/// idempotent and must finish before cancellation or settlement is acknowledged.
abstract interface class ResourceTaskAuthority {
  /// Establishes write authority for the supplied activation.
  Future<ResourceTaskLease> activate(SessionSnapshot snapshot);
}
