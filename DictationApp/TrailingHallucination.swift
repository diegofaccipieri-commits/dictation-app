import Foundation

/// Fechos de vídeo que o Whisper inventa quando o áudio termina em pausa ou ruído (vêm das legendas do
/// treino). Têm partes variáveis (endereço, nome do canal), por isso ficam em regex e não na lista fixa.
/// Só sai quando é a última frase do texto.
enum TrailingHallucination {
    private static let regex = try! NSRegularExpression(
        pattern: "(^|[.!?]\\s+)(?:"
            + "acesse (?:o )?(?:nosso )?(?:site|canal|link)\\s+(?:www\\.|https?://)\\S+"
            + "|inscreva-se no (?:nosso )?canal[^.!?]*"
            + "|legendas? (?:pela|por) (?:a )?comunidade amara\\.org"
            + ")\\s*[.!?]*\\s*$",
        options: [.caseInsensitive])

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let out = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        if out != text { NSLog("DictationApp: [CLEAN] stripped trailing hallucination sentence") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
