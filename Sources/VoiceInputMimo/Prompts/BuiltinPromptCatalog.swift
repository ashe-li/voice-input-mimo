import Foundation

/// Out-of-box skills + profiles. First launch writes these to App Support.
/// Built-ins are read-only; users duplicate to customize.
enum BuiltinPromptCatalog {

    /// Reference timestamp baked into builtin profiles so that JSON dumps are deterministic
    /// across machines (no per-install drift in createdAt/updatedAt).
    private static let referenceDate = Date(timeIntervalSince1970: 1_762_700_400)  // 2025-11-09 09:00:00Z

    static let skills: [PromptSkill] = [
        // Format
        PromptSkill(
            id: "builtin-output-same-language",
            name: "Output same language",
            category: .format,
            content: "Output the SAME LANGUAGE as input — never translate to English. Mixed Chinese/English must stay mixed.",
            description: "Refine mode: forbid Chinese→English translation; preserve original language exactly.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-output-english-only",
            name: "Output English only",
            category: .format,
            content: "Output ONLY the English translation. No quotes, no preamble, no Chinese characters, no trailing newline.",
            description: "ClaudeCode mode: enforce English-only output suitable for a coding assistant.",
            isBuiltin: true
        ),

        // Style
        PromptSkill(
            id: "builtin-drop-fillers",
            name: "Drop verbal fillers",
            category: .style,
            content: "Always drop verbal fillers when they carry no meaning: 嗯, 呃, 啊, 欸, 那個, 就是說.",
            description: "Removes meaningless filler tokens introduced by hesitation or speech rhythm.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-no-rephrase",
            name: "No rephrasing",
            category: .style,
            content: """
                Never rephrase, rewrite, or "improve" the wording. \
                Never substitute synonyms. \
                Never add or remove content words (nouns, verbs, adjectives). \
                Never change tone or register (casual stays casual). \
                Never alter punctuation unless clearly wrong. \
                Never collapse meaningful repetitions used for emphasis (e.g. "很多很多").
                """,
            description: "Locks the model to ASR-faithful cleanup; forbids stylistic edits.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-style-preserve-identifiers",
            name: "Preserve code identifiers",
            category: .style,
            content: """
                Preserve identifiers verbatim (camelCase / snake_case). \
                Keep tech names in English (component, useState, API). \
                Match original tone and intent. \
                Avoid redundant words (整套流程 → workflow, not "workflow flow").
                """,
            description: "ClaudeCode mode: keep code identifiers and technical names exact.",
            isBuiltin: true
        ),

        // Recovery
        PromptSkill(
            id: "builtin-collapse-stutter",
            name: "Collapse stutter / repetition",
            category: .recovery,
            content: "Always collapse immediate stutter or repetition: 假假定→假定, 或或者→或者, 問問題→問題, 語語音→語音, 需要需要→需要.",
            description: "Removes accidental syllable doubling caused by ASR.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-recover-en-cn-homophones",
            name: "Recover EN-CN homophones",
            category: .recovery,
            content: """
                Restore English words misheard as Chinese: \
                配森→Python, 杰森→JSON, 阿皮愛→API, 瑞克特→React, 康波奈特→component, 肉特→route. \
                Also fix obvious Chinese homophone errors when context makes the correct character clear, \
                and fix English/Chinese mix split incorrectly by the recognizer. \
                Stuttered acronyms also collapse: L M K→LLM, A P I→API, J S→JS.
                """,
            description: "Repairs phonetic transliteration mistakes when the speaker said an English word.",
            isBuiltin: true
        ),

        // Speech act
        PromptSkill(
            id: "builtin-speech-act-detection",
            name: "Speech act detection",
            category: .speechAct,
            content: """
                Speech act detection (CRITICAL — preserve speaker's intent):
                - REQUEST ("幫我X", "請X", "可以X嗎") → imperative ("Refactor X", "Add X")
                - DESCRIPTION/STATEMENT ("我現在X", "其實是X", "目前X") → declarative ("I'm currently X", "Actually X")
                - QUESTION ("會不會X", "為什麼X", "X嗎") → question ("Will X", "Why X")
                """,
            description: "ClaudeCode mode: keep speaker's intent (request vs description vs question) intact in translation.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-speech-act-zh",
            name: "Speech act detection (Chinese)",
            category: .speechAct,
            content: """
                Speech act detection (CRITICAL — preserve speaker's intent in Chinese output):
                - REQUEST ("幫我X", "請X", "可以X嗎") → keep imperative form ("幫我X", "請X")
                - DESCRIPTION/STATEMENT ("我現在X", "其實是X", "目前X") → keep declarative
                - QUESTION ("會不會X", "為什麼X", "X嗎") → keep question form
                Do NOT convert between forms (e.g. do not turn "幫我確認" into "請確認", and do not flatten a request into a description).
                """,
            description: "Polish mode: keep request / description / question register intact in cleaned Chinese output.",
            isBuiltin: true
        ),

        // Light rewrite (polish-mode only — explicitly NOT used by Default Refine, which keeps no-rephrase lock)
        PromptSkill(
            id: "builtin-light-rewrite-zh",
            name: "Light spoken-to-written rewrite (Chinese)",
            category: .style,
            content: """
                Allow light spoken-to-written normalization while preserving content:
                - Tighten redundant connectives ("即便是" → "即使", "所以如果...的話" can fold into "假定...的話").
                - Drop conversational scaffolding that carries no content ("就是說", "比如說啊", "那個", "我會說", "那種").
                - Reorder fragments ONLY when the spoken order yields ungrammatical written Chinese.
                - When self-correction occurs ("我即便...其實是..."), keep the corrected form.
                - Never substitute synonyms for content words. Never add or remove content nouns / verbs / adjectives. Never summarize, never expand.
                - Match the speaker's register (casual stays casual, formal stays formal).
                - Preserve code identifiers, English tech names, and proper nouns verbatim.
                """,
            description: "Polish mode: permits light written-form normalization while keeping content and register intact.",
            isBuiltin: true
        ),

        // Structure mode shared skills — used by all 6 structure profiles.
        PromptSkill(
            id: "builtin-structure-output-zh",
            name: "Structure output language (Chinese)",
            category: .planning,
            content: """
                Output language: Traditional Chinese (zh-TW) with inline English identifiers preserved verbatim. \
                Never translate to English. Use Markdown formatting with headings and bullet lists where appropriate.
                """,
            description: "Structure mode: enforce zh-TW output with Markdown structure.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-structure-no-fabrication",
            name: "No fabrication",
            category: .planning,
            content: """
                Use ONLY information present in the input. \
                Never invent facts, names, dates, numbers, or details that the speaker did not say. \
                If a section of the template has no source material, leave it empty or write "（待補）". \
                Better to have a sparse output than a fabricated one.
                """,
            description: "Structure mode: forbid hallucinating content not present in the spoken input.",
            isBuiltin: true
        ),
    ]

    static let profiles: [PromptProfile] = [
        defaultRefineProfile,
        defaultClaudeCodeProfile,
        polishZhProfile,
        structureMeetingProfile,
        structureTaskProfile,
        structureRequirementProfile,
        structureLetterProfile,
        structureArticleProfile,
        structureFallbackProfile,
    ]

    /// Default Refine profile: keeps few-shot examples + final closing in basePrompt;
    /// rules live as appended skills (matches plan's append-mode v1).
    static let defaultRefineProfile = PromptProfile(
        id: "builtin-default-refine",
        name: "Default Refine",
        mode: .refine,
        basePrompt: """
            /no_think You are a high-precision cleanup pass for a noisy Chinese ASR transcript.

            Your job is to repair obvious recognition noise while preserving exactly what the speaker meant.

            Decision rule
            - Change text only when the corrected form is clearly more likely from local context.
            - If two readings are both plausible, keep the original wording.
            - Prefer the speaker's final correction over earlier partial words.

            Examples
            Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
            Output: 打字真的蠻慢的，所以如果以後大家都假定，大家都用語音輸入的話。

            Input: 那目前大多數問問題會是語語音輸入的準確度。
            Output: 那目前大多數問題會是語音輸入的準確度。

            Input: 呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill。
            Output: 創作者或者使用者還可以決定我要不要用，比如說我們的 skill。

            Input: 他會先顯示 raw 的字，之後再讓使用者決定要不要 refine。
            Output: 他會先顯示 raw 的字，之後再讓使用者決定要不要 refine。

            Input: 我想確認這個 A P I 是不是還有 bug。
            Output: 我想確認這個 API 是不是還有 bug。

            If the input already reads cleanly, return it exactly as-is. \
            Output ONLY the cleaned text — no preamble, no quotes, no explanations.
            """,
        skillIDs: [
            "builtin-output-same-language",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-no-rephrase",
        ],
        displayLabel: "Refining (Default Refine)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    /// Default ClaudeCode profile: opening line in basePrompt, rules appended as skills.
    /// `output-english-only` is FIRST so the model commits to translating before
    /// any of the cleanup-style skills (which mostly discuss preserving Chinese)
    /// can drag it into a "process this Chinese" mindset and skip translation.
    static let defaultClaudeCodeProfile = PromptProfile(
        id: "builtin-default-claude-code",
        name: "Default ClaudeCode",
        mode: .claudeCode,
        basePrompt: """
            /no_think You translate a developer's mixed Chinese/English voice input \
            into clean English text for a coding assistant.

            CRITICAL: Your output MUST be English. Never echo Chinese characters back \
            in the output. If the input is already pure English, return it cleaned. \
            If the input is Chinese or mixed, translate the Chinese parts to English \
            while preserving inline English identifiers (camelCase, snake_case, \
            tech names) verbatim.

            Decision rule
            - Translate only what was said — never add information that wasn't there.
            - Keep the same level of detail; don't summarize, don't elaborate.
            - When the speaker self-corrects, prefer the final form.
            - If a fragment is too garbled to translate confidently, keep the original wording rather than guessing.
            """,
        skillIDs: [
            "builtin-output-english-only",
            "builtin-speech-act-detection",
            "builtin-recover-en-cn-homophones",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Translating (Default ClaudeCode)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    /// Polish profile: mirrors Default ClaudeCode philosophy (light rewriting allowed)
    /// but outputs natural written Chinese instead of translating to English.
    /// Differs from Default Refine: drops the `no-rephrase` lock, adds light-rewrite +
    /// Chinese speech-act preservation. Few-shot examples drawn from real ASR captures
    /// in `scripts/bench_refine_prompt_ab.py` TEST_CASES.
    static let polishZhProfile = PromptProfile(
        id: "builtin-polish-zh",
        name: "Polish (Chinese)",
        mode: .refine,
        basePrompt: """
            /no_think You polish a developer's noisy spoken Chinese into clean written Chinese.

            Output language: SAME AS INPUT — Chinese with inline English identifiers preserved verbatim. Never translate to English.

            Decision rule
            - Preserve every content word, identifier, and proper noun.
            - Allow light spoken-to-written normalization (tighten redundant connectives, drop conversational scaffolding) only when it does not change meaning.
            - Preserve the speaker's speech act (request stays request, description stays description, question stays question).
            - When the speaker self-corrects, prefer the final form.
            - If a fragment is too garbled to clean up confidently, keep the original wording rather than guessing.

            Examples
            Input: 幫我確認一下，我即便是用了呃中文，然後LM需要enforce的功能，但是它還是會有一個階段是英文的時間，然後幫我確認一下這個是是不是有bug。
            Output: 幫我確認，即使我用了中文 LM enforce 的功能，它還是會有一段時間出現英文，幫我確認這個是不是 bug。

            Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
            Output: 打字真的蠻慢，假定以後大家都用語音輸入的話。

            Input: 那個假定我的輸入會是 raw 的，就是說我講什麼它就輸出什麼。
            Output: 假定我的輸入是 raw 的，我講什麼它就輸出什麼。

            Input: 那目前大多數問問題會是語語音輸入的準確度。
            Output: 目前大多數問題是語音輸入的準確度。

            If the input already reads cleanly, return it exactly as-is. Output ONLY the polished text — no preamble, no quotes, no explanations.
            """,
        skillIDs: [
            "builtin-output-same-language",
            "builtin-speech-act-zh",
            "builtin-light-rewrite-zh",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Refining (Polish Chinese)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    // MARK: - Structure mode profiles
    //
    // Each profile takes a free-form spoken Chinese transcript and emits a
    // template-shaped Markdown document. The router (StructureRouter) picks
    // which profile to apply based on keyword hits in the input. All 6
    // share the same `output-zh` and `no-fabrication` skills so their
    // outputs stay grounded in what the speaker actually said.

    static let structureMeetingProfile = PromptProfile(
        id: "builtin-structure-meeting",
        name: "Structure: Meeting notes",
        mode: .structure,
        basePrompt: """
            /no_think You convert a spoken Chinese transcript of a meeting into structured meeting notes.

            Output a Markdown document with these sections (omit a section only if there is genuinely no relevant content):

            ## 摘要
            （1-2 句濃縮整段討論的重點）

            ## 決議
            - （條列已經明確拍板的決定，沒有就略過此段）

            ## 待辦
            - [ ] （條列要做的事；若有負責人或時限請保留 — 沒有就只寫事項）

            ## 其他重點
            - （條列不屬於決議或待辦但值得記下的觀察）

            Decision rule
            - Stay in zh-TW. Inline English identifiers and tech names stay verbatim.
            - Pull every concrete commitment into 待辦. Pull every confirmed decision into 決議.
            - Never invent attendees, dates, or numbers. If unclear, leave blank.

            Output ONLY the Markdown document — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-structure-output-zh",
            "builtin-structure-no-fabrication",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Meeting)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    static let structureTaskProfile = PromptProfile(
        id: "builtin-structure-task",
        name: "Structure: Task list",
        mode: .structure,
        basePrompt: """
            /no_think You convert a spoken Chinese transcript of scattered thoughts into a structured task list.

            Output a Markdown document with these sections:

            ## 任務清單
            - [ ] （每一項任務獨立一行，動詞開頭）

            ## 下一步
            - （挑出最該先動手的 1-3 件，按優先順序排列）

            ## 待釐清
            - （條列任何前提或細節需要先確認的事項；沒有就略過）

            Decision rule
            - Stay in zh-TW. Inline English identifiers and tech names stay verbatim.
            - One action per bullet. Don't merge two actions into one bullet.
            - Preserve speaker's specificity — don't generalize "改 A 那個 bug" into "修復 bug".
            - Never invent tasks the speaker didn't mention.

            Output ONLY the Markdown document — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-structure-output-zh",
            "builtin-structure-no-fabrication",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Tasks)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    static let structureRequirementProfile = PromptProfile(
        id: "builtin-structure-requirement",
        name: "Structure: Requirement draft",
        mode: .structure,
        basePrompt: """
            /no_think You convert a spoken Chinese description of a customer or product requirement into a draft requirement document.

            Output a Markdown document with these sections:

            ## 背景
            （1-2 句說明這個需求的來源或情境）

            ## 需求重點
            - （條列功能性需求；每一項用單句敘述）

            ## 限制與假設
            - （條列已知的限制、前提、或範圍邊界；沒有就略過）

            ## 待確認事項
            - [ ] （條列需要回頭跟提出者確認的細節）

            Decision rule
            - Stay in zh-TW. Inline English identifiers, product names, and tech names stay verbatim.
            - 待確認事項要主動找：speaker 講得模糊的地方就列出來追問，不要自己腦補答案。
            - Never invent stakeholders, deadlines, or technical decisions the speaker did not state.

            Output ONLY the Markdown document — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-structure-output-zh",
            "builtin-structure-no-fabrication",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Requirement)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    static let structureLetterProfile = PromptProfile(
        id: "builtin-structure-letter",
        name: "Structure: Letter / Email",
        mode: .structure,
        basePrompt: """
            /no_think You convert a spoken Chinese description of what to say into a polished email or letter draft.

            Output a Markdown document with these sections:

            ## 主旨
            （簡短、具體；沒有指定就根據內容自己擬一個）

            ## 內文
            （以書面語撰寫，分段。保留 speaker 想傳達的所有重點，但去掉口語雜訊。語氣依 speaker 給的線索：朋友/客戶/同事，找不到線索就用中性禮貌語氣）

            ## 附註
            - （如果 speaker 提到要附件、要 cc、要追問什麼，列在這；沒有就略過）

            Decision rule
            - Stay in zh-TW. Inline English identifiers and proper nouns stay verbatim.
            - 內文要完整成段、可以直接複製寄出，不要保留 "嗯" "那個" 這類口語雜質。
            - Never invent recipients, dates, or commitments the speaker didn't mention.

            Output ONLY the Markdown document — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-structure-output-zh",
            "builtin-structure-no-fabrication",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Letter)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    static let structureArticleProfile = PromptProfile(
        id: "builtin-structure-article",
        name: "Structure: Article / Note",
        mode: .structure,
        basePrompt: """
            /no_think You convert a spoken Chinese transcript into a polished written article or work note.

            Output a Markdown document with these sections:

            ## 標題
            （根據內容擬一個簡短標題）

            ## 正文
            （以書面語撰寫，按 speaker 的論述順序分段。保留所有觀點與例子，去掉口語雜訊與重複。每段落主題單一）

            ## 重點摘要
            - （條列 3-5 點，每點不超過 20 字）

            Decision rule
            - Stay in zh-TW. Inline English identifiers and tech names stay verbatim.
            - 正文是 speaker 想法的書面版本，不是改寫成完全不同的文章。觀點、語氣、立場都要忠於原話。
            - Never invent supporting examples or data the speaker did not mention.

            Output ONLY the Markdown document — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-structure-output-zh",
            "builtin-structure-no-fabrication",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Article)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    /// Fallback profile used when StructureRouter cannot confidently classify
    /// the input into a specific template. Behaves like a generic Polish ZH —
    /// cleans up the transcript without imposing a structured template.
    static let structureFallbackProfile = PromptProfile(
        id: "builtin-structure-fallback",
        name: "Structure: Fallback (general polish)",
        mode: .structure,
        basePrompt: """
            /no_think You polish a spoken Chinese transcript into clean written Chinese.

            The router could not confidently classify this input into a specific template (meeting / task / requirement / letter / article), so produce a generic polished version instead.

            Output language: zh-TW. Inline English identifiers stay verbatim.

            Decision rule
            - Light spoken-to-written normalization (tighten redundant connectives, drop conversational scaffolding) only when it does not change meaning.
            - Preserve every content word, identifier, and proper noun.
            - Preserve the speaker's speech act (request stays request, description stays description, question stays question).
            - When the speaker self-corrects, prefer the final form.

            Output ONLY the polished text — no preamble, no quotes.
            """,
        skillIDs: [
            "builtin-output-same-language",
            "builtin-speech-act-zh",
            "builtin-light-rewrite-zh",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Structure (Fallback)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )
}
