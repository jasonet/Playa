import AppKit
import ApplicationServices
import Foundation

private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as AnyObject?
}

private func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

private func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

private func find(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if predicate(element) { return element }
    guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
        return nil
    }
    for child in children {
        if let match = find(child, where: predicate) { return match }
    }
    return nil
}

private func press(_ description: String, in application: AXUIElement) throws {
    guard let element = find(application, where: {
        stringAttribute($0, kAXDescriptionAttribute) == description
            || stringAttribute($0, kAXTitleAttribute) == description
    }) else {
        throw NSError(domain: "PlayaModelsLayoutTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find \(description)"])
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw NSError(domain: "PlayaModelsLayoutTest", code: Int(result.rawValue), userInfo: [NSLocalizedDescriptionKey: "Could not press \(description): \(result.rawValue)"])
    }
}

let arguments = CommandLine.arguments
let applicationPath = arguments.count > 1 ? arguments[1] : "/Applications/Playa.app"
let workspace = Process()
workspace.executableURL = URL(fileURLWithPath: "/usr/bin/open")
workspace.arguments = [applicationPath]
try workspace.run()
workspace.waitUntilExit()
Thread.sleep(forTimeInterval: 3)

let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.local.Playa")
guard let processIdentifier = running.first?.processIdentifier else {
    fputs("FAIL: Playa is not running\n", stderr)
    exit(1)
}
let application = AXUIElementCreateApplication(processIdentifier)

var foundModels = false
for _ in 0..<10 {
    if (try? press("Models", in: application)) != nil {
        foundModels = true
        break
    }
    Thread.sleep(forTimeInterval: 0.5)
}

guard foundModels else {
    fputs("FAIL: Could not find Models button\n", stderr)
    exit(1)
}
Thread.sleep(forTimeInterval: 0.8)
try press("Installed", in: application)
Thread.sleep(forTimeInterval: 0.8)

guard let window = find(application, where: { stringAttribute($0, kAXRoleAttribute) == kAXWindowRole as String }),
      let splitView = find(application, where: { stringAttribute($0, kAXRoleAttribute) == kAXSplitGroupRole as String }),
      let windowSize = sizeAttribute(window, kAXSizeAttribute),
      let splitSize = sizeAttribute(splitView, kAXSizeAttribute)
else {
    fputs("FAIL: Could not read Playa window geometry\n", stderr)
    exit(1)
}

let difference = abs(windowSize.height - splitSize.height)
if difference > 1 {
    fputs("FAIL: Installed Models expands NavigationSplitView to \(Int(splitSize.height))pt inside a \(Int(windowSize.height))pt window\n", stderr)
    exit(1)
}

print("PASS: Installed Models remains constrained to the \(Int(windowSize.height))pt window")
