import AppKit
import WinnowCore
import SwiftUI

/// Folders to work in: add with a button or by dragging folders onto the list.
struct FolderList: View {
    @Binding var folders: [String]
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(folders, id: \.self) { path in
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Paths.displayName(path)).fontWeight(.medium)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { folders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(L("Remove this location"))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            HStack {
                Button { choose() } label: { Label(L("Add Location…"), systemImage: "plus") }
                    .buttonStyle(.link)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let path = url.standardizedFileURL.path
            if !folders.contains(path) { folders.append(path) }
        }
    }
}
