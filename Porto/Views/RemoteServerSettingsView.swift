import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteServerSettingsView: View {
    @ObservedObject var monitor: PortMonitor
    private let discovery: any SSHHostCandidateDiscovering
    @State private var showingPicker = false
    @State private var openManualEditorAfterPickerDismiss = false
    @State private var editorProfile: RemoteServerProfile?
    @State private var profileToDelete: RemoteServerProfile?
    @State private var testingProfileID: UUID?
    @State private var capabilityMessages: [UUID: String] = [:]
    @State private var profileTestTask: Task<Void, Never>?
    @State private var profileTestToken: UUID?

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
        .onAppear {
            monitor.refreshProfiles()
            SettingsWindowPresenter.bringToFront()
        }
        .onDisappear {
            profileTestTask?.cancel()
            profileTestTask = nil
            profileTestToken = nil
            testingProfileID = nil
        }
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
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName).font(.body.weight(.medium))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    Toggle(isOn: enabledBinding(for: profile)) {
                        EmptyView()
                    }
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(testingProfileID == profile.id)
                        .accessibilityLabel("\(profile.isEnabled ? "Disable" : "Enable") \(profile.displayName)")

                    Button {
                        testConnection(profile)
                    } label: {
                        if testingProfileID == profile.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(testingProfileID != nil || !profile.isEnabled)
                    .accessibilityLabel("Test connection to \(profile.displayName)")
                    .help(profile.isEnabled ? "Test the SSH connection and port inspection capability" : "Enable this profile before testing")

                    Menu {
                        Button("Edit") { editorProfile = profile }
                        Divider()
                        Button("Delete", role: .destructive) { profileToDelete = profile }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Actions for \(profile.displayName)")
                    .help("Edit or delete \(profile.displayName)")
                }
                if let message = capabilityMessages[profile.id] {
                    connectionTestIndicator(message)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profileSummary(profile))
    }

    private func enabledBinding(for profile: RemoteServerProfile) -> Binding<Bool> {
        Binding(
            get: { profile.isEnabled },
            set: { setEnabled(profile, enabled: $0) }
        )
    }

    private func setEnabled(_ profile: RemoteServerProfile, enabled: Bool) {
        do { try monitor.setProfileEnabled(id: profile.id, enabled: enabled) }
        catch { capabilityMessages[profile.id] = "The profile could not be updated." }
    }

    private func testConnection(_ profile: RemoteServerProfile) {
        capabilityMessages[profile.id] = nil
        testingProfileID = profile.id
        profileTestTask?.cancel()
        let testToken = UUID()
        profileTestToken = testToken
        profileTestTask = Task { @MainActor in
            let result = await monitor.testConnection(for: profile)
            guard !Task.isCancelled, profileTestToken == testToken else { return }
            testingProfileID = nil
            profileTestTask = nil
            profileTestToken = nil
            switch result {
            case .success:
                capabilityMessages[profile.id] = "Connection verified · port inspection available"
            case .refusedDisabled:
                capabilityMessages[profile.id] = "Enable this profile to test its connection."
            case .failed(let failure):
                capabilityMessages[profile.id] = failure.userMessage.isEmpty ? "Connection test was cancelled." : failure.userMessage
            }
        }
    }

    private func connectionTestIndicator(_ message: String) -> some View {
        let succeeded = message.hasPrefix("Connection verified")
        return Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(succeeded ? Color.green : Color.orange)
            .accessibilityLabel(message)
            .help(message)
    }

    private func profileSummary(_ profile: RemoteServerProfile) -> String {
        let state = profile.isEnabled ? "enabled" : "disabled"
        let key = profile.identityFilePath == nil ? nil : "private key selected"
        let details = [profile.sshAddress, "port \(profile.port)", key, state]
            .compactMap { $0 }
            .joined(separator: ", ")
        return "\(profile.displayName), \(details)"
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
    @State private var testToken: UUID?
    @State private var hostnameEntry: String

    init(monitor: PortMonitor, profile: RemoteServerProfile, onDone: @escaping () -> Void) {
        self.monitor = monitor
        _draft = State(initialValue: profile)
        _hostnameEntry = State(initialValue: profile.sshAddress)
        isNew = profile.displayName.isEmpty && profile.host.isEmpty && profile.username.isEmpty
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Add SSH Connection" : "Edit SSH Connection")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Display name", text: $draft.displayName)
                TextField("Hostname", text: $hostnameEntry, prompt: Text("user@hostname"))
                    .help("Enter a username and host, for example dei@192.168.2.28")
                TextField("Port", value: $draft.port, format: .number)
                LabeledContent("File path") {
                    HStack {
                        TextField("", text: identityFilePathBinding)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { showingImporter = true }
                        if draft.identityFilePath != nil {
                            Button("Clear") { draft.identityFilePath = nil }
                        }
                    }
                }
                Button("Test Connection") { testConnection() }
                    .disabled(isTesting)
            }
            .disabled(isTesting)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let testMessage {
                let succeeded = testMessage.hasPrefix("Connection verified")
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(succeeded ? Color.green : Color.orange)
                    .accessibilityLabel(testMessage)
                    .help(testMessage)
            }
            HStack {
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
            testToken = nil
            isTesting = false
            testMessage = nil
        }
    }

    private func save() {
        guard let profile = profileUsingHostnameEntry() else {
            validationMessage = "Enter a hostname in the form user@host, for example dei@192.168.2.28."
            return
        }
        do {
            try monitor.saveProfile(profile)
            close()
        } catch let error as RemoteServerProfileValidationError {
            validationMessage = error.userMessage
        } catch {
            validationMessage = "The profile could not be saved."
        }
    }

    private func testConnection() {
        guard let profile = profileUsingHostnameEntry() else {
            validationMessage = "Enter a hostname in the form user@host, for example dei@192.168.2.28."
            return
        }
        validationMessage = nil
        testMessage = nil
        isTesting = true
        let token = UUID()
        testToken = token
        testTask = Task { @MainActor in
            let result = await monitor.testDraftConnection(for: profile)
            guard !Task.isCancelled, testToken == token else { return }
            isTesting = false
            testTask = nil
            testToken = nil
            switch result {
            case .success: testMessage = "Connection verified · port inspection available"
            case .refusedDisabled: testMessage = "Enable this profile to test its connection."
            case .failed(let failure): testMessage = failure.userMessage.isEmpty ? "Connection test was cancelled." : failure.userMessage
            }
        }
    }

    private func profileUsingHostnameEntry() -> RemoteServerProfile? {
        guard let address = RemoteServerProfile.parseSSHAddress(hostnameEntry) else { return nil }
        var profile = draft
        profile.username = address.username
        profile.host = address.host
        return profile
    }

    private var identityFilePathBinding: Binding<String> {
        Binding(
            get: { draft.identityFilePath ?? "" },
            set: { draft.identityFilePath = $0.isEmpty ? nil : $0 }
        )
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
