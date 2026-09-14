import Foundation

/// Every voice the app offers, grouped by the pack that ships it. This is
/// the single source of truth: adding a language means adding one array
/// here and a `KokoroVariant` case, not editing six files.
///
/// Persona taglines/descriptions for Kokoro's English voices are educated
/// guesses from each name (the `af_`/`bf_` prefix gives real gender and
/// accent; the character adjectives don't come from listening to each
/// clip). Mandarin's 8 named voices use hexgrad's own documented personas.
/// Pocket TTS and Japanese have no persona data at all, so they carry
/// `nil` rather than something invented.
enum VoiceCatalog {
    static func voices(for variant: KokoroVariant) -> [Voice] {
        switch variant {
        case .english: return kokoroEnglish
        case .mandarin: return kokoroMandarin
        case .japanese: return kokoroJapanese
        }
    }

    static let all: [Voice] = kokoroEnglish + kokoroMandarin + kokoroJapanese + pocket + supertonic3

    /// Precomputed rather than scanned: cover-art resolution calls this
    /// once per visible tile while the Trending row scrolls, and a linear
    /// scan there would rebuild and walk the whole roster each time.
    /// Codes are unique across packs today; `uniquingKeysWith` keeps the
    /// first entry rather than trapping if that ever stops being true.
    private static let byCode: [String: Voice] = Dictionary(
        all.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    static func voice(for code: String) -> Voice? { byCode[code] }

    // MARK: - Kokoro-ANE (English, 28) — bundled, see ADR 2

    static let kokoroEnglish: [Voice] = [
        Voice(
            code: "af_alloy", tagline: "Poised and composed",
            longDescription:
                "Poised and composed, with a polished, professional edge — clear enough for crisp narration or presentations.",
            hasAvatar: true,
            previewLine:
                "Mountains rose beyond the valley as morning light spread slowly across the fields, waking birds after the storm."),
        Voice(
            code: "af_aoede", tagline: "Dreamy and artistic",
            longDescription:
                "Dreamy and artistic, with a soft, unhurried delivery well suited to reflective or lyrical text.",
            hasAvatar: true,
            previewLine:
                "She tuned her old guitar by the window, humming a quiet melody while rain tapped gently against the glass."),
        Voice(
            code: "af_bella", tagline: "Warm and confident",
            longDescription: "Warm and confident, with a rich, assured tone that carries a room.",
            hasAvatar: true,
            previewLine:
                "The bakery filled with the smell of fresh bread every morning, drawing neighbors in before the sun had fully risen."),
        Voice(
            code: "af_heart", tagline: "Warm and friendly",
            longDescription:
                "Warm and friendly, with an easy, conversational tone — great for everyday narration and casual reads.",
            hasAvatar: true,
            previewLine:
                "He wrote her a letter every week that summer, describing the ocean and the long walks near home."),
        Voice(
            code: "af_jessica", tagline: "Friendly and professional",
            longDescription:
                "Friendly and professional, with a clear, approachable delivery suited to explainers and guides.",
            hasAvatar: true,
            previewLine:
                "The train pulled away from the station just as the last passenger found her seat for the long journey."),
        Voice(
            code: "af_kore", tagline: "Bright and youthful",
            longDescription: "Bright and youthful, with an upbeat, energetic lift to every line.",
            hasAvatar: true,
            previewLine:
                "A gentle breeze moved through the orchard, carrying the scent of ripe apples toward the farmhouse porch where children played."),
        Voice(
            code: "af_nicole", tagline: "Sophisticated and polished",
            longDescription: "Sophisticated and polished, with a smooth, refined cadence.",
            hasAvatar: true,
            previewLine:
                "The scientist adjusted her instruments carefully, watching the readings shift as the experiment moved closer to its final stage."),
        Voice(
            code: "af_nova", tagline: "Vibrant and energetic",
            longDescription:
                "Vibrant and energetic, with a lively pace that suits upbeat, fast-moving content.",
            hasAvatar: true,
            previewLine:
                "Streetlights flickered on across the city as evening settled in, and the sound of traffic slowly began to fade away."),
        Voice(
            code: "af_river", tagline: "Free-spirited and relaxed",
            longDescription: "Free-spirited and relaxed, with an unhurried, laid-back delivery.",
            hasAvatar: true,
            previewLine:
                "The old fisherman rowed out before dawn, watching the mist rise off the water as the sky slowly turned pink."),
        Voice(
            code: "af_sarah", tagline: "Sweet and genuine",
            longDescription: "Sweet and genuine, with a warm, down-to-earth tone that feels personal.",
            hasAvatar: true,
            previewLine:
                "Every Saturday she walked to the farmers market, filling her basket with fresh vegetables, warm bread, and flowers."),
        Voice(
            code: "af_sky", tagline: "Bright and airy",
            longDescription: "Bright and airy, with a light, cheerful lilt.", hasAvatar: true,
            previewLine:
                "The kite climbed higher into the wind, dipping and turning above the beach while the children cheered from the sand."),
        Voice(
            code: "am_adam", tagline: "Warm and easygoing",
            longDescription: "Warm and easygoing, with a relaxed, approachable delivery.",
            hasAvatar: true,
            previewLine:
                "The engineer double checked every connection before powering on the machine, knowing one mistake could delay the whole project."),
        Voice(
            code: "am_echo", tagline: "Sharp and composed",
            longDescription: "Sharp and composed, with a crisp, confident edge.",
            previewLine:
                "Thunder rolled across the canyon walls, echoing long after the lightning had already faded from the darkening evening sky."),
        Voice(
            code: "am_eric", tagline: "Friendly and warm",
            longDescription: "Friendly and warm, with a steady, welcoming tone.",
            previewLine:
                "The chef tasted the sauce one more time, adjusting the seasoning slightly before sending the plate out to the table."),
        Voice(
            code: "am_fenrir", tagline: "Rugged, deep voice",
            longDescription: "Rugged and deep, with a strong, grounded presence.", hasAvatar: true,
            previewLine:
                "The hikers pushed through the dense forest, following an old trail marked only by faded paint on scattered trees."),
        Voice(
            code: "am_liam", tagline: "Youthful and relaxed",
            longDescription: "Youthful and relaxed, with a casual, easy pace.", hasAvatar: true,
            previewLine:
                "The coach gathered the team before the final match, reminding everyone that preparation mattered more than talent alone today."),
        Voice(
            code: "am_michael", tagline: "Reliable and warm",
            longDescription: "Reliable and warm, with a dependable, trustworthy tone.",
            previewLine:
                "The pilot announced a short delay due to weather, asking passengers to remain seated until the storm had passed completely."),
        Voice(
            code: "am_onyx", tagline: "Sleek and cool",
            longDescription: "Sleek and cool, with a smooth, understated confidence.",
            previewLine:
                "The blacksmith hammered steadily at the glowing metal, shaping it slowly into the curved blade he had planned for weeks."),
        Voice(
            code: "am_puck", tagline: "Playful and mischievous",
            longDescription: "Playful and mischievous, with a light, spirited energy.",
            previewLine:
                "The comedian paced the stage, waiting for the perfect moment to deliver the punchline he had rehearsed all week long."),
        Voice(
            code: "am_santa", tagline: "Warm and jolly",
            longDescription: "Warm and jolly, with a hearty, good-natured cheer.",
            previewLine:
                "Snow fell quietly over the village square as lanterns were lit one by one along the narrow, winding streets."),
        Voice(
            code: "bf_alice", tagline: "Elegant and refined",
            longDescription: "Elegant and refined, with a crisp, well-mannered British delivery.",
            hasAvatar: true,
            previewLine:
                "The librarian reshelved the last stack of books just as the evening bell rang and the doors slowly closed."),
        Voice(
            code: "bf_emma", tagline: "Poised and elegant",
            longDescription: "Poised and elegant, with a graceful, composed tone.",
            previewLine:
                "The painter stepped back from the canvas, studying the colors carefully before adding one final stroke to finish it."),
        Voice(
            code: "bf_isabella", tagline: "Graceful and refined",
            longDescription: "Graceful and refined, with a smooth, cultivated cadence.",
            previewLine:
                "The archaeologist brushed the dust away carefully, revealing an ancient carving that had remained hidden for centuries underground."),
        Voice(
            code: "bf_lily", tagline: "Gentle and delicate",
            longDescription: "Gentle and delicate, with a soft, soothing British lilt.",
            previewLine:
                "The gardener knelt beside the roses, trimming each stem carefully while humming softly to herself in the afternoon sun."),
        Voice(
            code: "bm_daniel", tagline: "Distinguished and calm",
            longDescription: "Distinguished and calm, with an even, authoritative delivery.",
            hasAvatar: true,
            previewLine:
                "The captain steadied the wheel as the waves grew rougher, guiding the small boat carefully back toward the harbor."),
        Voice(
            code: "bm_fable", tagline: "Warm storyteller",
            longDescription:
                "A warm storyteller's voice, rich and expressive — built for narration.",
            previewLine:
                "The old storyteller sat by the fire, beginning a tale that had been passed down through many generations before him."),
        Voice(
            code: "bm_george", tagline: "Distinguished and composed",
            longDescription: "Distinguished and composed, with a steady, refined British tone.",
            previewLine:
                "The professor closed his notes and looked out at the class, asking if anyone still had questions before the exam."),
        Voice(
            code: "bm_lewis", tagline: "Friendly and approachable",
            longDescription: "Friendly and approachable, with a warm, easy-going British manner.",
            previewLine:
                "The mechanic wiped his hands on a rag, satisfied that the engine finally sounded right after hours of careful work."),
    ]

    // MARK: - Kokoro-ANE (Mandarin, 10)

    // zf_001/zm_009 are FluidAudio's own hosted voices and have no
    // documented persona, so they get a plain, honest tagline. The 8 named
    // voices are hexgrad's own documented Mandarin personas.
    static let kokoroMandarin: [Voice] = [
        Voice(
            code: "zf_001", tagline: "Clear and steady",
            longDescription:
                "A clear, steady Mandarin voice — the standard default for everyday narration.",
            previewLine: "清晨的阳光洒进窗户,街道上渐渐热闹起来,人们开始了新一天的生活。"),
        Voice(
            code: "zm_009", tagline: "Clear and steady",
            longDescription: "A clear, steady Mandarin voice with an even, dependable delivery.",
            previewLine: "老师站在讲台前,耐心地讲解着今天的课程内容,学生们认真地做着笔记。"),
        Voice(
            code: "zf_xiaobei", tagline: "Warm and homely",
            longDescription:
                "Warm and natural, carrying a touch of Northeastern Chinese character — easy, conversational delivery.",
            hasAvatar: true,
            previewLine: "东北的冬天格外寒冷,雪花静静地落在屋顶上,街道显得格外安静祥和。"),
        Voice(
            code: "zf_xiaoni", tagline: "Clear and professional",
            longDescription:
                "Clear and composed, with a Shaanxi-inflected warmth well suited to informational content.",
            hasAvatar: true,
            previewLine: "她坐在图书馆里,仔细地翻阅着一本古老的书籍,窗外的树叶轻轻飘落。"),
        Voice(
            code: "zf_xiaoxiao", tagline: "Warm and lively",
            longDescription:
                "Warm and lively — a flagship Mandarin persona, expressive across a wide emotional range.",
            hasAvatar: true,
            previewLine: "春天来了,公园里的花朵竞相开放,孩子们在草地上快乐地奔跑嬉戏。"),
        Voice(
            code: "zf_xiaoyi", tagline: "Bright and expressive",
            longDescription:
                "Bright and expressive, with a youthful energy that shifts easily between playful and heartfelt.",
            hasAvatar: true,
            previewLine: "演唱会上灯光闪烁,观众们跟着音乐节拍欢呼,气氛热烈而充满活力。"),
        Voice(
            code: "zm_yunjian", tagline: "Passionate and bold",
            longDescription:
                "Passionate and dynamic, built for sports commentary and dramatic narration.",
            hasAvatar: true,
            previewLine: "比赛进行到最后一刻,现场观众屏住呼吸,期待着这激动人心的结果。"),
        Voice(
            code: "zm_yunxi", tagline: "Sunny and upbeat",
            longDescription: "Sunny and upbeat, with a lively conversational warmth.",
            hasAvatar: true,
            previewLine: "周末的午后,他和朋友们一起去爬山,呼吸着新鲜空气,心情格外愉快。"),
        Voice(
            code: "zm_yunxia", tagline: "Playful and youthful",
            longDescription: "Playful and youthful — a bright, cheerful young voice.",
            hasAvatar: true,
            previewLine: "小男孩举着风筝在草地上奔跑,笑声传遍了整个公园,十分天真可爱。"),
        Voice(
            code: "zm_yunyang", tagline: "Professional and reliable",
            longDescription:
                "Professional and reliable, with the composed authority of a news anchor.",
            hasAvatar: true,
            previewLine: "新闻播报员沉稳地念着今天的头条新闻,语气专业而值得信赖。"),
    ]

    // MARK: - Kokoro-ANE (Japanese, 5)

    // FluidAudio's own official roster (KokoroAneConstants.japaneseVoices).
    // No persona data published for these, and no preview clips captured
    // yet — all nil rather than invented.
    static let kokoroJapanese: [Voice] = [
        Voice(code: "jf_alpha"),
        Voice(code: "jf_gongitsune"),
        Voice(code: "jf_nezumi"),
        Voice(code: "jf_tebukuro"),
        Voice(code: "jm_kumo"),
    ]

    // MARK: - Pocket TTS (26, same roster for every language)

    // Named after LibriVox-style audiobook narrators with no persona data
    // at all, so these descriptions are freshly-written narration-toned
    // copy rather than anything sourced. No taglines, no preview clips yet
    // (see ADR 9 — Pocket's clips still need capturing).
    static let pocket: [Voice] = [
        Voice(code: "alba", longDescription: "A clear, gentle narrator voice with a calm, steady pace."),
        Voice(
            code: "anna",
            longDescription:
                "A warm, expressive voice well suited to storytelling and long-form reads."),
        Voice(code: "azelma", longDescription: "A soft, measured voice with a quiet, thoughtful delivery."),
        Voice(
            code: "bill_boerst",
            longDescription: "A steady, seasoned narrator voice with a relaxed, confident cadence."),
        Voice(code: "caro_davy", longDescription: "A bright, articulate voice with a brisk, engaging pace."),
        Voice(
            code: "charles",
            longDescription: "A calm, deliberate voice suited to serious or reflective narration."),
        Voice(code: "cosette", longDescription: "A soft, youthful voice with a gentle, sincere tone."),
        Voice(
            code: "eponine",
            longDescription: "An expressive, emotive voice with a slightly melancholic warmth."),
        Voice(
            code: "estelle",
            longDescription: "A refined, articulate voice with a smooth, unhurried delivery."),
        Voice(code: "eve", longDescription: "A clear, natural voice with an easy, conversational rhythm."),
        Voice(
            code: "fantine",
            longDescription: "A tender, soft-spoken voice with a quiet emotional depth."),
        Voice(code: "george", longDescription: "A steady, dependable voice with a classic narrator's tone."),
        Voice(
            code: "giovanni",
            longDescription: "A warm, expressive voice with a touch of theatrical flair."),
        Voice(code: "jane", longDescription: "A composed, articulate voice with a gentle, measured pace."),
        Voice(code: "javert", longDescription: "A firm, resolute voice with a serious, commanding edge."),
        Voice(code: "jean", longDescription: "A grounded, weathered voice with quiet, steady conviction."),
        Voice(
            code: "juergen",
            longDescription: "A deep, deliberate voice with a calm, authoritative presence."),
        Voice(code: "lola", longDescription: "A lively, expressive voice with a playful, energetic lift."),
        Voice(code: "marius", longDescription: "A youthful, earnest voice with an open, sincere tone."),
        Voice(code: "mary", longDescription: "A warm, gentle voice with a comforting, familiar quality."),
        Voice(
            code: "michael",
            longDescription: "A clear, confident voice suited to straightforward narration."),
        Voice(code: "paul", longDescription: "A steady, even voice with an unassuming, practical tone."),
        Voice(
            code: "peter_yearsley",
            longDescription: "A rich, classic narrator's voice with a measured, deliberate pace."),
        Voice(code: "rafael", longDescription: "A warm, textured voice with an expressive, animated delivery."),
        Voice(
            code: "stuart_bell",
            longDescription: "A crisp, articulate voice with a brisk, professional pace."),
        Voice(code: "vera", longDescription: "A soft, composed voice with a calm, reassuring tone."),
    ]

    // MARK: - Supertonic-3 (10 fixed speaker styles, all 31 languages — issue #27)

    // No persona data (fixed presets, not sourced from a named narrator);
    // no per-language flag makes sense, since the same voice speaks
    // whichever `SupertonicLanguage` is picked — see Voice.flagOverride.
    static let supertonic3: [Voice] = [
        Voice(code: "F1", flagOverride: "🌐"),
        Voice(code: "F2", flagOverride: "🌐"),
        Voice(code: "F3", flagOverride: "🌐"),
        Voice(code: "F4", flagOverride: "🌐"),
        Voice(code: "F5", flagOverride: "🌐"),
        Voice(code: "M1", flagOverride: "🌐"),
        Voice(code: "M2", flagOverride: "🌐"),
        Voice(code: "M3", flagOverride: "🌐"),
        Voice(code: "M4", flagOverride: "🌐"),
        Voice(code: "M5", flagOverride: "🌐"),
    ]
}
