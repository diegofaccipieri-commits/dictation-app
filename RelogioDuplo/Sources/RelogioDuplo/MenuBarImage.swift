import AppKit

/// Texto da barra em "negativo": placa preenchida com o texto vazado.
/// Imagem template: o sistema pinta a placa de branco na barra escura e de preto na clara.
enum MenuBarImage {
    static func make(text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        // Siglas das cidades em fonte menor que as horas.
        let small = NSFont.systemFont(ofSize: 9, weight: .bold)
        for label in ["TO", "SP"] {
            let range = (text as NSString).range(of: " \(label)")
            if range.location != NSNotFound { string.addAttribute(.font, value: small, range: range) }
        }
        let textSize = string.size()
        let size = NSSize(width: ceil(textSize.width) + 12, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            string.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
