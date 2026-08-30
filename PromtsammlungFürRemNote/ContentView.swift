import SwiftUI
import Network
import Combine

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Design Theme & Styling
struct AppTheme {
    static let primaryAccent = Color.indigo
    static let secondaryAccent = Color.purple
    static let liveAccent = Color.green
    
    static let cardBackground = Color.primary.opacity(0.03)
    static let cardBorder = Color.primary.opacity(0.08)
    static let shadowColor = Color.black.opacity(0.05)
    
    static let gradientAccent = LinearGradient(
        colors: [Color.indigo, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - 1. Datenmodelle

struct Prompt: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var category: String
    var icon: String
    var needsImage: Bool
    var isExpanded: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, title, text, category, icon, needsImage, isExpanded
    }
    
    init(id: UUID = UUID(), title: String, text: String, category: String, icon: String, needsImage: Bool, isExpanded: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.category = category
        self.icon = icon
        self.needsImage = needsImage
        self.isExpanded = isExpanded
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        category = try container.decode(String.self, forKey: .category)
        icon = try container.decode(String.self, forKey: .icon)
        needsImage = try container.decode(Bool.self, forKey: .needsImage)
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
    }
}

struct Category: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let icon: String
}

struct PlaceholderData: Identifiable {
    let id = UUID()
    let text: String
    let placeholders: [String]
}

struct IncomingCard: Codable, Identifiable, Equatable {
    var id: String { cardId.isEmpty ? UUID().uuidString : cardId }
    let cardId: String
    let remId: String
    let front: String
    let back: String
    let path: String
    let images: [String]
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case cardId, remId, front, back, path, images, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId) ?? ""
        remId = try container.decodeIfPresent(String.self, forKey: .remId) ?? ""
        front = try container.decodeIfPresent(String.self, forKey: .front) ?? ""
        back = try container.decodeIfPresent(String.self, forKey: .back) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
    }

    init(cardId: String, remId: String, front: String, back: String, path: String = "", images: [String] = [], timestamp: Double) {
        self.cardId = cardId
        self.remId = remId
        self.front = front
        self.back = back
        self.path = path
        self.images = images
        self.timestamp = timestamp
    }
}

// MARK: - 2. Lokaler HTTP-Server (Port 8000)

@MainActor
class CardServer: ObservableObject {
    static let shared = CardServer()
    
    @Published var lastCard: IncomingCard?
    private var listener: NWListener?
    private var isStarted = false
    
    init(port: UInt16 = 8000) {
        start(port: port)
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isStarted = false
    }
    
    func start(port: UInt16) {
        guard !isStarted else { return }
        stop()
        
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch newState {
                    case .ready:
                        self.isStarted = true
                        print("🟢 [CardServer SUCCESS] Server ist BEREIT auf Port \(port)!")
                    case .failed(let error):
                        print("🔴 [CardServer ERROR] Server FEHLGESCHLAGEN auf Port \(port): \(error)")
                        self.isStarted = false
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            self.start(port: port)
                        }
                    default:
                        break
                    }
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }
            
            listener.start(queue: .main)
        } catch {
            print("🔴 [CardServer] Fehler beim Starten: \(error)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        
        func receiveData(accumulatedData: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 10_485_760) { [weak self] chunk, _, isComplete, error in
                guard let self = self else { return }
                
                var currentData = accumulatedData
                if let chunk = chunk { currentData.append(chunk) }
                
                guard let requestString = String(data: currentData, encoding: .utf8) else {
                    if !isComplete && error == nil {
                        receiveData(accumulatedData: currentData)
                    } else {
                        connection.cancel()
                    }
                    return
                }
                
                if requestString.hasPrefix("OPTIONS") {
                    self.sendResponse(connection: connection, status: "204 No Content", body: "")
                    return
                }
                
                if requestString.contains("\r\n\r\n") {
                    let parts = requestString.components(separatedBy: "\r\n\r\n")
                    let headerPart = parts[0]
                    let bodyPart = parts[1...].joined(separator: "\r\n\r\n")
                    
                    var contentLength = 0
                    for line in headerPart.components(separatedBy: "\r\n") {
                        if line.lowercased().hasPrefix("content-length:") {
                            let val = line.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                            contentLength = Int(val) ?? 0
                        }
                    }
                    
                    if bodyPart.utf8.count >= contentLength {
                        if let jsonData = bodyPart.data(using: .utf8) {
                            do {
                                let card = try JSONDecoder().decode(IncomingCard.self, from: jsonData)
                                Task { @MainActor in self.lastCard = card }
                                self.sendResponse(connection: connection, status: "200 OK", body: "{\"status\":\"ok\"}")
                            } catch {
                                self.sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"invalid json\"}")
                            }
                        }
                        return
                    }
                }
                
                if !isComplete && error == nil {
                    receiveData(accumulatedData: currentData)
                } else {
                    connection.cancel()
                }
            }
        }
        receiveData()
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\n" +
        "Content-Type: application/json\r\n" +
        "Access-Control-Allow-Origin: *\r\n" +
        "Access-Control-Allow-Methods: POST, OPTIONS\r\n" +
        "Access-Control-Allow-Headers: Content-Type\r\n" +
        "Access-Control-Allow-Private-Network: true\r\n" +
        "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed({ _ in connection.cancel() }))
        } else {
            connection.cancel()
        }
    }
    
    deinit { listener?.cancel() }
}

// MARK: - 3. Platzhalter Helfer-Logik

struct PlaceholderHelper {
    static func replaceFlashcardShorthand(in text: String, with card: IncomingCard?) -> String {
        var result = text
        
        guard let card = card else {
            let replacements = [
                ("/Flashcard/", "(Keine RemNote Karte geladen)"),
                ("/Karte/", "(Keine RemNote Karte geladen)"),
                ("/Pfad/", "(Kein Pfad)"),
                ("/Path/", "(Kein Pfad)"),
                ("/Vorderseite/", "(Keine Vorderseite)"),
                ("/Front/", "(Keine Vorderseite)"),
                ("/Rückseite/", "(Keine Rückseite)"),
                ("/Back/", "(Keine Rückseite)"),
                ("/Liste/", "(Keine Liste geladen)"),
                ("/List/", "(Keine Liste geladen)")
            ]
            for (target, value) in replacements {
                result = result.replacingOccurrences(of: target, with: value, options: .caseInsensitive)
            }
            return result
        }
        
        let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = card.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !card.images.isEmpty
        
        var components: [String] = []
        if !path.isEmpty { components.append("Pfad: \(path)") }
        if !front.isEmpty { components.append("Vorderseite: \(front)") }
        if !back.isEmpty { components.append("Rückseite:\n\(back)") }
        else if hasImages { components.append("Rückseite:") }

        let fullFlashcardText = components.isEmpty ? "(Keine RemNote Karte geladen)" : components.joined(separator: "\n\n")
        let listText = back.isEmpty ? front : back
        let imageNotice = hasImages ? (card.images.count == 1 ? "[Angehängtes PNG-Bild]" : "[\(card.images.count) angehängte PNG-Bilder]") : "(Kein Bild)"
        
        let replacements = [
            ("/Flashcard/", fullFlashcardText),
            ("/Karte/", fullFlashcardText),
            ("/Pfad/", path.isEmpty ? "(Kein Pfad)" : path),
            ("/Path/", path.isEmpty ? "(Kein Pfad)" : path),
            ("/Vorderseite/", front.isEmpty ? "(Keine Vorderseite)" : front),
            ("/Front/", front.isEmpty ? "(Keine Vorderseite)" : front),
            ("/Rückseite/", back.isEmpty ? "(Keine Rückseite)" : back),
            ("/Back/", back.isEmpty ? "(Keine Rückseite)" : back),
            ("/Liste/", listText.isEmpty ? "(Keine Liste)" : listText),
            ("/List/", listText.isEmpty ? "(Keine Liste)" : listText),
            ("/Bild/", imageNotice),
            ("/Bilder/", imageNotice),
            ("/Image/", imageNotice),
            ("/Images/", imageNotice)
        ]
        
        for (target, value) in replacements {
            result = result.replacingOccurrences(of: target, with: value, options: .caseInsensitive)
        }
        
        return result
    }
    
    static func extractPlaceholders(from text: String) -> [String] {
        let regex = #/\{([^}]+)\}/#
        var placeholders: [String] = []
        for match in text.matches(of: regex) {
            let name = String(match.1)
            if !placeholders.contains(name) { placeholders.append(name) }
        }
        return placeholders
    }
    
    static func fillPlaceholders(in text: String, with values: [String: String]) -> String {
        var result = text
        for (key, val) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: val)
        }
        return result
    }
}

// MARK: - 4. Daten-Manager (Persistence)

@MainActor
class PromptStore: ObservableObject {
    @Published var categories: [Category] = []
    @Published var prompts: [Prompt] = []
    
    private let categoriesKey = "saved_categories"
    private let promptsKey = "saved_prompts"
    
    init() {
        load()
        var needsInitialSave = false
        
        if categories.isEmpty {
            categories = [
                Category(name: "Kreuzen", icon: "folder"),
                Category(name: "Karteikarten", icon: "archivebox"),
                Category(name: "Listen & Reihenfolge", icon: "list.number"),
                Category(name: "Text extrahieren", icon: "doc.text.magnifyingglass"),
                Category(name: "Übersetzen", icon: "character.book.closed"),
                Category(name: "Formatierung (OCR)", icon: "sparkles"),
                Category(name: "VL-Folien", icon: "rectangle.on.rectangle.angled"),
                Category(name: "Praktikum", icon: "cross.case")
            ]
            needsInitialSave = true
        }
        
        if prompts.isEmpty {
            prompts = [
                Prompt(title: "Erklären lassen", text: "Erkläre mir das Thema aus der Karteikarte einfach:\n\n/Karte/", category: "Karteikarten", icon: "doc.text", needsImage: false, isExpanded: false),
                Prompt(title: "Liste erklären & Eselsbrücke", text: "Erstelle mir für folgende Liste eine merkfähige Eselsbrücke (Mnemonic) und erkläre die einzelnen Schritte kurz:\n\n/Karte/", category: "Listen & Reihenfolge", icon: "list.number", needsImage: false, isExpanded: true),
                Prompt(title: "VL-Folie erklären lassen", text: "Erkläre diese Folie verständlich:\n\n/Karte/", category: "VL-Folien", icon: "doc.text", needsImage: true, isExpanded: false),
                Prompt(title: "Fragen erklären lassen", text: "Erkläre warum diese Antwort richtig ist:\n\n/Karte/", category: "Kreuzen", icon: "doc.text", needsImage: false, isExpanded: false),
                Prompt(title: "Text aus VL-Folie", text: "Extrahiere folgenden Text aus der Folie:\n\n/Karte/", category: "Text extrahieren", icon: "doc.text", needsImage: true, isExpanded: false)
            ]
            needsInitialSave = true
        }
        
        if needsInitialSave { save() }
    }
    
    func addPrompt(_ prompt: Prompt) { prompts.append(prompt); save() }
    func removePrompt(id: UUID) { prompts.removeAll(where: { $0.id == id }); save() }
    
    func renamePrompt(id: UUID, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].title = trimmed
            save()
        }
    }
    
    func updatePrompt(id: UUID, newText: String) {
        if let index = prompts.firstIndex(where: { $0.id == id }), prompts[index].text != newText {
            prompts[index].text = newText
            save()
        }
    }
    
    func toggleExpansion(id: UUID) {
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].isExpanded.toggle()
            save()
        }
    }

    func expandPrompt(id: UUID) {
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].isExpanded = true
            save()
        }
    }
    
    func movePromptUp(id: UUID) {
        guard let currentIndex = prompts.firstIndex(where: { $0.id == id }) else { return }
        let category = prompts[currentIndex].category
        if let swapIndex = (0..<currentIndex).reversed().first(where: { prompts[$0].category == category }) {
            prompts.swapAt(currentIndex, swapIndex)
            save()
        }
    }
    
    func movePromptDown(id: UUID) {
        guard let currentIndex = prompts.firstIndex(where: { $0.id == id }) else { return }
        let category = prompts[currentIndex].category
        if let swapIndex = ((currentIndex + 1)..<prompts.count).first(where: { prompts[$0].category == category }) {
            prompts.swapAt(currentIndex, swapIndex)
            save()
        }
    }
    
    func addCategory(name: String, icon: String) {
        if !categories.contains(where: { $0.name == name }) {
            categories.append(Category(name: name, icon: icon))
            save()
        }
    }
    
    @discardableResult
    func renameCategory(oldCategory: Category, newName: String, newIcon: String) -> Category {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return oldCategory }
        let updatedCategory = Category(name: trimmedName, icon: newIcon)
        
        if let index = categories.firstIndex(where: { $0.id == oldCategory.id }) {
            categories[index] = updatedCategory
        }
        for index in prompts.indices {
            if prompts[index].category == oldCategory.name {
                prompts[index].category = trimmedName
            }
        }
        save()
        return updatedCategory
    }
    
    func removeCategory(_ category: Category) {
        categories.removeAll(where: { $0.id == category.id })
        prompts.removeAll(where: { $0.category == category.name })
        save()
    }
    
    func moveCategoryUp(_ category: Category) {
        guard let currentIndex = categories.firstIndex(where: { $0.id == category.id }), currentIndex > 0 else { return }
        categories.swapAt(currentIndex, currentIndex - 1)
        save()
    }
    
    func moveCategoryDown(_ category: Category) {
        guard let currentIndex = categories.firstIndex(where: { $0.id == category.id }), currentIndex < categories.count - 1 else { return }
        categories.swapAt(currentIndex, currentIndex + 1)
        save()
    }
    
    private func save() {
        let encoder = JSONEncoder()
        if let encodedCats = try? encoder.encode(categories) { UserDefaults.standard.set(encodedCats, forKey: categoriesKey) }
        if let encodedPrompts = try? encoder.encode(prompts) { UserDefaults.standard.set(encodedPrompts, forKey: promptsKey) }
    }
    
    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: categoriesKey), let decoded = try? decoder.decode([Category].self, from: data) { categories = decoded }
        if let data = UserDefaults.standard.data(forKey: promptsKey), let decoded = try? decoder.decode([Prompt].self, from: data) { prompts = decoded }
    }
}

// MARK: - 5. Clipboard Helfer

struct Clipboard {
    static func copy(_ text: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#else
        let pasteboard = UIPasteboard.general
        pasteboard.string = text
#endif
    }
    
    static func copyPNGImage(_ imageString: String) {
        var base64Clean = imageString
        if imageString.contains(",") { base64Clean = imageString.components(separatedBy: ",").last ?? imageString }
        base64Clean = base64Clean.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = Data(base64Encoded: base64Clean, options: .ignoreUnknownCharacters) else {
            copy(imageString)
            return
        }
        
#if os(macOS)
        if let nsImage = NSImage(data: data) {
            let p = NSPasteboard.general
            p.clearContents()
            p.writeObjects([nsImage])
        }
#else
        if let uiImage = UIImage(data: data) {
            UIPasteboard.general.image = uiImage
        }
#endif
    }
}

// MARK: - 6. Bild-Anzeige Komponente

struct DataOrAsyncImage: View {
    let imageString: String
    
    var body: some View {
        if let platformImage = decodeBase64ToImage(imageString) {
            Image(platformImage: platformImage)
                .resizable()
                .scaledToFit()
        } else if let url = URL(string: imageString), !imageString.hasPrefix("data:") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: ProgressView().frame(width: 30, height: 30)
                case .success(let image): image.resizable().scaledToFit()
                case .failure: imageErrorView
                @unknown default: EmptyView()
                }
            }
        } else {
            imageErrorView
        }
    }
    
    private var imageErrorView: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.caption)
            Text("Bildfehler")
                .font(.system(size: 9))
        }
        .foregroundColor(.secondary)
        .padding(6)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }
    
    private func decodeBase64ToImage(_ str: String) -> PlatformImage? {
        var base64Clean = str
        if str.contains(",") { base64Clean = str.components(separatedBy: ",").last ?? str }
        base64Clean = base64Clean.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = Data(base64Encoded: base64Clean, options: .ignoreUnknownCharacters) else { return nil }
#if os(macOS)
        return NSImage(data: data)
#else
        return UIImage(data: data)
#endif
    }
}

// MARK: - 7. Kompakte RemNote Live Anzeige (Links unten)

struct RemNoteLiveCompactView: View {
    let card: IncomingCard
    @State private var copiedImageIndex: Int? = nil
    @State private var copiedFront = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.liveAccent)
                    .frame(width: 7, height: 7)
                    .shadow(color: AppTheme.liveAccent.opacity(0.8), radius: 3)
                
                Text("RemNote Live")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("AKTIV")
                    .font(.system(size: 8, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppTheme.liveAccent.opacity(0.18))
                    .foregroundColor(AppTheme.liveAccent)
                    .clipShape(Capsule())
            }
            
            // Text-Vorschau der Vorderseite
            if !card.front.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    Text(card.front)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    Spacer()
                    
                    Button {
                        Clipboard.copy(card.front)
                        copiedFront = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFront = false }
                    } label: {
                        Image(systemName: copiedFront ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(copiedFront ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Vorderseite kopieren")
                }
            }
            
            // Bilder-Bereich mit direktem PNG-Kopieren
            if !card.images.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(card.images.enumerated()), id: \.offset) { index, imgString in
                        VStack(spacing: 5) {
                            DataOrAsyncImage(imageString: imgString)
                                .frame(maxHeight: 75)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .background(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                            
                            Button {
                                Clipboard.copyPNGImage(imgString)
                                copiedImageIndex = index
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedImageIndex = nil }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedImageIndex == index ? "checkmark" : "doc.on.clipboard")
                                    Text(copiedImageIndex == index ? "Kopiert!" : "PNG kopieren")
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(copiedImageIndex == index ? .green : AppTheme.primaryAccent)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.primaryAccent.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: AppTheme.shadowColor, radius: 4, x: 0, y: 2)
    }
}

// MARK: - 8. Hauptansicht (MainView)

struct MainView: View {
    @StateObject var store = PromptStore()
    @ObservedObject var cardServer: CardServer
    
    @AppStorage("last_selected_category_name") private var lastSelectedCategoryName: String = ""
    @State private var selectedCategory: Category?
    @State private var showAddCategory = false
    @State private var categoryToEdit: Category? = nil
    @State private var showAddPrompt = false
    @State private var searchText = ""
    @State private var scrollToPromptId: UUID? = nil
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                cardServer: cardServer,
                selectedCategory: $selectedCategory,
                searchText: $searchText,
                showAddCategory: $showAddCategory,
                categoryToEdit: $categoryToEdit,
                scrollToPromptId: $scrollToPromptId
            )
        } detail: {
            if let category = selectedCategory {
                DetailContentView(
                    category: category,
                    store: store,
                    cardServer: cardServer,
                    showAddPrompt: $showAddPrompt,
                    scrollToPromptId: $scrollToPromptId
                )
            } else {
                ContentUnavailableView("Keine Kategorie gewählt", systemImage: "sidebar.left", description: Text("Wähle eine Kategorie aus der Seitenleiste."))
            }
        }
        .onAppear {
            restoreLastSelectedCategory()
        }
        .onChange(of: selectedCategory) { _, newCategory in
            if let name = newCategory?.name {
                lastSelectedCategoryName = name
            }
        }
        .sheet(isPresented: $showAddCategory) { AddCategoryView(store: store) }
        .sheet(item: $categoryToEdit) { category in
            EditCategoryView(store: store, category: category) { updated in
                if selectedCategory?.id == category.id { selectedCategory = updated }
            }
        }
    }
    
    private func restoreLastSelectedCategory() {
        if !lastSelectedCategoryName.isEmpty,
           let saved = store.categories.first(where: { $0.name == lastSelectedCategoryName }) {
            selectedCategory = saved
        } else if let first = store.categories.first {
            selectedCategory = first
            lastSelectedCategoryName = first.name
        }
    }
}

// MARK: - Sidebar Component (inkl. Alle Prompts kopieren)

struct SidebarView: View {
    @ObservedObject var store: PromptStore
    @ObservedObject var cardServer: CardServer
    @Binding var selectedCategory: Category?
    @Binding var searchText: String
    @Binding var showAddCategory: Bool
    @Binding var categoryToEdit: Category?
    @Binding var scrollToPromptId: UUID?
    
    @State private var hasCopiedAll = false
    
    var titleMatches: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return store.prompts.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    
    var contentMatches: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return store.prompts.filter {
            !$0.title.localizedCaseInsensitiveContains(query) &&
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        List(selection: $selectedCategory) {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section(header: Text("Kategorien").font(.caption).fontWeight(.bold).foregroundColor(.secondary)) {
                    ForEach(Array(store.categories.enumerated()), id: \.element.id) { index, cat in
                        Button {
                            selectedCategory = cat
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(selectedCategory?.id == cat.id ? .white : AppTheme.primaryAccent)
                                    .frame(width: 28, height: 28)
                                    .background(selectedCategory?.id == cat.id ? AppTheme.primaryAccent : AppTheme.primaryAccent.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                Text(cat.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(cat)
                        .contextMenu {
                            Button { categoryToEdit = cat } label: { Label("Bearbeiten", systemImage: "pencil") }
                            Divider()
                            Button { withAnimation { store.moveCategoryUp(cat) } } label: { Label("Nach oben", systemImage: "arrow.up") }.disabled(index == 0)
                            Button { withAnimation { store.moveCategoryDown(cat) } } label: { Label("Nach unten", systemImage: "arrow.down") }.disabled(index == store.categories.count - 1)
                            Divider()
                            Button(role: .destructive) {
                                if selectedCategory?.id == cat.id { selectedCategory = nil }
                                withAnimation { store.removeCategory(cat) }
                            } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                }
            } else {
                if titleMatches.isEmpty && contentMatches.isEmpty {
                    ContentUnavailableView(
                        "Keine Treffer",
                        systemImage: "magnifyingglass",
                        description: Text("Keine Prompts für '\(searchText)' gefunden.")
                    )
                } else {
                    if !titleMatches.isEmpty {
                        Section(header:
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.indent")
                                Text("Prompt-Titel")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .textCase(nil)
                        ) {
                            ForEach(titleMatches) { prompt in
                                Button {
                                    selectSearchResult(prompt)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(prompt.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                        
                                        Text("in \(prompt.category)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    if !contentMatches.isEmpty {
                        Section(header:
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("Inhaltliche Treffer")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .textCase(nil)
                        ) {
                            ForEach(contentMatches) { prompt in
                                Button {
                                    selectSearchResult(prompt)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(prompt.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                        
                                        Text(prompt.text.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Prompts")
        .searchable(text: $searchText, prompt: "Suchen...")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Button: Alle Prompts kopieren
                Button {
                    copyAllPrompts()
                } label: {
                    Image(systemName: hasCopiedAll ? "checkmark" : "doc.on.doc")
                        .foregroundColor(hasCopiedAll ? .green : .primary)
                }
                .help(hasCopiedAll ? "Alle Prompts kopiert!" : "Alle Prompts aus allen Kategorien kopieren")
                
                // Button: Kategorie hinzufügen
                Button { showAddCategory = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Kategorie hinzufügen")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let liveCard = cardServer.lastCard {
                RemNoteLiveCompactView(card: liveCard)
                    .padding(10)
            }
        }
    }
    
    private func copyAllPrompts() {
        var sections: [String] = []
        
        for category in store.categories {
            let categoryPrompts = store.prompts.filter { $0.category == category.name }
            guard !categoryPrompts.isEmpty else { continue }
            
            var catText = "# \(category.name)\n"
            for prompt in categoryPrompts {
                catText += "\n## \(prompt.title)\n\(prompt.text)\n"
            }
            sections.append(catText)
        }
        
        // Prüfen, falls es Prompts gibt, deren Kategorie nicht in der Kategorienliste ist
        let knownCategoryNames = Set(store.categories.map { $0.name })
        let orphanedPrompts = store.prompts.filter { !knownCategoryNames.contains($0.category) }
        if !orphanedPrompts.isEmpty {
            var catText = "# Weitere Prompts\n"
            for prompt in orphanedPrompts {
                catText += "\n## \(prompt.title)\n\(prompt.text)\n"
            }
            sections.append(catText)
        }
        
        let allText = sections.joined(separator: "\n----------------------------------------\n\n")
        Clipboard.copy(allText)
        
        withAnimation {
            hasCopiedAll = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                hasCopiedAll = false
            }
        }
    }
    
    private func selectSearchResult(_ prompt: Prompt) {
        if let cat = store.categories.first(where: { $0.name == prompt.category }) {
            selectedCategory = cat
            store.expandPrompt(id: prompt.id)
            scrollToPromptId = prompt.id
        }
    }
}

// MARK: - Detail Content Component

struct DetailContentView: View {
    let category: Category
    @ObservedObject var store: PromptStore
    @ObservedObject var cardServer: CardServer
    @Binding var showAddPrompt: Bool
    @Binding var scrollToPromptId: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: category.icon)
                        .font(.title2)
                        .foregroundColor(AppTheme.primaryAccent)
                        .padding(8)
                        .background(AppTheme.primaryAccent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    Text(category.name)
                        .font(.system(size: 26, weight: .bold))
                }
                
                Spacer()
                
                Button {
                    showAddPrompt = true
                } label: {
                    Label("Neuer Prompt", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.primaryAccent)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        let filtered = store.prompts.filter { $0.category == category.name }
                        
                        if filtered.isEmpty {
                            ContentUnavailableView("Keine Prompts in \(category.name)", systemImage: "doc.badge.plus", description: Text("Erstelle deinen ersten Prompt für diese Kategorie."))
                                .padding(.top, 40)
                        } else {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, prompt in
                                PromptCard(
                                    prompt: prompt,
                                    currentRemNoteCard: cardServer.lastCard,
                                    isFirst: index == 0,
                                    isLast: index == filtered.count - 1,
                                    onRename: { newTitle in store.renamePrompt(id: prompt.id, newTitle: newTitle) },
                                    onUpdateText: { newText in store.updatePrompt(id: prompt.id, newText: newText) },
                                    onToggleExpansion: { store.toggleExpansion(id: prompt.id) },
                                    onMoveUp: { withAnimation { store.movePromptUp(id: prompt.id) } },
                                    onMoveDown: { withAnimation { store.movePromptDown(id: prompt.id) } },
                                    onDelete: { store.removePrompt(id: prompt.id) }
                                )
                                .id(prompt.id)
                            }
                        }
                    }
                    .padding(24)
                }
                .onChange(of: scrollToPromptId) { _, targetId in
                    if let targetId = targetId {
                        withAnimation {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            scrollToPromptId = nil
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddPrompt) { AddPromptView(store: store, category: category.name) }
    }
}

// MARK: - Reusable Icon Picker Component

struct IconPickerGridView: View {
    @Binding var selectedIcon: String
    
    let availableIcons: [String] = [
        "folder", "character.book.closed", "archivebox", "terminal",
        "doc.text", "doc.text.magnifyingglass", "sparkles", "rectangle.on.rectangle.angled",
        "cross.case", "briefcase", "pencil", "gearshape",
        "list.bullet", "list.number", "star", "lightbulb", "brain", "graduationcap",
        "cpu", "chart.bar", "globe", "lock",
        "bubble.left", "character.bubble", "bubble.left.and.bubble.right"
    ]
    
    private let columns = [GridItem(.adaptive(minimum: 38), spacing: 8)]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(availableIcons, id: \.self) { icon in
                Button {
                    selectedIcon = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 36, height: 36)
                        .background(selectedIcon == icon ? AppTheme.primaryAccent.opacity(0.15) : Color.primary.opacity(0.03))
                        .foregroundColor(selectedIcon == icon ? AppTheme.primaryAccent : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selectedIcon == icon ? AppTheme.primaryAccent : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 9. Dialoge & Sheets

struct AddCategoryView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PromptStore
    
    @State private var name = ""
    @State private var selectedIcon = "folder"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundColor(AppTheme.primaryAccent)
                
                Text("Neue Kategorie")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME DER KATEGORIE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    TextField("Kategoriename...", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.primaryAccent.opacity(0.3), lineWidth: 1)
                        )
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("SYMBOL WÄHLEN")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    IconPickerGridView(selectedIcon: $selectedIcon)
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                }
            }
            
            HStack(spacing: 10) {
                Spacer()
                
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                
                Button("Hinzufügen") {
                    store.addCategory(name: name, icon: selectedIcon)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryAccent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct EditCategoryView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PromptStore
    let category: Category
    var onSave: ((Category) -> Void)? = nil
    
    @State private var name: String
    @State private var selectedIcon: String
    
    init(store: PromptStore, category: Category, onSave: ((Category) -> Void)? = nil) {
        self.store = store
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category.name)
        _selectedIcon = State(initialValue: category.icon)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundColor(AppTheme.primaryAccent)
                
                Text("Kategorie bearbeiten")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME DER KATEGORIE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    TextField("Name der Kategorie...", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.primaryAccent.opacity(0.3), lineWidth: 1)
                        )
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("SYMBOL WÄHLEN")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    IconPickerGridView(selectedIcon: $selectedIcon)
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                }
            }
            
            HStack(spacing: 10) {
                Spacer()
                
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                
                Button("Speichern") {
                    let updated = store.renameCategory(oldCategory: category, newName: name, newIcon: selectedIcon)
                    onSave?(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryAccent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct EditPromptSheet: View {
    @Environment(\.dismiss) var dismiss
    let currentTitle: String
    var onSave: (String) -> Void
    
    @State private var title: String
    
    init(currentTitle: String, onSave: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.onSave = onSave
        _title = State(initialValue: currentTitle)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundColor(AppTheme.primaryAccent)
                
                Text("Prompt umbenennen")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("TITEL DES PROMPTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                
                TextField("Titel eingeben...", text: $title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.primaryAccent.opacity(0.4), lineWidth: 1)
                    )
            }
            
            HStack(spacing: 10) {
                Spacer()
                
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                
                Button("Speichern") {
                    onSave(title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryAccent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct AddPromptView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PromptStore
    let category: String
    
    @State private var title = ""
    @State private var text = ""
    @State private var needsImage = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(AppTheme.primaryAccent)
                
                Text("Neuer Prompt in \(category)")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROMPT TITEL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    TextField("z.B. Liste analysieren oder Eselsbrücke", text: $title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("INHALT / TEMPLATE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Prompt Text hier...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        }
                        
                        TextEditor(text: $text)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(Color.clear)
                            .scrollContentBackground(.hidden)
                    }
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .frame(height: 110)
                    
                    Text("Tipp: Nutze /Karte/ für alles, /Liste/ für die Aufzählung, /Pfad/ für Ordner oder {Platzhalter} für freie Eingaben.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
                
                Toggle("Benötigt Bild-Upload", isOn: $needsImage)
                    .toggleStyle(.switch)
                    .font(.subheadline)
            }
            
            HStack(spacing: 10) {
                Spacer()
                
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                
                Button("Erstellen") {
                    let new = Prompt(title: title, text: text, category: category, icon: "doc.text", needsImage: needsImage)
                    store.addPrompt(new)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryAccent)
                .disabled(title.isEmpty || text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PlaceholderFillSheet: View {
    @Environment(\.dismiss) var dismiss
    let originalText: String
    let placeholders: [String]
    let remNoteCard: IncomingCard?
    let onCopy: (String) -> Void
    
    @State private var inputValues: [String: String] = [:]
    
    private var filledText: String {
        var result = originalText
        for key in placeholders {
            let val = inputValues[key] ?? ""
            if !val.isEmpty {
                result = result.replacingOccurrences(of: "{\(key)}", with: val)
            }
        }
        return result
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundColor(AppTheme.primaryAccent)
                
                Text("Prompt anpassen")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PLATZHALTER AUSFÜLLEN")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 0) {
                            ForEach(Array(placeholders.enumerated()), id: \.element) { index, placeholder in
                                HStack(spacing: 12) {
                                    Text(placeholder)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.primary)
                                        .frame(minWidth: 80, alignment: .leading)
                                    
                                    Spacer()
                                    
                                    TextField("Wert eingeben...", text: Binding(
                                        get: { inputValues[placeholder, default: ""] },
                                        set: { inputValues[placeholder] = $0 }
                                    ))
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(6)
                                    .frame(maxWidth: 260)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                
                                if index < placeholders.count - 1 {
                                    Divider()
                                        .padding(.leading, 14)
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("VORSCHAU")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        ScrollView {
                            Text(filledText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        .frame(maxHeight: 160)
                        .background(Color.primary.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
            
            HStack(spacing: 10) {
                Spacer()
                
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                
                Button("Fertig & Kopieren") {
                    onCopy(filledText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryAccent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 10. Einzelne Karte (PromptCard)

struct PromptCard: View {
    let prompt: Prompt
    let currentRemNoteCard: IncomingCard?
    let isFirst: Bool
    let isLast: Bool
    
    var onRename: (String) -> Void
    var onUpdateText: (String) -> Void
    var onToggleExpansion: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void
    
    @State private var hasCopied = false
    @State private var draftText = ""
    @State private var activePlaceholderData: PlaceholderData? = nil
    @State private var showRenameSheet = false
    
    var detectedTags: [String] {
        var tags: [String] = []
        let text = prompt.text
        
        if text.localizedCaseInsensitiveContains("/Karte/") || text.localizedCaseInsensitiveContains("/Flashcard/") {
            tags.append("RemNote Live")
        }
        if text.localizedCaseInsensitiveContains("/Vorderseite/") || text.localizedCaseInsensitiveContains("/Front/") {
            tags.append("Vorderseite")
        }
        if text.localizedCaseInsensitiveContains("/Rückseite/") || text.localizedCaseInsensitiveContains("/Back/") {
            tags.append("Rückseite")
        }
        if text.localizedCaseInsensitiveContains("/Pfad/") || text.localizedCaseInsensitiveContains("/Path/") {
            tags.append("Pfad")
        }
        if text.localizedCaseInsensitiveContains("/Liste/") || text.localizedCaseInsensitiveContains("/List/") {
            tags.append("Liste")
        }
        if text.localizedCaseInsensitiveContains("/Bild/") || text.localizedCaseInsensitiveContains("/Bilder/") ||
           text.localizedCaseInsensitiveContains("/Image/") || text.localizedCaseInsensitiveContains("/Images/") {
            tags.append("Bild")
        }
        
        let extracted = PlaceholderHelper.extractPlaceholders(from: text)
        for p in extracted {
            tags.append("{\(p)}")
        }
        return tags
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        onToggleExpansion()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(prompt.isExpanded ? 90 : 0))
                        
                        Text(prompt.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 4) {
                            ForEach(detectedTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.primaryAccent.opacity(0.1))
                                    .foregroundColor(AppTheme.primaryAccent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: initiateCopy) {
                        Image(systemName: hasCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundColor(hasCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Prompt kopieren")
                    
                    Menu {
                        Button { showRenameSheet = true } label: { Label("Bearbeiten", systemImage: "pencil") }
                        Divider()
                        Button(action: onMoveUp) { Label("Nach oben", systemImage: "arrow.up") }.disabled(isFirst)
                        Button(action: onMoveDown) { Label("Nach unten", systemImage: "arrow.down") }.disabled(isLast)
                        Divider()
                        Button(role: .destructive, action: onDelete) { Label("Löschen", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            
            if prompt.isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $draftText)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .padding(10)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .frame(minHeight: 90)
                        .task(id: draftText) {
                            do {
                                try await Task.sleep(nanoseconds: 400_000_000)
                                onUpdateText(draftText)
                            } catch {}
                        }
                    
                    Button(action: initiateCopy) {
                        HStack(spacing: 8) {
                            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(hasCopied ? "In Zwischenablage kopiert!" : "Prompt kopieren")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(hasCopied ? Color.green : AppTheme.primaryAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: hasCopied ? Color.green.opacity(0.3) : AppTheme.primaryAccent.opacity(0.3), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadowColor, radius: 4, x: 0, y: 2)
        .onAppear { draftText = prompt.text }
        .onChange(of: prompt.text) { _, newText in draftText = newText }
        .sheet(isPresented: $showRenameSheet) {
            EditPromptSheet(currentTitle: prompt.title) { newTitle in onRename(newTitle) }
        }
        .sheet(item: $activePlaceholderData) { data in
            PlaceholderFillSheet(
                originalText: data.text,
                placeholders: data.placeholders,
                remNoteCard: currentRemNoteCard,
                onCopy: { finalText in performCopy(finalText) }
            )
        }
    }
    
    private func initiateCopy() {
        var textToUse = draftText.isEmpty ? prompt.text : draftText
        textToUse = PlaceholderHelper.replaceFlashcardShorthand(in: textToUse, with: currentRemNoteCard)
        
        let keys = PlaceholderHelper.extractPlaceholders(from: textToUse)
        if keys.isEmpty {
            performCopy(textToUse)
        } else {
            activePlaceholderData = PlaceholderData(text: textToUse, placeholders: keys)
        }
    }
    
    private func performCopy(_ textToCopy: String) {
        Clipboard.copy(textToCopy)
        withAnimation { hasCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            hasCopied = false
        }
    }
}
