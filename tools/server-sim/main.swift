import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var failures = 0, passes = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("  ok   \(name)") } else { failures += 1; print("  FAIL \(name) \(detail())") }
}
struct Fixtures: Decodable {
    struct P: Decodable { var localID: String; var sha1: String; var date: String; var isImage: Bool }
    struct S: Decodable { var id: String; var sha1: String; var fileCreatedAt: String; var isImage: Bool; var isTrashed: Bool }
    var phone: [P]; var server: [S]; var truth: [String: String?]
}
let port = CommandLine.arguments.dropFirst().first ?? "18283"
let client = ImmichClient(server: URL(string: "http://127.0.0.1:\(port)")!, token: "good")
let fx = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: "fixtures.json")))

print("Dates")
for s in fx.server { check(Date(immich: s.fileCreatedAt) != nil, "parses \(s.fileCreatedAt)") }

print("Server errors (what the user reads, what the log gets)")
func logText() -> String {
    Thread.sleep(forTimeInterval: 0.3)
    return (try? String(contentsOf: FileLog.shared.fileURL, encoding: .utf8)) ?? ""
}
try? FileManager.default.removeItem(at: FileLog.shared.fileURL)
do { _ = try await URLSession.shared.data(for: client.request("/assets/local:ABC/L0/001/thumbnail")) } catch {}
do {
    let (data, response) = try await URLSession.shared.data(for: client.request("/assets/\(fx.server[0].id)/thumbnail"))
    check((response as? HTTPURLResponse)?.statusCode == 200 && data.count == 3, "thumbnail of a real asset is 200")
    let (d2, r2) = try await URLSession.shared.data(for: client.request("/assets/000003e7-0000-4000-8000-0000000003e7/thumbnail"))
    do { try ImmichClient.check(r2, d2); check(false, "missing thumbnail throws") } catch let e as ImmichError {
        check(e.localizedDescription == "The server doesn't have that item any more.", "missing thumbnail says so, not 'No Immich server'", e.localizedDescription)
    }
    let (d3, r3) = try await URLSession.shared.data(for: client.request("/nothing"))
    do { try ImmichClient.check(r3, d3) } catch let e as ImmichError {
        check(e.localizedDescription.hasPrefix("No Immich server"), "a wrong path still says wrong address", e.localizedDescription)
    }
    let (d4, r4) = try await URLSession.shared.data(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/proxy-html-404")!))
    do { try ImmichClient.check(r4, d4) } catch let e as ImmichError {
        check(e.localizedDescription.hasPrefix("No Immich server"), "an HTML 404 from a proxy says wrong address", e.localizedDescription)
    }
    let (d5, r5) = try await URLSession.shared.data(for: ImmichClient(server: client.server, token: "bad").request("/assets/x/thumbnail"))
    do { try ImmichClient.check(r5, d5) } catch let e as ImmichError { check(e.localizedDescription.hasPrefix("Wrong email"), "401 says session expired", e.localizedDescription) }
    let (d6, r6) = try await URLSession.shared.data(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/boom")!))
    do { try ImmichClient.check(r6, d6) } catch let e as ImmichError { check(e.localizedDescription.hasPrefix("The server answered 500"), "500 shows the code", e.localizedDescription) }
    do { let _: [String: String] = try await client.fetch("GET", "/garbage"); check(false, "garbage throws") } catch { check(error is DecodingError, "unreadable answer is a decoding error") }
}
// explanation: logs real failures, not cancellations
check(URLError(.cancelled).explanation == "" && CancellationError().explanation == "", "a cancellation has no message for an alert")
_ = CancellationError().explanation
check(!logText().contains("cancelled"), "a cancelled request is not logged")
_ = URLError(.cannotConnectToHost).explanation
check(logText().contains("[ERROR]"), "a real failure is logged")
let dead = ImmichClient(server: URL(string: "http://127.0.0.1:1")!, token: "good")
do { let _: [String: String] = try await dead.fetch("GET", "/server/ping"); check(false, "dead server throws") }
catch { check(error.explanation.hasPrefix("Nothing answers"), "connection refused explains the port", error.explanation) }

print("Merging, by capture time only (the fallback)")
func ref(_ p: Fixtures.P) -> AssetRef { AssetRef(id: "local:" + p.localID, isImage: p.isImage, date: Date(immich: p.date), localID: p.localID) }
let serverRefs = fx.server.map { AssetRef(id: $0.id, isImage: $0.isImage, date: Date(immich: $0.fileCreatedAt)) }
let timeResult = Matching.separate(fx.phone.map(ref), from: serverRefs)
func expectTime(_ name: String, matched: Bool) {
    let lid = "PH-\(name)/L0/001"
    check(timeResult.same.contains(lid) == matched, "\(name): \(matched ? "merged" : "kept separate")")
}
for n in ["same", "pgfmt", "spacefmt", "nozone", "subsecond", "edited", "bursta", "burstb"] { expectTime(n, matched: true) }
for n in ["tzshift", "phoneonly", "burstc", "photo-same-second-as-video"] { expectTime(n, matched: false) }
// "trashed" has a server copy at the same second, so by time alone it merges (the checksum pass knows better)
expectTime("trashed", matched: true)
check(timeResult.only.count + timeResult.same.count == fx.phone.count, "every phone photo is either merged or kept")
check(timeResult.serverIDs.count == timeResult.same.count, "one server photo per merged phone photo")

print("Merging, by checksum against the server")
var found: [String: String] = [:], checkedIDs: [String] = []
for start in stride(from: 0, to: fx.phone.count, by: 5) {
    let entries = fx.phone[start..<min(start + 5, fx.phone.count)].map { ["id": $0.localID, "checksum": $0.sha1] }
    struct Reply: Decodable { var results: [Matching.Check] }
    let reply: Reply = try await client.fetch("POST", "/assets/bulk-upload-check", body: ["assets": entries])
    let answer = Matching.duplicates(in: reply.results)
    checkedIDs += answer.checked; found.merge(answer.found) { $1 }
}
check(checkedIDs.count == fx.phone.count, "every photo got an answer")
for p in fx.phone {
    let expected = fx.truth[p.localID] ?? nil
    check(found[p.localID] == expected, "\(p.localID.dropFirst(3).dropLast(5)): \(expected == nil ? "not matched" : "matched to the right server photo")", "got \(String(describing: found[p.localID]))")
}

print("Uploads and the duplicate check on upload")
let tmp = FileManager.default.temporaryDirectory.appending(path: "up-test.heic")
try Data("new-photo".utf8).write(to: tmp)
let id = try await client.upload(tmp, fields: ["deviceAssetId": "PH-new/L0/001", "fileCreatedAt": "2026-05-10T10:20:30Z", "fileModifiedAt": "2026-05-10T10:20:30Z"])
check(id.count == 36, "upload returns the new asset id", id)
do { _ = try await ImmichClient(server: client.server, token: "bad").upload(tmp, fields: [:]); check(false, "bad token upload throws") }
catch let e as ImmichError { check(e.localizedDescription.hasPrefix("Wrong email"), "upload with an expired session says so", e.localizedDescription) }

print("Month bookkeeping through a day of changes (the Library's reload rule)")
do {
    // one month: 5 photos on the server; the iPhone has a, b, c not backed up; a looks like a server photo by time
    var pending: Set<String> = ["a", "b", "c"], dups: Set<String> = []
    var shown: Set<String>? = nil          // nil: month not loaded
    var cells = Matching.cellCount(server: 5, pending: pending, duplicates: dups)
    check(cells == 8, "before loading, the placeholder counts every iPhone photo", "\(cells)")
    func load() { let sep: Set<String> = pending.contains("a") ? ["a"] : []; dups = sep; shown = pending.subtracting(sep); cells = 5 + shown!.count }
    load()
    check(cells == Matching.cellCount(server: 5, pending: pending, duplicates: dups), "after loading, the cell count equals what a reload expects", "\(cells)")
    check(!Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "an unchanged month is not reloaded")
    pending.remove("b")   // the checksum check found b on the server
    check(Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "a photo found by checksum makes the month stale")
    check(Matching.cellCount(server: 5, pending: pending, duplicates: dups) == 6, "the stale month's new count is right")
    load()
    check(cells == 6 && !Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "after the reload it is settled again", "\(cells)")
    pending.remove("a")   // a was matched by checksum too: its time-guess is now stale
    check(!Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "a time-guess later confirmed by checksum changes nothing on screen")
    check(Matching.cellCount(server: 5, pending: pending, duplicates: dups) == cells, "and the cell count still agrees: 5 server + c", "\(cells)")
    pending.insert("d")   // a new photo on the iPhone
    check(Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "a new iPhone photo makes the month stale")
    pending = []          // backup uploaded everything
    check(Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "after a backup the month is reloaded")
    load()
    check(cells == 5 && !Matching.isStale(shown: shown!, duplicates: dups, pending: pending), "back to the server's 5")
}

print("Share extension upload: integrity, big files, odd names, failures")
let big = FileManager.default.temporaryDirectory.appending(path: "big photo (1) ü.mov")
var blob = Data(count: 40 << 20); for i in stride(from: 0, to: blob.count, by: 4096) { blob[i] = UInt8(i / 4096 % 251) }
try blob.write(to: big)
_ = try await client.upload(big, fields: ["deviceAssetId": "PH-big", "fileCreatedAt": "2026-05-10T10:20:30Z", "fileModifiedAt": "2026-05-10T10:20:30Z"])
let (upData, _) = try await URLSession.shared.data(for: client.request("/_uploads"))
let uploads = try JSONSerialization.jsonObject(with: upData) as! [[String: Any]]
let last = uploads.last!
check(last["_size"] as? Int == 40 << 20, "a 40 MB file arrives whole", "\(String(describing: last["_size"]))")
check(last["deviceAssetId"] as? String == "PH-big" && last["_filename"] as? String == "big photo (1) ü.mov", "fields and a file name with spaces and accents arrive", "\(last)")
check(last["deviceId"] as? String == "WoofPhoto", "the device id is sent")
check(last["_sha1"] as? String == { var h = ""; let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sha1sum"); p.arguments = [big.path]; let o = Pipe(); p.standardOutput = o; try! p.run(); p.waitUntilExit(); h = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""; return h }(), "the file's SHA-1 on the server equals the original's")
check(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appending(path: "upload-x").path) && ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("upload-") }.isEmpty ?? true), "the temporary form file is removed after an upload")

print("Connection failures")
var slow = client.request("/slow"); slow.timeoutInterval = 1
do { _ = try await URLSession.shared.data(for: slow); check(false, "slow server times out") }
catch { check((error as? URLError)?.code == .timedOut && error.explanation.contains("didn't answer in time"), "a timeout mentions the VPN", error.explanation) }
do { _ = try await URLSession.shared.data(from: URL(string: "http://no-such-host.invalid:2283/api/server/ping")!); check(false, "unknown host throws") }
catch { check(error.explanation.contains("name was not found"), "an unknown host says to check the spelling", error.explanation) }
let task = Task { try await URLSession.shared.data(for: slow.url.map { URLRequest(url: $0) }!) }
try? await Task.sleep(for: .milliseconds(100)); task.cancel()
do { _ = try await task.value } catch { _ = error.explanation }
check(!logText().contains("cancelled"), "cancelling a request in flight (scrolling away) is not logged")

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
