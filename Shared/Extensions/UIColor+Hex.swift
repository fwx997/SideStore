//
//  UIColor+Hex.swift
//  AltStore
//
//  Created by Riley Testut on 7/15/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

public extension UIColor
{
    // Borrowed from https://stackoverflow.com/a/26341062
    var hexString: String {
        let components = self.cgColor.components
        let r: CGFloat = components?[0] ?? 0.0
        let g: CGFloat = components?[1] ?? 0.0
        let b: CGFloat = components?[2] ?? 0.0

        let hexString = String.init(format: "%02lX%02lX%02lX", lroundf(Float(r * 255)), lroundf(Float(g * 255)), lroundf(Float(b * 255)))
        return hexString
    }
    
    // Borrowed from https://stackoverflow.com/a/33397427
    convenience init?(hexString: String)
    {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        // Upstream issue #1527: scanInt32 overflows for 8-digit hex >= 0x80000000 (e.g. opaque
        // ARGB colors "FF5733FF"), decoding them all to translucent white. Int64 holds every
        // 32-bit hex value, so scan Int64 and range-check before the UInt32 cast.
        guard let scanned = Scanner(string: hex).scanInt64(representation: .hexadecimal),
              scanned >= 0, scanned <= UInt32.max, case let int = UInt32(scanned) else { return nil }
        
        let a, r, g, b: UInt32
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
