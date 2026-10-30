import Foundation
import NetworkServiceKit
import CNetworkXPC
import Darwin

if CommandLine.arguments.dropFirst() == ["--self-check"] {
    print("{\"version\":\"\(ServicePaths.version)\",\"protocolVersion\":\(ServicePaths.protocolVersion)}")
    exit(0)
}
guard geteuid() == 0 else {
    fputs("keqdroid network service must be installed by keqdroid.pkg and launched by launchd.\n", stderr)
    exit(77)
}

do {
    if CommandLine.arguments.dropFirst() == ["--recover"] {
        try NetworkService.recoverInstallation()
        exit(0)
    }
    guard CommandLine.arguments.count == 1 else { throw ServiceFailure("invalidArguments", "Supported options: --self-check, --recover") }
    let requirementURL = ServicePaths.root.appendingPathComponent("client-requirement.txt")
    try SecureFiles.requireRootOwned(requirementURL, directory: false)
    let requirement = try String(contentsOf: requirementURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    // An exact release cdhash is used in production. An identifier requirement is allowed for local development.
    let pattern = #"^(cdhash H\"[0-9a-fA-F]{40}\"( or cdhash H\"[0-9a-fA-F]{40}\")*|identifier \"com\.keqdroid\.keqdroid\")$"#
    guard requirement.range(of: pattern, options: .regularExpression) != nil else { throw ServiceFailure("unsafeInstallation", "Client requirement must contain only exact release CDHashes or developer identifier.") }
    let service = try NetworkService(clientRequirement: requirement)
    let context = Unmanaged.passRetained(service).toOpaque()
    let status = keq_server_start(requirement, ServicePaths.application, { json, uid, gid, connection, reply, context in
        guard let context, let json else { return }
        let service = Unmanaged<NetworkService>.fromOpaque(context).takeUnretainedValue()
        service.submit(json: String(cString: json), identity: ClientIdentity(uid: uid, gid: gid, connectionID: connection)) { response in
            keq_server_reply(reply, response)
        }
    }, { uid, gid, connection, context in
        guard let context else { return }
        Unmanaged<NetworkService>.fromOpaque(context).takeUnretainedValue()
            .clientDisconnected(identity: ClientIdentity(uid: uid, gid: gid, connectionID: connection))
    }, context)
    guard status == 0 else { throw ServiceFailure("serviceRegistrationFailed", "Cannot register the launchd Mach service (\(status)).") }
    service.startMonitoring()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    termination.setEventHandler { service.shutdown { exit(0) } }
    interruption.setEventHandler { service.shutdown { exit(0) } }
    termination.resume(); interruption.resume()
    withExtendedLifetime((service, termination, interruption)) { dispatchMain() }
} catch {
    fputs("keqdroid network service: \(error.localizedDescription)\n", stderr)
    exit(78)
}
