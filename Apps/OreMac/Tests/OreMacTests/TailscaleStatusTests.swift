import Foundation
import Testing

@testable import OreMac

struct TailscaleStatusTests {
    @Test func parseRunningStatusPrefersMagicDNS() throws {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "kailash.tailnet-name.ts.net.",
            "TailscaleIPs": ["100.64.1.20", "fd7a:115c:a1e0::1"]
          },
          "CurrentTailnet": {
            "Name": "example.com",
            "MagicDNSEnabled": true
          }
        }
        """
        let kind = try #require(TailscaleStatus.parse(Data(json.utf8)))
        guard case .connected(let ipv4, let dns, let tailnet) = kind else {
            Issue.record("expected connected")
            return
        }
        #expect(ipv4 == "100.64.1.20")
        #expect(dns == "kailash.tailnet-name.ts.net")
        #expect(tailnet == "example.com")
    }

    @Test func parseNeedsLogin() throws {
        let kind = try #require(TailscaleStatus.parse(Data(#"{ "BackendState": "NeedsLogin" }"#.utf8)))
        #expect(kind == .needsLogin)
    }

    @Test func parseStoppedWithoutIPv4() throws {
        let json = #"{ "BackendState": "Running", "Self": { "TailscaleIPs": ["fd7a:115c:a1e0::1"] } }"#
        let kind = try #require(TailscaleStatus.parse(Data(json.utf8)))
        #expect(kind == .stopped)
    }

    @Test func dnsNameDropsTrailingDot() {
        #expect(TailscaleStatus.sanitizedDNS("mac.tailnet.ts.net.") == "mac.tailnet.ts.net")
        #expect(TailscaleStatus.sanitizedDNS(" ") == nil)
    }
}
