# Token Burn — AI 코딩 에이전트 사용량 모니터링 메뉴바 앱

AI 코딩 에이전트를 쓰면서 "지금 한도가 얼마나 남았지?", "오늘 토큰을 얼마나 태웠지?" 궁금했던 적 없으신가요?

**Token Burn**은 Claude Code와 Codex의 사용량을 macOS 메뉴바에서 실시간으로 보여주는 앱입니다.

## 왜 만들었나

Claude Code Max 구독을 쓰면서 가장 불편했던 건, 5시간 / 7일 사용 한도가 얼마나 남았는지 확인하기 어렵다는 것이었습니다. 웹에서 확인하려면 여러 단계를 거쳐야 하고, CLI에서 `/cost`를 쳐봐야 현재 세션 정보만 나옵니다.

"그냥 메뉴바에서 바로 보면 안 되나?"

이 한 문장에서 Token Burn이 시작됐습니다.

## 주요 기능

### 메뉴바 사용량 게이지

메뉴바에 Claude와 Codex의 잔여 사용량이 막대 그래프로 표시됩니다.

- **가로 채움**: 5시간 한도 잔여량
- **세로 높이**: 7일 한도 잔여량
- **heartbeat 애니메이션**: AI가 사용 중일 때 실시간 감지

한눈에 "지금 위험한가?"를 알 수 있습니다.

### Token Burn 트래커

Claude Code와 Codex가 로컬에 남기는 로그 파일(JSONL, SQLite)을 분석하여 토큰 소모량을 추적합니다.

- **1시간 / 24시간 / 7일** 스코프 전환 (스크롤/스와이프로 자연스럽게)
- **일별 막대 차트**로 소모 패턴 한눈에
- 오늘 얼마나 태웠는지 헤더에 바로 표시

모든 데이터는 **로컬에서만** 처리됩니다. 서버로 전송되는 정보는 없습니다.

### 리셋 타이머

Claude의 5시간/7일 한도가 언제 재설정되는지 정확히 알려줍니다. "3시간 38분 후 재설정" — 이걸 알면 작업 계획을 세울 수 있습니다.

### 사용 중 감지

`nettop`과 `lsof`를 활용하여 Claude Code / Codex가 실제로 API를 호출하고 있는지 실시간 감지합니다. 사용 중일 때 메뉴바 아이콘에 부드러운 heartbeat 애니메이션이 나타납니다.

## 기술적 도전들

### 키체인 반복 프롬프트

Claude Code는 OAuth 토큰을 macOS 키체인에 저장하는데, 토큰 갱신 시 키체인 항목을 **삭제 후 재생성**합니다. 이 때문에 "항상 허용"을 눌러도 8시간마다 비밀번호 프롬프트가 다시 떴습니다.

해결: 파일 기반 크레덴셜(`~/.claude/.credentials.json`)을 우선 읽고, 파일이 없으면 키체인에서 복원하는 방식으로 프롬프트 빈도를 최소화했습니다.

### macOS 26 메뉴바 호환성

macOS 26(Tahoe)에서 `.app` 번들 내 바이너리의 `NSStatusItem`이 표시되지 않는 문제가 있었습니다. 같은 바이너리를 `.app` 밖에서 실행하면 정상 동작했습니다.

해결: 바이너리를 `~/Library/Application Support/TokenBurn/`에 설치하고, LaunchAgent로 로그인 시 자동 실행하는 방식을 채택했습니다.

### 성능 최적화

메뉴바 앱은 항상 떠있기 때문에 리소스 사용이 최소화되어야 합니다.

- **아이콘 렌더링**: 데이터 변경 시에만 렌더링 (스냅샷 비교)
- **ProcessMonitor**: `nettop`/`lsof` 호출을 백그라운드 스레드로 이동
- **패널 전환**: MainPanel을 메모리에 유지하여 설정 화면 전환 시 재생성 방지

## 기술 스택

- **Swift** + **SwiftUI** (macOS 14+)
- **AppKit** NSStatusItem (메뉴바 아이콘)
- **Anthropic OAuth API** (Claude 사용량)
- **SQLite3** (Codex 로그 파싱)
- **Sparkle** (자동 업데이트)
- **Swift Package Manager**

## 앞으로

- Gemini 지원 추가
- 프로젝트별 토큰 분석
- 비용 추정 기능
- 알림 (한도 임박 시)

## 설치

```bash
# Homebrew (예정)
brew install --cask tokenburn

# 또는 GitHub Releases에서 DMG 다운로드
```

GitHub: [multi-turn-inc/ai-usage-meter](https://github.com/multi-turn-inc/ai-usage-meter)

---

*Token Burn은 Claude Code와 함께 개발되었습니다.*
