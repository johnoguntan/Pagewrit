import SwiftUI

/// Shared building blocks for in-book search (EPUB and PDF readers) so both
/// behave and look the same: one field, match options, scope switch, grouped
/// results, keyboard navigation and recent searches.

struct SearchColors {
    let text: Color
    let tint: Color
    let accent: Color
}

// MARK: - History

enum SearchHistory {
    static let key = "pagewrit.searchHistory"

    static func list(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func adding(_ term: String, to raw: String) -> String {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return raw }
        var items = list(raw).filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        items.insert(q, at: 0)
        return items.prefix(8).joined(separator: "\n")
    }
}

// MARK: - Matching

enum SearchMatcher {
    /// Regex for a query, honouring the match options. Nil if it can't be built.
    static func regex(for query: String, matchCase: Bool, wholeWord: Bool) -> NSRegularExpression? {
        var pattern = NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b" + pattern + "\\b" }
        var options: NSRegularExpression.Options = []
        if !matchCase { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// Text with the first match in bold accent, for a result row.
    static func snippet(_ text: String, query: String, matchCase: Bool, wholeWord: Bool,
                        accent: Color, size: CGFloat = 13) -> AttributedString {
        var attributed = AttributedString(text)
        guard let regex = regex(for: query, matchCase: matchCase, wholeWord: wholeWord),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let swiftRange = Range(m.range, in: text),
              let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
        else { return attributed }
        attributed[lower..<upper].font = .system(size: size, weight: .bold)
        attributed[lower..<upper].foregroundColor = accent
        return attributed
    }
}

// MARK: - Field

struct SearchFieldBar: View {
    @Binding var query: String
    let prompt: String
    var focused: FocusState<Bool>.Binding
    let colors: SearchColors
    let onSubmit: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onEscape: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(colors.tint)
            TextField("", text: $query, prompt: Text(prompt).foregroundStyle(colors.tint))
                .textFieldStyle(.plain)
                .font(DesignTokens.sansFont(size: 13))
                .foregroundStyle(colors.text)
                .focused(focused)
                .onSubmit(onSubmit)
                .onKeyPress(.downArrow) { onDown(); return .handled }
                .onKeyPress(.upArrow) { onUp(); return .handled }
                .onKeyPress(.escape) { onEscape(); return .handled }

            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.tint)
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityLabel("Clear (Esc)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.text.opacity(0.08)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Options

struct SearchOptionsBar: View {
    let firstScope: String
    let secondScope: String
    @Binding var firstScopeSelected: Bool
    @Binding var matchCase: Bool
    @Binding var wholeWord: Bool
    let colors: SearchColors

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                scopeButton(firstScope, active: firstScopeSelected) { firstScopeSelected = true }
                scopeButton(secondScope, active: !firstScopeSelected) { firstScopeSelected = false }
            }
            .background(Capsule().fill(colors.text.opacity(0.08)))

            Spacer(minLength: 0)

            chip("Aa", help: "Match case", on: $matchCase)
            chip("Word", help: "Whole word only", on: $wholeWord)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func scopeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.sansFont(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : colors.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? colors.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, help: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(title)
                .font(DesignTokens.sansFont(size: 11.5, weight: .semibold))
                .foregroundStyle(on.wrappedValue ? Color.white : colors.tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(on.wrappedValue ? colors.accent : colors.text.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Status

struct SearchStatusBar: View {
    let summary: String
    let position: String
    let colors: SearchColors
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(DesignTokens.sansFont(size: 11.5))
                .foregroundStyle(colors.tint)
            Spacer()
            Text(position)
                .font(DesignTokens.sansFont(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(colors.tint)
            stepButton("chevron.up", help: "Previous (\u{2191})", action: onPrevious)
            stepButton("chevron.down", help: "Next (\u{2193})", action: onNext)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func stepButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(colors.tint)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Group header and rows

struct SearchGroupHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let colors: SearchColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(title)
                    .font(DesignTokens.sansFont(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(DesignTokens.sansFont(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(colors.text.opacity(0.08)))
            }
            .foregroundStyle(colors.tint)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SearchResultRow: View {
    let text: AttributedString
    let selected: Bool
    let colors: SearchColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(DesignTokens.sansFont(size: 13))
                .foregroundStyle(colors.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? colors.accent.opacity(0.16) : Color.clear)
                )
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(colors.accent).frame(width: 3).padding(.vertical, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

struct SearchHint: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

struct SearchEmptyView: View {
    let query: String
    let hints: [SearchHint]
    let history: [String]
    let colors: SearchColors
    let onPickHistory: (String) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if typed.count >= 2 {
                    Text("No matches for \u{201C}\(typed)\u{201D}")
                        .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                        .foregroundStyle(colors.text)
                    if hints.isEmpty {
                        Text("Check the spelling, or try a shorter word.")
                            .font(DesignTokens.sansFont(size: 12))
                            .foregroundStyle(colors.tint)
                    } else {
                        Text("Filters are on. Loosen them to see more:")
                            .font(DesignTokens.sansFont(size: 12))
                            .foregroundStyle(colors.tint)
                        HStack(spacing: 6) {
                            ForEach(hints) { hint in
                                Button(action: hint.action) {
                                    Text(hint.title)
                                        .font(DesignTokens.sansFont(size: 11.5, weight: .semibold))
                                        .foregroundStyle(colors.accent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(colors.accent.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if !history.isEmpty {
                    HStack {
                        Text("RECENT")
                            .font(DesignTokens.sansFont(size: 10.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(colors.tint)
                        Spacer()
                        Button("Clear", action: onClearHistory)
                            .buttonStyle(.plain)
                            .font(DesignTokens.sansFont(size: 11.5))
                            .foregroundStyle(colors.accent)
                    }
                    ForEach(history, id: \.self) { term in
                        Button { onPickHistory(term) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11))
                                    .foregroundStyle(colors.tint)
                                Text(term)
                                    .font(DesignTokens.sansFont(size: 13))
                                    .foregroundStyle(colors.text)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Type at least 2 letters.")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(colors.tint)
                }
                Text("\u{2191}\u{2193} browse  \u{00B7}  Return to read  \u{00B7}  Esc to clear")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(colors.tint.opacity(0.8))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
