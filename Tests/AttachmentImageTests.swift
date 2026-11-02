import Foundation
import AppKit
import ImageIO

// Photos dragged in from the Photos app used to fail with "Image is too large after
// resizing": camera pictures compress poorly as PNG, so one fixed 1600-pixel resize was
// often still over the 2 MB attachment limit. Random noise compresses just as badly,
// which makes it a stand-in for a real photo.
@main struct AttachmentImageTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            print("PASS: \(name)")
        }
        func bitmap(width: Int, height: Int, noisy: Bool) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let count = rep.bytesPerRow * height
            if noisy { arc4random_buf(rep.bitmapData!, count) } else { memset(rep.bitmapData!, 120, count) }
            return rep
        }
        func image(width: Int, height: Int, noisy: Bool) -> NSImage {
            let result = NSImage(size: NSSize(width: width, height: height))
            result.addRepresentation(bitmap(width: width, height: height, noisy: noisy))
            return result
        }
        func pixels(_ attachment: Attachment) -> (Int, Int) {
            let rep = NSBitmapImageRep(data: attachment.data)
            return (rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0)
        }

        let photo = try Attachment.fromImage(image(width: 2400, height: 1800, noisy: true), name: "IMG_0001.HEIC")
        let (photoWidth, photoHeight) = pixels(photo)
        check(photo.isImage && photo.mimeType == "image/png", "photo-like image attaches as a PNG")
        check(photo.data.count <= Attachment.imageByteLimit, "photo-like image is shrunk under the 2 MB limit")
        check(photoWidth < 1600 && photoWidth >= Int(Attachment.minimumImageSide), "photo shrinks below 1600 pixels but stays useful")
        check(abs(Double(photoWidth) / Double(photoHeight) - 4.0 / 3.0) < 0.01, "photo keeps its shape")

        let plain = try Attachment.fromImage(image(width: 3000, height: 2000, noisy: false))
        check(pixels(plain).0 == 1600, "easily compressed images still use the full 1600-pixel preview")
        let small = try Attachment.fromImage(image(width: 300, height: 200, noisy: false))
        check(pixels(small) == (300, 200), "small images are never enlarged")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("silkwire-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bigPhoto = folder.appendingPathComponent("Big photo.png")
        try bitmap(width: 2200, height: 1800, noisy: true).representation(using: .png, properties: [:])!.write(to: bigPhoto)
        let bigPhotoBytes = (try FileManager.default.attributesOfItem(atPath: bigPhoto.path)[.size] as? Int) ?? 0
        check(bigPhotoBytes > 10 * 1024 * 1024, "fixture photo file is over the old 10 MB file limit")
        let loaded = try Attachment.load(bigPhoto)
        check(loaded.isImage && loaded.data.count <= Attachment.imageByteLimit, "photo files over 10 MB now attach after shrinking")
        let (loadedWidth, loadedHeight) = pixels(loaded)
        check(loadedWidth <= 1600 && abs(Double(loadedWidth) / Double(loadedHeight) - 2200.0 / 1800.0) < 0.01, "photo files are read at preview size and keep their shape")

        let tall = folder.appendingPathComponent("Tall photo.jpg")
        try bitmap(width: 1200, height: 3000, noisy: true).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: tall)
        let tallAttachment = try Attachment.load(tall)
        let (tallWidth, tallHeight) = pixels(tallAttachment)
        check(tallHeight <= 1600 && tallHeight > tallWidth && tallAttachment.data.count <= Attachment.imageByteLimit, "tall JPEG photos load, shrink and stay upright")

        // A real rotation tag: pixels stored sideways (800x400) with EXIF orientation 6,
        // the way an iPhone saves a portrait photo. It must arrive upright (400x800).
        let rotated = folder.appendingPathComponent("Rotated photo.jpg")
        let destination = CGImageDestinationCreateWithURL(rotated as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap(width: 800, height: 400, noisy: false).cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "rotation-tagged fixture written")
        let rotatedAttachment = try Attachment.load(rotated); check(pixels(rotatedAttachment) == (400, 800), "photos tagged as rotated arrive upright")

        var oversizeMessage = ""
        do { _ = try Attachment.fromImageFile(tall, maxPixels: 1_000_000) } catch { oversizeMessage = error.localizedDescription }
        check(oversizeMessage == "This image is too large to open safely. Try exporting a smaller copy first.", "images over the pixel limit are refused before decoding")

        let broken = folder.appendingPathComponent("Broken.jpg")
        try Data("this is not really a photo".utf8).write(to: broken)
        var brokenMessage = ""
        do { _ = try Attachment.load(broken) } catch { brokenMessage = error.localizedDescription }
        check(brokenMessage == "This image can't be read. Try exporting it as a PNG or JPEG first.", "damaged image files get a plain explanation")

        let bigText = folder.appendingPathComponent("notes.txt")
        try Data(repeating: 65, count: 11 * 1024 * 1024).write(to: bigText)
        var textMessage = ""
        do { _ = try Attachment.load(bigText) } catch { textMessage = error.localizedDescription }
        check(textMessage == "This file is over 10 MB, which is too big to attach.", "large text files are still refused, with a plain message")
        var folderMessage = ""
        do { _ = try Attachment.load(folder) } catch { folderMessage = error.localizedDescription }
        check(folderMessage.contains("Folders and aliases can't be attached"), "folders get a plain explanation")
        print("PASS: 16 attachment image checks")
    }
}
