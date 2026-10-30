import Foundation
import ObjectiveC
import Darwin

/// Optional bridge to the same native limiter used by System Settings.
/// Private selectors are loaded dynamically, checked for ABI compatibility,
/// and never called on systems where that interface is absent.
final class NativeChargeLimit {
    private let client: NSObject
    private init(client: NSObject) { self.client = client }

    static func connect() -> NativeChargeLimit? {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let allocMethod = class_getClassMethod(cls, NSSelectorFromString("alloc")),
              let initMethod = class_getInstanceMethod(cls, NSSelectorFromString("initWithClientName:")),
              let initEncoding = method_getTypeEncoding(initMethod),
              String(cString: initEncoding) == "@24@0:8@16" else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Init.self)
        let instance = alloc(cls, NSSelectorFromString("alloc"))
        guard let object = initialize(instance.takeUnretainedValue(), NSSelectorFromString("initWithClientName:"), "BetterBattery")?.takeRetainedValue() as? NSObject else { return nil }
        let signatures = [
            "isMCLSupported": "B16@0:8",
            "availableChargeLimitsWithError:": "@24@0:8^@16",
            "getMCLLimitWithError:": "C24@0:8^@16",
            "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
            "setMCLLimit:error:": "B28@0:8C16^@20"
        ]
        for (name, signature) in signatures {
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let encoding = method_getTypeEncoding(method),
                  String(cString: encoding) == signature else { return nil }
        }
        typealias Supported = @convention(c) (AnyObject, Selector) -> Bool
        let selector = NSSelectorFromString("isMCLSupported")
        let supported = unsafeBitCast(object.method(for: selector), to: Supported.self)
        guard supported(object, selector) else { return nil }
        return NativeChargeLimit(client: object)
    }

    var availableLimits: [Int] {
        typealias Limits = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSArray>?
        let selector = NSSelectorFromString("availableChargeLimitsWithError:")
        let call = unsafeBitCast(client.method(for: selector), to: Limits.self)
        var error: NSError?
        guard let result = call(client, selector, &error)?.takeUnretainedValue() as? [NSNumber], error == nil else { return [] }
        return result.map(\.intValue).filter { (80...100).contains($0) }.sorted()
    }

    var currentLimit: Int? {
        typealias Get = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt8
        let selector = NSSelectorFromString("getMCLLimitWithError:")
        let call = unsafeBitCast(client.method(for: selector), to: Get.self)
        var error: NSError?
        let value = Int(call(client, selector, &error))
        guard error == nil, (80...100).contains(value) else { return nil }
        typealias Enabled = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt64
        let enabledSelector = NSSelectorFromString("isMCLCurrentlyEnabled:")
        let enabledCall = unsafeBitCast(client.method(for: enabledSelector), to: Enabled.self)
        let enabled = enabledCall(client, enabledSelector, &error)
        guard error == nil else { return nil }
        return enabled == 0 ? 100 : value
    }

    func setLimit(_ limit: Int) -> Bool {
        guard availableLimits.contains(limit) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
        let selector = NSSelectorFromString("setMCLLimit:error:")
        let call = unsafeBitCast(client.method(for: selector), to: Set.self)
        var error: NSError?
        guard call(client, selector, UInt8(limit), &error), error == nil else { return false }
        return currentLimit == limit
    }
}
