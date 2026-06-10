/// The ONE shared dotted-extension helper for stored media files (002 audit L5): derive from the
/// MIME type first, fall back to parsing the source path, then to [fallback]. Used by both the
/// image and audio file-store paths so naming policy lives in exactly one place.
String mediaFileExtension({String? mimeType, String? path, required String fallback}) {
  switch (mimeType) {
    case 'image/jpeg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'audio/wav':
    case 'audio/x-wav':
      return '.wav';
  }
  if (path != null) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot > slash && dot != -1 && dot < path.length - 1) {
      return path.substring(dot);
    }
  }
  return fallback;
}
