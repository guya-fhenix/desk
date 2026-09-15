import Foundation
import SwiftUI

/// Remembers how a table is sorted, across a screen change and across a restart.
///
/// `Table` hands back `KeyPathComparator`s, which carry a closure and do not encode. So each table
/// names its sortable columns here, and only the names and directions are written to disk; the
/// comparator itself is rebuilt from the template, which matters for the columns that sort optionals.
struct TableSort<Value> {
    private let columns: [(name: String, template: KeyPathComparator<Value>)]
    let fallback: [KeyPathComparator<Value>]

    init(_ columns: [(String, KeyPathComparator<Value>)], fallback: [KeyPathComparator<Value>]) {
        self.columns = columns.map { (name: $0.0, template: $0.1) }
        self.fallback = fallback
    }

    /// Unknown names are skipped, so renaming a column degrades to the default instead of breaking.
    func load(_ stored: String) -> [KeyPathComparator<Value>] {
        let order: [KeyPathComparator<Value>] = stored.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, var comparator = columns.first(where: { $0.name == parts[0] })?.template else { return nil }
            comparator.order = parts[1] == "reverse" ? .reverse : .forward
            return comparator
        }
        return order.isEmpty ? fallback : order
    }

    func store(_ order: [KeyPathComparator<Value>]) -> String {
        order.compactMap { comparator in
            guard let name = columns.first(where: { $0.template.keyPath == comparator.keyPath })?.name else { return nil }
            return "\(name):\(comparator.order == .reverse ? "reverse" : "forward")"
        }
        .joined(separator: ",")
    }
}

extension View {
    /// Loads the remembered sort when the table appears and writes it back on every change.
    func remembersSort<Value>(
        _ memory: TableSort<Value>, order: Binding<[KeyPathComparator<Value>]>, stored: Binding<String>
    ) -> some View {
        onAppear { order.wrappedValue = memory.load(stored.wrappedValue) }
            .onChange(of: order.wrappedValue) { _, new in stored.wrappedValue = memory.store(new) }
    }
}
