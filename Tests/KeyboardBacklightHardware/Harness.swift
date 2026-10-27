import Foundation
import Darwin
@main struct Test {
 @MainActor static func main() {
  if KeyboardBacklightController.runIfRequested() { return }
  do {
   let hw = try KeyboardBacklightHardware()
   let before = hw.ids.map { ($0, hw.brightness($0), hw.automatic($0)) }
   print("BEFORE", before)
   let controller = KeyboardBacklightController()
   if let error = controller.turnOff() { fatalError(error) }
   print("OFF", hw.ids.map { (hw.brightness($0), hw.automatic($0)) })
   assert(hw.ids.allSatisfy { hw.brightness($0) <= 0.001 && !hw.automatic($0) })
   if CommandLine.arguments.contains("--crash") { fflush(stdout); kill(getpid(), SIGKILL) }
   assert(controller.keepOff() == nil)
   if let error = controller.restore() { fatalError(error) }
   print("RESTORED", hw.ids.map { (hw.brightness($0), hw.automatic($0)) })
   assert(before.allSatisfy { abs(hw.brightness($0.0) - $0.1) <= 0.01 && hw.automatic($0.0) == $0.2 })
   assert(!FileManager.default.fileExists(atPath: KeyboardBacklightController.journalURL.path))
  } catch { fatalError("\(error)") }
 }
}
