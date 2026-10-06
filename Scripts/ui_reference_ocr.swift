import Foundation
import Vision
import AppKit

// Verification helper: OCR the rendered UI reference images so the *text* that
// actually landed in each capture can be checked mechanically (right copy, right
// surface, still legible at capture scale). It says nothing about beauty.
//
// Usage: swift Scripts/ui_reference_ocr.swift build/ui-references/*.png

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: ui_reference_ocr.swift <png>...\n".utf8))
    exit(2)
}

for path in paths.sorted() {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cg = bitmap.cgImage else {
        print("\(path): could not load")
        continue
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try handler.perform([request])
    } catch {
        print("\(path): OCR failed — \(error.localizedDescription)")
        continue
    }

    let observations = (request.results ?? []).sorted { lhs, rhs in
        // Top of image first, then left to right.
        if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.02 {
            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    print("== \(URL(fileURLWithPath: path).lastPathComponent)")
    if observations.isEmpty {
        print("   (no text recognised)")
        continue
    }
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let box = observation.boundingBox
        let heightPct = Int((box.height * Double(cg.height)).rounded())
        print("   [h≈\(heightPct)px] \(candidate.string)")
    }
}
