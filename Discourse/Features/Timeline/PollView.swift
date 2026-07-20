import SwiftUI

/// Inline poll: question, votable options with result bars, end-poll for the author.
struct PollView: View {
    let poll: PollItem
    let message: MessageItem
    let viewModel: TimelineViewModel

    private var showsResults: Bool {
        poll.isDisclosed || poll.isEnded || poll.votedByMe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(poll.question)
                    .font(.body.weight(.semibold))
                    .accessibilityLabel(Text("Poll: \(poll.question)"))
            }

            ForEach(poll.answers) { answer in
                Button {
                    guard !poll.isEnded else { return }
                    viewModel.votePoll(message: message, answerId: answer.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: answer.votedByMe ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(answer.votedByMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(answer.text)
                        Spacer(minLength: 12)
                        if showsResults {
                            Text(String(answer.voteCount))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(alignment: .leading) {
                        if showsResults, poll.totalVotes > 0 {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.tint.opacity(answer.votedByMe ? 0.25 : 0.12))
                                    .frame(width: proxy.size.width
                                        * CGFloat(answer.voteCount) / CGFloat(poll.totalVotes))
                            }
                            .accessibilityHidden(true)
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(poll.isEnded)
                // One spoken element per option: text, then count and voted state.
                .accessibilityLabel(Text(answer.text))
                .accessibilityValue(showsResults
                    ? Text("^[\(answer.voteCount) vote](inflect: true)")
                    : Text(verbatim: ""))
                .accessibilityAddTraits(answer.votedByMe ? .isSelected : [])
            }

            HStack(spacing: 8) {
                // Combine the two status captions into one spoken element.
                HStack(spacing: 8) {
                    if poll.isEnded {
                        Text("Final result — ^[\(poll.totalVotes) vote](inflect: true)")
                    } else {
                        Text("^[\(poll.totalVotes) vote](inflect: true)")
                    }
                    if !showsResults {
                        Text("Results shown when the poll ends")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityElement(children: .combine)
                Spacer()
                if message.isOwn && !poll.isEnded {
                    Button("End Poll") {
                        viewModel.endPoll(message: message)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 380)
        // 0.35, not 0.5: option chips (0.5) stack on this, and 0.5 here would
        // double-darken every nested row.
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Poll composer sheet.
struct NewPollSheet: View {
    let viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var answers: [String] = ["", ""]
    @State private var disclosed = true
    @State private var isCreating = false
    #if os(iOS)
    private enum Field: Hashable {
        case question
        case option(Int)
    }
    @FocusState private var focusedField: Field?
    #endif

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty
            && answers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        #if os(iOS)
        // Form + nav-bar Cancel/Create; the fixed macOS frame and inline
        // buttons don't fit a phone sheet.
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask a question", text: $question)
                        .focused($focusedField, equals: .question)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .option(0) }
                }
                Section {
                    ForEach(answers.indices, id: \.self) { index in
                        HStack {
                            TextField("Option \(index + 1)", text: $answers[index])
                                .focused($focusedField, equals: .option(index))
                                .submitLabel(index == answers.count - 1 ? .done : .next)
                                .onSubmit {
                                    if index < answers.count - 1 {
                                        focusedField = .option(index + 1)
                                    } else {
                                        focusedField = nil
                                    }
                                }
                            // Explicit delete, no swipe needed.
                            Button {
                                answers.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(answers.count > 2
                                        ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                            }
                            .buttonStyle(.borderless)
                            .disabled(answers.count <= 2)
                            .accessibilityLabel(Text("Remove Option \(index + 1)"))
                        }
                    }
                    if answers.count < 8 {
                        Button("Add Option", systemImage: "plus.circle") {
                            answers.append("")
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("A poll needs at least two options.")
                }
                Section {
                    Toggle("Show results while the poll is open", isOn: $disclosed)
                } footer: {
                    Text("When this is off, votes stay hidden until you end the poll.")
                }
            }
            .navigationTitle("New Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") { create() }
                        .disabled(!canCreate || isCreating)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        VStack(alignment: .leading, spacing: 12) {
            Label("New Poll", systemImage: "chart.bar.xaxis")
                .font(.title3.weight(.semibold))

            TextField("Question", text: $question)
                .textFieldStyle(.roundedBorder)

            ForEach(answers.indices, id: \.self) { index in
                HStack {
                    TextField("Option \(index + 1)", text: $answers[index])
                        .textFieldStyle(.roundedBorder)
                    if answers.count > 2 {
                        Button {
                            answers.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if answers.count < 8 {
                Button("Add Option", systemImage: "plus.circle") {
                    answers.append("")
                }
                .buttonStyle(.borderless)
            }

            Toggle("Show results while the poll is open", isOn: $disclosed)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isCreating ? "Creating…" : "Create Poll") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isCreating)
            }
        }
        .padding(20)
        .frame(width: 380)
        #endif
    }

    private func create() {
        isCreating = true
        let finalAnswers = answers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            await viewModel.createPoll(
                question: question.trimmingCharacters(in: .whitespaces),
                answers: finalAnswers,
                disclosed: disclosed)
            dismiss()
        }
    }
}
