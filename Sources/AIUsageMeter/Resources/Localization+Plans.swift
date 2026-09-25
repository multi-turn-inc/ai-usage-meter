import Foundation

/// Strings for the plan board and its advice.
extension LocalizationManager {

    private func pick(_ en: String, _ ko: String, _ ja: String, _ zh: String, _ es: String,
                      _ fr: String, _ de: String, _ pt: String, _ ru: String, _ it: String) -> String {
        switch currentLanguage {
        case .english: return en
        case .korean: return ko
        case .japanese: return ja
        case .chinese: return zh
        case .spanish: return es
        case .french: return fr
        case .german: return de
        case .portuguese: return pt
        case .russian: return ru
        case .italian: return it
        }
    }

    var useNow: String {
        pick("Use now", "지금 쓸 요금제", "今使うプラン", "现在使用", "Usar ahora",
             "À utiliser", "Jetzt nutzen", "Usar agora", "Использовать сейчас", "Usa ora")
    }

    var inUse: String {
        pick("In use", "현재 사용 중", "使用中", "正在使用", "En uso", "En cours d'utilisation", "In Nutzung",
             "Em uso", "Используется", "In uso")
    }

    var recommended: String {
        pick("Recommended", "추천", "おすすめ", "推荐", "Recomendado", "Recommandé", "Empfohlen", "Recomendado",
             "Рекомендуем", "Consigliato")
    }

    var otherPlans: String {
        pick("Other plans", "다른 요금제", "他のプラン", "其他方案", "Otros planes", "Autres forfaits",
             "Weitere Pläne", "Outros planos", "Другие планы", "Altri piani")
    }

    var keepGoingResetsFirst: String {
        pick("Keep using it — this plan resets first", "계속 쓰세요 — 가장 먼저 리셋되는 요금제예요",
             "このまま使用 — 最初にリセットされるプランです", "继续使用 — 这个方案最先重置",
             "Sigue usándolo: este plan se reinicia primero", "Continuez — ce forfait se réinitialise en premier",
             "Weiter so — dieser Plan wird zuerst zurückgesetzt", "Continue usando — este plano reinicia primeiro",
             "Продолжайте — этот план сбросится первым", "Continua — questo piano si azzera per primo")
    }

    var keepGoingOnlyOption: String {
        pick("Keep using it — the only plan with room", "계속 쓰세요 — 여유 있는 유일한 요금제예요",
             "このまま使用 — 余裕のある唯一のプランです", "继续使用 — 唯一有余量的方案",
             "Sigue usándolo: es el único plan con margen", "Continuez — c'est le seul forfait avec de la marge",
             "Weiter so — der einzige Plan mit Spielraum", "Continue usando — é o único plano com margem",
             "Продолжайте — это единственный план с запасом", "Continua — è l'unico piano con margine")
    }

    var keepGoingMostRoom: String {
        pick("Keep using it — nothing is about to reset", "계속 쓰세요 — 곧 리셋되는 요금제가 없어요",
             "このまま使用 — 期限の近いプランはありません", "继续使用 — 暂无即将重置的方案",
             "Sigue usándolo: nada está por reiniciarse", "Continuez — rien n'est sur le point d'être réinitialisé",
             "Weiter so — nichts wird bald zurückgesetzt", "Continue usando — nada está para reiniciar",
             "Продолжайте — ничего не сбросится скоро", "Continua — niente sta per azzerarsi")
    }

    func switchTo(_ name: String) -> String {
        pick("Switch to \(name)", "\(name) 요금제로 바꾸세요", "\(name)に切り替え", "切换到 \(name)",
             "Cambia a \(name)", "Passez à \(name)", "Zu \(name) wechseln", "Mude para \(name)",
             "Переключитесь на \(name)", "Passa a \(name)")
    }

    func resetsFirstIn(_ duration: String) -> String {
        pick("it resets first, in \(duration)", "\(duration) 뒤 가장 먼저 리셋돼요",
             "\(duration)後に最初にリセット", "\(duration)后最先重置",
             "se reinicia primero, en \(duration)", "réinitialisé en premier, dans \(duration)",
             "wird zuerst zurückgesetzt, in \(duration)", "reinicia primeiro, em \(duration)",
             "сбросится первым, через \(duration)", "si azzera per primo, tra \(duration)")
    }

    var copyCommand: String {
        pick("Copy command", "명령 복사", "コマンドをコピー", "复制命令", "Copiar comando", "Copier la commande",
             "Befehl kopieren", "Copiar comando", "Скопировать команду", "Copia comando")
    }

    var copied: String {
        pick("Copied", "복사됨", "コピーしました", "已复制", "Copiado", "Copié", "Kopiert", "Copiado",
             "Скопировано", "Copiato")
    }

    var copyLaunchCommand: String {
        pick("Copy command to run on this plan", "이 요금제로 실행하는 명령 복사",
             "このプランで実行するコマンドをコピー", "复制在此方案上运行的命令",
             "Copiar el comando para usar este plan", "Copier la commande pour ce forfait",
             "Befehl für diesen Plan kopieren", "Copiar o comando para usar este plano",
             "Скопировать команду для этого плана", "Copia il comando per questo piano")
    }

    /// The plan to use now, on its chip.
    var now: String {
        pick("Now", "지금", "今", "当前", "Ahora", "Maintenant", "Jetzt", "Agora", "Сейчас", "Ora")
    }

    var resetsFirst: String {
        pick("Resets first", "가장 먼저 리셋", "最初にリセット", "最先重置", "Se reinicia primero",
             "Réinitialisé en premier", "Wird zuerst zurückgesetzt", "Reinicia primeiro",
             "Сбросится первым", "Si azzera per primo")
    }

    func unusedAtPace(_ percent: Int) -> String {
        pick("~\(percent)% would expire unused at this pace",
             "이 속도면 \(percent)%는 못 쓰고 사라짐",
             "このペースだと\(percent)%が未使用のままリセット",
             "按此速度约\(percent)%将作废",
             "a este ritmo ~\(percent)% caducará sin usar",
             "à ce rythme ~\(percent)% expirera inutilisé",
             "bei diesem Tempo verfallen ~\(percent)% ungenutzt",
             "neste ritmo ~\(percent)% expira sem uso",
             "при таком темпе ~\(percent)% сгорит",
             "a questo ritmo ~\(percent)% scade inutilizzato")
    }

    func freesAfter(_ duration: String) -> String {
        pick("frees in \(duration)", "\(duration) 뒤 풀림", "\(duration)後に解除", "\(duration)后恢复",
             "libre en \(duration)", "libre dans \(duration)", "frei in \(duration)", "libera em \(duration)",
             "освободится через \(duration)", "libero tra \(duration)")
    }

    func runsOutEarly(_ duration: String) -> String {
        pick("runs out \(duration) before reset", "리셋 \(duration) 전에 소진 예상",
             "リセットの\(duration)前に枯渇", "将在重置前\(duration)用完",
             "se agota \(duration) antes del reinicio", "épuisé \(duration) avant la réinitialisation",
             "\(duration) vor dem Reset aufgebraucht", "esgota \(duration) antes do reinício",
             "закончится за \(duration) до сброса", "finisce \(duration) prima dell'azzeramento")
    }

    func nextPlan(_ name: String) -> String {
        pick("Next: \(name)", "다음: \(name)", "次: \(name)", "下一个：\(name)", "Luego: \(name)",
             "Ensuite : \(name)", "Danach: \(name)", "Depois: \(name)", "Затем: \(name)", "Poi: \(name)")
    }

    func backTo(_ name: String, in duration: String) -> String {
        pick("Back to \(name) in \(duration)", "\(duration) 뒤 \(name) 요금제로 복귀",
             "\(duration)後に\(name)へ戻る", "\(duration)后回到\(name)",
             "Vuelve a \(name) en \(duration)", "Retour à \(name) dans \(duration)",
             "In \(duration) zurück zu \(name)", "Volte para \(name) em \(duration)",
             "Через \(duration) вернуться к \(name)", "Torna a \(name) tra \(duration)")
    }

    var onlyPlanWithRoom: String {
        pick("Only plan with room", "여유 있는 유일한 요금제", "余裕のある唯一のプラン", "唯一有余量的方案",
             "Único plan con margen", "Seul forfait avec de la marge", "Einziger Plan mit Spielraum",
             "Único plano com margem", "Единственный план с запасом", "Unico piano con margine")
    }

    var nothingExpiring: String {
        pick("Nothing expiring yet · most room", "곧 리셋되는 요금제 없음 · 여유 최대",
             "期限の近いプランなし・余裕が最大", "暂无即将重置 · 余量最多",
             "Nada caduca aún · más margen", "Rien n'expire encore · plus de marge",
             "Nichts läuft bald ab · meister Spielraum", "Nada expirando · mais margem",
             "Ничего не сгорает · больше всего запаса", "Nulla in scadenza · più margine")
    }

    var everythingOut: String {
        pick("Everything is out", "모든 요금제 소진", "すべて枯渇", "全部用尽", "Todo agotado",
             "Tout est épuisé", "Alles aufgebraucht", "Tudo esgotado", "Всё исчерпано", "Tutto esaurito")
    }

    func freesIn(_ name: String, _ duration: String) -> String {
        pick("\(name) frees up in \(duration)", "\(name) \(duration) 뒤 풀림",
             "\(name)は\(duration)後に解除", "\(name) \(duration)后恢复",
             "\(name) se libera en \(duration)", "\(name) se libère dans \(duration)",
             "\(name) wieder frei in \(duration)", "\(name) libera em \(duration)",
             "\(name) освободится через \(duration)", "\(name) si libera tra \(duration)")
    }

    var connect: String {
        pick("Connect", "연결", "接続", "连接", "Conectar", "Connecter", "Verbinden", "Conectar",
             "Подключить", "Collega")
    }

    var notConnected: String {
        pick("Not connected", "미연결", "未接続", "未连接", "Sin conectar", "Non connecté",
             "Nicht verbunden", "Não conectado", "Не подключено", "Non collegato")
    }

    var credits: String {
        pick("Credits", "크레딧", "クレジット", "额度", "Créditos", "Crédits", "Guthaben", "Créditos",
             "Кредиты", "Crediti")
    }

    var signIn: String {
        pick("Sign in", "로그인", "ログイン", "登录", "Entrar", "Connexion", "Anmelden", "Entrar",
             "Войти", "Accedi")
    }

    var signingIn: String {
        pick("Signing in…", "로그인 중…", "ログイン中…", "登录中…", "Iniciando…", "Connexion…",
             "Anmeldung…", "Entrando…", "Вход…", "Accesso…")
    }

    var allowAccess: String {
        pick("Allow", "허용", "許可", "允许", "Permitir", "Autoriser", "Erlauben", "Permitir",
             "Разрешить", "Consenti")
    }

    var hide: String {
        pick("Hide", "숨기기", "非表示", "隐藏", "Ocultar", "Masquer", "Ausblenden", "Ocultar",
             "Скрыть", "Nascondi")
    }

    func loginCount(_ count: Int) -> String {
        pick("\(count) logins", "로그인 \(count)개", "ログイン\(count)件", "\(count)个登录",
             "\(count) sesiones", "\(count) connexions", "\(count) Logins", "\(count) logins",
             "входов: \(count)", "\(count) accessi")
    }

    var out: String {
        pick("Out", "소진", "枯渇", "用尽", "Agotado", "Épuisé", "Leer", "Esgotado", "Исчерпан", "Esaurito")
    }

    var left: String {
        pick("left", "남음", "残り", "剩余", "restante", "restant", "übrig", "restante", "осталось", "rimasto")
    }

    func resetsIn(_ duration: String) -> String {
        pick("resets in \(duration)", "\(duration) 뒤 리셋", "\(duration)後にリセット", "\(duration)后重置",
             "se reinicia en \(duration)", "réinit. dans \(duration)", "Reset in \(duration)",
             "reinicia em \(duration)", "сброс через \(duration)", "si azzera tra \(duration)")
    }

    var noPlansYet: String {
        pick("No plans yet. Add one in Settings.", "요금제가 없습니다. 설정에서 추가하세요.",
             "プランがありません。設定で追加してください。", "暂无方案，请在设置中添加。",
             "Aún no hay planes. Añade uno en Ajustes.", "Aucun forfait. Ajoutez-en un dans les Paramètres.",
             "Noch keine Pläne. In den Einstellungen hinzufügen.", "Nenhum plano ainda. Adicione em Configurações.",
             "Планов нет. Добавьте в настройках.", "Nessun piano. Aggiungine uno nelle Impostazioni.")
    }

    var pinToMenuBar: String {
        pick("Show in menu bar", "메뉴바에 표시", "メニューバーに表示", "在菜单栏显示", "Mostrar en la barra de menús",
             "Afficher dans la barre des menus", "In der Menüleiste zeigen", "Mostrar na barra de menus",
             "Показывать в строке меню", "Mostra nella barra dei menu")
    }

    var unpinFromMenuBar: String {
        pick("Stop showing in menu bar", "메뉴바 표시 해제", "メニューバー表示を解除", "取消菜单栏显示",
             "Dejar de mostrar en la barra", "Ne plus afficher dans la barre", "Nicht mehr in der Menüleiste",
             "Parar de mostrar na barra", "Не показывать в строке меню", "Non mostrare nella barra")
    }

    var addPlanHint: String {
        pick("Same email in another org? Choose it on the sign-in page.",
             "같은 이메일의 다른 조직은 로그인 화면에서 고르세요.",
             "同じメールの別組織はログイン画面で選択してください。",
             "同一邮箱的其他组织，请在登录页中选择。",
             "¿Mismo correo en otra organización? Elígela al iniciar sesión.",
             "Même e-mail, autre organisation ? Choisissez-la à la connexion.",
             "Gleiche E-Mail, andere Organisation? Beim Anmelden auswählen.",
             "Mesmo e-mail em outra organização? Escolha na tela de login.",
             "Та же почта в другой организации? Выберите её при входе.",
             "Stessa email in un'altra organizzazione? Sceglila all'accesso.")
    }
}
