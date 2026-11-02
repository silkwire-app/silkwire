import Foundation

// Development builds are ad-hoc signed: a replacement may no longer resolve a
// security scope issued to an older signing identity. Resolve the BOOKMARK, not
// its stored path, without UI/mounting as a compatibility fallback. Never accept
// a stale/moved bookmark or synthesize a grant from a path alone. macOS file
// permissions and the native per-operation Project broker remain authoritative.
func nativeResolveProjectFolder(_ folder: ProjectFolder) throws -> URL {
    var stale = false
    let url: URL
    do {
        url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    } catch {
        stale = false
        do { url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw nativeFailure("\(folder.name) could not be restored. Choose that folder again in Project settings; its saved grant was not changed.") }
    }
    guard !stale, url.standardizedFileURL.resolvingSymlinksInPath().path == folder.path,
          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw nativeFailure("\(folder.name) moved or its grant is stale. Choose it again in Project settings; no replacement folder was granted.")
    }
    return url
}
