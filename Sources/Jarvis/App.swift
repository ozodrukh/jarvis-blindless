import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: JarvisController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Self.controller?.close() }
}

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = JarvisController()
    var body: some Scene {
        Window("Джарвис", id: "main") {
            MainView(controller: controller, player: controller.player)
                .task { AppDelegate.controller = controller; controller.start() }
        }
        .defaultSize(width: 700, height: 650)
        .windowResizability(.contentMinSize)
        MenuBarExtra("Джарвис", systemImage: "waveform") {
            JarvisMenu(controller: controller)
        }
    }
}

private struct JarvisMenu: View {
    @ObservedObject var controller: JarvisController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(controller.status)
        Button("Открыть окно") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Слушать запрос") { controller.listen() }.disabled(!controller.ready || !controller.microphoneOn)
        Button("Пауза книги") { controller.pauseBook() }
        Button("Остановить ответ") { controller.interrupt() }
        Button("Завершить разговор") { controller.endChat() }.disabled(!controller.chatActive)
        Button("Выбрать файл настроек…") { controller.chooseConfiguration() }
        Button(controller.microphoneOn ? "Выключить микрофон" : "Включить микрофон") { controller.toggleMicrophone() }.disabled(!controller.ready)
        Divider()
        Button("Завершить Джарвиса") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private struct MainView: View {
    @ObservedObject var controller: JarvisController
    @ObservedObject var player: BookPlayer
    @State private var message = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Джарвис").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Голосовой помощник · онлайн и локально").foregroundStyle(.secondary)
                }
                Spacer()
                Label(controller.microphoneOn ? "Микрофон включён" : "Микрофон выключен",
                      systemImage: controller.microphoneOn ? "mic.fill" : "mic.slash")
            }
            Text(controller.status).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Состояние. \(controller.status)")
            HStack {
                Button("Слушать запрос", systemImage: "waveform") { controller.listen() }
                    .disabled(!controller.ready || !controller.microphoneOn).buttonStyle(.borderedProminent)
                    .keyboardShortcut("l", modifiers: .command)
                Button("Остановить ответ") { controller.interrupt() }.keyboardShortcut(.escape, modifiers: [])
                Button("Завершить разговор") { controller.endChat() }.disabled(!controller.chatActive)
                Button(controller.microphoneOn ? "Выключить микрофон" : "Включить микрофон") { controller.toggleMicrophone() }
                    .disabled(!controller.ready)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Микрофон").font(.caption)
                    ProgressView(value: controller.inputLevel).frame(width: 100)
                        .accessibilityLabel("Уровень микрофона")
                        .accessibilityValue(controller.inputDescription)
                    Text(controller.inputDescription).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(controller.configurationName).font(.caption).lineLimit(1).help(controller.configurationName)
                    Spacer()
                    Button("Выбрать настройки…") { controller.chooseConfiguration() }
                    Button("Перечитать") { controller.restartVoice() }
                }
                if !controller.configurationWarning.isEmpty {
                    Text(controller.configurationWarning).font(.caption).foregroundStyle(.red)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(player.summary).font(.headline).textSelection(.enabled)
                    if !player.problem.isEmpty { Text(player.problem).foregroundStyle(.red).textSelection(.enabled) }
                    if player.books.isEmpty {
                        Text("Выберите папку audiobooks с файлом meta.json. Для первой проверки можно взять демонстрационную библиотеку из комплекта.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        List(player.books) { book in
                            Button { controller.playBook(book) } label: {
                                HStack {
                                    Image(systemName: player.currentID == book.id ? "speaker.wave.2" : "book")
                                    VStack(alignment: .leading) {
                                        Text(book.title)
                                        if let author = book.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text("\(book.files.count) частей").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Слушать книгу \(book.title) с сохранённого места")
                        }.frame(minHeight: 100, idealHeight: 150, maxHeight: 220)
                    }
                    HStack {
                        Button("Выбрать папку книг…") { controller.chooseLibrary() }
                        Button("Пауза") { controller.pauseBook() }.disabled(player.currentID == nil)
                        Spacer()
                    }
                }.padding(6)
            } label: { Text("Аудиокниги").accessibilityAddTraits(.isHeader) }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.lastHeard.isEmpty ? "Скажите: «Джарвис, какие у меня книги?»" : "Вы: \(controller.lastHeard)")
                            if !controller.lastReply.isEmpty { Text("Джарвис: \(controller.lastReply)") }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(minHeight: 70, idealHeight: 110, maxHeight: 160)
                    HStack {
                        TextField("Например: продолжи книгу", text: $message).onSubmit(send)
                            .accessibilityLabel("Текстовый запрос для проверки")
                        Button("Отправить", action: send).disabled(!controller.ready || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(6)
            } label: { Text("Разговор").accessibilityAddTraits(.isHeader) }
            HStack {
                Button("Перезапустить голосовой режим") { controller.restartVoice() }
                Spacer()
                if let elapsed = controller.responseTime {
                    Text("Подготовка ответа: \(elapsed, specifier: "%.1f") с").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !controller.stageTimings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(["stt", "llm", "tts"], id: \.self) { stage in
                        if let timing = controller.stageTimings[stage] {
                            Text("\(stage == "stt" ? "Распознавание" : stage == "llm" ? "Ответ" : "Озвучка"): \(timing)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            Text("Окно можно закрыть: помощник останется в строке меню. Чтобы отключить прослушивание, выключите микрофон или завершите приложение.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        }
        .frame(minWidth: 650, minHeight: 600)
    }

    private func send() { controller.sendText(message); message = "" }
}
