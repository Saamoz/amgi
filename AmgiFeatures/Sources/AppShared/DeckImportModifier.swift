//
//  DeckImportModifier.swift
//  AppShared
//
//  Created by Vladimir Gusev on 13.06.2026.
//

public import SwiftUI
import Theme
import UniformTypeIdentifiers

private struct DeckImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var openedFile: URL?
    let onRefresh: () -> Void

    @State private var status: ImportStatusBanner.Status?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data]) { result in
                handleImport(result)
            }
            .onChange(of: openedFile, initial: true) { _, url in
                guard let url else { return }
                openedFile = nil
                handleImport(.success(url))
            }
            .overlay(alignment: .top) { ImportStatusBanner(status: status) }
            .animation(AmgiMotion.momentum, value: status)
            .alert(
                "Couldn't import deck",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

}

private extension DeckImportModifier {
    func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let ext = url.pathExtension.lowercased()
            guard ext == "apkg" || ext == "colpkg" else {
                failure = "Unsupported file type. Please select an .apkg or .colpkg file."
                return
            }
            Task {
                status = .importing(fileName: url.lastPathComponent)
                do {
                    let summary = try await ImportHelper.importPackage(from: url)
                    onRefresh()
                    status = .finished(summary: summary)
                    try? await Task.sleep(for: .seconds(3))
                    status = nil
                } catch {
                    status = nil
                    failure = error.localizedDescription
                }
            }
        case .failure(let error):
            failure = "Could not select file: \(error.localizedDescription)"
        }
    }
}

extension View {
    public func deckImport(isPresented: Binding<Bool>, onRefresh: @escaping () -> Void) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented, openedFile: .constant(nil), onRefresh: onRefresh))
    }

    /// Also imports `openedFile` when it is set: an .apkg or .colpkg opened
    /// in Amgi from Files or the share sheet.
    public func deckImport(
        isPresented: Binding<Bool>,
        openedFile: Binding<URL?>,
        onRefresh: @escaping () -> Void
    ) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented, openedFile: openedFile, onRefresh: onRefresh))
    }
}
