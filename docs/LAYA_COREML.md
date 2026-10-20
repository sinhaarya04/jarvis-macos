# Laya-CoreML assessment

Reviewed [mizorewww/laya-coreml](https://github.com/mizorewww/laya-coreml/tree/12b7501583c7f03a6b2e49ebe118a2c6302505b9) on September 22, 2026.

This Apache-2.0 project provides local typed decisions through Core ML. Its short-input variant targets the Apple Neural Engine, with CPU work at the boundaries. Inference does not require PyTorch, Transformers or MLX. It returns choices/probabilities, not generated conversation or summaries.

The README reports approximately 5 ms median short decisions on an M3 Max with 128 GiB RAM, excluding loading and warmup. That is not a measurement on this 8 GB M3. The fast ANE bundle permits 96 total tokens across state, questions and options; first initialization can take tens of seconds. A separate longer-context bundle exists. Published conversion checks establish limited fidelity, not broad command accuracy. W8 weight compression does not imply an equivalent speed multiplier.

Use it as a candidate for short intent selection after transcription. Keep explicit Mac actions independent of model output, and retain a generative model for summaries. Do not send whole emails or browser pages to the 96-token variant.

JARVIS currently uses deterministic command routing. The fork's source was reviewed; its model weights have not been installed or benchmarked here. Integrate only after a local accuracy, latency and memory comparison demonstrates a benefit.
