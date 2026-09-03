import Foundation
import ParsoAudioPlayback

/// The "one tap per player item" bookkeeping — the fix for EQ silently dying on
/// every gapless auto-advance — now lives in `parso-audio-engine`
/// (`ParsoAudioPlayback.EQTapRegistry`), lifted verbatim from this file
/// (parso-audio-engine/docs/UNIFICATION_PLAN.md §3).
public typealias EQTapRegistry = ParsoAudioPlayback.EQTapRegistry
