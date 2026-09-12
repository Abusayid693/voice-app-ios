import Foundation

/// One distinct 16-20 word sentence per voice, used to generate that
/// voice's preview clip (see
/// docs/adr/0009-bundled-voice-preview-clips.md's regeneration recipe) —
/// deliberately varied content/phrasing rather than one shared
/// line, so voices are easy to tell apart when auditioned back to back.
enum VoicePreviewLines {
    static let fallback =
        "This is a short preview of this voice, spoken clearly so you can decide if it fits your project well."

    static let lines: [String: String] = [
        // Kokoro-ANE (28)
        "af_alloy": "Mountains rose beyond the valley as morning light spread slowly across the fields, waking birds after the storm.",
        "af_aoede": "She tuned her old guitar by the window, humming a quiet melody while rain tapped gently against the glass.",
        "af_bella": "The bakery filled with the smell of fresh bread every morning, drawing neighbors in before the sun had fully risen.",
        "af_heart": "He wrote her a letter every week that summer, describing the ocean and the long walks near home.",
        "af_jessica": "The train pulled away from the station just as the last passenger found her seat for the long journey.",
        "af_kore": "A gentle breeze moved through the orchard, carrying the scent of ripe apples toward the farmhouse porch where children played.",
        "af_nicole": "The scientist adjusted her instruments carefully, watching the readings shift as the experiment moved closer to its final stage.",
        "af_nova": "Streetlights flickered on across the city as evening settled in, and the sound of traffic slowly began to fade away.",
        "af_river": "The old fisherman rowed out before dawn, watching the mist rise off the water as the sky slowly turned pink.",
        "af_sarah": "Every Saturday she walked to the farmers market, filling her basket with fresh vegetables, warm bread, and flowers.",
        "af_sky": "The kite climbed higher into the wind, dipping and turning above the beach while the children cheered from the sand.",
        "am_adam": "The engineer double checked every connection before powering on the machine, knowing one mistake could delay the whole project.",
        "am_echo": "Thunder rolled across the canyon walls, echoing long after the lightning had already faded from the darkening evening sky.",
        "am_eric": "The chef tasted the sauce one more time, adjusting the seasoning slightly before sending the plate out to the table.",
        "am_fenrir": "The hikers pushed through the dense forest, following an old trail marked only by faded paint on scattered trees.",
        "am_liam": "The coach gathered the team before the final match, reminding everyone that preparation mattered more than talent alone today.",
        "am_michael": "The pilot announced a short delay due to weather, asking passengers to remain seated until the storm had passed completely.",
        "am_onyx": "The blacksmith hammered steadily at the glowing metal, shaping it slowly into the curved blade he had planned for weeks.",
        "am_puck": "The comedian paced the stage, waiting for the perfect moment to deliver the punchline he had rehearsed all week long.",
        "am_santa": "Snow fell quietly over the village square as lanterns were lit one by one along the narrow, winding streets.",
        "bf_alice": "The librarian reshelved the last stack of books just as the evening bell rang and the doors slowly closed.",
        "bf_emma": "The painter stepped back from the canvas, studying the colors carefully before adding one final stroke to finish it.",
        "bf_isabella": "The archaeologist brushed the dust away carefully, revealing an ancient carving that had remained hidden for centuries underground.",
        "bf_lily": "The gardener knelt beside the roses, trimming each stem carefully while humming softly to herself in the afternoon sun.",
        "bm_daniel": "The captain steadied the wheel as the waves grew rougher, guiding the small boat carefully back toward the harbor.",
        "bm_fable": "The old storyteller sat by the fire, beginning a tale that had been passed down through many generations before him.",
        "bm_george": "The professor closed his notes and looked out at the class, asking if anyone still had questions before the exam.",
        "bm_lewis": "The mechanic wiped his hands on a rag, satisfied that the engine finally sounded right after hours of careful work.",
    ]
}
