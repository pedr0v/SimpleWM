import Foundation
import CoreGraphics
import ApplicationServices
import MachO
import os

/// Private SkyLight (SLS*/CGS*) functions, loaded with `dlopen`/`dlsym`.
///
/// Every symbol is optional. A missing symbol disables only the feature that
/// needs it. No private header and no C target exist in this package.
/// All members are constants after `init`, so the type is safe to share.
public final class SkyLight: @unchecked Sendable {
    public typealias MainConnectionIDFn = @convention(c) () -> Int32
    public typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    public typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    public typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
    public typealias ManagedDisplayGetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    public typealias CopyManagedDisplayForWindowFn = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    public typealias CopyActiveMenuBarDisplayIdentifierFn = @convention(c) (Int32) -> Unmanaged<CFString>?
    public typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    public typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    public typealias SpaceSetCompatIDFn = @convention(c) (Int32, UInt64, Int32) -> CGError
    public typealias SetWindowListWorkspaceFn = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> CGError
    public typealias ManagedDisplayIsAnimatingFn = @convention(c) (Int32, CFString) -> Bool
    /// File-local symbol. `dlsym` returns NULL. The loader walks `LC_SYMTAB`.
    /// On macOS 26.1 the function returns void. Ignore the result.
    public typealias PerformBridgedOperationFn = @convention(c) (AnyObject) -> Int64
    /// `_SLPSSetFrontProcessWithOptions(psn, wid, mode)`. Mode `0x200` is `kCPSUserGenerated`.
    public typealias SetFrontProcessWithOptionsFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    /// `GetProcessForPID` (deprecated HIServices). Loaded with `dlsym` to avoid the warning.
    public typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    /// `_AXUIElementGetWindow(element, &windowID)` (private HIServices). Loaded
    /// with `dlsym`, so a macOS update that removes it does not stop the launch.
    public typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// Shared loader. `nil` members mean the symbol is absent.
    public static let shared = SkyLight()

    public let handle: UnsafeMutableRawPointer?
    public let mainConnectionID: MainConnectionIDFn?
    public let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    public let getActiveSpace: GetActiveSpaceFn?
    public let spaceGetType: SpaceGetTypeFn?
    public let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpaceFn?
    public let copyManagedDisplayForWindow: CopyManagedDisplayForWindowFn?
    public let copyActiveMenuBarDisplayIdentifier: CopyActiveMenuBarDisplayIdentifierFn?
    public let copySpacesForWindows: CopySpacesForWindowsFn?
    public let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn?
    public let spaceSetCompatID: SpaceSetCompatIDFn?
    public let setWindowListWorkspace: SetWindowListWorkspaceFn?
    public let managedDisplayIsAnimating: ManagedDisplayIsAnimatingFn?
    public let performBridgedOperation: PerformBridgedOperationFn?
    public let setFrontProcessWithOptions: SetFrontProcessWithOptionsFn?
    public let getProcessForPID: GetProcessForPIDFn?
    public let axUIElementGetWindow: AXUIElementGetWindowFn?

    /// Connection ID cached at load time. Zero when SkyLight is absent.
    public let cid: Int32

    public static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    /// Name prefix of the file-local bridged-operation function.
    ///
    /// The parameter type in the mangled name changes between releases:
    /// `P8NSObject` (older) and `P47SLSAsynchronousBridgedWindowManagementOperation`
    /// (macOS 26.1). The prefix matches both.
    public static let bridgedOperationSymbolPrefix =
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP"

    static let log = Logger(subsystem: "com.simplewm.app", category: "skylight")

    private init() {
        let h = dlopen(SkyLight.frameworkPath, RTLD_LAZY)
        handle = h
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else {
                SkyLight.log.warning("SkyLight symbol missing: \(name, privacy: .public)")
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        mainConnectionID = sym("SLSMainConnectionID", MainConnectionIDFn.self)
        copyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
        getActiveSpace = sym("SLSGetActiveSpace", GetActiveSpaceFn.self)
        spaceGetType = sym("SLSSpaceGetType", SpaceGetTypeFn.self)
        managedDisplayGetCurrentSpace = sym("SLSManagedDisplayGetCurrentSpace", ManagedDisplayGetCurrentSpaceFn.self)
        copyManagedDisplayForWindow = sym("SLSCopyManagedDisplayForWindow", CopyManagedDisplayForWindowFn.self)
        copyActiveMenuBarDisplayIdentifier = sym("SLSCopyActiveMenuBarDisplayIdentifier", CopyActiveMenuBarDisplayIdentifierFn.self)
        copySpacesForWindows = sym("SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
        moveWindowsToManagedSpace = sym("SLSMoveWindowsToManagedSpace", MoveWindowsToManagedSpaceFn.self)
        spaceSetCompatID = sym("SLSSpaceSetCompatID", SpaceSetCompatIDFn.self)
        setWindowListWorkspace = sym("SLSSetWindowListWorkspace", SetWindowListWorkspaceFn.self)
        managedDisplayIsAnimating = sym("SLSManagedDisplayIsAnimating", ManagedDisplayIsAnimatingFn.self)
        setFrontProcessWithOptions = sym("_SLPSSetFrontProcessWithOptions", SetFrontProcessWithOptionsFn.self)
        performBridgedOperation = SkyLight.findLocalSymbol(
            SkyLight.bridgedOperationSymbolPrefix,
            in: h
        ).map { unsafeBitCast($0, to: PerformBridgedOperationFn.self) }
        if performBridgedOperation == nil {
            SkyLight.log.warning("SkyLight local symbol missing: SLSPerformAsynchronousBridgedWindowManagementOperation")
        }
        // RTLD_DEFAULT is ((void *)-2). Swift does not import the macro.
        if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") {
            getProcessForPID = unsafeBitCast(p, to: GetProcessForPIDFn.self)
        } else {
            getProcessForPID = nil
        }
        if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            axUIElementGetWindow = unsafeBitCast(p, to: AXUIElementGetWindowFn.self)
        } else {
            SkyLight.log.warning("Accessibility symbol missing: _AXUIElementGetWindow. Windows cannot map to IDs.")
            axUIElementGetWindow = nil
        }
        cid = mainConnectionID?() ?? 0
    }

    /// Finds a file-local symbol by walking `LC_SYMTAB` of the loaded image
    /// (yabai `macho_find_symbol`). Returns nil when the image or symbol is absent.
    /// The symbol name may be a prefix: the first match wins.
    ///
    /// Steps:
    /// 1. Find the dyld image whose `dlopen(name, RTLD_NOLOAD)` handle equals `handle`.
    /// 2. Read `LC_SEGMENT_64 __LINKEDIT` and `LC_SYMTAB` from its `mach_header_64`.
    /// 3. Compare each `nlist_64` name with `name` and return `n_value + slide`.
    static func findLocalSymbol(_ name: String, in handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        guard let handle, !name.isEmpty else { return nil }
        guard let index = imageIndex(for: handle) else {
            log.warning("findLocalSymbol: no dyld image for handle")
            return nil
        }
        return findSymbol(prefix: name, imageIndex: index)
    }

    /// Returns the dyld image index that `handle` refers to.
    static func imageIndex(for handle: UnsafeMutableRawPointer) -> UInt32? {
        let count = _dyld_image_count()
        // Fast path: compare names with the framework path forms.
        var candidates: [UInt32] = []
        for i in 0..<count {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName)
            if name.contains("/SkyLight.framework/") { candidates.append(i) }
        }
        let all = candidates + (0..<count).filter { !candidates.contains($0) }
        for i in all {
            guard let cName = _dyld_get_image_name(i) else { continue }
            guard let h = dlopen(cName, RTLD_LAZY | RTLD_NOLOAD) else { continue }
            defer { dlclose(h) }
            if h == handle { return i }
        }
        return nil
    }

    /// Walks the symbol table of dyld image `imageIndex`. Returns the first
    /// defined symbol whose name starts with `prefix`.
    static func findSymbol(prefix: String, imageIndex: UInt32) -> UnsafeMutableRawPointer? {
        guard let header = _dyld_get_image_header(imageIndex) else { return nil }
        let slide = _dyld_get_image_vmaddr_slide(imageIndex)
        let base = UnsafeRawPointer(header)
        let mh = base.load(as: mach_header_64.self)
        guard mh.magic == MH_MAGIC_64 else { return nil }

        var linkedit: segment_command_64?
        var symtab: symtab_command?
        var cursor = base + MemoryLayout<mach_header_64>.size
        for _ in 0..<mh.ncmds {
            let lc = cursor.load(as: load_command.self)
            if lc.cmd == UInt32(LC_SEGMENT_64) {
                let seg = cursor.load(as: segment_command_64.self)
                if segmentName(seg) == "__LINKEDIT" { linkedit = seg }
            } else if lc.cmd == UInt32(LC_SYMTAB) {
                symtab = cursor.load(as: symtab_command.self)
            }
            guard lc.cmdsize > 0 else { return nil }
            cursor += Int(lc.cmdsize)
        }
        guard let linkedit, let symtab, symtab.nsyms > 0 else { return nil }

        // Address of file offset 0 of __LINKEDIT, in memory.
        let linkeditBase = Int(linkedit.vmaddr) + slide - Int(linkedit.fileoff)
        guard let lbase = UnsafeRawPointer(bitPattern: linkeditBase) else { return nil }
        let symbols = (lbase + Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
        let strings = (lbase + Int(symtab.stroff)).assumingMemoryBound(to: UInt8.self)
        let target = Array(prefix.utf8)
        let strSize = Int(symtab.strsize)

        for i in 0..<Int(symtab.nsyms) {
            let entry = symbols[i]
            // Skip debug (stab) entries and undefined symbols.
            if entry.n_type & UInt8(N_STAB) != 0 { continue }
            if entry.n_type & UInt8(N_TYPE) != UInt8(N_SECT) { continue }
            let strx = Int(entry.n_un.n_strx)
            guard strx > 0, strx + target.count <= strSize else { continue }
            let s = strings + strx
            var k = 0
            while k < target.count, s[k] == target[k] { k += 1 }
            guard k == target.count, entry.n_value != 0 else { continue }
            return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
        }
        return nil
    }

    private static func segmentName(_ seg: segment_command_64) -> String {
        var name = seg.segname
        return withUnsafeBytes(of: &name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Maps an Accessibility element to its `CGWindowID`. The function calls the
/// private `_AXUIElementGetWindow`, which `SkyLight` loads with `dlsym`.
/// Returns `.failure` when the symbol is absent.
public func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<UInt32>) -> AXError {
    guard let getWindow = SkyLight.shared.axUIElementGetWindow else { return .failure }
    return getWindow(element, out)
}
