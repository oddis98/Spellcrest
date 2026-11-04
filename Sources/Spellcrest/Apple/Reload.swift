#if os(macOS) // the editor, and so hot reload, is Mac-only
import Foundation
import MachO
import ObjectiveC

/// Hot reload. The editor compiles the game's code into a fresh library; the game loads it and moves every live
/// object over to the new version of its class. Objects keep their memory, so the game's state (where the player
/// is, the score, …) stays, and from then on they run the new code.
///
/// That only works while each class keeps the same stored properties: a changed layout would put old values in the
/// wrong places, so then nothing is swapped and the game asks for a restart. Static and global variables in the game
/// start over, because the new library has its own.
@MainActor enum Reloader {
    /// Loads the library at `path` and switches objects to its classes. Returns a line for the console.
    static func load(_ path: String) -> String {
        guard dlopen(path, RTLD_NOW) != nil else { return "Reload failed: \(String(cString: dlerror()))" }
        return swap(liveObjects(), to: classes(inImage: path))
    }

    /// Switches each object whose class has a new version in `classes` (by name), or none of them if any class
    /// changed its stored properties.
    static func swap(_ objects: [AnyObject], to classes: [String: AnyClass]) -> String {
        var swaps: [(AnyObject, AnyClass)] = []
        for object in objects {
            let old: AnyClass = type(of: object)
            guard let new = classes[NSStringFromClass(old)], new !== old else { continue }
            guard sameLayout(old, new) else {
                return "Can't reload: \(old) changed its stored properties. Restart the game to see that change."
            }
            swaps.append((object, new))
        }
        for (object, new): (AnyObject, AnyClass) in swaps { object_setClass(object, new) }
        let names = Set(swaps.map { "\(type(of: $0.0))" }).sorted()
        return names.isEmpty ? "Reloaded" : "Reloaded \(names.joined(separator: ", "))"
    }

    /// Every object reachable from the current scene through stored properties.
    static func liveObjects() -> [AnyObject] {
        var seen = Set<ObjectIdentifier>()
        var objects: [AnyObject] = []
        func visit(_ value: Any) {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class {
                let object = value as AnyObject
                guard seen.insert(ObjectIdentifier(object)).inserted else { return }
                objects.append(object)
            }
            var level: Mirror? = mirror
            while let current = level {
                for child in current.children { visit(child.value) }
                level = current.superclassMirror
            }
        }
        visit(Scene.current)
        if let next = Scene.changing?.next { visit(next) } // the scene a transition is going to
        return objects
    }

    /// The classes a loaded library defines, by name. Two classes now share each name (old and new), so they're
    /// told apart by the image they come from.
    static func classes(inImage path: String) -> [String: AnyClass] {
        // The library's path exactly as the loader recorded it.
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let image = (0..<_dyld_image_count()).reversed().lazy.compactMap({ _dyld_get_image_name($0).map { String(cString: $0) } })
            .first(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target }) else { return [:] }
        var nameCount: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &nameCount) else { return [:] }
        defer { free(names) }
        let wanted = Set((0..<Int(nameCount)).map { String(cString: names[$0]) })

        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return [:] }
        defer { free(UnsafeMutableRawPointer(list)) }
        // Read the list as raw pointers: turning each class into a Swift type sends it a message, and some
        // system classes crash when that happens.
        let pointers = UnsafeRawPointer(list).assumingMemoryBound(to: UnsafeRawPointer.self)
        var classes: [String: AnyClass] = [:]
        for i in 0..<Int(count) {
            let found: AnyClass = unsafeBitCast(pointers[i], to: AnyClass.self)
            let name = String(cString: class_getName(found))
            guard wanted.contains(name), let file = class_getImageName(found), String(cString: file) == image else { continue }
            classes[name] = found
        }
        return classes
    }

    /// Same size and the same stored properties in the same places, so an object of one fits the other.
    static func sameLayout(_ a: AnyClass, _ b: AnyClass) -> Bool {
        class_getInstanceSize(a) == class_getInstanceSize(b) && storedProperties(a) == storedProperties(b)
    }

    static func storedProperties(_ type: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(type, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { "\(ivar_getName(list[$0]).map { String(cString: $0) } ?? "?")@\(ivar_getOffset(list[$0]))" }
    }
}
#endif
