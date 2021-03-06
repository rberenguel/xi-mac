// Copyright 2017 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa

/// A builder for TextLine objects.
class TextLineBuilder {
    var attrString: NSMutableAttributedString
    var defaultFgColor: UInt32 = 0xff000000
    var fgSpans: [ColorSpan] = []
    var selSpans: [SelSpan] = []
    var fakeItalicSpans: [FakeItalicSpan] = []
    var underlineSpans: [UnderlineSpan] = []
    // Note: the font here is used only to get underline metrics, this may change.
    var font: CTFont

    init(_ text: String, font: CTFont) {
        let attributes = [
            NSAttributedStringKey.font: font,
            ]
        self.font = font
        self.attrString = NSMutableAttributedString(string: text, attributes: attributes)
    }

    /// Sets the default color of the text not covered by spans.
    func setFgColor(argb: UInt32) {
        defaultFgColor = argb
    }

    /// Add a foreground color span to the text line. This method assumes that such spans
    /// are added in sorted order and do not overlap.
    func addFgSpan(range: CountableRange<Int>, argb: UInt32) {
        if !range.isEmpty {
            fgSpans.append(ColorSpan(range: range, argb: argb))
        }
    }

    func addSelSpan(range: CountableRange<Int>) {
        if !range.isEmpty {
            selSpans.append(SelSpan(range: range))
        }
    }

    func addFakeItalicSpan(range: CountableRange<Int>) {
        if !range.isEmpty {
            fakeItalicSpans.append(FakeItalicSpan(range: range))
        }
    }

    func addUnderlineSpan(range: CountableRange<Int>, style: UnderlineStyle) {
        if !range.isEmpty {
            underlineSpans.append(UnderlineSpan(range: range, style: style))
        }
    }

    func addFontSpan(range: CountableRange<Int>, font: CTFont) {
        let attrs = [NSAttributedStringKey.font: font]
        attrString.addAttributes(attrs, range: NSRange(range))
    }

    func build(fontCache: FontCache) -> TextLine {
        let ctLine = CTLineCreateWithAttributedString(attrString)

        var fgColor = argbToFloats(argb: defaultFgColor)
        var fgSpanIx = 0
        var fakeItalicSpanIx = 0
        var glyphs: [GlyphInstance] = []
        let runs = CTLineGetGlyphRuns(ctLine) as [AnyObject] as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            let attributes: NSDictionary = CTRunGetAttributes(run)
            var glyphsPtr = CTRunGetGlyphsPtr(run)
            var glyphsBuf: [CGGlyph] = []
            if glyphsPtr == nil {
                glyphsBuf = [CGGlyph](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphsBuf)
                glyphsPtr = UnsafePointer<CGGlyph>(glyphsBuf)
            }
            var posPtr = CTRunGetPositionsPtr(run)
            var posBuf: [CGPoint] = []
            if posPtr == nil {
                posBuf = [CGPoint](repeating: CGPoint(), count: count)
                CTRunGetPositions(run, CFRangeMake(0, count), &posBuf)
                posPtr = UnsafePointer<CGPoint>(posBuf)
            }
            var indicesPtr = CTRunGetStringIndicesPtr(run)
            var indicesBuf: [CFIndex] = []
            if indicesPtr == nil {
                indicesBuf = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRangeMake(0, count), &indicesBuf)
                indicesPtr = UnsafePointer<CFIndex>(indicesBuf)
            }
            let font = attributes[kCTFontAttributeName] as! CTFont
            let fr = fontCache.getFontRef(font: font)
            for i in 0..<count {
                let glyph = glyphsPtr![i]
                let pos = posPtr![i]
                let ix = indicesPtr![i]
                if fgSpanIx < fgSpans.count && ix >= fgSpans[fgSpanIx].range.endIndex {
                    fgSpanIx += 1
                }
                if fgSpanIx < fgSpans.count && fgSpans[fgSpanIx].range.contains(ix) {
                    // TODO: maybe could reduce the amount of conversion
                    fgColor = argbToFloats(argb: fgSpans[fgSpanIx].argb)
                } else {
                    fgColor = argbToFloats(argb: defaultFgColor)
                }
                if fakeItalicSpanIx < fakeItalicSpans.count && ix >= fakeItalicSpans[fakeItalicSpanIx].range.endIndex {
                    fakeItalicSpanIx += 1
                }
                let fakeItalic = fakeItalicSpanIx < fakeItalicSpans.count && fakeItalicSpans[fakeItalicSpanIx].range.contains(ix)
                let flags = fakeItalic ? FLAG_FAKE_ITALIC : 0
                glyphs.append(GlyphInstance(fontRef: fr, glyph: glyph, x: GLfloat(pos.x), y: GLfloat(pos.y), fgColor: fgColor, flags: flags))
            }
        }
        var selRanges: [Range<GLfloat>] = []
        for selSpan in selSpans {
            selRanges.append(getCtLineRange(ctLine, selSpan.range))
        }
        var underlineRanges: [UnderlineRange] = []
        if !underlineSpans.isEmpty {
            // TODO: not sure these metrics are high-quality. Also, when we do rich text,
            // might want to use actual font (if overriden by span).
            let ulPos = CTFontGetUnderlinePosition(font)
            let ulThickness = CTFontGetUnderlineThickness(font)
            for underlineSpan in underlineSpans {
                let range = getCtLineRange(ctLine, underlineSpan.range)
                // TODO: the underline should probably match the actual color
                let argb = defaultFgColor
                var thickness = ulThickness
                switch underlineSpan.style {
                case .single:
                    ()
                case .thick:
                    thickness *= 2
                }
                let y = GLfloat(-ulPos - 0.5 * thickness) ..< GLfloat(-ulPos + 0.5 * thickness)
                underlineRanges.append(UnderlineRange(range: range, y: y, argb: argb))
            }
        }
        return TextLine(glyphs: glyphs, ctLine: ctLine, selRanges: selRanges, underlineRanges: underlineRanges, knownWidth: nil)
    }
}

/// A line of text with attributes that is ready for drawing.
struct TextLine {
    var glyphs: [GlyphInstance]
    // The CTLine is kept mostly for caret queries
    var ctLine: CTLine
    var selRanges: [Range<GLfloat>]
    var underlineRanges: [UnderlineRange]

    func offsetForIndex(utf16Ix: Int) -> CGFloat {
        return CTLineGetOffsetForStringIndex(ctLine, utf16Ix, nil)
    }

    //HACK: in the gutter case, we just stash the width and ignore the ctLine
    fileprivate var knownWidth: Double?

    var width: Double {
        return knownWidth ?? CTLineGetTypographicBounds(ctLine, nil, nil, nil)
    }

    /// Fast approach to build a new string out of an atlas of glyphs.  This
    /// only works properly (i.e. rendered correctly) for monospace fonts
    /// although non-monospace fonts will still produce some output.
    func scatterGather<C: Collection>(indices glyphIndices: C, font: CTFont)
            -> TextLine where C.Element == Int, C.IndexDistance == Int {
        var newGlyphs = Array<GlyphInstance>()
        newGlyphs.reserveCapacity(glyphIndices.count)

        var glyphPosition = 0
        var newWidth = 0.0
        for i in glyphIndices {
            newGlyphs.append(self.glyphs[i])
            newGlyphs[glyphPosition].x = self.glyphs[glyphPosition].x
            newGlyphs[glyphPosition].y = self.glyphs[glyphPosition].y
            if glyphPosition + 1 < self.glyphs.count {
                newWidth += Double(self.glyphs[glyphPosition + 1].x - self.glyphs[glyphPosition].x)
            } else {
                newWidth += self.width - Double(self.glyphs[glyphPosition].x)
            }
            glyphPosition += 1
        }

        return TextLine(glyphs: newGlyphs, ctLine: ctLine, selRanges: [], underlineRanges: [], knownWidth: newWidth);
    }
}

struct GlyphInstance {
    var fontRef: FontRef
    var glyph: CGGlyph
    // next 2 values are in pixels
    var x: GLfloat
    var y: GLfloat
    var fgColor: (GLfloat, GLfloat, GLfloat, GLfloat)
    // Currently, flags are for fake italic, but will also have subpixel position
    var flags: UInt32
}

struct UnderlineRange {
    // Having separate ranges for x and y is maybe silly (it defines a rect), but makes it
    // more similar to selection ranges etc.
    var range: Range<GLfloat>
    var y: Range<GLfloat>
    var argb: UInt32
}

let FLAG_FAKE_ITALIC: UInt32 = 1 << 16
let FLAG_HI_DPI: UInt32 = 1 << 17

// Possible refactor: have Span<T> so range is separated from payload
struct ColorSpan {
    // The range is in units of UTF-16 code units
    var range: CountableRange<Int>
    var argb: UInt32
}

struct SelSpan {
    var range: CountableRange<Int>
}

struct FakeItalicSpan {
    var range: CountableRange<Int>
}

struct UnderlineSpan {
    var range: CountableRange<Int>
    var style: UnderlineStyle
}

enum UnderlineStyle {
    case single
    case thick
}

/// Converts color value in argb format to tuple of 4 floats.
func argbToFloats(argb: UInt32) -> (GLfloat, GLfloat, GLfloat, GLfloat) {
    return (GLfloat((argb >> 16) & 0xff),
            GLfloat((argb >> 8) & 0xff),
            GLfloat(argb & 0xff),
            GLfloat(argb >> 24))
}

// TODO: make bidi-aware (signature changes to returning list of ranges)
func getCtLineRange(_ ctLine: CTLine, _ range: CountableRange<Int>) -> Range<GLfloat> {
    let start = GLfloat(CTLineGetOffsetForStringIndex(ctLine, range.startIndex, nil))
    let end = GLfloat(CTLineGetOffsetForStringIndex(ctLine, range.endIndex, nil))
    return start ..< end
}
