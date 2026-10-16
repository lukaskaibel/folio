#if DEBUG
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sample notes and files for trying Notebook and for its screenshots and tests, written to a folder of your choice so
/// your own files are never touched. Launch with `-NotebookLibrary <folder> -NotebookDemo YES`.
enum DemoLibrary {
    /// Hidden from the sidebar at first, to show hiding with: the header's eye button brings them back.
    static let hiddenFolders = ["Archive"]

    static func create(at root: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Travel/Kyoto trip.md").path) { return }
        func folder(_ path: String) -> URL {
            let url = root.appendingPathComponent(path, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ path: String, _ text: String) {
            try? Data(text.utf8).write(to: root.appendingPathComponent(path))
        }

        _ = folder("Archive/2025")
        _ = folder("Inbox")
        _ = folder("Personal/Cooking")
        _ = folder("Projects/Design")
        _ = folder("Travel/Photos")
        _ = folder("Travel/.assets")
        _ = folder("University/Linear algebra")

        write("Archive/2025/Old apartment.md", "# Handover\n\n- [x] Meter readings\n- [x] Keys returned\n- [ ] Deposit back\n")
        write("Inbox/Gift ideas.md", "- [ ] Book for Mia: *The Remains of the Day*\n- [ ] Good olive oil\n- [x] Concert tickets\n")
        write("Inbox/Shared link.md", "https://example.com/an-article-worth-reading\n\nRead this on the train.\n")

        write("Travel/Kyoto trip.md", """
        Five days in October. Flights and the ryokan are booked, everything else stays loose. Costs are in [[Budget]], the tickets in [[Flight tickets.pdf]].

        ![](.assets/torii.png)

        ## Packing
        - [x] Passport
        - [x] Rail pass voucher
        - [ ] Power adapter, type A
        - [ ] Rain jacket

        ## Plan
        - **Day 1** Fushimi Inari at sunrise, before the tour groups
        - **Day 2** Arashiyama: bamboo grove early, then along the river
        - **Day 3** Day trip to [[Nara]]

        Room details are on the [ryokan's site](https://www.example.com/ryokan). Check-in is ==from 3 pm==, dinner at 7.

        > [!tip] Good to know
        > Get an ICOCA card at the airport. It works on every train and in most convenience stores.

        | Day | Area | Note |
        | --- | --- | --- |
        | 1 | Fushimi | Early start |
        | 2 | Arashiyama | Bamboo grove |
        | 3 | Nara | Deer park |
        | 4 | Gion | Evening walk |

        ![[Flight tickets.pdf]]

        """)
        write("Travel/Budget.md", """
        Everything for [[Kyoto trip]], in the currency it gets paid in.

        | Item | Cost | Paid |
        | --- | ---: | --- |
        | Flights | €1,240 | Yes |
        | Ryokan, four nights | ¥88,000 | Yes |
        | Rail pass | ¥50,000 | No |
        | Food and temples | ¥60,000 | No |

        Roughly **€2,450** in total at today's rate.

        """)
        write("Personal/Weekend.md", """
        Market on Saturday morning, cooking with Mia in the evening. Sunday stays empty on purpose.

        ## Saturday
        - [ ] Tomatoes, basil, burrata
        - [ ] Sourdough from the corner bakery
        - [ ] Flowers for the table

        Dinner: the mushroom risotto from [[Recipes]].

        """)
        write("Personal/Cooking/Recipes.md", """
        ## Mushroom risotto
        1. Sweat a shallot in butter
        2. Toast the rice, then a glass of white wine
        3. Ladle in stock, stir, repeat for 18 minutes
        4. Fold in the mushrooms and *lots* of parmesan

        ```text
        Serves 2 · 320 g rice · 1 l stock
        ```

        """)
        write("Projects/Notebook roadmap.md", """
        How the pieces fit together, and what ships when.

        ## Architecture
        ```mermaid
        graph LR
          Files --> Markdown --> Editor
          Files --> Index --> Search
        ```

        ## Milestones
        | Milestone | Goal | Status |
        | --- | --- | --- |
        | M0 | Editor and file spikes | Done |
        | M1 | Finder replacement | Doing |
        | M2 | Live preview | Next |

        ```swift
        // The editor keeps the Markdown exactly as it is in the file.
        let document = MarkdownParser.parse(text)
        styler.style(storage, document: document)
        ```

        Offer from the agency: [[Offer.pdf]]

        """)
        write("Projects/Design/Meeting notes.md", "# Kick-off\n\n- Keep it **minimal**\n- Notes are plain files\n- ⌘F finds everything\n")
        write("University/Linear algebra/Week 3.md", """
        ## Eigenvalues
        λ is an eigenvalue of $A$ when there is a vector that $A$ only stretches:

        $$
        A\\mathbf{x} = \\lambda\\mathbf{x}, \\quad \\mathbf{x} \\neq 0
        $$

        Find them by solving $\\det(A - \\lambda I) = 0$.

        > [!important] Exam
        > Sheet 3, tasks 2 and 4 by Thursday.

        """)

        drawTorii(to: root.appendingPathComponent("Travel/.assets/torii.png"))
        drawTorii(to: root.appendingPathComponent("Travel/ryokan.jpg"), jpeg: true)
        makePDF(at: root.appendingPathComponent("Travel/Flight tickets.pdf"), title: "Itinerary receipt", lines: [
            "Booking reference K7Q2LM", "Outbound Mon 12 Oct: FRA 13:40 to KIX 08:45, flight XY 2041",
            "Return Sat 17 Oct: KIX 10:55 to FRA 16:15, flight XY 2042", "Haruka express from Kansai Airport to Kyoto Station",
        ])
        makePDF(at: root.appendingPathComponent("Projects/Offer.pdf"), title: "Offer", lines: [
            "Design and build of the Notebook website", "Three pages, light and dark", "Delivery in four weeks",
        ])
    }

    private static func drawTorii(to url: URL, jpeg: Bool = false) {
        let width = 1400, height = 620
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func fill(_ hex: UInt32) {
            context.setFillColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        fill(0xF3CDB0); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        fill(0xFBE6CB); context.fillEllipse(in: CGRect(x: 960, y: 400, width: 140, height: 140))
        fill(0xD29C84); context.fillEllipse(in: CGRect(x: -200, y: -380, width: 1200, height: 640))
        fill(0xB97968); context.fillEllipse(in: CGRect(x: 600, y: -420, width: 1100, height: 620))
        fill(0xB5321F)
        context.fill([
            CGRect(x: 260, y: 430, width: 600, height: 34), CGRect(x: 300, y: 370, width: 520, height: 22),
            CGRect(x: 340, y: 0, width: 36, height: 450), CGRect(x: 744, y: 0, width: 36, height: 450),
        ])
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        CGImageDestinationFinalize(destination)
    }

    private static func makePDF(at url: URL, title: String, lines: [String]) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        func draw(_ text: String, size: CGFloat, weight: CTFontUIFontType, at point: CGPoint) {
            let font = CTFontCreateUIFontForLanguage(weight, size, nil)!
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        draw(title, size: 26, weight: .emphasizedSystem, at: CGPoint(x: 56, y: 766))
        for (index, line) in lines.enumerated() {
            draw(line, size: 13, weight: .system, at: CGPoint(x: 56, y: 713 - CGFloat(index) * 26))
        }
        context.endPDFPage()
        context.closePDF()
    }
}
#endif
