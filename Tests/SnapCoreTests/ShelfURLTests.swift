import Foundation
import Testing
@testable import SnapCore

@MainActor
private final class FakeHandler: ShelfActionHandling {
    var performed: [ShelfAction] = []
    var opened: [String] = []
    func perform(_ action: ShelfAction) { performed.append(action) }
    func openItem(id: String) { opened.append(id) }
}

@MainActor
@Suite struct ShelfURLTests {
    private func parse(_ text: String) -> ShelfAction? {
        ShelfURL.parse(URL(string: text)!)
    }

    @Test func acceptsEveryAllowlistedAction() {
        for action in ShelfAction.allCases {
            #expect(parse("snap://\(action.rawValue)") == action)
        }
        #expect(parse("snap://capture-area/") == .captureArea)
        #expect(parse("SNAP://Capture-Area") == .captureArea)
    }

    @Test func advertisedActionsMatchTheAllowlist() {
        #expect(ShelfURL.advertisedActions == ["capture-area", "capture-window", "open-item", "check-for-updates"])
    }

    @Test func rejectsUnknownHostsAndOtherSchemes() {
        #expect(parse("snap://delete-everything") == nil)
        #expect(parse("snap://") == nil)
        #expect(parse("snap:capture-area") == nil)
        #expect(parse("other://capture-area") == nil)
        #expect(parse("https://capture-area") == nil)
        #expect(parse("file:///tmp/a") == nil)
    }

    @Test func rejectsParametersPathsAndAuthority() {
        #expect(parse("snap://capture-area?x=1") == nil)
        #expect(parse("snap://capture-area#x") == nil)
        #expect(parse("snap://capture-area/extra") == nil)
        #expect(parse("snap://user@capture-area") == nil)
        #expect(parse("snap://capture-area:80") == nil)
    }

    @Test func routerDispatchesAcceptedURLsToTheHandler() {
        let handler = FakeHandler()
        let router = ShelfRouter(handler: handler) { _ in }
        for action in ShelfAction.allCases {
            #expect(router.handle(URL(string: "snap://\(action.rawValue)")!))
        }
        #expect(handler.performed == ShelfAction.allCases)
    }

    @Test func routerIgnoresAndLogsRejectedURLsWithoutTheQuery() {
        let handler = FakeHandler()
        var lines: [String] = []
        let router = ShelfRouter(handler: handler) { lines.append($0) }
        #expect(!router.handle(URL(string: "snap://evil?secret=hunter2")!))
        #expect(!router.handle(URL(string: "snap://capture-area?secret=hunter2")!))
        #expect(handler.performed.isEmpty)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.contains("hunter2") && !$0.contains("secret") })
    }
}

@MainActor
@Suite struct ShelfOpenItemTests {
    private func request(_ text: String) -> ShelfRequest? {
        ShelfURL.request(URL(string: text)!)
    }

    @Test func parsesOpenItem() {
        #expect(request("snap://open-item?id=20261024-140322-3f9a1c2e") == .openItem(id: "20261024-140322-3f9a1c2e"))
        #expect(request("snap://capture-area") == .action(.captureArea))
    }

    @Test func ignoresUnknownParameters() {
        #expect(request("snap://open-item?id=abc-1&t=4&x=y") == .openItem(id: "abc-1"))
    }

    @Test func refusesBadOpenItemIDs() {
        #expect(request("snap://open-item") == nil)
        #expect(request("snap://open-item?id=") == nil)
        #expect(request("snap://open-item?id=../x") == nil)
        #expect(request("snap://open-item?id=\(String(repeating: "a", count: 65))") == nil)
        #expect(request("snap://open-item/extra?id=abc") == nil)
        #expect(request("snap://open-item?id=a%20b") == nil)
        #expect(request("snap://open-item?id=abc#frag") == nil)
    }

    @Test func plainActionsUnchanged() {
        #expect(request("snap://capture-area?x=1") == nil)
        #expect(ShelfURL.parse(URL(string: "snap://open-item?id=abc")!) == nil)
    }

    @Test func routerOpensItems() {
        let handler = FakeHandler()
        let router = ShelfRouter(handler: handler) { _ in }
        #expect(router.handle(URL(string: "snap://open-item?id=abc-1")!))
        #expect(handler.opened == ["abc-1"])
        #expect(handler.performed.isEmpty)
    }
}
