import XCTest
@testable import ReunioesLogic

final class TrailingHallucinationTests: XCTestCase {

    func testRemoveAcesseONossoSiteComEnderecoNoFim() {
        let t = "O próximo passo vai ser a approval letter. Acesse o nosso site www.mesmerism.info.com"
        XCTAssertEqual(TrailingHallucination.strip(t), "O próximo passo vai ser a approval letter.")
    }

    func testRemoveInscrevaSeNoCanalNoFim() {
        XCTAssertEqual(TrailingHallucination.strip("Fechado. Inscreva-se no canal e ative o sininho!"), "Fechado.")
    }

    func testRemoveLegendasAmaraNoFim() {
        XCTAssertEqual(TrailingHallucination.strip("Pode mandar. Legendas pela comunidade Amara.org"), "Pode mandar.")
    }

    func testTextoSoComAlucinacaoFicaVazio() {
        XCTAssertEqual(TrailingHallucination.strip("Acesse o nosso site www.exemplo.com.br"), "")
    }

    func testNaoMexeQuandoAFraseEstaNoMeio() {
        let t = "Acesse o nosso site www.imigrando.com e depois me avise."
        XCTAssertEqual(TrailingHallucination.strip(t), t)
    }

    func testNaoMexeSemEndereco() {
        let t = "Fale para ele: acesse o nosso site."
        XCTAssertEqual(TrailingHallucination.strip(t), t)
    }
}
