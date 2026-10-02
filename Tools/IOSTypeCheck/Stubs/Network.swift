// Stub Network framework for the type-check harness. NOT part of any shipped product.
// Covers the NWConnection reachability probe and NWPathMonitor in LocalSpoofingManager.swift.
//
// `NWEndpoint.Port(rawValue:)` is failable in the real SDK, and LocalSpoofingManager.swift
// force-unwraps it. Declaring it non-failable here would turn that correct code into a false
// "cannot force unwrap non-optional" error, so it must stay `init?`.

@_exported import Foundation

public struct NWEndpoint {
    public struct Host: Hashable, Sendable { public let rawValue: String; public init(_ s: String) { rawValue = s } }
    public struct Port: Hashable, Sendable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
    }
}

public struct NWParameters: Sendable {
    public static let tcp = NWParameters()
    public init() {}
}

public struct NWPath: Sendable { public var status: NWPath.Status { .satisfied } }
extension NWPath {
    public enum Status: Int, Sendable { case unsatisfied, satisfied, requiresConnection }
}

public final class NWConnection {
    public enum State: Sendable {
        case setup, waiting, preparing, ready, failed(NWError), cancelled
        public static func == (l: State, r: State) -> Bool { true }
    }
    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using params: NWParameters) {}
    public var stateUpdateHandler: (@Sendable (State) -> Void)?
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
}
public struct NWError: Sendable { public var errorDescription: String? { nil } }

public final class NWPathMonitor {
    public init() {}
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
}
