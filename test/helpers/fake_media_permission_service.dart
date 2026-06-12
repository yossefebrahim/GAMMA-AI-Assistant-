import 'package:ai_assistant/domain/services/media_permission_service.dart';

/// In-memory [MediaPermissionService] for unit/widget tests (contract: media_permission.md "Test
/// double", extended with the 003 mic surface).
///
/// Camera and mic script **independently**: [cameraStatus] returns [status] and [requestCamera]
/// consumes [requestResults]; [micStatus] returns [micStatusValue] and [requestMic] consumes
/// [micRequestResults] (then falls back to [micStatusValue]) so a `denied → granted` sequence is
/// scriptable per permission. [openSettings] and [requestMic] are recorded — exercising the
/// explainer / settings / decline branches (FR-009/FR-010/FR-011) without a device. Existing 002
/// camera tests are untouched.
class FakeMediaPermissionService implements MediaPermissionService {
  FakeMediaPermissionService({
    this.status = MediaPermissionStatus.granted,
    List<MediaPermissionStatus>? requestResults,
    this.micStatusValue = MediaPermissionStatus.granted,
    List<MediaPermissionStatus>? micRequestResults,
    this.storageStatusValue = MediaPermissionStatus.granted,
    List<MediaPermissionStatus>? storageRequestResults,
  }) : requestResults = requestResults ?? <MediaPermissionStatus>[],
       micRequestResults = micRequestResults ?? <MediaPermissionStatus>[],
       storageRequestResults =
           storageRequestResults ?? <MediaPermissionStatus>[];

  /// Status returned by [cameraStatus].
  MediaPermissionStatus status;

  /// Successive results returned by [requestCamera], in order.
  List<MediaPermissionStatus> requestResults;
  int _requestIndex = 0;

  /// Status returned by [micStatus] (003).
  MediaPermissionStatus micStatusValue;

  /// Successive results returned by [requestMic], in order (003).
  List<MediaPermissionStatus> micRequestResults;
  int _micRequestIndex = 0;

  /// Status returned by [storageStatus] (all-files access for the model store).
  MediaPermissionStatus storageStatusValue;

  /// Successive results returned by [requestStorage], in order (then falls back to
  /// [storageStatusValue]) so a `denied → granted` sequence is scriptable.
  List<MediaPermissionStatus> storageRequestResults;
  int _storageRequestIndex = 0;

  // --- call recorders ---
  int statusCalls = 0;
  int requestCalls = 0;
  int micStatusCalls = 0;
  int micRequestCalls = 0;
  int storageStatusCalls = 0;
  int storageRequestCalls = 0;
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
  Future<MediaPermissionStatus> micStatus() async {
    micStatusCalls++;
    return micStatusValue;
  }

  @override
  Future<MediaPermissionStatus> requestMic() async {
    micRequestCalls++;
    if (_micRequestIndex < micRequestResults.length) {
      return micRequestResults[_micRequestIndex++];
    }
    return micStatusValue;
  }

  @override
  Future<MediaPermissionStatus> storageStatus() async {
    storageStatusCalls++;
    return storageStatusValue;
  }

  @override
  Future<MediaPermissionStatus> requestStorage() async {
    storageRequestCalls++;
    if (_storageRequestIndex < storageRequestResults.length) {
      return storageRequestResults[_storageRequestIndex++];
    }
    return storageStatusValue;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCalls++;
  }
}
