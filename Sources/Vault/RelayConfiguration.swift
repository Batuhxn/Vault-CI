#if DEBUG
// Legacy plaintext LAN demo; excluded from Release and unreachable from WatchlinkRootView.
import Foundation

/// Location of the M2 test relay.
///
/// M2 is a deliberately minimal proof of one path: iPhone -> local network ->
/// a developer computer running the test relay. The address is hard-coded on
/// purpose — there is no Bonjour discovery in this milestone.
///
/// The public CI mirror is generated with `host` rewritten to the loopback
/// placeholder `127.0.0.1`. Never point it at a public host.
///
/// This is not the production transport: traffic is plaintext and
/// unauthenticated.
struct RelayConfiguration {
    let host: String
    let port: UInt16

    static let `default` = RelayConfiguration(host: "127.0.0.1", port: 8787)
}

#endif
