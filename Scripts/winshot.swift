// Prints the window ID of the first on-screen window owned by a process name.
import CoreGraphics
import Foundation
let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == name {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    if (b["Height"] as! Double) > 200 { print(w[kCGWindowNumber as String]!); break }
}
