#if DEBUG
import AppKit
import PDFKit

/// Sample notes and files for trying Folio and for its screenshots and tests, written to a folder of your choice so
/// your own files are never touched. Launch with `-FolioLibrary <folder> -FolioDemo YES`.
enum DemoLibrary {
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

        _ = folder("Inbox")
        _ = folder("Personal/Cooking")
        _ = folder("Projects/Design")
        _ = folder("Travel/Photos")
        _ = folder("Travel/.assets")
        _ = folder("University/Linear algebra")

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
        write("Projects/Folio roadmap.md", """
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
            "Design and build of the Folio website", "Three pages, light and dark", "Delivery in four weeks",
        ])
    }

    private static func drawTorii(to url: URL, jpeg: Bool = false) {
        let size = NSSize(width: 1400, height: 620)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(hex: 0xF3CDB0).setFill(); rect.fill()
            NSColor(hex: 0xFBE6CB).setFill(); NSBezierPath(ovalIn: NSRect(x: 960, y: 400, width: 140, height: 140)).fill()
            NSColor(hex: 0xD29C84).setFill(); NSBezierPath(ovalIn: NSRect(x: -200, y: -380, width: 1200, height: 640)).fill()
            NSColor(hex: 0xB97968).setFill(); NSBezierPath(ovalIn: NSRect(x: 600, y: -420, width: 1100, height: 620)).fill()
            NSColor(hex: 0xB5321F).setFill()
            NSRect(x: 260, y: 430, width: 600, height: 34).fill()
            NSRect(x: 300, y: 370, width: 520, height: 22).fill()
            NSRect(x: 340, y: 0, width: 36, height: 450).fill()
            NSRect(x: 744, y: 0, width: 36, height: 450).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = jpeg ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) : bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func makePDF(at url: URL, title: String, lines: [String]) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold)]).draw(at: CGPoint(x: 56, y: 760))
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 13)]).draw(at: CGPoint(x: 56, y: 710 - CGFloat(index) * 26))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }
}
#endif
