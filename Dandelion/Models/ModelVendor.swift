//
//  ModelVendor.swift
//  Dandelion
//
//  Maps a Zen model's `modelID` to the asset-catalog image name for its
//  vendor's logo (see Assets.xcassets/vendor-*.imageset), so the catalog row
//  can show a recognizable icon without the catalog itself carrying vendor
//  metadata (models.dev doesn't expose one).
//

import Foundation

enum ModelVendor {
    /// SF Symbol shown for a modelID that doesn't match any known vendor prefix
    /// (e.g. small/unbranded free models like `big-pickle`).
    static let fallbackSystemImage = "cpu"

    /// Ordered so more specific prefixes can be listed before broader ones if
    /// that's ever needed; matched against the lowercased modelID.
    private static let prefixesByAsset: [(prefix: String, asset: String)] = [
        ("claude", "vendor-anthropic"),
        ("gpt", "vendor-openai"),
        ("gemini", "vendor-google"),
        ("grok", "vendor-xai"),
        ("glm", "vendor-zhipu"),
        ("qwen", "vendor-alibaba"),
        ("kimi", "vendor-moonshot"),
        ("minimax", "vendor-minimax"),
        ("deepseek", "vendor-deepseek"),
        ("mimo", "vendor-xiaomi"),
        ("hy3", "vendor-tencent"),
        ("nemotron", "vendor-nvidia"),
        ("ling", "vendor-antgroup"),
        ("ring", "vendor-antgroup"),
    ]

    /// The `Assets.xcassets` image name for `modelID`'s vendor, or `nil` if
    /// unrecognized (callers should fall back to `fallbackSystemImage`).
    static func assetName(forModelID modelID: String) -> String? {
        let lowered = modelID.lowercased()
        return prefixesByAsset.first { lowered.hasPrefix($0.prefix) }?.asset
    }
}
