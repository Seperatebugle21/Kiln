// Test driver for Kiln's MachOSigner on a Mac: signs a dylib with a key and certificate from files.
// Usage: signer <dylib> <PKCS#1 RSA private key, DER> <team ID> <certificate DER>...
import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write(Data("usage: signer <dylib> <key.der> <team id> <cert.der>...\n".utf8))
    exit(2)
}
let keyData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
var error: Unmanaged<CFError>?
guard let key = SecKeyCreateWithData(keyData as CFData, [
    kSecAttrKeyType: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
] as CFDictionary, &error) else {
    print("Could not load the key: \(error!.takeRetainedValue())")
    exit(1)
}
let certificates = try arguments[4...].map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
let signer = MachOSigner(privateKey: key, certificates: certificates, teamID: arguments[3])
try signer.sign(fileAt: URL(fileURLWithPath: arguments[1]), identifier: "app.kiln.build.HelloKiln")
print("Signed \(arguments[1])")
