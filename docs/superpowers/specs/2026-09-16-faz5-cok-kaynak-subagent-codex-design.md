# Faz 5 — Çok-Kaynak Merge / Subagent / Codex / Reasoning (Remote Native Chat)

**Tarih:** 2026-09-16
**Branch:** `feat/remote-orca-main` (main'e commit YOK)
**Durum:** DEVİR TASLAĞI — implementasyondan önce `superpowers:brainstorming` + yoğun orca keşfi. En büyük/en karmaşık faz; **kesinlikle alt-fazlara bölünmeli.**
**Referans: orca** (`/Users/balkan/Desktop/side-projects/orca`).

## 1. Amaç ve kapsam

Native chat'i tam orca paritesine taşıyan son faz. Faz 1-4 tek-kaynak (transcript) +
Claude odaklıydı; Faz 5 çok-kaynağı, alt-ajanları, Codex'i ve zengin blokları ekler:

- **transcript > hook > scrape merge:** aynı turu üç kaynaktan birleştirme (orca'nın
  kaynak-önceliği modeli; `source` alanı Faz 1'de decode-hazır ama gönderilmiyor).
- **Subagent grupları:** `subagent-group` bloğu render (Faz 1 decode+stub); alt-ajan
  araç ağacı (Faz 2 "lider araç" idi), alt-ajan promptları (Faz 3 lider-only idi).
- **Codex decoder + uçtan-uca:** Codex transcript/hook/keystroke (Faz 1-4 Claude odaklıydı,
  model alanları hazır — `buildCodexAskAnswerKeys`, Codex event adları reducer'da tanınıyor).
- **Reasoning blokları:** düşünme/reasoning render (orca reasoning blokları).
- **Edit-patch diff gutter:** Edit/patch araç sonuçlarını diff olarak gösterme.
- **`/clear` çoklu-kaynak lifecycle:** karar 21 — `/clear` sonrası yeni session dosyası takibi
  (Faz 1'de sabit `claudeSessionID`; çoklu-kaynakta lifecycle burada tamamlanır).

### ÖNERİLEN ALT-FAZ BÖLÜMÜ (devralan karar versin)
- **Faz 5.0:** Codex sağlayıcısı uçtan-uca (decoder + prompt + turn-status Codex paritesi).
- **Faz 5.1:** subagent grupları render + alt-ajan araç/prompt (Faz 2/3 lider-only genişlemesi).
- **Faz 5.2:** transcript>hook>scrape merge + `source` alanı + /clear lifecycle.
- **Faz 5.3:** reasoning blokları + edit-patch diff gutter (zengin render).

## 2. Mevcut zemin (yeniden kullanılan)
- **`ChatBlock`** `subagent-group` (decode+stub, Faz 1) — render burada.
- **`source` alanı** (Faz 1: "orca ile birebir adlandır ki additive olsun" — burada gönderilir).
- **`AgentHookEvent`** subagent*/Codex event adları (reducer/journal zaten tanıyor, Faz 2/3).
- **`TurnStatusReducer` / `PromptJournal`** — alt-ajan/Codex için genişletilir.
- **`ClaudeTranscriptChatDecoder`** — Codex decoder kardeşi + merge katmanı.
- **`ChatTranscriptSourcing`** — hook/scrape kaynakları eklenip merge edilir.

## 3. Mimari yön (devralan netleştirir — DERİN orca keşfi şart)
- **Merge:** orca'nın kaynak-önceliği (transcript otoriter, hook canlılık, scrape yedek);
  aynı item'ı üç kaynaktan tekilleştirme (Faz 3 journal revision/itemId benzeri).
- **Subagent:** `agentID` taşıyan olaylar (mevcut) → alt-ajan grup ağacı; `subagent-group`
  bloğu + alt-ajan turn-status/prompt.
- **Codex:** ayrı transcript formatı + `~/.codex/` hook yolu (AgentHookInstaller Codex hazır);
  keystroke `buildCodexAskAnswerKeys` (Faz 3.1'e bağlı).
- **Reasoning/diff:** yeni `ChatBlock` türleri (reasoning, edit-patch) — orca ile birebir adlandır.

## 4. Test stratejisi
- Merge birim testleri (üç-kaynak çakışma/tekilleştirme senaryoları).
- Codex decoder golden testleri (gerçek Codex transcript örnekleri).
- Subagent grup render + alt-ajan durum; reasoning/diff parse.
- Uçtan-uca = cihaz (Claude + Codex).

## 5. Referans orca dosyaları (devralan keşfetsin — bu spec DERİN incelemedi)
- `src/shared/agent-hook-listener/providers/` (claude + codex event/tool-field normalizasyonu)
- `src/shared/agent-session-journal-types.ts` (render item türleri: reasoning, diff, subagent)
- `src/shared/native-chat-ask.ts` `buildCodexAskAnswerKeys`
- merge/kaynak-önceliği: `src/shared/` agent-status/journal projeksiyonları
- `mobile/src/session/` subagent/reasoning/diff render bileşenleri

## 6. Önce yap (implementasyondan önce — ZORUNLU)
1. Bu faz en büyüğü; **her alt-fazı ayrı ele al** (5.0 Codex → 5.1 subagent → 5.2 merge → 5.3 zengin render).
2. Her biri için orca'yı derinlemesine keşfet (bu spec yalnız Faz 1 roadmap'inden yön verdi).
3. Her alt-faz: `superpowers:brainstorming` → `writing-plans` → SDD.
4. Karar 21 (`/clear` lifecycle) ve `docs/decisions.md` ile tutarlılığı kontrol et.
