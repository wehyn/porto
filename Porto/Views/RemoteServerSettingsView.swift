import SwiftUI
import UniformTypeIdentifiers

struct RemoteServerSettingsView: View {
    @ObservedObject var monitor: PortMonitor
    private let discovery: any SSHHostCandidateDiscovering
    @State private var showingPicker = false
    @State private var openManualEditorAfterPickerDismiss = false
    @State private var editorProfile: RemoteServerProfile?
    @State private var profileToDelete: RemoteServerProfile?

    init(monitor: PortMonitor, discovery: any SSHHostCandidateDiscovering = LocalSSHHostCandidateDiscovery()) {
        self.monitor = monitor
        self.discovery = discovery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Servers").font(.title2.weight(.semibold))
                    Text("Saved profiles are used only when you select them in the Porto menu.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingPicker = true
                } label: {
                    Label("Add SSH Connection", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            .padding(24)

            Divider()

            if monitor.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Remote Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server profile to make it available in the Porto menu.")
                } actions: {
                    Button("Add SSH Connection") {
                        showingPicker = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(monitor.profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 380, idealHeight: 460)
        .onAppear { monitor.refreshProfiles() }
        .sheet(isPresented: $showingPicker, onDismiss: openManualEditorIfRequested) {
            SSHConnectionPicker(monitor: monitor, discovery: discovery) {
                openManualEditorAfterPickerDismiss = true
                showingPicker = false
            }
        }
        .sheet(item: $editorProfile) { profile in
            RemoteServerProfileEditor(monitor: monitor, profile: profile) {
                editorProfile = nil
            }
        }
        .confirmationDialog(
            "Delete remote server?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profile = profileToDelete {
                Button("Delete \(profile.displayName)", role: .destructive) {
                    monitor.deleteProfile(id: profile.id)
                    profileToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: {
            if let profile = profileToDelete {
                Text("This removes the saved profile for \(profile.host). It does not affect the remote server.")
            }
        }
    }

    private func openManualEditorIfRequested() {
        guard openManualEditorAfterPickerDismiss else { return }
        openManualEditorAfterPickerDismiss = false
        editorProfile = RemoteServerProfile(displayName: "", host: "", username: "")
    }

    private func profileRow(_ profile: RemoteServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(profile.isEnabled ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName).font(.body.weight(.medium))
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(profile.identityFilePath == nil ? "No private key selected" : "Private key selected")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Enabled", isOn: enabledBinding(for: profile))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(profile.isEnabled ? "Disable \(profile.displayName)" : "Enable \(profile.displayName)")
            Button("Edit") { editorProfile = profile }
                .buttonStyle(.borderless)
            Button("Delete", systemImage: "trash") { profileToDelete = profile }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel("Delete \(profile.displayName)")
                .help("Delete \(profile.displayName)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profileSummary(profile))
    }

    private func enabledBinding(for profile: RemoteServerProfile) -> Binding<Bool> {
        Binding(
            get: { profile.isEnabled },
            set: { enabled in
                do { try monitor.setProfileEnabled(id: profile.id, enabled: enabled) }
                catch { /* Store validation is unchanged by this toggle. */ }
            }
        )
    }

    private func profileSummary(_ profile: RemoteServerProfile) -> String {
        let state = profile.isEnabled ? "enabled" : "disabled"
        let key = profile.identityFilePath == nil ? "no private key" : "private key selected"
        return "\(profile.displayName), \(profile.username) at \(profile.host), port \(profile.port), \(key), \(state)"
    }
}

protocol SSHHostCandidateDiscovering: Sendable {
    func load() -> [SSHHostCandidate]
}

struct LocalSSHHostCandidateDiscovery: SSHHostCandidateDiscovering, Sendable {
    func load() -> [SSHHostCandidate] {
        SSHHostCatalog().load().candidates
    }
}

struct SSHConnectionImportPlanner: Sendable {
    static func profiles(
        from candidates: [SSHHostCandidate],
        selectedIDs: Set<String>,
        existingProfiles: [RemoteServerProfile]
    ) -> [RemoteServerProfile] {
        var names = Set(existingProfiles.map { folded($0.displayName) })
        var imported: [RemoteServerProfile] = []
        for candidate in candidates where selectedIDs.contains(candidate.id) {
            let name = candidate.displayID
            guard !names.contains(folded(name)) else { continue }
            imported.append(RemoteServerProfile(
                displayName: name,
                host: candidate.host,
                username: candidate.username,
                port: candidate.port,
                identityFilePath: candidate.identityFilePath,
                isEnabled: false
            ))
            names.insert(folded(name))
        }
        return imported
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

private struct SSHConnectionPicker: View {
    @ObservedObject var monitor: PortMonitor
    let discovery: any SSHHostCandidateDiscovering
    let onAddManually: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SSHHostCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add SSH Connection").font(.title2.weight(.semibold))
                    Text("Choose a connection detected in your local SSH configuration.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close")
            }

            if isLoading {
                ProgressView("Looking for local SSH connections…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if candidates.isEmpty {
                ContentUnavailableView("No SSH connections detected", systemImage: "server.rack")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                List(candidates) { candidate in
                    Button { toggle(candidate) } label: { candidateRow(candidate) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(candidate.displayID), \(candidate.host), \(selectedIDs.contains(candidate.id) ? "selected" : "not selected")")
                }
                .listStyle(.inset)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button { loadCandidates() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh detected SSH connections")
                .accessibilityLabel("Refresh detected SSH connections")
                .disabled(isLoading)
                Button("Add manually") { onAddManually() }
                    .buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 540)
        .frame(minHeight: 360)
        .onAppear { loadCandidates() }
    }

    private func candidateRow(_ candidate: SSHHostCandidate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayID).font(.body.weight(.medium))
                Text(candidate.addressLabel)
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIDs.contains(candidate.id) ? Color.accentColor : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
    }

    private func toggle(_ candidate: SSHHostCandidate) {
        if selectedIDs.contains(candidate.id) { selectedIDs.remove(candidate.id) }
        else { selectedIDs.insert(candidate.id) }
    }

    private func loadCandidates() {
        isLoading = true
        statusMessage = nil
        Task { @MainActor in
            let found = discovery.load()
            guard !Task.isCancelled else { return }
            candidates = found
            selectedIDs.formIntersection(Set(found.map(\.id)))
            isLoading = false
        }
    }

    private func addSelected() {
        let imports = SSHConnectionImportPlanner.profiles(
            from: candidates, selectedIDs: selectedIDs, existingProfiles: monitor.profiles)
        let selectedCount = candidates.filter { selectedIDs.contains($0.id) }.count
        var saved = 0
        for profile in imports {
            do { try monitor.saveProfile(profile); saved += 1 }
            catch { statusMessage = "Some selected connections could not be added." }
        }
        if saved < selectedCount && statusMessage == nil {
            statusMessage = "Some selected connections were already added."
        }
        guard saved == selectedCount else {
            monitor.refreshProfiles()
            return
        }
        monitor.refreshProfiles()
        dismiss()
    }
}

private struct RemoteServerProfileEditor: View {
    @ObservedObject var monitor: PortMonitor
    @State private var draft: RemoteServerProfile
    private let isNew: Bool
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var validationMessage: String?
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?

    init(monitor: PortMonitor, profile: RemoteServerProfile, onDone: @escaping () -> Void) {
        self.monitor = monitor
        _draft = State(initialValue: profile)
        isNew = profile.displayName.isEmpty && profile.host.isEmpty && profile.username.isEmpty
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Add SSH Connection" : "Edit SSH Connection")
                .font(.title2.weight(.semibold))
            Form {
                TextField("ID / Display name", text: $draft.displayName)
                TextField("Host", text: $draft.host)
                TextField("Username", text: $draft.username)
                HStack {
                    TextField("Port", value: $draft.port, format: .number)
                        .frame(width: 100)
                    Spacer()
                    Toggle("Enabled", isOn: $draft.isEnabled)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.identityFilePath ?? "No private key selected")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(draft.identityFilePath == nil ? .secondary : .primary)
                        Text("Only the file path is stored; the key is never read or copied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { showingImporter = true }
                    if draft.identityFilePath != nil {
                        Button("Clear") { draft.identityFilePath = nil }
                    }
                }
            }
            .disabled(isTesting)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let testMessage {
                Label(testMessage, systemImage: testMessage == "Connection succeeded." ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(testMessage == "Connection succeeded." ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(!draft.isEnabled || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { close() }
                Button(isNew ? "Add" : "Save") { save() }
                    .disabled(isTesting)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): draft.identityFilePath = urls.first?.path
            case .failure: validationMessage = "The private key could not be selected."
            }
        }
        .onDisappear {
            cancelTest()
            testMessage = nil
        }
    }

    private func save() {
        do {
            try monitor.saveProfile(draft)
            close()
        } catch let error as RemoteServerProfileValidationError {
            validationMessage = error.userMessage
        } catch {
            validationMessage = "The profile could not be saved."
        }
    }

    private func testConnection() {
        testMessage = nil
        isTesting = true
        let profile = draft
        testTask = Task { @MainActor in
            let result = await monitor.testConnection(for: profile)
            guard !Task.isCancelled else { return }
            isTesting = false
            testTask = nil
            switch result {
            case .success: testMessage = "Connection succeeded."
            case .refusedDisabled: testMessage = "Enable this profile to test its connection."
            case .failed(let failure): testMessage = failure.userMessage.isEmpty ? "Connection test was cancelled." : failure.userMessage
            }
        }
    }

    private func close() {
        cancelTest()
        dismiss()
        onDone()
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }
}
