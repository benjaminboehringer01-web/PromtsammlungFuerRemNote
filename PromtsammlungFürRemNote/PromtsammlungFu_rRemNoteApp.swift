import SwiftUI

@main
struct PromptManagerApp: App {
    @StateObject var cardServer = CardServer.shared
    
    var body: some Scene {
        WindowGroup {
            MainView(cardServer: cardServer)
        }
    }
}


