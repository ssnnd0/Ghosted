// Stub UIKit for the Linux/macOS type-check harness. NOT part of any shipped product.
//
// It exists so `swiftc -typecheck` can check Sources/Ghosted/GhostedApp.swift and
// Sources/Alerts/ProximityAlertManager.swift on a host with no iOS SDK. Only the surface those
// files actually touch is declared. Fidelity rules applied here, learned the hard way:
//
//   * The real SDK marks UIKit @MainActor. UIView, UIViewController, UIFont and friends are marked
//     accordingly, otherwise actor-isolation errors are silently missed.
//   * `UILabel.font` is `UIFont!` (IUO), not `UIFont?` — an Optional breaks the leading-dot lookup
//     that GhostedApp.swift uses (`.preferredFont(forTextStyle: .body)`).
//   * `preferredFont(forTextStyle:)` and `monospacedSystemFont(ofSize:weight:)` are statics on
//     UIFont, not on UILabel.
//   * NSLayoutDimension needs the anchor-form overloads as well as the constant-form ones
//     (`constraint(lessThanOrEqualTo:constant:)` vs `constraint(lessThanOrEqualToConstant:)`).
//
// `Selector` is declared locally because corelibs-Foundation has no Objective-C runtime on Linux.

@_exported import Foundation

public struct Selector: Hashable, Sendable { public init() {} }

public struct UIColor {
    public static let systemBackground = UIColor()
    public static let systemGray6 = UIColor()
    public static let separator = UIColor()
    public static let label = UIColor()
    public static let secondaryLabel = UIColor()
    public static let systemOrange = UIColor()
    public static let systemRed = UIColor()
    public var cgColor: CGColor { CGColor() }
}
public struct CGColor {}

public class NSLayoutAnchor<T: AnyObject>: NSObject {
    public func constraint(equalTo anchor: NSLayoutAnchor<T>, constant: CGFloat = 0) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(greaterThanOrEqualTo anchor: NSLayoutAnchor<T>, constant: CGFloat = 0) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(lessThanOrEqualTo anchor: NSLayoutAnchor<T>, constant: CGFloat = 0) -> NSLayoutConstraint { NSLayoutConstraint() }
}
public final class NSLayoutXAxisAnchor: NSLayoutAnchor<NSLayoutXAxisAnchor> {}
public final class NSLayoutYAxisAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor> {}
public final class NSLayoutDimension: NSLayoutAnchor<NSLayoutDimension> {
    public func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(greaterThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
    public func constraint(lessThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}
public final class NSLayoutConstraint: NSObject {
    public static func activate(_ constraints: [NSLayoutConstraint]) {}
}
public final class UILayoutGuide: NSObject {
    public let topAnchor = NSLayoutYAxisAnchor()
    public let bottomAnchor = NSLayoutYAxisAnchor()
}
public final class CALayer: NSObject {
    public var cornerRadius: CGFloat = 0
    public var borderWidth: CGFloat = 0
    public var borderColor: CGColor?
}

open class UIResponder: NSObject {}

@MainActor
open class UIView: UIResponder {
    open var backgroundColor: UIColor!
    open var translatesAutoresizingMaskIntoConstraints: Bool = true
    open var layer: CALayer { CALayer() }
    open var safeAreaLayoutGuide: UILayoutGuide { UILayoutGuide() }
    open var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var widthAnchor: NSLayoutDimension { NSLayoutDimension() }
    open var heightAnchor: NSLayoutDimension { NSLayoutDimension() }
    open func addSubview(_ v: UIView) {}
}

open class UILabel: UIView {
    open var numberOfLines: Int = 1
    open var text: String?
    open var textColor: UIColor!
    open var font: UIFont!
}

open class UIFont: NSObject {
    public static func preferredFont(forTextStyle style: TextStyle) -> UIFont { UIFont() }
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: Weight) -> UIFont { UIFont() }
    /// Distinct from `monospacedSystemFont` on Apple platforms: this one uses lining figures
    /// with tabular widths, so digits do not jitter as a counter changes. Modelling them as one
    /// method would hide a caller assuming the wrong one.
    public static func monospacedDigitSystemFont(ofSize size: CGFloat, weight: Weight) -> UIFont { UIFont() }

    public struct TextStyle: RawRepresentable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let largeTitle = TextStyle(rawValue: "largeTitle")
        public static let title1 = TextStyle(rawValue: "title1")
        public static let title2 = TextStyle(rawValue: "title2")
        public static let title3 = TextStyle(rawValue: "title3")
        public static let headline = TextStyle(rawValue: "headline")
        public static let subheadline = TextStyle(rawValue: "subheadline")
        public static let body = TextStyle(rawValue: "body")
        public static let callout = TextStyle(rawValue: "callout")
        public static let footnote = TextStyle(rawValue: "footnote")
        public static let caption1 = TextStyle(rawValue: "caption1")
        public static let caption2 = TextStyle(rawValue: "caption2")
    }
    public struct Weight: RawRepresentable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let regular = Weight(rawValue: 0)
    }
}

open class UIControl: UIView {
    public struct Event: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let touchUpInside = Event(rawValue: 1)
        // UIControl.Event is a genuine bitmask upstream, so alternatives combine with `.union`
        // rather than `[]`. Modelling it as OptionSet keeps that expressible.
        public static let touchUpOutside = Event(rawValue: 2)
        public static let valueChanged = Event(rawValue: 4096)
        public static let editingChanged = Event(rawValue: 8192)
    }
    public struct State: RawRepresentable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let normal = State(rawValue: 0)
    }
    open var isEnabled: Bool = true
    open func addTarget(_ target: Any?, action: Selector, for controlEvents: UIControl.Event) {}
}

open class UIButton: UIControl {
    public enum ButtonType: Sendable { case system, custom }
    public init(type: ButtonType) { super.init() }
    open func setTitle(_ title: String?, for state: UIControl.State) {}
}

// MARK: - Text input

/// Modelled as its own subclass rather than folded into `UILabel`: on Apple platforms
/// `UITextField` is a `UIView` and does *not* have a `text`/`font` pair inherited from anywhere.
/// Code that sets `.text` on a text field must compile because the subclass declares it.
open class UITextField: UIView {
    // These are `NS_REQUIRES_SUPER`-style NS_ENUM wrapper types on Apple platforms (subclasses of
    // NSInteger, initialised by raw value), not bare `Int` enums. Modelling them as Swift enums
    // keeps leading-dot syntax working, which is the part callers depend on.
    public struct BorderStyle: RawRepresentable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let none = BorderStyle(rawValue: 0)
        public static let line = BorderStyle(rawValue: 1)
        public static let bezel = BorderStyle(rawValue: 2)
        public static let roundedRect = BorderStyle(rawValue: 3)
    }
    public struct AutocorrectionType: RawRepresentable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let `default` = AutocorrectionType(rawValue: 0)
        public static let no = AutocorrectionType(rawValue: 1)
        public static let yes = AutocorrectionType(rawValue: 2)
    }
    public struct AutocapitalizationType: RawRepresentable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let none = AutocapitalizationType(rawValue: 0)
        public static let words = AutocapitalizationType(rawValue: 1)
        public static let sentences = AutocapitalizationType(rawValue: 2)
        public static let allCharacters = AutocapitalizationType(rawValue: 3)
    }
    public struct KeyboardType: RawRepresentable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let `default` = KeyboardType(rawValue: 0)
        public static let numbersAndPunctuation = KeyboardType(rawValue: 4)
        public static let numberPad = KeyboardType(rawValue: 5)
        public static let decimalPad = KeyboardType(rawValue: 6)
        public static let emailAddress = KeyboardType(rawValue: 7)
        public static let URL = KeyboardType(rawValue: 8)
    }
    public struct ClearButtonMode: RawRepresentable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let never = ClearButtonMode(rawValue: 0)
        public static let whileEditing = ClearButtonMode(rawValue: 1)
        public static let unlessEditing = ClearButtonMode(rawValue: 2)
        public static let always = ClearButtonMode(rawValue: 3)
    }

    open var text: String?
    open var placeholder: String?
    open var font: UIFont!
    open var textColor: UIColor!
    open var borderStyle: BorderStyle = .none
    open var autocorrectionType: AutocorrectionType = .default
    open var autocapitalizationType: AutocapitalizationType = .sentences
    open var keyboardType: KeyboardType = .default
    open var clearButtonMode: ClearButtonMode = .never
    open var isEnabled: Bool = true
}

open class UISlider: UIControl {
    open var minimumValue: Float = 0
    open var maximumValue: Float = 1
    open var value: Float = 0.5
}

open class UIStackView: UIView {
    public enum Axis: Int, Sendable { case horizontal, vertical }
    public enum Alignment: Int, Sendable { case center, fill, leading }
    open var axis: Axis = .horizontal
    open var spacing: CGFloat = 0
    open var alignment: Alignment = .fill
    open func addArrangedSubview(_ v: UIView) {}
}

@MainActor
open class UIViewController: UIResponder {
    open var view: UIView = UIView()
    public init(nibName: String?, bundle: Bundle?) { super.init() }
    public required init?(coder: NSCoder) { fatalError() }
    open func viewDidLoad() {}
}

open class UIWindow: UIView {
    open var rootViewController: UIViewController!
    public init(frame: CGRect) { super.init() }
    open func makeKeyAndVisible() {}
}

open class UIScreen: NSObject {
    @MainActor public static let main = UIScreen()
    public var bounds: CGRect { .zero }
}

@MainActor open class UINotificationFeedbackGenerator: NSObject {
    public enum FeedbackType: Int, Sendable { case success, warning, error }
    public override init() {}
    open func notificationOccurred(_ type: FeedbackType) {}
}

open class UIApplication: UIResponder {
    public struct LaunchOptionsKey: Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public static let shared = UIApplication()
}

@MainActor public protocol UIApplicationDelegate: AnyObject {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
}
