# Controlled fixture transfer — verified

Parent found the five fixtures inside ASUS LXC212 `/tmp/lifeos-english-fixtures/`, while the phone's `/sdcard/Download/LifeOS-English-QA/` was empty. The LXC path is not a gama-dev path. The previous staging command had not completed the final push; stdin consumption was suspected, not established.

Repeated only the owned-folder push through `ssh -n asus` and `pct exec 212 ... </dev/null`: five files pushed, 742676 bytes. No unrelated files touched. Phone SHA-256 values exactly match local originals:

- QA-English-short.wav: `7af096f16375a8e354cd3c9321eff1d1e211b07306f642b8848c41757d484f73`
- QA-English-lesson.mp4: `6161e4e7fc066ea8c3e4be16fab02610b8c6399136164f2580fbb2a36750fc25`
- QA-English-silence.wav: `6b454e58dda23568eb196d6b02ae2c360112fa817da431e1c633979ecd166bb3`
- QA-English-corrupt.mp3: `00599c7382d1274e4d84cbfa41108017eff4eb72d1dcfcfa88a054490e978ccf`

Device worker mujg8mzq-y-990b notified; it remains the sole UI controller. Import outcomes are still pending, not established by a successful file transfer.
