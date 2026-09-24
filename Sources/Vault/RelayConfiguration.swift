import Foundation

/// Location of the M2 test relay.
///
/// M2 is a deliberately minimal proof of one path: iPhone -> local network ->
/// a developer computer running the test relay. The address is hard-coded on
/// purpose — there is no Bonjour discovery in this milestone.
///
/// Public CI snapshot: the endpoint is a loopback placeholder. Point it at a
/// relay on your own local network to test; never at a public host.
///
/// This is not the production transport: traffic is plaintext and
/// unauthenticated.
struct RelayConfiguration {
    let host: String
    let port: UInt16

    static let `default` = RelayConfiguration(host: "127.0.0.1", port: 8787)
}
