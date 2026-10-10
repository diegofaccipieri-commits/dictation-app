# voxtral-server

`DictationApp/voxtral-server` is ExecuTorch's `voxtral_realtime_runner` with a persistent
`--server` mode added (`main.cpp.patch`): the model stays loaded and DictationApp streams each
dictation over stdin. Built from pytorch/executorch @ f2575be5ac0e8f1c937a07931d2e08b79353e524.

Model (not in the repo, ~4.4 GB): `hf download mistral-experimental/Voxtral-Mini-4B-Realtime-2602-ExecuTorch`,
then move `model-metal-int4.pte`, `preprocessor.pte` and `tekken.json` to
`~/Documents/huggingface/models/voxtral/`. Without them the app falls back to Whisper.

Rebuild:

```
git clone https://github.com/pytorch/executorch && cd executorch
git checkout f2575be5ac0e8f1c937a07931d2e08b79353e524
git apply /path/to/dictation-app/scripts/voxtral-server/main.cpp.patch
xcodebuild -downloadComponent MetalToolchain   # once
EXECUTORCH_BUILD_KERNELS_TORCHAO=1 TORCHAO_BUILD_EXPERIMENTAL_MPS=1 ./install_executorch.sh
CMAKE_BUILD_PARALLEL_LEVEL=3 make voxtral_realtime-metal   # more jobs ran a 16 GB Mac out of memory
cp cmake-out/examples/models/voxtral_realtime/voxtral_realtime_runner /path/to/dictation-app/DictationApp/voxtral-server
install_name_tool -change /opt/llvm-openmp/lib/libomp.dylib @executable_path/libomp.dylib \
  /path/to/dictation-app/DictationApp/voxtral-server
cp "$(brew --prefix libomp)/lib/libomp.dylib" /path/to/dictation-app/DictationApp/
```
