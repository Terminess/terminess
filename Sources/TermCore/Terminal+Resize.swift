extension Terminal {
    public func resize(columns newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(1, newRows)
        guard newCols != columns || newRows != rows else { return }

        var primaryCursor = isAlternate ? savedPrimaryCursor : cursor
        let (px, py, pending) = reflowPrimary(newCols: newCols, newRows: newRows,
                                              cursorX: primaryCursor.x, cursorY: primaryCursor.y,
                                              pendingWrap: primaryCursor.pendingWrap)
        primaryCursor.x = px
        primaryCursor.y = py
        primaryCursor.pendingWrap = pending

        var altCursor = isAlternate ? cursor : savedAlternateCursor
        cropAlternate(newCols: newCols, newRows: newRows, cursor: &altCursor)

        columns = newCols
        rows = newRows
        if isAlternate {
            cursor = altCursor
            savedPrimaryCursor = primaryCursor
        } else {
            cursor = primaryCursor
            savedAlternateCursor.x = min(savedAlternateCursor.x, newCols - 1)
            savedAlternateCursor.y = min(savedAlternateCursor.y, newRows - 1)
        }
        cursor.x = min(cursor.x, newCols - 1)
        cursor.y = min(cursor.y, newRows - 1)

        scrollTop = 0
        scrollBottom = newRows - 1
        tabStops = Terminal.defaultTabStops(newCols)
        dirty = Array(repeating: true, count: newRows)
        version &+= 1
        if modes.inBandResize { reportSize() }
    }

    private func cropAlternate(newCols: Int, newRows: Int, cursor c: inout Cursor) {
        let s = alternate
        for y in 0..<s.rows.count { s.rows[y].resize(to: newCols) }
        if newRows < s.rows.count {
            let excess = s.rows.count - newRows
            let belowCursor = max(0, s.rows.count - 1 - c.y)
            let fromBottom = min(excess, belowCursor)
            s.rows.removeLast(fromBottom)
            let fromTop = excess - fromBottom
            if fromTop > 0 { s.rows.removeFirst(fromTop); c.y -= fromTop }
        } else if newRows > s.rows.count {
            s.rows.append(contentsOf: repeatElement(Row(columns: newCols), count: newRows - s.rows.count))
        }
        s.columns = newCols
        s.rowCount = newRows
        c.x = min(c.x, newCols - 1)
        c.y = min(max(c.y, 0), newRows - 1)
    }

    private struct LogicalLine {
        var cells: [Cell] = []
        var clusters: [Int: String] = [:]
    }

    private func reflowPrimary(newCols: Int, newRows: Int, cursorX: Int, cursorY: Int,
                               pendingWrap: Bool) -> (Int, Int, Bool) {
        let s = primary
        let scrollbackRows = s.scrollback.rows
        var visible = s.rows

        var lastUsed = cursorY
        for y in stride(from: visible.count - 1, to: cursorY, by: -1)
        where visible[y].wrapped || visible[y].cells.contains(where: { !$0.isEmpty || !$0.attrs.bg.isDefault }) {
            lastUsed = y
            break
        }
        visible = Array(visible[0...lastUsed])
        let all = scrollbackRows + visible
        let cursorRow = scrollbackRows.count + cursorY

        var lines: [LogicalLine] = []
        var current = LogicalLine()
        var cursorLine = 0
        var cursorOffset = 0
        for (r, row) in all.enumerated() {
            var cells = row.cells
            if row.wrapped, let last = cells.last, last.isEmpty, r + 1 < all.count, all[r + 1].cells.first?.isWide == true {
                cells.removeLast()
            }
            if !row.wrapped {
                while let last = cells.last, last.isEmpty, last.attrs.bg.isDefault, !last.isWideTail { cells.removeLast() }
            }
            if r == cursorRow {
                cursorLine = lines.count
                cursorOffset = current.cells.count + cursorX + (pendingWrap ? 1 : 0)
            }
            let base = current.cells.count
            for (x, text) in row.clusters where x < cells.count { current.clusters[base + x] = text }
            current.cells.append(contentsOf: cells)
            if !row.wrapped {
                lines.append(current)
                current = LogicalLine()
            }
        }
        if !current.cells.isEmpty || current.clusters.count > 0 { lines.append(current) }
        if lines.isEmpty { lines.append(LogicalLine()) }

        var out: [Row] = []
        var newCursorRow = 0
        var newCursorCol = 0
        var newPending = false
        for (li, line) in lines.enumerated() {
            var row = Row(columns: newCols)
            var x = 0
            var placedCursor = false
            var i = 0
            while i < line.cells.count {
                let cell = line.cells[i]
                if cell.isWideTail { i += 1; continue }
                let w = cell.isWide ? 2 : 1
                if x + w > newCols {
                    row.wrapped = true
                    out.append(row)
                    row = Row(columns: newCols)
                    x = 0
                }
                if li == cursorLine && !placedCursor && i >= cursorOffset {
                    newCursorRow = out.count
                    newCursorCol = x
                    placedCursor = true
                }
                row.cells[x] = cell
                if let text = line.clusters[i] { row.clusters[x] = text }
                if w == 2 && x + 1 < newCols {
                    var tail = cell.attrs
                    tail.flags.remove([.wide, .cluster])
                    tail.flags.insert(.wideTail)
                    row.cells[x + 1] = Cell(attrs: tail)
                }
                x += w
                i += 1
            }
            out.append(row)
            if li == cursorLine && !placedCursor {
                let extra = max(0, cursorOffset - line.cells.count)
                var r = out.count - 1
                var col = x + extra
                if extra == 0 && col == newCols {
                    col = newCols - 1
                    newPending = true
                }
                while col >= newCols {
                    out[r].wrapped = true
                    out.append(Row(columns: newCols))
                    r += 1
                    col -= newCols
                }
                newCursorRow = r
                newCursorCol = col
            }
        }

        while out.count < newRows { out.append(Row(columns: newCols)) }
        var split = out.count - newRows
        if newCursorRow < split { split = newCursorRow }
        let visibleRows = Array(out[split..<min(split + newRows, out.count)])
        s.scrollback.replaceAll(Array(out[0..<split]))
        s.rows = visibleRows + Array(repeating: Row(columns: newCols), count: max(0, newRows - visibleRows.count))
        s.columns = newCols
        s.rowCount = newRows
        return (min(newCursorCol, newCols - 1), newCursorRow - split, newPending)
    }
}
