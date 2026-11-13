public struct Scrollback: Sendable {
    public let capacity: Int
    private var storage: [Row] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public subscript(i: Int) -> Row {
        get { storage[(head + i) % storage.count] }
        set { storage[(head + i) % storage.count] = newValue }
    }

    @discardableResult
    mutating func push(_ row: Row) -> Row? {
        guard capacity > 0 else { return row }
        if storage.count < capacity {
            storage.append(row)
            return nil
        }
        let evicted = storage[head]
        storage[head] = row
        head = (head + 1) % capacity
        return evicted
    }

    mutating func popNewest() -> Row? {
        guard !storage.isEmpty else { return nil }
        normalise()
        return storage.removeLast()
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }

    public var rows: [Row] {
        guard head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    mutating func replaceAll(_ rows: [Row]) {
        storage = rows.count > capacity ? Array(rows.suffix(capacity)) : rows
        head = 0
    }

    private mutating func normalise() {
        guard head != 0 else { return }
        storage = rows
        head = 0
    }
}

public final class Screen {
    public internal(set) var columns: Int
    public internal(set) var rowCount: Int
    public internal(set) var rows: [Row]
    public internal(set) var scrollback: Scrollback
    public internal(set) var scrolledOff = 0

    init(columns: Int, rows: Int, scrollback: Int) {
        self.columns = columns
        self.rowCount = rows
        self.rows = Array(repeating: Row(columns: columns), count: rows)
        self.scrollback = Scrollback(capacity: scrollback)
    }

    func blankRow(_ fill: Cell = .blank) -> Row { Row(columns: columns, fill: fill) }

    private func recycled(_ spare: Row?, _ fill: Cell) -> Row {
        guard var r = spare, r.cells.count == columns else { return blankRow(fill) }
        r.cells.withUnsafeMutableBufferPointer { $0.update(repeating: fill) }
        if !r.clusters.isEmpty { r.clusters.removeAll() }
        r.wrapped = false
        r.mark = []
        return r
    }

    func scrollUp(top: Int, bottom: Int, count n: Int, fill: Cell, toScrollback: Bool) {
        let n = min(n, bottom - top + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            let gone = rows.remove(at: top)
            var spare: Row?
            if toScrollback {
                spare = scrollback.push(gone)
                scrolledOff += 1
            } else {
                spare = gone
            }
            rows.insert(recycled(spare, fill), at: bottom)
        }
    }

    func scrollDown(top: Int, bottom: Int, count n: Int, fill: Cell) {
        let n = min(n, bottom - top + 1)
        guard n > 0 else { return }
        for _ in 0..<n {
            rows.remove(at: bottom)
            rows.insert(blankRow(fill), at: top)
        }
    }

    func clearAll(fill: Cell = .blank) {
        for y in 0..<rowCount { rows[y] = blankRow(fill) }
    }
}
