// Make CyberView the default app for images + markdown.
// Run: swift set-default.swift
import AppKit
import UniformTypeIdentifiers

let appURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/CyberView.app")

var types: [UTType] = [.png, .jpeg, .gif, .webP, .tiff, .heic, .bmp]
if let md = UTType("net.daringfireball.markdown") { types.append(md) }
var remaining = types.count

for type in types {
    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
        if let error {
            print("\(type.identifier): FAILED — \(error.localizedDescription)")
        } else {
            print("\(type.identifier): ok")
        }
        remaining -= 1
    }
}

while remaining > 0 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
