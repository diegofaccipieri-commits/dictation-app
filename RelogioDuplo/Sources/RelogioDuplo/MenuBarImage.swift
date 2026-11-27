import AppKit
import RelogioDuploCore

/// Texto da barra em "negativo": placa preenchida com o texto vazado.
enum MenuBarImage {
    /// Sem trecho vermelho, a imagem é template: o sistema pinta a placa de branco na barra escura
    /// e de preto na clara. Com o domingo em vermelho a imagem precisa de cor própria, então a
    /// placa é pintada aqui, conforme `darkBar`, e o domingo é escrito em vermelho sobre ela.
    static func make(pieces: [MenuBarText.Piece], darkBar: Bool) -> NSImage {
        let mainFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let smallFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let cutout = NSMutableAttributedString()   // o que é vazado da placa
        let overlay = NSMutableAttributedString()  // o que é escrito em vermelho por cima
        var hasAlert = false
        for piece in pieces {
            let (text, font, isAlert): (String, NSFont, Bool) = switch piece {
            case .main(let text): (text, mainFont, false)
            case .small(let text): (text, smallFont, false)
            case .alert(let text): (text, mainFont, true)
            }
            hasAlert = hasAlert || isAlert
            // As duas camadas têm o mesmo texto e as mesmas fontes, então as letras caem no mesmo lugar.
            cutout.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: isAlert ? NSColor.clear : NSColor.black,
            ]))
            overlay.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: isAlert ? NSColor.systemRed : NSColor.clear,
            ]))
        }
        let textSize = cutout.size()
        let size = NSSize(width: ceil(textSize.width) + 12, height: 18)
        let plate: NSColor = hasAlert ? (darkBar ? .white : .black) : .black

        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2)
            plate.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            cutout.draw(at: origin)
            if hasAlert {
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                overlay.draw(at: origin)
            }
            return true
        }
        image.isTemplate = !hasAlert
        return image
    }
}
