import Foundation

enum Language: String, CaseIterable, Codable {
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case chinese = "zh"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case russian = "ru"
    case italian = "it"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .chinese: return "中文"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .italian: return "Italiano"
        }
    }
}

@Observable
class LocalizationManager {
    static let shared = LocalizationManager()

    var currentLanguage: Language {
        didSet {
            AppDefaults.userDefaults.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    private init() {
        if let saved = AppDefaults.userDefaults.string(forKey: "appLanguage"),
           let lang = Language(rawValue: saved) {
            self.currentLanguage = lang
        } else {
            self.currentLanguage = .english
        }
    }

    // MARK: - Localized Strings

    var aiUsage: String {
        switch currentLanguage {
        case .english: return "AI Usage"
        case .korean: return "AI 사용량"
        case .japanese: return "AI使用量"
        case .chinese: return "AI使用量"
        case .spanish: return "Uso de IA"
        case .french: return "Utilisation IA"
        case .german: return "KI-Nutzung"
        case .portuguese: return "Uso de IA"
        case .russian: return "Использование ИИ"
        case .italian: return "Utilizzo IA"
        }
    }

    var settings: String {
        switch currentLanguage {
        case .english: return "Settings"
        case .korean: return "설정"
        case .japanese: return "設定"
        case .chinese: return "设置"
        case .spanish: return "Ajustes"
        case .french: return "Paramètres"
        case .german: return "Einstellungen"
        case .portuguese: return "Configurações"
        case .russian: return "Настройки"
        case .italian: return "Impostazioni"
        }
    }

    var updating: String {
        switch currentLanguage {
        case .english: return "Updating..."
        case .korean: return "업데이트 중..."
        case .japanese: return "更新中..."
        case .chinese: return "更新中..."
        case .spanish: return "Actualizando..."
        case .french: return "Mise à jour..."
        case .german: return "Aktualisiere..."
        case .portuguese: return "Atualizando..."
        case .russian: return "Обновление..."
        case .italian: return "Aggiornamento..."
        }
    }

    var lastUpdate: String {
        switch currentLanguage {
        case .english: return "Updated"
        case .korean: return "업데이트"
        case .japanese: return "更新"
        case .chinese: return "更新"
        case .spanish: return "Actualizado"
        case .french: return "Mis à jour"
        case .german: return "Aktualisiert"
        case .portuguese: return "Atualizado"
        case .russian: return "Обновлено"
        case .italian: return "Aggiornato"
        }
    }

    var ago: String {
        switch currentLanguage {
        case .english: return "ago"
        case .korean: return "전"
        case .japanese: return "前"
        case .chinese: return "前"
        case .spanish: return "hace"
        case .french: return "il y a"
        case .german: return "vor"
        case .portuguese: return "atrás"
        case .russian: return "назад"
        case .italian: return "fa"
        }
    }

    // Time formatting
    func formatMinutes(_ minutes: Int) -> String {
        switch currentLanguage {
        case .english: return "\(minutes)m"
        case .korean: return "\(minutes)분"
        case .japanese: return "\(minutes)分"
        case .chinese: return "\(minutes)分钟"
        case .spanish: return "\(minutes)min"
        case .french: return "\(minutes)min"
        case .german: return "\(minutes)Min"
        case .portuguese: return "\(minutes)min"
        case .russian: return "\(minutes)мин"
        case .italian: return "\(minutes)min"
        }
    }

    func formatHours(_ hours: Int) -> String {
        switch currentLanguage {
        case .english: return "\(hours)h"
        case .korean: return "\(hours)시간"
        case .japanese: return "\(hours)時間"
        case .chinese: return "\(hours)小时"
        case .spanish: return "\(hours)h"
        case .french: return "\(hours)h"
        case .german: return "\(hours)Std"
        case .portuguese: return "\(hours)h"
        case .russian: return "\(hours)ч"
        case .italian: return "\(hours)h"
        }
    }

    func formatDays(_ days: Int) -> String {
        switch currentLanguage {
        case .english: return "\(days)d"
        case .korean: return "\(days)일"
        case .japanese: return "\(days)日"
        case .chinese: return "\(days)天"
        case .spanish: return "\(days)d"
        case .french: return "\(days)j"
        case .german: return "\(days)T"
        case .portuguese: return "\(days)d"
        case .russian: return "\(days)д"
        case .italian: return "\(days)g"
        }
    }

    func formatHoursMinutes(_ hours: Int, _ minutes: Int) -> String {
        if hours > 0 && minutes > 0 {
            return "\(formatHours(hours)) \(formatMinutes(minutes))"
        } else if hours > 0 {
            return formatHours(hours)
        } else {
            return formatMinutes(minutes)
        }
    }

    func formatDaysHours(_ days: Int, _ hours: Int) -> String {
        if days > 0 && hours > 0 {
            return "\(formatDays(days)) \(formatHours(hours))"
        } else if days > 0 {
            return formatDays(days)
        } else {
            return formatHours(hours)
        }
    }

    // "resets in X time" format
    func formatResetTime(_ text: String) -> String {
        switch currentLanguage {
        case .english: return "resets in \(text)"
        case .korean: return "\(text) 후 재설정"
        case .japanese: return "\(text)後にリセット"
        case .chinese: return "\(text)后重置"
        case .spanish: return "reinicia en \(text)"
        case .french: return "réinitialise dans \(text)"
        case .german: return "Reset in \(text)"
        case .portuguese: return "reinicia em \(text)"
        case .russian: return "сброс через \(text)"
        case .italian: return "reset tra \(text)"
        }
    }

    // Settings labels
    var language: String {
        switch currentLanguage {
        case .english: return "Language"
        case .korean: return "언어"
        case .japanese: return "言語"
        case .chinese: return "语言"
        case .spanish: return "Idioma"
        case .french: return "Langue"
        case .german: return "Sprache"
        case .portuguese: return "Idioma"
        case .russian: return "Язык"
        case .italian: return "Lingua"
        }
    }

    var refreshInterval: String {
        switch currentLanguage {
        case .english: return "Refresh Interval"
        case .korean: return "새로고침 간격"
        case .japanese: return "更新間隔"
        case .chinese: return "刷新间隔"
        case .spanish: return "Intervalo de actualización"
        case .french: return "Intervalle de rafraîchissement"
        case .german: return "Aktualisierungsintervall"
        case .portuguese: return "Intervalo de atualização"
        case .russian: return "Интервал обновления"
        case .italian: return "Intervallo di aggiornamento"
        }
    }

    var theme: String {
        switch currentLanguage {
        case .english: return "Theme"
        case .korean: return "테마"
        case .japanese: return "テーマ"
        case .chinese: return "主题"
        case .spanish: return "Tema"
        case .french: return "Thème"
        case .german: return "Thema"
        case .portuguese: return "Tema"
        case .russian: return "Тема"
        case .italian: return "Tema"
        }
    }

    var launchAtLogin: String {
        switch currentLanguage {
        case .english: return "Launch at Login"
        case .korean: return "로그인 시 실행"
        case .japanese: return "ログイン時に起動"
        case .chinese: return "登录时启动"
        case .spanish: return "Iniciar al iniciar sesión"
        case .french: return "Lancer au démarrage"
        case .german: return "Bei Anmeldung starten"
        case .portuguese: return "Iniciar no login"
        case .russian: return "Запускать при входе"
        case .italian: return "Avvia al login"
        }
    }

    var services: String {
        switch currentLanguage {
        case .english: return "Services"
        case .korean: return "서비스"
        case .japanese: return "サービス"
        case .chinese: return "服务"
        case .spanish: return "Servicios"
        case .french: return "Services"
        case .german: return "Dienste"
        case .portuguese: return "Serviços"
        case .russian: return "Сервисы"
        case .italian: return "Servizi"
        }
    }

    var general: String {
        switch currentLanguage {
        case .english: return "General"
        case .korean: return "일반"
        case .japanese: return "一般"
        case .chinese: return "通用"
        case .spanish: return "General"
        case .french: return "Général"
        case .german: return "Allgemein"
        case .portuguese: return "Geral"
        case .russian: return "Общие"
        case .italian: return "Generale"
        }
    }

    var enabled: String {
        switch currentLanguage {
        case .english: return "Enabled"
        case .korean: return "활성화"
        case .japanese: return "有効"
        case .chinese: return "已启用"
        case .spanish: return "Habilitado"
        case .french: return "Activé"
        case .german: return "Aktiviert"
        case .portuguese: return "Ativado"
        case .russian: return "Включено"
        case .italian: return "Attivato"
        }
    }

    var minutes: String {
        switch currentLanguage {
        case .english: return "minutes"
        case .korean: return "분"
        case .japanese: return "分"
        case .chinese: return "分钟"
        case .spanish: return "minutos"
        case .french: return "minutes"
        case .german: return "Minuten"
        case .portuguese: return "minutos"
        case .russian: return "минут"
        case .italian: return "minuti"
        }
    }

    var usageHistory: String {
        switch currentLanguage {
        case .english: return "Usage History"
        case .korean: return "사용량 기록"
        case .japanese: return "使用履歴"
        case .chinese: return "使用记录"
        case .spanish: return "Historial de uso"
        case .french: return "Historique"
        case .german: return "Nutzungsverlauf"
        case .portuguese: return "Histórico"
        case .russian: return "История"
        case .italian: return "Cronologia"
        }
    }

    var resetOnUse: String {
        switch currentLanguage {
        case .english: return "resets 5h after use"
        case .korean: return "사용 시 5시간 후 재설정"
        case .japanese: return "使用後5時間でリセット"
        case .chinese: return "使用后5小时重置"
        case .spanish: return "reinicia 5h después de usar"
        case .french: return "réinitialise 5h après utilisation"
        case .german: return "Reset 5h nach Nutzung"
        case .portuguese: return "reinicia 5h após uso"
        case .russian: return "сброс через 5ч после использования"
        case .italian: return "reset 5h dopo l'uso"
        }
    }

    var hours24: String {
        switch currentLanguage {
        case .english: return "24h"
        case .korean: return "24시간"
        case .japanese: return "24時間"
        case .chinese: return "24小时"
        case .spanish: return "24h"
        case .french: return "24h"
        case .german: return "24h"
        case .portuguese: return "24h"
        case .russian: return "24ч"
        case .italian: return "24h"
        }
    }

    var days7: String {
        switch currentLanguage {
        case .english: return "7d"
        case .korean: return "7일"
        case .japanese: return "7日"
        case .chinese: return "7天"
        case .spanish: return "7d"
        case .french: return "7j"
        case .german: return "7T"
        case .portuguese: return "7d"
        case .russian: return "7д"
        case .italian: return "7g"
        }
    }

    var update: String {
        switch currentLanguage {
        case .english: return "Update"
        case .korean: return "업데이트"
        case .japanese: return "アップデート"
        case .chinese: return "更新"
        case .spanish: return "Actualización"
        case .french: return "Mise à jour"
        case .german: return "Aktualisierung"
        case .portuguese: return "Atualização"
        case .russian: return "Обновление"
        case .italian: return "Aggiornamento"
        }
    }

    var available: String {
        switch currentLanguage {
        case .english: return "available"
        case .korean: return "사용 가능"
        case .japanese: return "利用可能"
        case .chinese: return "可用"
        case .spanish: return "disponible"
        case .french: return "disponible"
        case .german: return "verfügbar"
        case .portuguese: return "disponível"
        case .russian: return "доступно"
        case .italian: return "disponibile"
        }
    }

    var checking: String {
        switch currentLanguage {
        case .english: return "Checking..."
        case .korean: return "확인 중..."
        case .japanese: return "確認中..."
        case .chinese: return "检查中..."
        case .spanish: return "Comprobando..."
        case .french: return "Vérification..."
        case .german: return "Prüfen..."
        case .portuguese: return "Verificando..."
        case .russian: return "Проверка..."
        case .italian: return "Verifica..."
        }
    }

    var updateNow: String {
        switch currentLanguage {
        case .english: return "Update"
        case .korean: return "업데이트"
        case .japanese: return "更新"
        case .chinese: return "更新"
        case .spanish: return "Actualizar"
        case .french: return "Mettre à jour"
        case .german: return "Aktualisieren"
        case .portuguese: return "Atualizar"
        case .russian: return "Обновить"
        case .italian: return "Aggiorna"
        }
    }

    var checkUpdate: String {
        switch currentLanguage {
        case .english: return "Check"
        case .korean: return "확인"
        case .japanese: return "確認"
        case .chinese: return "检查"
        case .spanish: return "Comprobar"
        case .french: return "Vérifier"
        case .german: return "Prüfen"
        case .portuguese: return "Verificar"
        case .russian: return "Проверить"
        case .italian: return "Verifica"
        }
    }

    // Menu bar legend onboarding
    var menuBarLegendTitle: String {
        switch currentLanguage {
        case .english: return "Menu bar meter"
        case .korean: return "메뉴바 표시"
        case .japanese: return "メニューバー表示"
        case .chinese: return "菜单栏指示"
        case .spanish: return "Indicador en la barra de menús"
        case .french: return "Indicateur de la barre de menus"
        case .german: return "Menüleisten-Anzeige"
        case .portuguese: return "Indicador na barra de menus"
        case .russian: return "Индикатор в строке меню"
        case .italian: return "Indicatore nella barra dei menu"
        }
    }

    var menuBarLegendDescription: String {
        switch currentLanguage {
        case .english: return "Horizontal fill shows 5h remaining. Bar height shows 7d remaining."
        case .korean: return "가로 채움은 5시간(5h) 남은 양, 세로 높이는 7일(7d) 남은 양을 뜻해요."
        case .japanese: return "横方向の埋まり具合が5時間(5h)の残量、バーの高さが7日(7d)の残量を示します。"
        case .chinese: return "横向填充表示5小时(5h)剩余，柱形高度表示7天(7d)剩余。"
        case .spanish: return "El relleno horizontal muestra lo que queda en 5 h; la altura de las barras muestra lo que queda en 7 días."
        case .french: return "Le remplissage horizontal indique le restant sur 5 h ; la hauteur des barres indique le restant sur 7 j."
        case .german: return "Die horizontale Füllung zeigt den Rest für 5 Std.; die Balkenhöhe zeigt den Rest für 7 Tage."
        case .portuguese: return "O preenchimento horizontal mostra o restante em 5 h; a altura das barras mostra o restante em 7 dias."
        case .russian: return "Горизонтальная заполненность показывает остаток за 5 ч, а высота столбиков — остаток за 7 дн."
        case .italian: return "Il riempimento orizzontale mostra il restante in 5 h; l'altezza delle barre mostra il restante in 7 gg."
        }
    }

    var menuBarLegendQuickTip: String {
        switch currentLanguage {
        case .english: return "↔ 5h left · ↕ 7d left"
        case .korean: return "가로(↔) 5h 남음 · 세로(↕) 7d 남음"
        case .japanese: return "横(↔) 5h 残り · 縦(↕) 7d 残り"
        case .chinese: return "横向(↔) 剩余 5h · 纵向(↕) 剩余 7d"
        case .spanish: return "↔ Quedan 5 h · ↕ Quedan 7 d"
        case .french: return "↔ Reste 5 h · ↕ Reste 7 j"
        case .german: return "↔ 5 Std. übrig · ↕ 7 Tage übrig"
        case .portuguese: return "↔ Restam 5 h · ↕ Restam 7 d"
        case .russian: return "↔ Осталось 5 ч · ↕ Осталось 7 д"
        case .italian: return "↔ 5 h rimaste · ↕ 7 gg rimasti"
        }
    }

    var menuBarLegendHorizontal: String {
        switch currentLanguage {
        case .english: return "5h left"
        case .korean: return "5h 남음"
        case .japanese: return "5h 残り"
        case .chinese: return "剩余 5h"
        case .spanish: return "Quedan 5 h"
        case .french: return "Reste 5 h"
        case .german: return "5 Std. übrig"
        case .portuguese: return "Restam 5 h"
        case .russian: return "Осталось 5 ч"
        case .italian: return "5 h rimaste"
        }
    }

    var menuBarLegendVertical: String {
        switch currentLanguage {
        case .english: return "7d left"
        case .korean: return "7d 남음"
        case .japanese: return "7d 残り"
        case .chinese: return "剩余 7d"
        case .spanish: return "Quedan 7 d"
        case .french: return "Reste 7 j"
        case .german: return "7 Tage übrig"
        case .portuguese: return "Restam 7 d"
        case .russian: return "Осталось 7 д"
        case .italian: return "7 gg rimasti"
        }
    }

    var menuBarLegendGotIt: String {
        switch currentLanguage {
        case .english: return "Got it"
        case .korean: return "알겠어요"
        case .japanese: return "OK"
        case .chinese: return "知道了"
        case .spanish: return "Entendido"
        case .french: return "Compris"
        case .german: return "Verstanden"
        case .portuguese: return "Entendi"
        case .russian: return "Понятно"
        case .italian: return "Capito"
        }
    }

    var support: String {
        switch currentLanguage {
        case .english: return "Support"
        case .korean: return "지원"
        case .japanese: return "サポート"
        case .chinese: return "支持"
        case .spanish: return "Soporte"
        case .french: return "Support"
        case .german: return "Support"
        case .portuguese: return "Suporte"
        case .russian: return "Поддержка"
        case .italian: return "Supporto"
        }
    }

    var bugReport: String {
        switch currentLanguage {
        case .english: return "Bug Report"
        case .korean: return "버그 리포트"
        case .japanese: return "バグ報告"
        case .chinese: return "反馈问题"
        case .spanish: return "Reportar error"
        case .french: return "Signaler un bug"
        case .german: return "Fehler melden"
        case .portuguese: return "Reportar bug"
        case .russian: return "Сообщить об ошибке"
        case .italian: return "Segnala bug"
        }
    }

    var bugReportPlaceholder: String {
        switch currentLanguage {
        case .english: return "Describe the issue..."
        case .korean: return "어떤 문제가 있나요?"
        case .japanese: return "問題を説明してください..."
        case .chinese: return "请描述问题..."
        case .spanish: return "Describe el problema..."
        case .french: return "Décrivez le problème..."
        case .german: return "Beschreiben Sie das Problem..."
        case .portuguese: return "Descreva o problema..."
        case .russian: return "Опишите проблему..."
        case .italian: return "Descrivi il problema..."
        }
    }

    var bugReportSent: String {
        switch currentLanguage {
        case .english: return "Thank you for your feedback!"
        case .korean: return "소중한 의견 감사합니다!"
        case .japanese: return "フィードバックありがとうございます！"
        case .chinese: return "感谢您的反馈！"
        case .spanish: return "¡Gracias por tu opinión!"
        case .french: return "Merci pour votre retour !"
        case .german: return "Danke für Ihr Feedback!"
        case .portuguese: return "Obrigado pelo feedback!"
        case .russian: return "Спасибо за отзыв!"
        case .italian: return "Grazie per il feedback!"
        }
    }

    var send: String {
        switch currentLanguage {
        case .english: return "Send"
        case .korean: return "보내기"
        case .japanese: return "送信"
        case .chinese: return "发送"
        case .spanish: return "Enviar"
        case .french: return "Envoyer"
        case .german: return "Senden"
        case .portuguese: return "Enviar"
        case .russian: return "Отправить"
        case .italian: return "Invia"
        }
    }

    var donate: String {
        switch currentLanguage {
        case .english: return "Donate"
        case .korean: return "후원하기"
        case .japanese: return "寄付"
        case .chinese: return "捐赠"
        case .spanish: return "Donar"
        case .french: return "Faire un don"
        case .german: return "Spenden"
        case .portuguese: return "Doar"
        case .russian: return "Пожертвовать"
        case .italian: return "Dona"
        }
    }

    var includeDiagnostics: String {
        switch currentLanguage {
        case .english: return "Include diagnostics"
        case .korean: return "진단 정보 포함"
        case .japanese: return "診断情報を含める"
        case .chinese: return "包含诊断信息"
        case .spanish: return "Incluir diagnósticos"
        case .french: return "Inclure les diagnostics"
        case .german: return "Diagnosedaten einschließen"
        case .portuguese: return "Incluir diagnósticos"
        case .russian: return "Включить диагностику"
        case .italian: return "Includi diagnostica"
        }
    }

    var viewDiagnostics: String {
        switch currentLanguage {
        case .english: return "View included data"
        case .korean: return "포함될 정보 보기"
        case .japanese: return "含まれるデータを確認"
        case .chinese: return "查看包含的数据"
        case .spanish: return "Ver datos incluidos"
        case .french: return "Voir les données incluses"
        case .german: return "Enthaltene Daten anzeigen"
        case .portuguese: return "Ver dados incluídos"
        case .russian: return "Просмотреть данные"
        case .italian: return "Visualizza dati inclusi"
        }
    }
}

// Global accessor
let L = LocalizationManager.shared
