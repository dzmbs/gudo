import Foundation
@testable import HostKit
import Testing
import GudoCore

/// A private CA (P-256, CN "Homelab Relay CA", O "Homelab", valid until 2036-10-17).
let homelabCA = """
    -----BEGIN CERTIFICATE-----
    MIIBjjCCATSgAwIBAgIUSoG9sFYaaEkWPSycjKU8bAoZRj4wCgYIKoZIzj0EAwIw
    LTEZMBcGA1UEAwwQSG9tZWxhYiBSZWxheSBDQTEQMA4GA1UECgwHSG9tZWxhYjAe
    Fw0yNjEwMjAyMTUyMjNaFw0zNjEwMTcyMTUyMjNaMC0xGTAXBgNVBAMMEEhvbWVs
    YWIgUmVsYXkgQ0ExEDAOBgNVBAoMB0hvbWVsYWIwWTATBgcqhkjOPQIBBggqhkjO
    PQMBBwNCAAQq4waIe2UN/pjLOo+U/H9nGl9Vm8a4RSKrSgBTPz8Uy8RFzotPsv0F
    key4Do2IH9pNxWnflm3DGqfPjrYJfJ7LozIwMDAdBgNVHQ4EFgQU7x9GPQB874JA
    eTMypSd6jyglmI0wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA
    wK2pAsrAs5VcFe04UQqd3icYpN0zltXDy+GsHNW0yjsCIBUnRBOu94Pog2SDAWTG
    R09HUVo4ApZPlQQ5SFv4T5FB
    -----END CERTIFICATE-----

    """

/// A second CA (CN "Second Relay CA", valid until 2027-10-20).
let secondCA = """
    -----BEGIN CERTIFICATE-----
    MIIBaDCCAQ6gAwIBAgIUX9U8I30dP5P85oK6brBVyO4+2SQwCgYIKoZIzj0EAwIw
    GjEYMBYGA1UEAwwPU2Vjb25kIFJlbGF5IENBMB4XDTI2MTAyMDIxNTIyM1oXDTI3
    MTAyMDIxNTIyM1owGjEYMBYGA1UEAwwPU2Vjb25kIFJlbGF5IENBMFkwEwYHKoZI
    zj0CAQYIKoZIzj0DAQcDQgAEGRJssY9/mfn80QYxw7B5e8nDR7XiWHM8xjAANuH1
    OcCAZE/HOvKLaCFwXm8+IzWTxJLwZSVUj6zPfcLHefoQS6MyMDAwHQYDVR0OBBYE
    FOmSOA7nRdnk+fSOW0peOkGGjNq1MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0E
    AwIDSAAwRQIhAIkFZ56gflJcNkSS6LCRHxUBKqg3W/6UX99dCqu9TUJxAiARwqku
    ZYrde5ge3+XPB0T923Oc0XFfyLBt8bP4rE5w+g==
    -----END CERTIFICATE-----

    """

@MainActor
@Suite struct RelaySettingsTests {
    @Test func pemFilesWithOneOrMoreCertificates() throws {
        let one = try RelayCertificate.parse(Data(homelabCA.utf8))
        #expect(one.count == 1)
        #expect(one[0].subject == "Homelab Relay CA")
        let expires = try #require(one[0].expires)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: expires).year == 2036)
        #expect(!one[0].isExpired)

        // A bundle (with CRLF line ends and text around the blocks) gives each certificate.
        let bundle = ("# relay CAs\r\n" + homelabCA + "comment\n" + secondCA).replacingOccurrences(of: "\n", with: "\r\n")
        let both = try RelayCertificate.parse(Data(bundle.utf8))
        #expect(both.map(\.subject) == ["Homelab Relay CA", "Second Relay CA"])
        #expect(both[0].der == one[0].der)
        #expect(both[0].der.first == 0x30)
    }

    @Test func derFilesAndThingsThatAreNotCertificates() throws {
        let der = try RelayCertificate.parse(Data(homelabCA.utf8))[0].der
        #expect(try RelayCertificate.parse(der).map(\.subject) == ["Homelab Relay CA"])

        #expect(throws: RelayCertificate.Problem.notACertificate) { try RelayCertificate.parse(Data("hello".utf8)) }
        #expect(throws: RelayCertificate.Problem.notACertificate) { try RelayCertificate.parse(Data()) }
        let key = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----\n"
        #expect(throws: RelayCertificate.Problem.privateKey) { try RelayCertificate.parse(Data(key.utf8)) }
        // A block whose body is not a certificate.
        let junk = "-----BEGIN CERTIFICATE-----\naGVsbG8gd29ybGQ=\n-----END CERTIFICATE-----\n"
        #expect(throws: RelayCertificate.Problem.notACertificate) { try RelayCertificate.parse(Data(junk.utf8)) }
    }

    @Test func relayURLsAreCheckedAsTyped() throws {
        #expect(try RelayURL.parse("relay.example.com").absoluteString == "https://relay.example.com")
        #expect(try RelayURL.parse("  https://relay.example.com:8443  ").absoluteString == "https://relay.example.com:8443")
        #expect(try RelayURL.parse("http://192.168.1.5:3340").absoluteString == "http://192.168.1.5:3340")
        #expect(throws: RelayURL.Problem.empty) { try RelayURL.parse("  ") }
        #expect(throws: RelayURL.Problem.scheme("ftp")) { try RelayURL.parse("ftp://relay.example.com") }
        #expect(throws: RelayURL.Problem.malformed) { try RelayURL.parse("relay example com") }
        #expect(throws: RelayURL.Problem.malformed) { try RelayURL.parse("https://") }
        #expect(throws: RelayURL.Problem.malformed) { try RelayURL.parse("https://relay.example.com/?x=1") }
    }

    @Test func settingsMapToTheConnection() throws {
        let der = try RelayCertificate.parse(Data(homelabCA.utf8))[0].der

        // Default: the ticket decides; no extra roots, no own relay.
        let automatic = RelaySettings()
        #expect(automatic.clientRelay() == .default)
        #expect(automatic.connectOptions(askpass: true) == ConnectOptions(relayCaDer: [], relayUrls: [], relayAuthToken: nil, askpass: true, browser: true, programStatus: true, clipboard: true))
        // Someone else's host never drives this device's browser.
        #expect(automatic.connectOptions(askpass: true, guest: true).browser == false)
        // The launch configuration's `.disabled` (tests) still holds.
        #expect(automatic.clientRelay(base: .disabled) == .disabled)

        // Direct only: relays off whatever the ticket says; the CA still travels.
        let direct = RelaySettings(mode: .directOnly, customURL: "relay.example.com", authToken: "t", certificates: [der])
        #expect(direct.clientRelay() == .disabled)
        let options = direct.connectOptions(askpass: false)
        #expect(options.relayCaDer == [der])
        #expect(options.relayUrls.isEmpty)
        #expect(options.relayAuthToken == nil)

        // Custom: the device's relay and token replace the ticket's.
        let custom = RelaySettings(mode: .custom, customURL: "relay.example.com", authToken: " t0k3n ", certificates: [der])
        #expect(custom.clientRelay() == .default)
        #expect(custom.connectOptions(askpass: true) == ConnectOptions(
            relayCaDer: [der], relayUrls: ["https://relay.example.com"], relayAuthToken: "t0k3n", askpass: true, browser: true, programStatus: true, clipboard: true))
        // An invalid URL never reaches the core: the ticket decides.
        let broken = RelaySettings(mode: .custom, customURL: "not a url", authToken: "t")
        #expect(broken.connectOptions(askpass: true).relayUrls.isEmpty)
        #expect(broken.connectOptions(askpass: true).relayAuthToken == nil)
    }

    @Test func thePairingSheetSaysWhichRelayAHostUses() {
        let custom = TicketRelays.custom(urls: ["https://relay.home.arpa"], hasAuthToken: true)
        let automatic = RelaySettings()
        #expect(automatic.relay(for: .default) == ("Default", false))
        #expect(automatic.relay(for: .disabled) == ("None, direct only", false))
        #expect(automatic.relay(for: custom) == ("relay.home.arpa", false))
        let direct = RelaySettings(mode: .directOnly)
        #expect(direct.relay(for: .default) == ("None, direct only", true))
        #expect(direct.relay(for: .disabled) == ("None, direct only", false))
        let own = RelaySettings(mode: .custom, customURL: "relay.example.com")
        #expect(own.relay(for: custom) == ("relay.example.com", true))
        #expect(own.relay(for: .disabled) == ("None, direct only", false))
    }

    @Test func settingsPersistWithTheTokenInTheSecretStore() throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore()
        let der = try RelayCertificate.parse(Data(homelabCA.utf8))[0].der
        let model = HostsModel(secrets: secrets, repository: HostRepository(directory: directory))
        #expect(model.relaySettings == RelaySettings())

        let settings = RelaySettings(mode: .custom, customURL: "https://relay.example.com", authToken: "s3cret", certificates: [der])
        try model.setRelaySettings(settings)
        #expect(model.relaySettings == settings)
        let json = try String(contentsOf: directory.appending(path: RelaySettings.fileName), encoding: .utf8)
        #expect(json.contains("relay.example.com"))
        #expect(!json.contains("s3cret"), "the token is a secret")
        #expect(try secrets.string(for: RelaySettings.tokenKey) == "s3cret")

        // A new model (the next launch) reads them back, and dials with them.
        let reloaded = HostsModel(secrets: secrets, repository: HostRepository(directory: directory))
        #expect(reloaded.relaySettings == settings)
        #expect(reloaded.clientConfig(Data(count: 32)).relay == .default)

        try reloaded.setRelaySettings(RelaySettings(mode: .directOnly))
        #expect(reloaded.clientConfig(Data(count: 32)).relay == .disabled)
        #expect(try secrets.string(for: RelaySettings.tokenKey) == nil, "no token, nothing kept")
        #expect(HostsModel(secrets: secrets, repository: HostRepository(directory: directory)).relaySettings.mode == .directOnly)
    }
}
