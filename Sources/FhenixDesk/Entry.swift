import AppKit
import DeskCore
import Foundation

@main
enum Entry {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--doctor") {
            setvbuf(stdout, nil, _IOLBF, 0)
            await Doctor.run()
            return
        }
        FhenixDeskApp.main()
    }
}
