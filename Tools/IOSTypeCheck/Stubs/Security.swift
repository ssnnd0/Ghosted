// Stub Security framework for the type-check harness. NOT part of any shipped product.
// Covers the Keychain pairing-record helpers in LocalSpoofingManager.swift.
//
// Linux Foundation has no CFDictionary/CFTypeRef, so both are aliased to Foundation types that
// `as`-cast identically ([String: Any] and AnyObject). All `kSec*`/`errSec*` globals are marked
// nonisolated(unsafe) so Swift 6 does not infer MainActor isolation for them.

@_exported import Foundation

public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = AnyObject

public nonisolated(unsafe) let kSecClass = "class"
public nonisolated(unsafe) let kSecClassGenericPassword = "genp"
public nonisolated(unsafe) let kSecAttrService = "svce"
public nonisolated(unsafe) let kSecAttrAccount = "acct"
public nonisolated(unsafe) let kSecValueData = "v_Data"
public nonisolated(unsafe) let kSecAttrAccessible = "pdmn"
public nonisolated(unsafe) let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "ck"
public nonisolated(unsafe) let kSecReturnData = "r_Data"
public nonisolated(unsafe) let kSecMatchLimit = "m_Limit"
public nonisolated(unsafe) let kSecMatchLimitOne = "m_LimitOne"
public nonisolated(unsafe) let errSecSuccess: Int32 = 0
public nonisolated(unsafe) let errSecItemNotFound: Int32 = -25300

@discardableResult
public func SecItemDelete(_ query: CFDictionary) -> Int32 { errSecSuccess }
@discardableResult
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> Int32 { errSecSuccess }
@discardableResult
public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> Int32 { errSecSuccess }
