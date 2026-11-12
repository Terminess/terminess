import Testing
@testable import TermCore

let ESC = "\u{1B}"

func term(_ cols: Int = 10, _ rows: Int = 4, _ input: String = "") -> Terminal {
    let t = Terminal(columns: cols, rows: rows, scrollback: 100)
    t.feed(input)
    return t
}

func replies(_ t: Terminal, _ input: String) -> String {
    var out: [UInt8] = []
    t.onResponse = { out += $0 }
    t.feed(input)
    return String(decoding: out, as: UTF8.self)
}

@Suite struct PrintingTests {
    @Test func wrapsAtRightMargin() {
        let t = term(5, 3, "abcdefg")
        #expect(t.screenText() == "abcde\nfg\n")
        #expect(t.screen.rows[0].wrapped)
        #expect(t.cursor.x == 2 && t.cursor.y == 1)
    }

    @Test func pendingWrapDoesNotWrapUntilNextCharacter() {
        let t = term(5, 3, "abcde")
        #expect(t.cursor.x == 4 && t.cursor.pendingWrap)
        t.feed("\r\n")
        #expect(t.cursor.y == 1 && !t.screen.rows[0].wrapped)
    }

    @Test func autowrapOffOverwritesLastColumn() {
        let t = term(5, 3, "\(ESC)[?7labcdefg")
        #expect(t.screenText() == "abcdg\n\n")
    }

    @Test func wideCharacters() {
        let t = term(6, 2, "a日b")
        #expect(t.screen.rows[0].cells[1].isWide)
        #expect(t.screen.rows[0].cells[2].isWideTail)
        #expect(t.screenText() == "a日b\n")
        #expect(t.cursor.x == 4)
    }

    @Test func wideCharacterAtEdgeWraps() {
        let t = term(5, 2, "abcd日")
        #expect(t.screenText() == "abcd\n日")
        #expect(t.screen.rows[0].wrapped)
    }

    @Test func overwritingHalfAWideCharacterClearsIt() {
        let t = term(6, 1, "日本\(ESC)[2GX")
        #expect(t.screenText() == " X本")
    }

    @Test func emojiClusters() {
        let flag = term(10, 1, "🇬🇧x")
        #expect(flag.screenText() == "🇬🇧x")
        #expect(flag.cursor.x == 3)

        let family = term(10, 1, "👨‍👩‍👧x")
        #expect(family.screenText() == "👨‍👩‍👧x")
        #expect(family.cursor.x == 3)

        let skin = term(10, 1, "👍🏽x")
        #expect(skin.cursor.x == 3)

        let heart = term(10, 1, "❤️x")
        #expect(heart.cursor.x == 3)

        let accent = term(10, 1, "e\u{301}x")
        #expect(accent.screenText() == "e\u{301}x")
        #expect(accent.cursor.x == 2)
    }

    @Test func zwjDoesNotJoinPlainText() {
        let t = term(10, 1, "a\u{200D}b")
        #expect(t.cursor.x == 2)
    }

    @Test func decSpecialGraphics() {
        let t = term(10, 1, "\(ESC)(0lqqk\(ESC)(Bx")
        #expect(t.screenText() == "┌──┐x")
    }

    @Test func repeatLastCharacter() {
        let t = term(10, 1, "ab\(ESC)[3b")
        #expect(t.screenText() == "abbbb")
    }

    @Test func insertMode() {
        let t = term(6, 1, "abc\(ESC)[1G\(ESC)[4hX")
        #expect(t.screenText() == "Xabc")
    }

    @Test func tabs() {
        let t = term(20, 1, "a\tb\(ESC)[3gc")
        #expect(t.screenText() == "a       bc")
        let back = term(20, 1, "abcdefghij\(ESC)[Zx")
        #expect(back.screenText() == "abcdefghxj")
    }
}

@Suite struct CursorAndEraseTests {
    @Test func cursorPositioning() {
        let t = term(10, 5, "\(ESC)[3;4HX\(ESC)[HY")
        #expect(t.screen.rows[2].plainText() == "   X")
        #expect(t.screen.rows[0].plainText() == "Y")
    }

    @Test func movementClampsToScreen() {
        let t = term(10, 5, "\(ESC)[99;99H")
        #expect(t.cursor.x == 9 && t.cursor.y == 4)
        t.feed("\(ESC)[50A")
        #expect(t.cursor.y == 0)
    }

    @Test func originModeIsRelativeToScrollRegion() {
        let t = term(10, 6, "\(ESC)[2;4r\(ESC)[?6h\(ESC)[1;1HX\(ESC)[9;1HY")
        #expect(t.screen.rows[1].plainText() == "X")
        #expect(t.screen.rows[3].plainText() == "Y")
    }

    @Test func eraseLineModes() {
        let t = term(6, 1, "abcdef\(ESC)[3G\(ESC)[K")
        #expect(t.screenText() == "ab")
        let t1 = term(6, 1, "abcdef\(ESC)[3G\(ESC)[1K")
        #expect(t1.screenText() == "   def")
    }

    @Test func eraseDisplay() {
        let t = term(4, 3, "aaaa\r\nbbbb\r\ncccc\(ESC)[2;2H\(ESC)[J")
        #expect(t.screenText() == "aaaa\nb\n")
        let t2 = term(4, 3, "aaaa\r\nbbbb\r\ncccc\(ESC)[2;2H\(ESC)[1J")
        #expect(t2.screenText() == "\n  bb\ncccc")
    }

    @Test func eraseUsesBackgroundColour() {
        let t = term(4, 1, "\(ESC)[41m\(ESC)[K")
        #expect(t.screen.rows[0].cells[3].attrs.bg == .indexed(1))
    }

    @Test func insertAndDeleteCharacters() {
        let t = term(6, 1, "abcdef\(ESC)[2G\(ESC)[2@")
        #expect(t.screenText() == "a  bcd")
        t.feed("\(ESC)[3P")
        #expect(t.screenText() == "acd")
    }

    @Test func eraseCharacters() {
        let t = term(6, 1, "abcdef\(ESC)[2G\(ESC)[2X")
        #expect(t.screenText() == "a  def")
    }

    @Test func saveAndRestoreCursor() {
        let t = term(10, 4, "\(ESC)[2;3H\(ESC)[1m\(ESC)7\(ESC)[H\(ESC)[0m\(ESC)8X")
        #expect(t.screen.rows[1].plainText() == "  X")
        #expect(t.screen.rows[1].cells[2].attrs.flags.contains(.bold))
    }
}

@Suite struct ScrollingTests {
    @Test func linefeedAtBottomScrollsIntoScrollback() {
        let t = term(5, 2, "1\r\n2\r\n3")
        #expect(t.screenText() == "2\n3")
        #expect(t.screen.scrollback.count == 1)
        #expect(t.screen.scrollback[0].plainText() == "1")
    }

    @Test func scrollRegion() {
        let t = term(5, 4, "a\r\nb\r\nc\r\nd\(ESC)[2;3r\(ESC)[3;1H\nX")
        #expect(t.screenText() == "a\nc\nX\nd")
        #expect(t.screen.scrollback.count == 0)
    }

    @Test func reverseIndexAtTopScrollsDown() {
        let t = term(5, 3, "a\r\nb\r\nc\(ESC)[H\(ESC)M")
        #expect(t.screenText() == "\na\nb")
    }

    @Test func insertAndDeleteLines() {
        let t = term(5, 4, "a\r\nb\r\nc\r\nd\(ESC)[2;1H\(ESC)[L")
        #expect(t.screenText() == "a\n\nb\nc")
        t.feed("\(ESC)[2M")
        #expect(t.screenText() == "a\nc\n\n")
    }

    @Test func scrollUpAndDownSequences() {
        let t = term(5, 3, "a\r\nb\r\nc\(ESC)[S")
        #expect(t.screenText() == "b\nc\n")
        t.feed("\(ESC)[2T")
        #expect(t.screenText() == "\n\nb")
    }
}

@Suite struct ModeTests {
    @Test func alternateScreenSavesAndRestores() {
        let t = term(10, 3, "main\(ESC)[?1049h")
        #expect(t.isAlternate && t.screenText() == "\n\n")
        t.feed("alt")
        t.feed("\(ESC)[?1049l")
        #expect(!t.isAlternate)
        #expect(t.screenText() == "main\n\n")
        #expect(t.cursor.x == 4)
    }

    @Test func alternateScreenHasNoScrollback() {
        let t = term(5, 2, "\(ESC)[?1049h1\r\n2\r\n3")
        #expect(t.alternate.scrollback.count == 0)
        #expect(t.primary.scrollback.count == 0)
    }

    @Test func trackedModes() {
        let t = term(10, 2, "\(ESC)[?2004h\(ESC)[?1003h\(ESC)[?1006h\(ESC)[?25l\(ESC)[?1h")
        #expect(t.modes.bracketedPaste)
        #expect(t.modes.mouseTracking == .any)
        #expect(t.modes.mouseEncoding == .sgr)
        #expect(!t.modes.cursorVisible)
        #expect(t.modes.applicationCursorKeys)
    }

    @Test func cursorStyle() {
        let t = term(10, 2, "\(ESC)[6 q")
        #expect(t.cursorShape == .bar && !t.modes.cursorBlink)
    }

    @Test func fullReset() {
        let t = term(10, 2, "abc\(ESC)[?2004h\(ESC)c")
        #expect(t.screenText() == "\n" && !t.modes.bracketedPaste)
    }
}

@Suite struct SGRTests {
    func attrs(_ s: String) -> Attributes { term(10, 1, s + "x").screen.rows[0].cells[0].attrs }

    @Test func basicAttributes() {
        let a = attrs("\(ESC)[1;3;4;7;9m")
        #expect(a.flags.contains([.bold, .italic, .inverse, .strikethrough]))
        #expect(a.underline == .single)
    }

    @Test func colours() {
        #expect(attrs("\(ESC)[31;42m").fg == .indexed(1))
        #expect(attrs("\(ESC)[31;42m").bg == .indexed(2))
        #expect(attrs("\(ESC)[91m").fg == .indexed(9))
        #expect(attrs("\(ESC)[38;5;200m").fg == .indexed(200))
        #expect(attrs("\(ESC)[38;2;1;2;3m").fg == .rgb(1, 2, 3))
        #expect(attrs("\(ESC)[38:2::4:5:6m").fg == .rgb(4, 5, 6))
        #expect(attrs("\(ESC)[38:2:7:8:9m").fg == .rgb(7, 8, 9))
        #expect(attrs("\(ESC)[48:5:17m").bg == .indexed(17))
        #expect(attrs("\(ESC)[58:2::9:9:9m").underlineColor == .rgb(9, 9, 9))
    }

    @Test func colourThenMoreAttributes() {
        let a = attrs("\(ESC)[38;2;1;2;3;1m")
        #expect(a.fg == .rgb(1, 2, 3) && a.flags.contains(.bold))
    }

    @Test func underlineStyles() {
        #expect(attrs("\(ESC)[4:3m").underline == .curly)
        #expect(attrs("\(ESC)[21m").underline == .double)
        #expect(attrs("\(ESC)[4m\(ESC)[24m").underline == .none)
    }

    @Test func resets() {
        #expect(attrs("\(ESC)[1;31m\(ESC)[0m") == Attributes())
        #expect(attrs("\(ESC)[1;31m\(ESC)[m") == Attributes())
        let a = attrs("\(ESC)[1;2m\(ESC)[22m")
        #expect(!a.flags.contains(.bold) && !a.flags.contains(.faint))
    }
}

@Suite struct ReplyTests {
    @Test func deviceAttributes() {
        #expect(replies(term(), "\(ESC)[c") == "\(ESC)[?62;22c")
        #expect(replies(term(), "\(ESC)[>c") == "\(ESC)[>1;10;0c")
    }

    @Test func cursorPositionReport() {
        #expect(replies(term(), "\(ESC)[3;5H\(ESC)[6n") == "\(ESC)[3;5R")
    }

    @Test func modeReports() {
        let t = term()
        #expect(replies(t, "\(ESC)[?2026$p") == "\(ESC)[?2026;2$y")
        #expect(replies(t, "\(ESC)[?2004h\(ESC)[?2004$p") == "\(ESC)[?2004;1$y")
        #expect(replies(t, "\(ESC)[?2027$p") == "\(ESC)[?2027;3$y")
        #expect(replies(t, "\(ESC)[?9999$p") == "\(ESC)[?9999;0$y")
    }

    @Test func colourQueries() {
        let t = term()
        t.palette.background = RGB(0x10, 0x20, 0x30)
        #expect(replies(t, "\(ESC)]11;?\u{07}") == "\(ESC)]11;rgb:1010/2020/3030\(ESC)\\")
        #expect(replies(t, "\(ESC)]4;1;?\u{07}") == "\(ESC)]4;1;rgb:cdcd/3131/3131\(ESC)\\")
    }

    @Test func kittyKeyboardOnlyWhenSupported() {
        let t = term()
        #expect(replies(t, "\(ESC)[?u") == "")
        t.supportsKittyKeyboard = true
        #expect(replies(t, "\(ESC)[>3u\(ESC)[?u") == "\(ESC)[?3u")
        #expect(replies(t, "\(ESC)[<u\(ESC)[?u") == "\(ESC)[?0u")
    }

    @Test func sizeReports() {
        let t = term(80, 24)
        #expect(replies(t, "\(ESC)[18t") == "\(ESC)[8;24;80t")
    }

    @Test func requestStatusString() {
        let t = term()
        #expect(replies(t, "\(ESC)[1;31m\(ESC)P$qm\(ESC)\\") == "\(ESC)P1$r0;1;38;5;1m\(ESC)\\")
        #expect(replies(t, "\(ESC)P$qr\(ESC)\\") == "\(ESC)P1$r1;4r\(ESC)\\")
    }

    @Test func titleAndHyperlink() {
        let t = term(10, 1, "\(ESC)]2;hello\u{07}\(ESC)]8;;https://x.test\u{07}ab\(ESC)]8;;\u{07}c")
        #expect(t.title == "hello")
        let link = t.screen.rows[0].cells[0].attrs.link
        #expect(link != 0 && t.hyperlink(id: link) == "https://x.test")
        #expect(t.screen.rows[0].cells[2].attrs.link == 0)
    }
}

@Suite struct ResizeTests {
    @Test func reflowNarrower() {
        let t = term(10, 3, "abcdefgh")
        t.resize(columns: 4, rows: 3)
        #expect(t.screenText() == "abcd\nefgh\n")
        #expect(t.cursor.y == 1 && t.cursor.x == 3 && t.cursor.pendingWrap)
    }

    @Test func reflowWiderRejoinsWrappedLines() {
        let t = term(4, 3, "abcdefgh")
        #expect(t.screenText() == "abcd\nefgh\n")
        t.resize(columns: 10, rows: 3)
        #expect(t.screenText() == "abcdefgh\n\n")
        #expect(t.cursor.x == 8 && t.cursor.y == 0)
    }

    @Test func hardLineBreaksSurvive() {
        let t = term(10, 3, "ab\r\ncd")
        t.resize(columns: 3, rows: 3)
        #expect(t.screenText() == "ab\ncd\n")
    }

    @Test func shrinkingRowsPushesIntoScrollback() {
        let t = term(5, 4, "1\r\n2\r\n3\r\n4")
        t.resize(columns: 5, rows: 2)
        #expect(t.screenText() == "3\n4")
        #expect(t.screen.scrollback.count == 2)
        t.resize(columns: 5, rows: 4)
        #expect(t.screenText() == "1\n2\n3\n4")
    }

    @Test func wideCharactersReflow() {
        let t = term(6, 3, "ab日本")
        t.resize(columns: 3, rows: 3)
        #expect(t.screenText() == "ab\n日\n本")
    }

    @Test func alternateScreenIsCropped() {
        let t = term(10, 3, "main\(ESC)[?1049h\(ESC)[Hxxxxxxxxxx")
        t.resize(columns: 5, rows: 3)
        #expect(t.screenText().hasPrefix("xxxxx"))
        t.feed("\(ESC)[?1049l")
        #expect(t.screenText().hasPrefix("main"))
    }
}

@Suite struct WidthTests {
    @Test func scalarWidths() {
        #expect(CharWidth.of("a") == 1)
        #expect(CharWidth.of("日") == 2)
        #expect(CharWidth.of("👍") == 2)
        #expect(CharWidth.of("\u{301}") == 0)
        #expect(CharWidth.of("\u{200D}") == 0)
        #expect(CharWidth.of("é") == 1)
        #expect(CharWidth.of("\u{00AD}") == 1)
        #expect(CharWidth.of("─") == 1)
    }
}
