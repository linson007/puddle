import Foundation
import Security

enum CuaHelperTrust {
    static func verify(_ executable: URL, requirement: String? = Bundle.main.object(forInfoDictionaryKey: "PuddleCuaDriverRequirement") as? String) throws {
        guard let requirement, !requirement.isEmpty else {
            throw PuddleError("This build has no trusted Cua Driver identity. Browser sessions are disabled until the app publisher configures and tests a signed helper.")
        }
        var code: SecStaticCode?, rule: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let rule, SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else {
            throw PuddleError("Cua Driver failed its publisher identity or signature check. Reinstall the supported signed driver before starting a browser session.")
        }
    }
}
