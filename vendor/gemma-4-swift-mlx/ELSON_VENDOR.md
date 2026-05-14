Vendored snapshot of VincentGourbin/gemma-4-swift-mlx at revision
`c6f8ab5820379898b1d437e8e5c463f376672613`.

Local patches:
- Use the existing `scaleArray` in `TurboQuantProdCodec` for Swift 6.2 / MLX scalar multiplication compatibility.
- Exclude LoRA training sources from the `Gemma4Swift` library target. Elson only uses inference.
