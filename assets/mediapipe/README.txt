Run scripts/prepare-reader-voice.sh to bundle the SHA-256 pinned Kokoro
LiteRT-LM model. Phonon is downloaded only after selection in settings.

Pocket TTS is an optional, separately downloaded English narrator (163 MB).
Original model: Pocket TTS by Kyutai, https://huggingface.co/kyutai/pocket-tts
Authors: Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Vaclav Volhejn,
Neil Zeghidour, and Alexandre Defossez.
Licensed under Creative Commons Attribution 4.0 International:
https://creativecommons.org/licenses/by/4.0/
The app uses the LiteRT community's INT8 conversion with eight built-in voices:
https://huggingface.co/litert-community/pocket-tts
Pinned revision: 03f949ec418ccd4d153008f7ef9c58c754cc0616
SHA-256: 465e0083cd61188772aed76160b07af0dcf59057497d7659f43f3f2b13a174a1
The converted weights are used without further modification.
