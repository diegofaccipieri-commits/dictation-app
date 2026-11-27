import AppKit
import RelogioDuploCore

/// Texto da barra em "negativo": placa preenchida com o texto vazado.
/// Imagem template: o sistema pinta a placa de branco na barra escura e de preto na clara.
enum MenuBarImage {
    static func make(pieces: [MenuBarText.Piece]) -> NSImage {
        let mainFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let smallFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let string = NSMutableAttributedString()
        for piece in pieces {
            let (text, font): (String, NSFont) = switch piece {
            case .main(let text): (text, mainFont)
            case .small(let text): (text, smallFont)
            }
            string.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
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
