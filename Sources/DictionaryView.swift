import SwiftUI

/// One find→replace rule shown as a row in the dictionary list.
struct DictRule: Identifiable {
    let id = UUID()
    var from: String
    var to: String
}

/// Standalone window for managing the STT correction dictionary.
/// Reads/writes `~/.aloud/dictionary.txt` (same file `CorrectionDictionary` consumes).
struct DictionaryView: View {
    @State private var dictFrom = ""
    @State private var dictTo = ""
    @State private var dictRules: [DictRule] = []
    @State private var dictMsg = ""

    private static var dictPath: String { KeyStore.dir + "/dictionary.txt" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom Dictionary")
                    .font(.title3).bold()

                Text("Words the STT keeps mis-transcribing — enter what it got wrong and what it should be, then press +. Add/remove takes effect instantly.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField("Mis-heard as", text: $dictFrom)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addRule)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    TextField("Replace with", text: $dictTo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addRule)
                    Button(action: addRule) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dictFrom.trimmingCharacters(in: .whitespaces).isEmpty
                              || dictTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if dictRules.isEmpty {
                    Text("No rules yet — try adding e.g.  gamezxz → Gamezxz   ·   bitcoin → Bitcoin   ·   teh → the")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 8).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                } else {
                    VStack(spacing: 4) {
                        ForEach(dictRules) { rule in
                            HStack(spacing: 8) {
                                Text(rule.from).lineLimit(1).truncationMode(.tail)
                                Image(systemName: "arrow.right").foregroundColor(.secondary).font(.caption)
                                Text(rule.to).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    withAnimation { removeRule(rule) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                }

                if !dictMsg.isEmpty { Text(dictMsg).font(.caption) }

                Spacer(minLength: 0)

                Text("File: ~/.aloud/dictionary.txt · edit it directly if you like — changes apply instantly, no restart · start a line with # for a comment")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(20)
        }
        .frame(width: 460, height: 460)
        .onAppear { loadDict() }
    }

    // MARK: - Load / save

    private func loadDict() {
        let raw = (try? String(contentsOfFile: Self.dictPath, encoding: .utf8)) ?? ""
        var rules: [DictRule] = []
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let arrow = trimmed.range(of: "->") else { continue }
            let from = trimmed[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let to   = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if from.isEmpty || to.isEmpty { continue }
            rules.append(DictRule(from: String(from), to: String(to)))
        }
        dictRules = rules
    }

    private func saveDict() {
        let text = dictRules
            .map { "\($0.from) -> \($0.to)" }
            .joined(separator: "\n")
        try? FileManager.default.createDirectory(atPath: KeyStore.dir, withIntermediateDirectories: true)
        try? text.write(toFile: Self.dictPath, atomically: true, encoding: .utf8)
        // อัปเดต mtime ให้ CorrectionDictionary reload ในครั้งถัดไป
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: Self.dictPath)
    }

    private func addRule() {
        let f = dictFrom.trimmingCharacters(in: .whitespaces)
        let t = dictTo.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else {
            flashDict("⚠️ Fill in both fields")
            return
        }
        withAnimation { dictRules.append(DictRule(from: f, to: t)) }
        dictFrom = ""; dictTo = ""
        saveDict()
        flashDict("✅ Added")
    }

    private func removeRule(_ rule: DictRule) {
        dictRules.removeAll { $0.id == rule.id }
        saveDict()
        flashDict("✅ Removed")
    }

    private func flashDict(_ msg: String) {
        dictMsg = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dictMsg = "" }
    }
}
