import 'package:ai_assistant/domain/services/media_permission_service.dart';

/// In-memory [MediaPermissionService] for unit/widget tests (contract: media_permission.md "Test
/// double").
///
/// [cameraStatus] returns [status]; [requestCamera] returns the next entry from [requestResults]
/// (then falls back to [status]) so a `denied → granted` sequence is scriptable; [openSettings]
/// is recorded — exercising the explainer / settings / decline branches (FR-009/FR-010/FR-011)
/// without a device.
class FakeMediaPermissionService implements MediaPermissionService {
  FakeMediaPermissionService({
    this.status = MediaPermissionStatus.granted,
    List<MediaPermissionStatus>? requestResults,
  }) : requestResults = requestResults ?? <MediaPermissionStatus>[];

  /// Status returned by [cameraStatus].
  MediaPermissionStatus status;

  /// Successive results returned by [requestCamera], in order.
  List<MediaPermissionStatus> requestResults;
  int _requestIndex = 0;

  // --- call recorders ---
  int statusCalls = 0;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<MediaPermissionStatus> cameraStatus() async {
    statusCalls++;
    return status;
  }

  @override
  Future<MediaPermissionStatus> requestCamera() async {
    requestCalls++;
    if (_requestIndex < requestResults.length) {
      return requestResults[_requestIndex++];
    }
    return status;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCalls++;
  }
}
