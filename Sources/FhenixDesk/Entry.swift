import AppKit
import DeskCore
import Foundation

@main
enum Entry {
    static func main() async {
        // A child that exits before reading all its stdin would otherwise kill the app with SIGPIPE; ignored, the
        // write fails with EPIPE instead and the command's own result says what happened.
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.contains("--doctor") {
            setvbuf(stdout, nil, _IOLBF, 0)
            await Doctor.run()
            return
        }
        #if DEBUG
        if let index = arguments.firstIndex(of: "--snapshot") {
            Snapshot.start(Array(arguments.dropFirst(index + 1)))
            return
        }
        #endif
        FhenixDeskApp.main()
    }
}
