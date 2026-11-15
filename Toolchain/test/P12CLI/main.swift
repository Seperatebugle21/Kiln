// Test driver for Kiln's PKCS12 reader on a Mac: reads a .p12 and signs a dylib with its key.
// Usage: p12test <file.p12> <password> <dylib>
import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: p12test <file.p12> <password> <dylib>")
    exit(2)
}
let contents = try PKCS12.parse(try Data(contentsOf: URL(fileURLWithPath: arguments[1])), password: arguments[2])
var error: Unmanaged<CFError>?
guard let key = SecKeyCreateWithData(contents.rsaPrivateKey as CFData, [
    kSecAttrKeyType: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
] as CFDictionary, &error) else {
    print("key not accepted: \(error!.takeRetainedValue())")
    exit(1)
}
let leaf = try CertificateInfo(der: contents.certificates[0])
print("key: \(contents.rsaPrivateKey.count) bytes, certificates: \(contents.certificates.count), team: \(leaf.organizationalUnit ?? "-")")
try MachOSigner(privateKey: key, certificates: contents.certificates, teamID: leaf.organizationalUnit ?? "")
    .sign(fileAt: URL(fileURLWithPath: arguments[3]), identifier: "app.kiln.build.HelloKiln")
print("signed \(arguments[3])")

// A wrong password must be reported as such.
do {
    _ = try PKCS12.parse(try Data(contentsOf: URL(fileURLWithPath: arguments[1])), password: arguments[2] + "x")
    print("wrong password was accepted")
    exit(1)
} catch PKCS12.Failure.wrongPassword {
    print("wrong password rejected")
}
