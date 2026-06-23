# Token Burn 블로그 글 작성 맥락

## 1. 프로젝트 개요

**Token Burn**은 Claude Code와 Codex의 사용량을 macOS 메뉴바에서 실시간으로 보여주는 오픈소스 앱이다. 원래 "AI Usage Meter"라는 이름으로 시작했고, 토큰 추적 기능을 추가하면서 "Token Burn"으로 리브랜딩했다.

- **GitHub**: https://github.com/multi-turn-inc/ai-usage-meter
- **기술 스택**: Swift, SwiftUI, AppKit, Swift Package Manager
- **지원 서비스**: Claude Code (Anthropic), Codex (OpenAI)
- **현재 버전**: v4.2.0

## 2. 블로그 플랫폼 정보

- **프레임워크**: Next.js 16 + MDX
- **경로**: `/Users/junghunkim/_PARA/2_Areas/🏢_멀티턴_운영/ZUZU/docs/multi-turn-homepage`
- **글 위치**: `src/content/blog/token-burn.mdx`
- **이미지 위치**: `public/blog/figures/token-burn/`
- **썸네일**: `public/blog/thumbnails/token-burn.png` (아직 없음)
- **영문 번역**: `src/content/blog/token-burn.en.mdx` (아직 없음)

### Frontmatter 형식
```yaml
---
title: "제목"
description: "SEO 설명"
date: "YYYY-MM-DD"
author:
  name: "JUNGHUN KIM"
  picture: "/blog/authors/junghun.png"
thumbnail: "/blog/thumbnails/token-burn.png"
tags: ["tag1", "tag2"]
---
```

## 3. 블로그 기존 글 톤 & 스타일

- **언어**: 한국어 기본, 영문/독문 번역 별도 파일
- **톤**: 철학적이면서 기술적. 문제에서 출발하여 비판 → 제안 → 구체적 설계로 진행
- **개성**: 지적 정직함 (한계 인정, 위험 명시), 시각 자료는 장식이 아닌 설명용
- **분량**: 짧은 글 ~650자부터 긴 글 5000+자까지 다양
- **구조**: `##` h2를 주요 구분으로 사용, 표와 코드블록 활용

### 효과적인 패턴들
1. **Problem-First Opening** — 해결책이 아닌 고통에서 시작
2. **기존 접근 비판** — 테이블로 공정하게 비교
3. **구체적 숫자** — 추상보다 "82x22 픽셀", "8시간마다"
4. **솔직한 한계** — "우아한 해결이라고 할 수 없지만, 동작한다"
5. **질문으로 마무리** — 답이 아닌 다음 측정 대상 제시

## 4. 현재 초안 상태

`src/content/blog/token-burn.mdx`에 초안이 있음. 구조:

1. **보이지 않는 소비** — 토큰 불투명성 문제 제기
2. **메뉴바에서 한 눈에** — 메뉴바 아이콘 설명 (5h/7d 이중 인코딩)
3. **토큰 소모량 추적** — Token Burn 차트, JSONL/SQLite 파싱
4. **기존 도구와의 차이** — `/cost`, ccusage, TokenTracker 비교. "잔여량 중심 관점"
5. **기술적 세부** — 키체인, macOS 26, 토큰 정확성
6. **설정** — 간단한 설정 소개
7. **앞으로** — 프로젝트별 토큰 분석 방향

## 5. 준비된 이미지

| 파일 | 내용 | 상태 |
|------|------|------|
| `panel.png` | 메인 패널 (원형 게이지 + 서비스 카드 + Token Burn 차트) | ✅ macOS 네이티브 캡처 |
| `settings.png` | 설정 화면 (서비스 토글 + 일반 + 업데이트 + 지원) | ✅ macOS 네이티브 캡처 |
| `menubar.png` | 메뉴바 아이콘 (Claude + Codex 바) | ✅ 프로그래밍 렌더링 |
| `thumbnails/token-burn.png` | 블로그 목록 썸네일 | ❌ 아직 없음 |

이미지들은 `screencapture -l <windowID>`로 캡처하여 macOS 네이티브 그림자가 포함된 깔끔한 상태.

## 6. Token Burn 핵심 기능

### 메뉴바 아이콘
- Claude(오렌지)와 Codex(보라-블루) 막대 그래프
- 가로 채움 = 5시간 잔여량, 세로 높이 = 7일 잔여량
- AI 사용 중 heartbeat 애니메이션 (nettop/lsof로 실시간 감지)
- 반투명 검정 배경으로 다크/라이트 모드 모두 가시성 확보

### 메인 패널
- 원형 게이지 2개 (Claude, Codex)
- 서비스 카드 (5h/7d 퍼센트, 리셋 시간, Max/Pro 뱃지)
- Token Burn 차트 (1h/24h/7d 스코프, 트랙패드 스크롤로 전환)
- 헤더에 "Token Burn · XXK today"

### 토큰 파싱
- Claude Code: `~/.claude/projects/**/*.jsonl` (JSONL)
- Codex: `~/.codex/logs_2.sqlite` (SQLite)
- `input_tokens + output_tokens`만 카운트 (cache 제외, Claude /stats와 일치)
- 메시지별 타임스탬프 기준 집계

### 기술적 도전
1. **키체인 반복 프롬프트**: Claude Code가 토큰 갱신 시 키체인 ACL 초기화 → 파일 우선 읽기로 해결
2. **macOS 26 NSStatusItem**: .app 번들에서 메뉴바 아이콘 미표시 → LaunchAgent + 번들 외부 바이너리로 우회
3. **성능**: 12fps 아이콘 렌더링 + ProcessMonitor 백그라운드 처리

## 7. 개발 여정 (블로그에서 활용 가능한 스토리)

- 처음엔 단순한 사용량 게이지 앱 (원형 그래프 2개)
- 키체인 반복 프롬프트 문제로 파일 기반 크레덴셜 구현
- 토큰 추적 기능 추가하면서 "AI Usage Meter" → "Token Burn" 리브랜딩
- ccusage(4800+ stars)와의 차별점: 메뉴바 상주, 잔여량 중심
- macOS 26에서 .app 번들 메뉴바 아이콘 미표시 — Stats 앱 분석, 수십 번의 디버깅 끝에 LaunchAgent 우회
- Codex 색상 변경 (초록 → 보라-블루) — 새 Codex 아이콘 반영
- 설정 UI 전면 재디자인 — 아이콘 행 + 카드 스타일
- Claude Code와 함께 개발 (이 대화 자체가 하나의 긴 페어 프로그래밍 세션)

## 8. 경쟁 환경

| 도구 | 유형 | Stars | 차별점 |
|------|------|-------|--------|
| ccusage | CLI | 4800+ | 가장 인기, npx로 실행 |
| TokenTracker | 메뉴바 앱 | - | 11개 AI 도구, brew 설치 |
| tokscale | CLI | - | 멀티툴 + 리더보드 |
| TokenEater | 메뉴바 앱 | - | 실시간 세션 모니터링 |

Token Burn의 차별점: **잔여량 중심 관점** + **메뉴바 이중 인코딩** (5h 가로 + 7d 세로)

## 9. 요청사항

- 블로그 톤에 맞게 글을 다듬어주세요
- 필요하다면 구조를 재배치하거나 섹션을 추가/삭제해주세요
- 썸네일 이미지가 필요합니다 (블로그 목록에 표시)
- 영문 번역(`token-burn.en.mdx`)도 필요합니다
- 이미지 배치와 캡션을 최적화해주세요
- "Claude Code와 함께 개발한 경험" 서사를 더 살려도 좋습니다
