import SwiftUI

struct RootView: View {
    var sync: SyncManager
    @State private var statusDraft = ""
    @State private var peerDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(sync.myId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    ShareLink(item: sync.myId) {
                        Label("Share my ID", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("My endpoint")
                } footer: {
                    Text("Peers add each other by endpoint id — share yours, paste theirs below. Adding works one-way: the other side learns about you on first contact.")
                }

                Section("My status") {
                    TextField(sync.myStatus.isEmpty ? "What's happening?" : sync.myStatus,
                              text: $statusDraft)
                        .onSubmit { setStatus() }
                    Button("Set status") { setStatus() }
                        .disabled(statusDraft.isEmpty)
                }

                Section("Add peer") {
                    TextField("Peer endpoint id", text: $peerDraft)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        let id = peerDraft
                        peerDraft = ""
                        Task { await sync.addPeer(id) }
                    }
                    .disabled(peerDraft.isEmpty)
                }

                Section("Peers") {
                    if sync.peers.isEmpty {
                        Text("No peers yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sync.peers) { peer in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peer.id.prefix(8) + "…")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(peer.status ?? "(nothing heard yet)")
                                .foregroundStyle(peer.status == nil ? .secondary : .primary)
                            if let seen = peer.lastContact {
                                Text("last contact \(seen.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("StatusBoard")
            .refreshable { await sync.sweep() }
        }
    }

    private func setStatus() {
        let text = statusDraft
        guard !text.isEmpty else { return }
        statusDraft = ""
        Task { await sync.setStatus(text) }
    }
}
