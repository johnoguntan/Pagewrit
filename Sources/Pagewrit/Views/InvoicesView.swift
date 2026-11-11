import SwiftUI
import AppKit

/// Every invoice Pagewrit found, sorted by what needs doing first: overdue,
/// then due this week, then the rest, with paid ones tucked away at the end.
struct InvoicesView: View {
    let searchText: String

    @ObservedObject private var store = InvoiceStore.shared
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("pagewrit.invoiceGrouping") private var groupingRaw = "status"
    @State private var editing: Invoice?
    @State private var hoveredID: String?

    private struct Section: Identifiable {
        let title: String
        let items: [Invoice]
        let urgent: Bool
        var id: String { title }
    }

    // MARK: Data

    private var visible: [Invoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.invoices }
        return store.invoices.filter {
            $0.vendor.lowercased().contains(query)
                || ($0.number ?? "").lowercased().contains(query)
                || $0.title.lowercased().contains(query)
        }
    }

    private static func byDueDate(_ a: Invoice, _ b: Invoice) -> Bool {
        (a.due ?? .distantFuture) < (b.due ?? .distantFuture)
    }

    private var sections: [Section] {
        let items = visible
        if groupingRaw == "vendor" {
            let grouped = Dictionary(grouping: items, by: { $0.vendor })
            return grouped.keys
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { Section(title: $0, items: (grouped[$0] ?? []).sorted(by: Self.byDueDate), urgent: false) }
        }
        func pick(_ status: InvoiceStatus) -> [Invoice] {
            items.filter { $0.status() == status }.sorted(by: Self.byDueDate)
        }
        let paid = items.filter { $0.paid }.sorted { ($0.paidOn ?? .distantPast) > ($1.paidOn ?? .distantPast) }
        return [
            Section(title: "Overdue", items: pick(.overdue), urgent: true),
            Section(title: "Due this week", items: pick(.dueSoon), urgent: false),
            Section(title: "Coming up", items: pick(.upcoming), urgent: false),
            Section(title: "No due date", items: pick(.noDate), urgent: false),
            Section(title: "Paid", items: paid, urgent: false)
        ].filter { !$0.items.isEmpty }
    }

    /// What is still owed, per currency.
    private var outstanding: String? {
        var totals: [String: Double] = [:]
        for invoice in store.invoices where !invoice.paid {
            if let amount = invoice.amount { totals[invoice.currency, default: 0] += amount }
        }
        guard !totals.isEmpty else { return nil }
        return totals.keys.sorted().map { currency in
            var probe = Invoice(id: "", vendor: "", currency: currency, title: "")
            probe.amount = totals[currency]
            return probe.amountText ?? ""
        }.joined(separator: " and ")
    }

    private var summary: String {
        var parts: [String] = []
        if store.overdueCount > 0 { parts.append("\(store.overdueCount) overdue") }
        if store.dueSoonCount > 0 { parts.append("\(store.dueSoonCount) due this week") }
        if let outstanding { parts.append("\(outstanding) outstanding") }
        if parts.isEmpty { return "\(store.invoices.count) \(store.invoices.count == 1 ? "invoice" : "invoices"), nothing waiting on you." }
        return parts.joined(separator: ", ")
    }

    // MARK: Body

    var body: some View {
        Group {
            if store.invoices.isEmpty { emptyState } else { content }
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear { store.requestNotificationsIfNeeded() }
        .sheet(item: $editing) { invoice in
            InvoiceEditor(invoice: invoice) { updated in
                store.update(updated)
                editing = nil
            } onRemove: {
                store.remove(invoice.id)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Invoices")
                            .font(DesignTokens.serifFont(size: 42, weight: .bold))
                            .tracking(-1.2)
                        Text(summary)
                            .font(DesignTokens.sansFont(size: 14))
                            .foregroundStyle(store.overdueCount > 0 ? DesignTokens.accentSecondary : Color.secondary)
                    }
                    Spacer(minLength: 12)
                    PWSegmented(selection: $groupingRaw,
                                options: [("Status", "status"), ("Vendor", "vendor")])
                        .accessibilityLabel("Group invoices by")
                }
                .padding(.bottom, 18)

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(DesignTokens.serifFont(size: 20, weight: .bold))
                                .foregroundStyle(section.urgent ? DesignTokens.accentSecondary : Color.primary)
                            Text("\(section.items.count)")
                                .font(DesignTokens.sansFont(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 26)
                        .padding(.bottom, 6)

                        ForEach(section.items) { invoice in
                            row(invoice)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Row

    private func tint(for status: InvoiceStatus) -> Color {
        switch status {
        case .overdue: return DesignTokens.accentSecondary
        case .dueSoon: return DesignTokens.accentInk
        default: return Color.secondary
        }
    }

    private func row(_ invoice: Invoice) -> some View {
        let status = invoice.status()
        let hovered = hoveredID == invoice.id
        return HStack(spacing: 14) {
            Image(systemName: invoice.paid ? "checkmark.circle" : "doc.text")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(invoice.paid ? DesignTokens.accent : Color.secondary)
                .frame(width: 40, height: 48)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 3) {
                Text(invoice.vendor)
                    .font(DesignTokens.sansFont(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(detail(invoice))
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail(invoice))
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                if let amount = invoice.amountText {
                    Text(amount)
                        .font(DesignTokens.serifFont(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(invoice.paid ? Color.secondary : Color.primary)
                }
                Text(invoice.dueLabel())
                    .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(tint(for: status))
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) { store.setPaid(invoice.id, !invoice.paid) }
            } label: {
                Text(invoice.paid ? "Undo" : "Mark paid")
            }
            .buttonStyle(.pw(invoice.paid ? .ghost : .soft, size: .small))

            Menu {
                Button("Open file") { open(invoice) }
                Button("Edit details") { editing = invoice }
                Divider()
                Button("Not an invoice", role: .destructive) { store.remove(invoice.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("More for this invoice")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovered ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { open(invoice) }
        .onHover { inside in hoveredID = inside ? invoice.id : (hoveredID == invoice.id ? nil : hoveredID) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the invoice")
    }

    private func detail(_ invoice: Invoice) -> String {
        var parts: [String] = []
        if let number = invoice.number { parts.append("Invoice \(number)") }
        if let issued = invoice.issued { parts.append("issued \(Invoice.shortDate.string(from: issued))") }
        if parts.isEmpty { parts.append(invoice.title) }
        return parts.joined(separator: ", ")
    }

    private func open(_ invoice: Invoice) {
        guard library.books.contains(where: { $0.contentHash == invoice.id }) else { return }
        openWindow(id: "reader", value: invoice.id)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dog")
                .font(.system(size: 46))
                .foregroundStyle(DesignTokens.accent)
            Text("No invoices yet.")
                .font(DesignTokens.serifFont(size: 30, weight: .bold))
                .tracking(-0.7)
            Text("Pagewrit looks inside your PDFs and Word files for invoices and tells you when they are due. You can also right click any book and choose Mark as Invoice.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

/// Fix what the detector got wrong: who it is from, how much, and when it is due.
private struct InvoiceEditor: View {
    @State var invoice: Invoice
    let onSave: (Invoice) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var amountText: String
    @State private var hasDue: Bool
    @State private var dueDate: Date

    init(invoice: Invoice,
         onSave: @escaping (Invoice) -> Void,
         onRemove: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        _invoice = State(initialValue: invoice)
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _amountText = State(initialValue: invoice.amount.map { String(format: "%.2f", $0) } ?? "")
        _hasDue = State(initialValue: invoice.due != nil)
        _dueDate = State(initialValue: invoice.due ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Invoice details")
                .font(DesignTokens.serifFont(size: 24, weight: .bold))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label("From")
                    TextField("Who sent it", text: $invoice.vendor)
                }
                GridRow {
                    label("Number")
                    TextField("Optional", text: Binding(
                        get: { invoice.number ?? "" },
                        set: { invoice.number = $0.isEmpty ? nil : $0 }))
                }
                GridRow {
                    label("Amount")
                    HStack(spacing: 8) {
                        TextField("Currency", text: $invoice.currency).frame(width: 70)
                        TextField("0.00", text: $amountText)
                    }
                }
                GridRow {
                    label("Due")
                    HStack(spacing: 10) {
                        Toggle("", isOn: $hasDue).labelsHidden()
                            .accessibilityLabel("Has a due date")
                        DatePicker("", selection: $dueDate, displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityLabel("Due date")
                            .disabled(!hasDue)
                    }
                }
                GridRow {
                    label("Paid")
                    Toggle("", isOn: $invoice.paid).labelsHidden()
                        .accessibilityLabel("Paid")
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Not an invoice", action: onRemove)
                    .buttonStyle(.pw(.danger))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.pw(.soft))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.pw(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 440)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.sansFont(size: 13))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func save() {
        var updated = invoice
        let cleaned = amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        updated.amount = Double(cleaned)
        updated.due = hasDue ? dueDate : nil
        if updated.paid, updated.paidOn == nil { updated.paidOn = Date() }
        if !updated.paid { updated.paidOn = nil }
        if updated.vendor.trimmingCharacters(in: .whitespaces).isEmpty { updated.vendor = updated.title }
        onSave(updated)
    }
}
