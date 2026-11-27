// Verificação do CalendarCompanion.installIfNeeded com pastas temporárias.
// Rodar com: scripts/checks/calendar-companion.sh
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
let ours = "com.diegofaccipieri.RelogioDuplo"

func app(_ dir: String, binary: String?, bundleID: String = ours) -> URL {
    let url = root.appendingPathComponent(dir).appendingPathComponent("RelogioDuplo.app")
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let binary else { return url }
    try! fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try! binary.write(to: url.appendingPathComponent("Contents/MacOS/RelogioDuplo"), atomically: true, encoding: .utf8)
    let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
    try! plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
    return url
}
func binary(_ u: URL) -> String {
    (try? String(contentsOf: u.appendingPathComponent("Contents/MacOS/RelogioDuplo"), encoding: .utf8)) ?? "<nada>"
}
func leftovers(_ u: URL) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)) ?? []).filter { $0 != "RelogioDuplo.app" }
}
var fails = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok    " : "FALHOU", name); if !ok { fails += 1 } }

let embedded = app("emb", binary: "v2")

let fresh = app("fresh", binary: nil)
var hooks = 0
check("instala quando ausente, sem chamar o fechamento",
      try! CalendarCompanion.installIfNeeded(embedded: embedded, installed: fresh, beforeReplace: { hooks += 1 })
      && binary(fresh) == "v2" && hooks == 0)
check("não reinstala quando igual",
      try! !CalendarCompanion.installIfNeeded(embedded: embedded, installed: fresh, beforeReplace: { hooks += 1 }) && hooks == 0)

let old = app("old", binary: "v1")
check("substitui quando o binário difere, fechando antes",
      try! CalendarCompanion.installIfNeeded(embedded: embedded, installed: old, beforeReplace: { hooks += 1 })
      && binary(old) == "v2" && hooks == 1)
check("não sobra pasta temporária", leftovers(old).isEmpty)

check("sem embutido não faz nada",
      try! !CalendarCompanion.installIfNeeded(embedded: root.appendingPathComponent("nada/RelogioDuplo.app"), installed: old)
      && binary(old) == "v2")

let foreign = app("foreign", binary: "outro app", bundleID: "com.exemplo.outro")
var threw = false
hooks = 0
do { _ = try CalendarCompanion.installIfNeeded(embedded: embedded, installed: foreign, beforeReplace: { hooks += 1 }) } catch { threw = true }
check("app de outra origem no mesmo caminho: recusa, não apaga, não fecha nada",
      threw && binary(foreign) == "outro app" && hooks == 0)

let locked = app("locked", binary: "v1")
try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.deletingLastPathComponent().path)
threw = false
do { _ = try CalendarCompanion.installIfNeeded(embedded: embedded, installed: locked) } catch { threw = true }
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.deletingLastPathComponent().path)
check("sem permissão de escrita: lança erro e mantém o instalado inteiro", threw && binary(locked) == "v1")

try? fm.removeItem(at: root)
exit(fails == 0 ? 0 : 1)
