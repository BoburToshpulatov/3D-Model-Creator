import SwiftUI
import RealityKit
import Foundation
import os
import UniformTypeIdentifiers
import ModelIO
import SceneKit

// MARK: - Main App Entry Point
@main
struct ObjectCaptureReconstructionApp: App {
    static let subsystem: String = "com.example.apple-samplecode.ObjectCaptureReconstruction.Enhanced"
    static let windowTitle = "3D Model Creator — Enhanced UI"
    
    var body: some SwiftUI.Scene {
        WindowGroup(Self.windowTitle, id: "main") {
            NavigationStack {
                ContentView()
                    .frame(minWidth: 1000, minHeight: 700)
            }
            // The design is dark only, so make the system controls, the toolbar, and the alerts render dark
            // even when the Mac is in the light appearance.
            .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 860)
    }
}

// MARK: - Content View
struct ContentView: View {
    @State private var appDataModel = AppDataModel()
    @State private var showErrorAlert = false
    @State private var showDevelopersView = false
    
    var body: some View {
        ZStack {
            // Modern gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.08),
                    Color(red: 0.08, green: 0.08, blue: 0.12),
                    Color(red: 0.06, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                switch appDataModel.state {
                case .ready, .error:
                    // In the error state, an alert gets displayed over the settings through the alert modifier on this view.
                    EnhancedSettingsView()
                        .padding(40)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                NavigationLink {
                                    DevelopersView()
                                        .environment(appDataModel)
                                } label: {
                                    Label("For developers", systemImage: "curlybraces.square")
                                }
                                .keyboardShortcut("d", modifiers: [.command, .shift])
                            }
                        }
                case .reconstructing, .viewing:
                    EnhancedProcessingView()
                }
            }
        }
        .environment(appDataModel)
        .navigationTitle(ObjectCaptureReconstructionApp.windowTitle)
        .onChange(of: appDataModel.state) {
            if appDataModel.state == .error {
                showErrorAlert = true
            }
        }
        .alert(appDataModel.alertMessage, isPresented: $showErrorAlert) {
            Button("OK") {
                appDataModel.state = .ready
            }
        }
    }
}

// MARK: - App Data Model
private let logger = Logger(subsystem: ObjectCaptureReconstructionApp.subsystem,
                            category: "AppDataModel")

@MainActor @Observable class AppDataModel {
    enum State: Equatable {
        case ready
        case reconstructing
        case viewing
        case error
    }
    
    enum ExportFormat: String, CaseIterable, Identifiable {
        case usdz = "USDZ"
        case obj = "OBJ"
        case usda = "USDA"
        case stl = "STL"
        case ply = "PLY"
        case dae = "DAE"
        
        var id: String { rawValue }
        
        var fileExtension: String {
            rawValue.lowercased()
        }
        
        var description: String {
            switch self {
            case .usdz: return "Universal Scene Description (Apple's format)"
            case .obj: return "Wavefront Object (Folder with material and textures)"
            case .usda: return "USD ASCII (Editable text format)"
            case .stl: return "Stereolithography (3D printing)"
            case .ply: return "Polygon File Format (Point clouds)"
            case .dae: return "COLLADA (Web/game engines)"
            }
        }
        
        var icon: String {
            switch self {
            case .usdz: return "cube.fill"
            case .obj: return "square.stack.3d.up.fill"
            case .usda: return "doc.text.fill"
            case .stl: return "printer.fill"
            case .ply: return "circle.hexagongrid.fill"
            case .dae: return "globe"
            }
        }
    }
    
    private(set) var session: PhotogrammetrySession?
    var state: State = .ready {
        didSet {
            logger.log("State switched to \(String(describing: self.state))")
            // Leaving the processing views ends the session, so stop any work that's still in flight.
            if state == .ready || state == .error {
                if let session, session.isProcessing { session.cancel() }
                session = nil
            }
        }
    }
    
    var imageFolder: URL?
    var modelFolder: URL?
    var modelName: String?
    var modelFileURLToDisplay: URL?
    var sessionConfiguration: PhotogrammetrySession.Configuration = PhotogrammetrySession.Configuration()
    var detailLevelOptionUnderQualityMenu = PhotogrammetrySession.Request.Detail.medium
    
    struct DetailLevelOptionsUnderAdvancedMenu {
        var isSelected = false
        var preview = false
        var reduced = false
        var medium = false
        var full = false
        var raw = false
    }
    
    var detailLevelOptionsUnderAdvancedMenu = DetailLevelOptionsUnderAdvancedMenu()
    var alertMessage: String = ""
    var numRequestedModels = 0
    var boundingBoxAvailable = false
    var selectedExportFormat: ExportFormat = .usdz
    
    func startReconstruction() async {
        logger.log("Starting the reconstruction...")
        guard let imageFolder = imageFolder else {
            alertMessage = "Image folder is not selected"
            state = .error
            return
        }
        guard modelName != nil else {
            alertMessage = "Model name is not selected"
            state = .error
            return
        }
        guard modelFolder != nil else {
            alertMessage = "Model folder is not selected"
            state = .error
            return
        }
        
        guard PhotogrammetrySession.isSupported else {
            alertMessage = "Object reconstruction is not supported on this Mac"
            state = .error
            return
        }
        
        let requests = createReconstructionRequests()
        guard !requests.isEmpty else { return }
        numRequestedModels = requests.count
        state = .reconstructing
        
        do {
            let session = try await createSession(imageFolder: imageFolder, configuration: sessionConfiguration)
            
            // The person can cancel while the session is being created.
            guard state == .reconstructing else {
                logger.log("Reconstruction was canceled before the session was created.")
                return
            }
            self.session = session
            try session.process(requests: requests)
            logger.log("Processing requests started...")
        } catch {
            logger.warning("Creating the session or processing the session failed: \(error)")
            guard state == .reconstructing else { return }
            alertMessage = Self.message(for: error)
            state = .error
        }
    }
    
    // Returns a message that's suitable for the error alert.
    static func message(for error: any Error) -> String {
        if let error = error as? PhotogrammetrySession.Error {
            return error.description
        }
        return error.localizedDescription
    }
    
    private nonisolated func createSession(imageFolder: URL,
                                           configuration: PhotogrammetrySession.Configuration) async throws -> PhotogrammetrySession {
        return try PhotogrammetrySession(input: imageFolder, configuration: configuration)
    }
    
    private func createReconstructionRequests() -> [PhotogrammetrySession.Request] {
        var detailLevelList: Set<PhotogrammetrySession.Request.Detail> = [detailLevelOptionUnderQualityMenu]
        if detailLevelOptionsUnderAdvancedMenu.isSelected {
            if detailLevelOptionsUnderAdvancedMenu.preview { detailLevelList.insert(.preview) }
            if detailLevelOptionsUnderAdvancedMenu.reduced { detailLevelList.insert(.reduced) }
            if detailLevelOptionsUnderAdvancedMenu.medium { detailLevelList.insert(.medium) }
            if detailLevelOptionsUnderAdvancedMenu.full { detailLevelList.insert(.full) }
            if detailLevelOptionsUnderAdvancedMenu.raw { detailLevelList.insert(.raw) }
        }
        
        var requests: [PhotogrammetrySession.Request] = []
        // Process from the fastest to the slowest detail level so the first model shows up early.
        for detailLevel in detailLevelList.sorted(by: { $0.rawValue < $1.rawValue }) {
            let modelFileURL = modelFolder!.appending(path: (modelName!) + "-\(detailLevel)" + ".usdz")
            requests.append(PhotogrammetrySession.Request.modelFile(url: modelFileURL, detail: detailLevel))
        }
        return requests
    }
}

extension PhotogrammetrySession.Error: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidImages:
            return "No valid images found in selected folder"
        case .invalidOutput:
            return "Cannot save to selected folder"
        case .insufficientStorage:
            return "Not enough disk space available to begin processing."
        @unknown default:
            return "\(self)"
        }
    }
}

// MARK: - Image Helper
class ImageHelper {
    static let validImageSuffixes: Set<String> = ["heic", "jpg", "jpeg", "png"]
    
    static func getListOfURLs(from folder: URL?) -> [URL] {
        guard let folder = folder else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: folder,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
                .filter { !$0.hasDirectoryPath && isLoadableImageFile($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return []
        }
    }
    
    struct MetadataAvailability {
        var depth = false
        var gravity = false
        var boundingBox = false
    }
    
    static func loadMetadataAvailability(from urls: [URL]) async -> MetadataAvailability {
        guard !urls.isEmpty else { return MetadataAvailability() }
        
        var metadataAvailability = MetadataAvailability()
        var numImagesWithDepth = 0
        var numImagesWithGravity = 0
        
        for url in urls.prefix(10) {
            if Task.isCancelled { break }
            guard let sample = try? await PhotogrammetrySample(contentsOf: url) else { continue }
            
            if sample.depthDataMap != nil {
                numImagesWithDepth += 1
                if numImagesWithDepth >= 3 {
                    metadataAvailability.depth = true
                }
            }
            
            if sample.gravity != nil {
                numImagesWithGravity += 1
                if numImagesWithGravity >= 3 {
                    metadataAvailability.gravity = true
                }
            }
            
            if sample.boundingBox != nil {
                metadataAvailability.boundingBox = true
            }
            
            if metadataAvailability.depth && metadataAvailability.gravity && metadataAvailability.boundingBox {
                break
            }
        }
        
        return metadataAvailability
    }
    
    static private func isLoadableImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let suffix = url.pathExtension.lowercased()
        return validImageSuffixes.contains(suffix)
    }
}

// MARK: - UI Components
struct GlassCard<Content: View>: View {
    let content: Content
    let prominent: Bool
    
    init(prominent: Bool = false, @ViewBuilder content: () -> Content) {
        self.prominent = prominent
        self.content = content()
    }
    
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: prominent ? [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.05)
                            ] : [
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.2),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 15)
            )
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    let subtitle: String?
    
    init(title: String, icon: String, subtitle: String? = nil) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.blue)
                }
                
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
            }
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.leading, 56)
            }
        }
    }
}

struct ThumbnailView: View {
    let imageFolderURL: URL
    let frameSize: CGSize
    @State private var image: CGImage?
    
    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(.blue)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .task(id: imageFolderURL) {
            image = await createThumbnail(url: imageFolderURL)
        }
    }
    
    private nonisolated func createThumbnail(url: URL) async -> CGImage? {
        let maxPixelSize = max(frameSize.width, frameSize.height) * 2
        let options = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else {
            return nil
        }
        return thumbnail
    }
}

// MARK: - Settings View
struct EnhancedSettingsView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    var body: some View {
        VStack(spacing: 32) {
            // Hero Header
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 70, height: 70)
                            .blur(radius: 20)
                        
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("3D Model Creator")
                            .font(.system(size: 42, weight: .black))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        
                        Text("Transform your photos into stunning 3D models with advanced photogrammetry")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                    
                    // Top-right "For developers" button (Duplicate for visibility here too)
                    NavigationLink {
                        DevelopersView()
                            .environment(appDataModel)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "curlybraces.square")
                            Text("For developers")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Input Section
                    GlassCard(prominent: true) {
                        VStack(spacing: 24) {
                            SectionHeader(
                                title: "Input Configuration",
                                icon: "photo.stack.fill",
                                subtitle: "Select your image folder and output settings"
                            )
                            
                            VStack(spacing: 16) {
                                ImageFolderView()
                                Divider().background(Color.white.opacity(0.1))
                                ModelNameField()
                                Divider().background(Color.white.opacity(0.1))
                                ModelFolderView()
                            }
                        }
                        .padding(28)
                    }
                    
                    // Reconstruction Options
                    GlassCard {
                        VStack(spacing: 24) {
                            SectionHeader(
                                title: "Reconstruction Settings",
                                icon: "slider.horizontal.3",
                                subtitle: "Fine-tune your 3D model generation"
                            )
                            
                            VStack(spacing: 20) {
                                MeshTypeView()
                                Divider().background(Color.white.opacity(0.1))
                                QualityView()
                                Divider().background(Color.white.opacity(0.1))
                                MaskingView()
                                Divider().background(Color.white.opacity(0.1))
                                IgnoreBoundingBoxView()
                            }
                            .padding(.horizontal, 4)
                        }
                        .padding(28)
                    }
                    
                    // Process Button
                    ProcessButton()
                        .padding(.top, 12)
                }
                .padding(.bottom, 32)
            }
        }
    }
}

// MARK: - Input Views
struct ImageFolderView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var selectedFolder: URL?
    @State private var imageURLs: [URL] = []
    @State private var numImages: Int?
    @State private var metadataAvailability = ImageHelper.MetadataAvailability()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Image Folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                
                if metadataAvailability.gravity && metadataAvailability.depth {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                        Text("High Quality")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.18))
                    )
                }
                
                Spacer()
                
                if let numImages = numImages {
                    Text("\(numImages) images")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.2))
                        )
                }
            }
            
            VStack(spacing: 0) {
                ImageFolderThumbnailView(imageURLs: $imageURLs)
                    .padding(16)
                
                Divider().background(Color.white.opacity(0.1))
                
                ImageFolderSelectionView(selectedFolder: $selectedFolder)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .onAppear {
            selectedFolder = appDataModel.imageFolder
        }
        .onChange(of: selectedFolder) {
            appDataModel.imageFolder = selectedFolder
            appDataModel.boundingBoxAvailable = false
            metadataAvailability = ImageHelper.MetadataAvailability()
        }
        .dropDestination(for: URL.self) { items, _ in
            guard let url = items.first, url.hasDirectoryPath else { return false }
            selectedFolder = url
            return true
        }
        .task(id: selectedFolder) {
            guard let selectedFolder else {
                numImages = nil
                imageURLs = []
                metadataAvailability = ImageHelper.MetadataAvailability()
                appDataModel.boundingBoxAvailable = false
                return
            }
            
            imageURLs = ImageHelper.getListOfURLs(from: selectedFolder)
            if imageURLs.isEmpty {
                appDataModel.alertMessage = "No valid images found in selected folder"
                appDataModel.state = .error
                self.selectedFolder = nil
                return
            }
            
            numImages = imageURLs.count
            let availability = await ImageHelper.loadMetadataAvailability(from: imageURLs)
            // Ignore the result if the person picked a different folder in the meantime.
            guard !Task.isCancelled else { return }
            metadataAvailability = availability
            appDataModel.boundingBoxAvailable = availability.boundingBox
        }
    }
}

struct ImageFolderThumbnailView: View {
    @Binding var imageURLs: [URL]
    @State private var thumbnailURLs: [URL]?
    
    var body: some View {
        HStack(spacing: 12) {
            if let thumbnailURLs, !thumbnailURLs.isEmpty {
                ForEach(thumbnailURLs, id: \.self) { thumbnailURL in
                    ThumbnailView(imageFolderURL: thumbnailURL, frameSize: CGSize(width: 60, height: 60))
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 100, height: 80)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.blue.opacity(0.55))
                        Text("No Images")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
        .frame(minHeight: 80)
        .onChange(of: imageURLs) {
            guard !imageURLs.isEmpty else {
                thumbnailURLs = nil
                return
            }
            
            let numImages = imageURLs.count
            if numImages < 5 {
                thumbnailURLs = imageURLs
            } else {
                let step = numImages / 5
                thumbnailURLs = (0..<5).map { imageURLs[$0 * step] }
            }
        }
    }
}

struct ImageFolderSelectionView: View {
    @Binding var selectedFolder: URL?
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var showFileImporter = false
    
    var body: some View {
        Button {
            showFileImporter.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedFolder == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.blue)
                
                if let selectedFolder = selectedFolder {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFolder.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(selectedFolder.path)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Text("Choose Folder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                _ = directory.startAccessingSecurityScopedResource()
                selectedFolder = directory
            case .failure(let error):
                appDataModel.alertMessage = "\(error)"
                appDataModel.state = .error
            }
        }
    }
}

struct ModelNameField: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var modelName: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Name")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            
            TextField("", text: $modelName, prompt: Text("Enter a name for your 3D model").foregroundColor(.white.opacity(0.6)))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(modelName.isEmpty ? Color.white.opacity(0.15) : Color.blue.opacity(0.6), lineWidth: 1.5)
                        )
                )
        }
        .onChange(of: modelName) {
            // The name becomes a file name, so drop surrounding whitespace and path separators.
            let fileName = modelName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing(/[\/:]/, with: "-")
            appDataModel.modelName = fileName.isEmpty ? nil : fileName
        }
        .onAppear {
            if let appModelName = appDataModel.modelName {
                modelName = appModelName
            }
        }
    }
}

struct ModelFolderView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var showFileImporter = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output Location")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            
            Button {
                showFileImporter.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: appDataModel.modelFolder == nil ? "folder.badge.plus" : "folder.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.blue)
                    
                    if let selectedFolder = appDataModel.modelFolder {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedFolder.lastPathComponent)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text(selectedFolder.path)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    } else {
                        Text("Choose Output Folder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                _ = directory.startAccessingSecurityScopedResource()
                appDataModel.modelFolder = directory
            case .failure(let error):
                appDataModel.alertMessage = "\(error)"
                appDataModel.state = .error
            }
        }
    }
}

// MARK: - Reconstruction Options
struct MeshTypeView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    var body: some View {
        @Bindable var appDataModel = appDataModel
        
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mesh Type")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Geometry structure")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            Picker("", selection: $appDataModel.sessionConfiguration.meshPrimitive) {
                Text("Triangular").tag(PhotogrammetrySession.Configuration.MeshPrimitive.triangle)
                Text("Quad").tag(PhotogrammetrySession.Configuration.MeshPrimitive.quad)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }
}

struct QualityView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var showAdvancedOptions = false
    
    var body: some View {
        @Bindable var appDataModel = appDataModel
        
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quality Level")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Model detail and size")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Picker("", selection: $appDataModel.detailLevelOptionUnderQualityMenu) {
                    Text("Preview").tag(PhotogrammetrySession.Request.Detail.preview)
                    Text("Reduced").tag(PhotogrammetrySession.Request.Detail.reduced)
                    Text("Medium").tag(PhotogrammetrySession.Request.Detail.medium)
                    Text("Full").tag(PhotogrammetrySession.Request.Detail.full)
                    Text("Raw").tag(PhotogrammetrySession.Request.Detail.raw)
                    Text("Custom").tag(PhotogrammetrySession.Request.Detail.custom)
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                
                Button {
                    showAdvancedOptions = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            Circle()
                                .fill(Color.blue.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $showAdvancedOptions) {
            AdvancedReconstructionOptions()
                .preferredColorScheme(.dark)
        }
        .onChange(of: appDataModel.detailLevelOptionUnderQualityMenu) {
            // The custom specification only applies to the custom detail level.
            if appDataModel.detailLevelOptionUnderQualityMenu != .custom {
                appDataModel.sessionConfiguration.customDetailSpecification = PhotogrammetrySession.Configuration.CustomDetailSpecification()
            }
        }
    }
}

struct MaskingView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var selectedMaskOption = 0
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Object Masking")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Environment handling")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            Picker("", selection: $selectedMaskOption) {
                Text("Isolate Object").tag(0)
                Text("Include Environment").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .onChange(of: selectedMaskOption) {
            appDataModel.sessionConfiguration.isObjectMaskingEnabled = (selectedMaskOption == 0)
        }
        .onAppear {
            selectedMaskOption = appDataModel.sessionConfiguration.isObjectMaskingEnabled ? 0 : 1
        }
    }
}

struct IgnoreBoundingBoxView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    var body: some View {
        @Bindable var appDataModel = appDataModel
        
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bounding Box")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("iOS capture crop")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            Toggle("Ignore iOS bounding box", isOn: $appDataModel.sessionConfiguration.ignoreBoundingBox)
                .toggleStyle(.switch)
                .tint(.blue)
                .foregroundColor(.white)
        }
        .disabled(!appDataModel.boundingBoxAvailable)
        .opacity(appDataModel.boundingBoxAvailable ? 1.0 : 0.5)
    }
}

struct AdvancedReconstructionOptions: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    var body: some View {
        @Bindable var appDataModel = appDataModel
        
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Advanced Options")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("Fine-tune your reconstruction")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Divider().background(Color.white.opacity(0.2))
            
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Polygon Count")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    TextField("", value: $appDataModel.sessionConfiguration.customDetailSpecification.maximumPolygonCount, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Texture Resolution")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Picker("", selection: $appDataModel.sessionConfiguration.customDetailSpecification.maximumTextureDimension) {
                        Text("1K").tag(PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension.oneK)
                        Text("2K").tag(PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension.twoK)
                        Text("4K").tag(PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension.fourK)
                        Text("8K").tag(PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension.eightK)
                        Text("16K").tag(PhotogrammetrySession.Configuration.CustomDetailSpecification.TextureDimension.sixteenK)
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider().background(Color.white.opacity(0.2))
                
                Toggle("Process Multiple Detail Levels", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.isSelected)
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .foregroundColor(.white)
                
                if appDataModel.detailLevelOptionsUnderAdvancedMenu.isSelected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Detail Levels")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                        
                        VStack(spacing: 8) {
                            Toggle("Preview", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.preview)
                            Toggle("Reduced", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.reduced)
                            Toggle("Medium", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.medium)
                            Toggle("Full", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.full)
                            Toggle("Raw", isOn: $appDataModel.detailLevelOptionsUnderAdvancedMenu.raw)
                        }
                        .toggleStyle(.switch)
                        .tint(.blue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 450)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
        .onChange(of: appDataModel.sessionConfiguration.customDetailSpecification) {
            // The polygon count and the texture resolution only take effect at the custom detail level.
            if appDataModel.sessionConfiguration.customDetailSpecification != PhotogrammetrySession.Configuration.CustomDetailSpecification() {
                appDataModel.detailLevelOptionUnderQualityMenu = .custom
            }
        }
    }
}

struct ProcessButton: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var processing = false
    @State private var isHovered = false
    
    var body: some View {
        Button {
            if !processing {
                processing = true
                Task {
                    await appDataModel.startReconstruction()
                    processing = false
                }
            }
        } label: {
            HStack(spacing: 14) {
                if processing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Text(processing ? "Processing..." : "Generate 3D Model")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                
                if !processing {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: processing ? [Color.gray.opacity(0.6), Color.gray.opacity(0.8)] : [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    
                    if !processing && isHovered {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.1))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: processing ? .clear : .blue.opacity(0.5), radius: 20, x: 0, y: 10)
            .scaleEffect(isHovered && !processing ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(processing || !canProcess)
        .opacity(canProcess ? 1.0 : 0.5)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
    
    private var canProcess: Bool {
        appDataModel.imageFolder != nil &&
        appDataModel.modelName != nil &&
        appDataModel.modelFolder != nil
    }
}

// MARK: - Processing View
struct EnhancedProcessingView: View {
    @State private var processedRequestsDetailLevel: [String] = []
    @State private var firstModelFileURL: URL?
    @State private var showExportOptions = false
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.06),
                    Color(red: 0.06, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                if appDataModel.state == .viewing {
                    EnhancedTopBarView(processedRequestsDetailLevel: processedRequestsDetailLevel)
                        .padding(28)
                }
                
                ZStack {
                    EnhancedModelView(url: firstModelFileURL)
                    
                    if appDataModel.state == .viewing, firstModelFileURL != nil {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    showExportOptions = true
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "square.and.arrow.down.fill")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                        Text("Export Model")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 16)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.blue, Color.purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(14)
                                    .shadow(color: .blue.opacity(0.5), radius: 15, x: 0, y: 8)
                                }
                                .buttonStyle(.plain)
                                .padding(36)
                            }
                        }
                    }
                }
                
                EnhancedBottomBarView(
                    firstModelFileURL: $firstModelFileURL,
                    processedRequestsDetailLevel: $processedRequestsDetailLevel
                )
                .padding(28)
            }
            
            if showExportOptions {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showExportOptions = false
                        }
                    }
                
                ExportOptionsSheet(isPresented: $showExportOptions, modelURL: firstModelFileURL)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showExportOptions)
    }
}

struct EnhancedModelView: View {
    let url: URL?
    
    var body: some View {
        ZStack {
            if let url {
                RealityView { content in
                    do {
                        let entity = try await ModelEntity(contentsOf: url)
                        content.add(entity)
                        content.cameraTarget = entity
                    } catch {
                        logger.warning("Couldn't load the model: \(error)")
                    }
                }
                .realityViewCameraControls(.orbit)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.02, blue: 0.05),
                            Color(red: 0.04, green: 0.04, blue: 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else {
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 160, height: 160)
                            .blur(radius: 40)
                        
                        Image(systemName: "cube.transparent")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    VStack(spacing: 8) {
                        Text("Creating Your 3D Model")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("This may take several minutes")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(1.2)
                }
            }
        }
    }
}

struct EnhancedTopBarView: View {
    let processedRequestsDetailLevel: [String]
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var isHovered = false
    
    var body: some View {
        GlassCard(prominent: true) {
            HStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(detailLevels)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text(appDataModel.modelFolder?.lastPathComponent ?? "")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Button {
                    Task {
                        await openInFinder(url: appDataModel.modelFolder!)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Open in Finder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.blue.opacity(isHovered ? 0.28 : 0.18))
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovered = hovering
                }
            }
            .padding(20)
        }
    }
    
    private var detailLevels: String {
        var message = ""
        for (index, detailLevel) in processedRequestsDetailLevel.enumerated() {
            message.append(detailLevel.capitalized)
            if index == processedRequestsDetailLevel.count - 1 {
                message.append(processedRequestsDetailLevel.count > 1 ? " models saved" : " model saved")
            } else {
                message.append(", ")
            }
        }
        return message
    }
    
    private nonisolated func openInFinder(url: URL) async {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
    }
}

struct EnhancedBottomBarView: View {
    @Binding var firstModelFileURL: URL?
    @Binding var processedRequestsDetailLevel: [String]
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var processingComplete = false
    @State private var firstImageURL: URL?
    
    var body: some View {
        GlassCard(prominent: true) {
            if processingComplete {
                HStack(spacing: 20) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All Models Completed")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                        Text("Your 3D models are ready")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    Button("Create New Model") {
                        appDataModel.state = .ready
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .padding(20)
            } else {
                HStack(spacing: 20) {
                    if let firstImageURL {
                        ThumbnailView(imageFolderURL: firstImageURL, frameSize: CGSize(width: 70, height: 70))
                    }
                    
                    ReconstructionProgressView(
                        firstModelFileURL: $firstModelFileURL,
                        processedRequestsDetailLevel: $processedRequestsDetailLevel,
                        processingComplete: $processingComplete
                    )
                }
                .padding(20)
            }
        }
        .task(id: appDataModel.imageFolder) {
            // Look up the image once instead of listing the folder on every progress update.
            firstImageURL = ImageHelper.getListOfURLs(from: appDataModel.imageFolder).first
        }
    }
}


struct ReconstructionProgressView: View {
    @Binding var firstModelFileURL: URL?
    @Binding var processedRequestsDetailLevel: [String]
    @Binding var processingComplete: Bool

    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var progress = 0.0
    @State private var estimatedRemainingTime: TimeInterval?
    @State private var currentRequestDetailLevel: PhotogrammetrySession.Request.Detail?
    @State private var isCancelling = false
    @State private var numProcessedModels = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusMessage)
                .foregroundColor(.white)

            HStack(spacing: 12) {
                if appDataModel.session != nil {
                    ProgressView(value: progress)
                        .frame(maxWidth: 400)
                        .tint(.blue)
                        .task {
                            await getSessionOutput()
                        }
                } else {
                    ProgressView(value: 0)
                        .frame(maxWidth: 400)
                        .tint(.blue)
                }

                Button {
                    logger.log("Cancel button is clicked!")
                    isCancelling = true
                    if let session = appDataModel.session {
                        logger.log("Cancelling the session...")
                        session.cancel()
                    } else {
                        logger.log("Canceled the session before processing has started. Going back to the settings view...")
                        appDataModel.state = .ready
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Cancel")
                .disabled(isCancelling)
            }

            HStack {
                Text(formattedEstimatedRemainingTime)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Text("Model \(min(numProcessedModels, appDataModel.numRequestedModels)) of \(appDataModel.numRequestedModels)")
                    .foregroundColor(.white.opacity(0.8))
            }
            .font(.caption)
        }
    }

    private var statusMessage: String {
        guard appDataModel.session != nil, let currentRequestDetailLevel = currentRequestDetailLevel else { return "Preparing images..." }
        let detailLevel = "\(String(describing: currentRequestDetailLevel))".capitalized
        return "Creating \(detailLevel) 3D Model..."
    }

    private var formattedEstimatedRemainingTime: String {
        let calculating = "Calculating..."
        guard let estimatedRemainingTime = estimatedRemainingTime else { return calculating }

        if let estimatedRemainingTime = Self.remainingTimeFormatter.string(from: estimatedRemainingTime) {
            return "About " + estimatedRemainingTime + " remaining"
        } else {
            return calculating
        }
    }

    private static let remainingTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.minute, .second]
        return formatter
    }()

    func getSessionOutput() async {
        do {
            guard let session = appDataModel.session else { return }
            for try await output in session.outputs {
                switch output {
                case .requestProgress(let request, let fractionComplete):
                    requestProgress(request: request, fractionComplete: fractionComplete)

                case .requestProgressInfo(_, let progressInfo):
                    estimatedRemainingTime = progressInfo.estimatedRemainingTime

                case .requestError(_, let error):
                    logger.log("requestError received: \(error)")

                    if isCancelling {
                        appDataModel.alertMessage = ""
                        appDataModel.state = .ready
                    } else {
                        appDataModel.alertMessage = "Reconstruction Failed\n\(AppDataModel.message(for: error))"
                        appDataModel.state = .error
                    }
                    return

                case .requestComplete(let request, _):
                    logger.log("requestComplete received: \(String(describing: output))")
                    requestComplete(request: request)

                case .processingComplete:
                    logger.log("processingComplete received")

                    if appDataModel.state != .error {
                        processingComplete = true
                    }

                case .processingCancelled:
                    logger.log("processingCancelled received")
                    appDataModel.state = .ready
                    return

                case .invalidSample(let id, let reason):
                    logger.warning("Invalid sample \(id): \(reason)")

                case .skippedSample(let id):
                    logger.warning("Skipped sample \(id)")

                default:
                    continue
                }
            }
        } catch is CancellationError {
            logger.log("Getting output was canceled.")
        } catch {
            logger.error("Getting output failed with \(error)")
            appDataModel.alertMessage = "Reconstruction Failed\n\(AppDataModel.message(for: error))"
            appDataModel.state = .error
        }
    }

    // MARK: - helper functions
    func requestProgress(request: PhotogrammetrySession.Request, fractionComplete: Double) {
        progress = fractionComplete

        if case .modelFile(_, let detail, _) = request, currentRequestDetailLevel != detail {
            currentRequestDetailLevel = detail
        }
    }

    func requestComplete(request: PhotogrammetrySession.Request) {
        if case .modelFile(let url, let detail, _) = request {
            processedRequestsDetailLevel.append("\(detail)")
            if firstModelFileURL == nil {
                firstModelFileURL = url
            }
            numProcessedModels += 1

            // Update the app's state to show the model after completing the first request.
            appDataModel.state = .viewing
        }
    }
}


// MARK: - Export Sheet
struct ExportOptionsSheet: View {
    @Binding var isPresented: Bool
    let modelURL: URL?
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    @State private var selectedFormat: AppDataModel.ExportFormat = .usdz
    @State private var isExporting = false
    @State private var showFileExporter = false
    @State private var exportDocument: ModelDocument?
    @State private var exportError: String?
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 28) {
                // Handle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 50, height: 6)
                    .padding(.top, 16)
                
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .blur(radius: 20)
                        
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    VStack(spacing: 6) {
                        Text("Export 3D Model")
                            .font(.system(size: 28, weight: .black))
                            .foregroundColor(.white)
                        
                        Text("Choose your preferred format for export")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .padding(.top, 12)
                
                // Format Grid
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(AppDataModel.ExportFormat.allCases) { format in
                            FormatOptionCard(
                                format: format,
                                isSelected: selectedFormat == format
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedFormat = format
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .frame(maxHeight: 320)
                
                // Export Button
                Button {
                    exportModel()
                } label: {
                    HStack(spacing: 12) {
                        if isExporting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.9)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        Text(isExporting ? "Exporting..." : "Export as \(selectedFormat.rawValue)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: isExporting ? [Color.gray, Color.gray.opacity(0.85)] : [Color.blue, Color.purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .shadow(color: isExporting ? .clear : .blue.opacity(0.4), radius: 20, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                .padding(.horizontal, 28)
                
                // Cancel Button
                Button("Cancel") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isPresented = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .padding(.bottom, 8)
            }
            .padding(.bottom, 36)
            .background(
                RoundedRectangle(cornerRadius: 32)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.14, blue: 0.18),
                                Color(red: 0.10, green: 0.10, blue: 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 32)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: -15)
            )
        }
        .alert("Export Error", isPresented: $showError) {
            Button("OK") {
                exportError = nil
            }
        } message: {
            if let exportError = exportError {
                Text(exportError).foregroundColor(.white)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: exportDocument?.isFolder == true ? .folder : .data,
            defaultFilename: exportFilename
        ) { result in
            handleExport(result)
        }
    }
    
    // Formats that write several files, like OBJ with its material and textures, export as a folder.
    private var exportFilename: String {
        let name = appDataModel.modelName ?? "model"
        let fileExtension = selectedFormat.fileExtension
        return exportDocument?.isFolder == true ? "\(name)-\(fileExtension)" : "\(name).\(fileExtension)"
    }
    
    private func exportModel() {
        guard let modelURL = modelURL else { return }
        
        isExporting = true
        exportDocument?.cleanUp()
        exportDocument = nil
        appDataModel.selectedExportFormat = selectedFormat
        
        let format = selectedFormat
        let name = appDataModel.modelName ?? "model"
        Task {
            do {
                exportDocument = try await ModelExporter.makeDocument(from: modelURL, format: format, name: name)
                showFileExporter = true
            } catch {
                exportError = "Conversion failed: \(error.localizedDescription)"
                showError = true
            }
            isExporting = false
        }
    }
    
    private func handleExport(_ result: Result<URL, Error>) {
        exportDocument?.cleanUp()
        exportDocument = nil
        
        switch result {
        case .success(let url):
            logger.log("Model exported as \(selectedFormat.rawValue) to \(url.lastPathComponent)")
            isPresented = false
        case .failure(let error):
            // Keep the sheet open so the alert has a view to present from.
            exportError = "Export failed: \(error.localizedDescription)"
            showError = true
        }
    }
}

// Converts the reconstructed USDZ file into the other export formats, off the main actor.
enum ModelExporter {
    enum ExportError: LocalizedError {
        case unsupportedFormat(String)
        case emptyModel
        case writeFailed
        
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format): return "\(format) export is not supported on this Mac."
            case .emptyModel: return "The model file doesn't contain any geometry."
            case .writeFailed: return "The converted model couldn't be written."
            }
        }
    }
    
    static func makeDocument(from sourceURL: URL, format: AppDataModel.ExportFormat, name: String) async throws -> ModelDocument {
        if format == .usdz {
            return ModelDocument(fileURLs: [sourceURL], temporaryDirectory: nil)
        }
        
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "\(name).\(format.fileExtension)")
        
        do {
            if format == .dae {
                // Model I/O can't write COLLADA, but SceneKit can.
                let scene = try SCNScene(url: sourceURL)
                guard scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil) else {
                    throw ExportError.writeFailed
                }
            } else {
                guard MDLAsset.canExportFileExtension(format.fileExtension) else {
                    throw ExportError.unsupportedFormat(format.rawValue)
                }
                // Export the whole asset to keep the transform hierarchy and the materials.
                let asset = MDLAsset(url: sourceURL)
                guard asset.count > 0 else { throw ExportError.emptyModel }
                asset.loadTextures()
                try asset.export(to: outputURL)
            }
            
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard !fileURLs.isEmpty else { throw ExportError.writeFailed }
            return ModelDocument(fileURLs: fileURLs, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct FormatOptionCard: View {
    let format: AppDataModel.ExportFormat
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isSelected ? [Color.blue.opacity(0.3), Color.purple.opacity(0.2)] : [Color.white.opacity(0.05), Color.white.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: format.icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(
                            isSelected ?
                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
                
                VStack(spacing: 6) {
                    Text(format.rawValue)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(format.description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                if isSelected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Selected")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.25))
                    )
                }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        isSelected || isHovered ?
                        Color.white.opacity(0.10) :
                        Color.white.opacity(0.04)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                isSelected ?
                                LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing) :
                                LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .scaleEffect(isSelected || isHovered ? 1.02 : 1.0)
            .shadow(color: isSelected ? .blue.opacity(0.3) : .clear, radius: 15, x: 0, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct ModelDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .folder] }
    
    let fileURLs: [URL]
    // The folder to remove after exporting converted files.
    let temporaryDirectory: URL?
    
    var isFolder: Bool { fileURLs.count > 1 }
    
    init(fileURLs: [URL], temporaryDirectory: URL?) {
        self.fileURLs = fileURLs
        self.temporaryDirectory = temporaryDirectory
    }
    
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if fileURLs.count == 1, let fileURL = fileURLs.first {
            return try FileWrapper(url: fileURL, options: .immediate)
        }
        var fileWrappers: [String: FileWrapper] = [:]
        for fileURL in fileURLs {
            fileWrappers[fileURL.lastPathComponent] = try FileWrapper(url: fileURL, options: .immediate)
        }
        return FileWrapper(directoryWithFileWrappers: fileWrappers)
    }
    
    func cleanUp() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

// MARK: - Developers View
struct DevelopersView: View {
    @Environment(AppDataModel.self) private var appDataModel: AppDataModel
    
    private var jsonExamplePayload: String {
        // Build a JSON example reflecting current configuration
        var levels: [String] = []
        if appDataModel.detailLevelOptionsUnderAdvancedMenu.isSelected {
            if appDataModel.detailLevelOptionsUnderAdvancedMenu.preview { levels.append("preview") }
            if appDataModel.detailLevelOptionsUnderAdvancedMenu.reduced { levels.append("reduced") }
            if appDataModel.detailLevelOptionsUnderAdvancedMenu.medium { levels.append("medium") }
            if appDataModel.detailLevelOptionsUnderAdvancedMenu.full { levels.append("full") }
            if appDataModel.detailLevelOptionsUnderAdvancedMenu.raw { levels.append("raw") }
        } else {
            levels = ["\(appDataModel.detailLevelOptionUnderQualityMenu)"]
        }
        
        let mesh = appDataModel.sessionConfiguration.meshPrimitive == .quad ? "quad" : "triangle"
        let mask = appDataModel.sessionConfiguration.isObjectMaskingEnabled
        let ignoreBB = appDataModel.sessionConfiguration.ignoreBoundingBox
        let poly = appDataModel.sessionConfiguration.customDetailSpecification.maximumPolygonCount
        let texDim = appDataModel.sessionConfiguration.customDetailSpecification.maximumTextureDimension
        
        let textureString: String = {
            switch texDim {
            case .oneK: return "1K"
            case .twoK: return "2K"
            case .fourK: return "4K"
            case .eightK: return "8K"
            case .sixteenK: return "16K"
            @unknown default: return "unknown"
            }
        }()
        
        let name = appDataModel.modelName ?? "model"
        let exportFmt = appDataModel.selectedExportFormat.fileExtension
        
        let dict: [String: Any] = [
            "modelName": name,
            "detailLevels": levels,
            "meshPrimitive": mesh,
            "isObjectMaskingEnabled": mask,
            "ignoreBoundingBox": ignoreBB,
            "customDetailSpecification": [
                "maximumPolygonCount": poly,
                "maximumTextureDimension": textureString
            ],
            "exportFormat": exportFmt
        ]
        
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("For developers")
                    .font(.system(size: 36, weight: .black))
                    .foregroundColor(.white)
                
                Text("HTTP API to submit images, receive live progress, and download the final 3D model. The payload mirrors the options you configure in this app.")
                    .foregroundColor(.white.opacity(0.8))
                
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "1) Create Model", icon: "square.and.arrow.up.on.square.fill", subtitle: "POST /models")
                        Text("Multipart form-data request to upload images and parameters.")
                            .foregroundColor(.white.opacity(0.8))
                        
                        Group {
                            Text("Endpoint")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("POST https://your.api.server/models")
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("Content-Type")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("multipart/form-data; boundary=…")
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("Parts")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("""
                            images[]: one or more files (heic, jpg, jpeg, png)
                            metadata: application/json; charset=utf-8
                            """)
                            .foregroundColor(.white.opacity(0.9))
                            
                            Text("metadata JSON example")
                                .font(.headline)
                                .foregroundColor(.white)
                            ScrollView(.horizontal) {
                                Text(jsonExamplePayload)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(20)
                }
                
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "2) Progress Stream", icon: "dot.radiowaves.left.and.right", subtitle: "GET /models/{id}/stream")
                        Text("Receive live status updates while reconstruction runs. Recommended transport: Server-Sent Events (SSE).")
                            .foregroundColor(.white.opacity(0.8))
                        Group {
                            Text("Endpoint")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("GET https://your.api.server/models/{id}/stream")
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("SSE event fields")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("""
                            event: progress
                            data: { "fractionComplete": 0.42, "estimatedRemainingTime": 123.0, "detailLevel": "medium" }

                            event: complete
                            data: { "downloadURL": "https://.../models/{id}/download?format=usdz" }

                            event: error
                            data: { "message": "Reconstruction Failed" }
                            """)
                            .foregroundColor(.white.opacity(0.9))
                            .font(.system(.footnote, design: .monospaced))
                        }
                    }
                    .padding(20)
                }
                
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "3) Download Model", icon: "square.and.arrow.down.fill", subtitle: "GET /models/{id}/download")
                        Text("Download the final 3D model in the requested format.")
                            .foregroundColor(.white.opacity(0.8))
                        Group {
                            Text("Endpoint")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("GET https://your.api.server/models/{id}/download?format=usdz")
                                .foregroundColor(.white.opacity(0.9))
                            
                            Text("Query")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("""
                            format: One of \(AppDataModel.ExportFormat.allCases.map { $0.fileExtension }.joined(separator: ", "))
                            """)
                            .foregroundColor(.white.opacity(0.9))
                            
                            Text("Response")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("application/octet-stream (model file bytes)")
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .padding(20)
                }
                
                Text("Tip: mirror the exact parameter names shown above so your server can map them directly to your reconstruction pipeline.")
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(28)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.08),
                    Color(red: 0.08, green: 0.08, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("API Documentation")
    }
}
