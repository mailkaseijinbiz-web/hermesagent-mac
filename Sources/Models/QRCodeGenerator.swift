import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct QRCodeGenerator {
    // Generate crisp QR code NSImage from URL string
    static func generate(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        
        if let outputImage = filter.outputImage {
            // QR codes are tiny (e.g. 29x29). Scale it up for a sharp image
            let scaleX: CGFloat = 10
            let scaleY: CGFloat = 10
            let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            let scaledImage = outputImage.transformed(by: transform)
            
            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
            }
        }
        return nil
    }
}
