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
        // `--review <pr-url>` does what the Review button does, from a terminal. Useful for scripts and for
        // checking a review end to end without the window.
        if let index = arguments.firstIndex(of: "--review"), index + 1 < arguments.count {
            setvbuf(stdout, nil, _IOLBF, 0)
            await Doctor.review(url: arguments[index + 1])
            return
        }
        FhenixDeskApp.main()
    }
}
