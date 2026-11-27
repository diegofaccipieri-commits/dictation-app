import RelogioDuploCore
import SwiftUI

/// Janela "Cidades e relógios": de 1 a 4 relógios, cada um com cidade e sigla.
struct CitiesView: View {
    let model: AppModel
    @State private var picking: UUID?

    var body: some View {
        let clocks = model.settings.clocks
        VStack(alignment: .leading, spacing: 12) {
            Text("Relógios na barra de menu").font(.headline)

            ForEach(Array(clocks.enumerated()), id: \.element.id) { index, clock in
                HStack(spacing: 8) {
                    Button { picking = clock.id } label: {
                        HStack {
                            Text(model.cityName(for: clock))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                        }
                        .frame(width: 190)
                    }
                    .popover(isPresented: Binding(
                        get: { picking == clock.id },
                        set: { if !$0 { picking = nil } }
                    )) {
                        CityPicker(cities: model.cities, selected: clock.zoneID) { city in
                            model.setCity(city, for: clock.id)
                            picking = nil
                        }
                    }

                    TextField("Sigla", text: Binding(
                        get: { clock.label },
                        set: { model.setLabel($0, for: clock.id) }
                    ))
                    .frame(width: 58)
                    .accessibilityLabel("Sigla de \(model.cityName(for: clock))")

                    Button { model.moveClock(clock.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                        .accessibilityLabel("Mover para cima")
                    Button { model.moveClock(clock.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == clocks.count - 1)
                        .accessibilityLabel("Mover para baixo")
                    Button { model.removeClock(clock.id) } label: { Image(systemName: "trash") }
                        .disabled(clocks.count == 1)
                        .accessibilityLabel("Remover relógio")
                }
            }

            HStack {
                Button("Adicionar relógio") { model.addClock() }
                    .disabled(clocks.count >= Settings.maxClocks)
                Spacer()
                Text("\(clocks.count) de \(Settings.maxClocks)").foregroundStyle(.secondary)
            }

            Text("A sigla aparece ao lado da hora na barra. Até 4 caracteres.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct CityPicker: View {
    let cities: [City]
    let selected: String
    let choose: (City) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("Buscar cidade", text: $query)
                .textFieldStyle(.roundedBorder)
            List(CityCatalog.search(query, in: cities)) { city in
                Button { choose(city) } label: {
                    HStack {
                        Text(city.name)
                        Spacer()
                        Text(city.region).font(.caption).foregroundStyle(.secondary)
                        if city.zoneID == selected { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 300, height: 340)
    }
}
