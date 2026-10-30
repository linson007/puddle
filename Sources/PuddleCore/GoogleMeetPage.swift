import Foundation

public struct GoogleMeetPageState: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case prejoin, joining, waiting, joined, signIn, ended, unsupported }
    public let stage: Stage
    public let clickedJoin: Bool
    public init(stage: Stage, clickedJoin: Bool = false) { self.stage = stage; self.clickedJoin = clickedJoin }
}

public enum GoogleMeetPage {
    /// Only fixed UI rules run. Meeting text never becomes executable instructions.
    public static func script(join: Bool, guestName: String) throws -> String {
        let data = try ChromeJSON.data(["join": join, "guestName": String(guestName.prefix(60))])
        let configuration = String(decoding: data, as: UTF8.self)
        return """
        (() => {
          const config = \(configuration);
          const result = (stage, clickedJoin = false) => JSON.stringify({stage, clickedJoin});
          if (location.hostname === 'accounts.google.com') return result('signIn');
          if (location.protocol !== 'https:' || location.hostname !== 'meet.google.com') return result('unsupported');
          const visible = element => element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden';
          const buttons = [...document.querySelectorAll('button, [role="button"]')].filter(visible);
          const label = element => (element.getAttribute('aria-label') || element.textContent || '').replace(/\\s+/g, ' ').trim();
          const enabled = element => !element.disabled && element.getAttribute('aria-disabled') !== 'true';
          if (buttons.some(element => /^(leave call|hang up)(\\b|$)/i.test(label(element)))) return result('joined');
          const body = (document.body?.innerText || '').slice(0, 60000).replace(/\\s+/g, ' ');
          if (/(you left the meeting|you've left the meeting|you were removed|you can't join this (call|meeting)|meeting (has )?ended|no one responded|request to join was denied)/i.test(body)) return result('ended');
          if (/(asking to join|someone (will|needs to) let you in|you'll join.*lets you in|waiting for.*(admit|join))/i.test(body)) return result('waiting');
          const withoutMedia = buttons.find(element => enabled(element) && /^continue without (microphone|camera|microphone and camera|camera and microphone)$/i.test(label(element)));
          if (withoutMedia) {
            if (config.join) withoutMedia.click();
            return result('joining');
          }
          const joinButton = buttons.find(element => enabled(element) && /^(join now|ask to join|join meeting)$/i.test(label(element)));
          const nameInput = [...document.querySelectorAll('input')].find(element => visible(element) && /^(your name|name)$/i.test(element.getAttribute('aria-label') || element.getAttribute('placeholder') || ''));
          if (joinButton || nameInput) {
            if (config.join) {
              if (nameInput && !nameInput.value.trim()) {
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(nameInput, config.guestName);
                nameInput.dispatchEvent(new Event('input', {bubbles: true}));
                nameInput.dispatchEvent(new Event('change', {bubbles: true}));
              }
              if (joinButton && enabled(joinButton)) { joinButton.click(); return result('joining', true); }
            }
            return result('prejoin');
          }
          if (/sign in to (join|continue)/i.test(body)) return result('signIn');
          return result('unsupported');
        })()
        """
    }
}

public actor GoogleMeetBrowserSession {
    private let connection: any ChromeCommanding
    private var targetID: String?
    private var sessionID: String?
    private var opened = false
    private var pendingTarget: Task<String, Error>?
    private var cleanup: Task<Bool, Never>?
    public var hasOwnedTarget: Bool { targetID != nil }
    public init(connection: any ChromeCommanding) { self.connection = connection }
    public func open(link: MeetingJoinLink) async throws {
        guard link.provider == .googleMeet else { throw PuddleError("The attendance assistant supports Google Meet links only.") }
        var parts = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
        var query = parts.queryItems ?? []; query.removeAll { $0.name == "hl" }; query.append(URLQueryItem(name: "hl", value: "en")); parts.queryItems = query
        try await openPage(url: parts.url!)
    }
    /// Exercises the actual browser/session commands on a blank page without joining a call.
    public func checkConnection() async throws -> String {
        let version = try await command("Browser.getVersion", [:])
        try await openPage(url: URL(string: "about:blank")!)
        let evaluation = try await command("Runtime.evaluate", ["expression": "6 * 7", "returnByValue": true, "awaitPromise": true, "userGesture": false], page: true)
        guard evaluation["exceptionDetails"] == nil, let value = evaluation["result"] as? [String: Any], value["value"] as? Int == 42 else {
            throw PuddleError("Chrome could not evaluate the blank test page. No meeting was opened.")
        }
        return String((version["product"] as? String ?? "Chrome").prefix(100))
    }
    private func openPage(url: URL) async throws {
        guard !opened, cleanup == nil else { throw PuddleError("This Meet browser session has already ended or opened a tab. Start a new session.") }
        opened = true
        let existing = try await command("Target.getTargets", [:])
        let targets = existing["targetInfos"] as? [[String: Any]] ?? []
        guard !targets.contains(where: { ($0["type"] as? String) == "page" && URL(string: $0["url"] as? String ?? "")?.host == "meet.google.com" }) else {
            throw PuddleError("A Meet tab is already open in Puddle's dedicated browser. Finish or close that tab before starting another attendance session.")
        }
        for name in ["microphone", "camera"] {
            _ = try await command("Browser.setPermission", ["permission": ["name": name], "setting": "denied", "origin": "https://meet.google.com"])
        }
        // Finish identifying a dispatched creation even if attendance is cancelled.
        // Otherwise cleanup can race the reply and leave a newly created tab behind.
        try Task.checkCancellation()
        let connection = connection
        let creation = Task.detached { () throws -> String in
            let result = try await connection.command("Target.createTarget", parameters: ChromeJSON.data(["url": "about:blank", "newWindow": true]), sessionID: nil)
            let target = try ChromeJSON.object(result)
            guard let id = target["targetId"] as? String, !id.isEmpty else { throw PuddleError("Chrome did not identify the new Meet tab. Check its dedicated window.") }
            return id
        }
        pendingTarget = creation
        let id = try await creation.value
        guard cleanup == nil else { throw CancellationError() }
        targetID = id
        let attached = try await command("Target.attachToTarget", ["targetId": id, "flatten": true])
        guard let session = attached["sessionId"] as? String else { throw PuddleError("Chrome could not attach to the dedicated Meet tab.") }
        sessionID = session
        let navigation = try await command("Page.navigate", ["url": url.absoluteString], page: true)
        if let error = navigation["errorText"] as? String, !error.isEmpty {
            throw PuddleError("Chrome could not open the Meet page: \(String(error.prefix(160))). Check the dedicated browser window.")
        }
    }
    public func inspect(join: Bool, guestName: String) async throws -> GoogleMeetPageState {
        guard sessionID != nil else { throw PuddleError("Open a Meet session first.") }
        let result = try await command("Runtime.evaluate", ["expression": GoogleMeetPage.script(join: join, guestName: guestName),
            "returnByValue": true, "awaitPromise": true, "userGesture": join], page: true)
        guard result["exceptionDetails"] == nil, let remote = result["result"] as? [String: Any],
              let value = remote["value"] as? String, value.utf8.count <= 4096 else { throw PuddleError("The Meet page changed. Continue joining in its browser window.") }
        return try JSONDecoder().decode(GoogleMeetPageState.self, from: Data(value.utf8))
    }
    public func leave() async -> Bool {
        if let cleanup { return await cleanup.value }
        let knownID = targetID, creation = pendingTarget
        sessionID = nil
        let connection = connection
        let cleanup = Task.detached { () -> Bool in
            let id: String?
            if let knownID { id = knownID }
            else if let creation {
                do { id = try await creation.value }
                catch { await connection.close(); return false } // A dispatched creation may have succeeded without a reply.
            } else { await connection.close(); return true }
            guard let id else { await connection.close(); return false }
            // closeTarget's deprecated success field is not proof of the current state.
            // A tab the user already closed can also make closeTarget return an error.
            if let parameters = try? ChromeJSON.data(["targetId": id]) {
                _ = try? await connection.command("Target.closeTarget", parameters: parameters, sessionID: nil)
            }
            var verified = false
            for attempt in 0..<5 {
                do {
                    let result = try await connection.command("Target.getTargets", parameters: Data("{}".utf8), sessionID: nil)
                    let response = try ChromeJSON.object(result)
                    guard let targets = response["targetInfos"] as? [[String: Any]],
                          targets.allSatisfy({ ($0["targetId"] as? String)?.isEmpty == false }) else { break }
                    if !targets.contains(where: { $0["targetId"] as? String == id }) { verified = true; break }
                } catch { break }
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(100)) }
            }
            await connection.close(); return verified
        }
        self.cleanup = cleanup
        let verified = await cleanup.value
        if verified { targetID = nil }
        return verified
    }
    public func release() async { await connection.close() }
    private func command(_ method: String, _ parameters: [String: Any], page: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard cleanup == nil else { throw CancellationError() }
        return try ChromeJSON.object(await connection.command(method, parameters: ChromeJSON.data(parameters), sessionID: page ? sessionID : nil))
    }
}
