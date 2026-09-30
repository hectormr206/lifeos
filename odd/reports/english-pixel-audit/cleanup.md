# Audit resources cleaned; private evidence backup retained

**Completed by the parent after the cleanup worker stopped at its permission boundary.** The worker made no backup or deletion; the parent then verified ownership/hashes and performed the authorized maintenance. Installed app, models, learning records, source changes and original audit evidence are retained. Physical voiced microphone/ZIPA testing remains user-deferred.

## Private backup

`/home/hectormr/backups/lifeos-releases/english-pixel-audit-20260927-candidate2/`

Directory permissions0700; files0600, verified. Contains:

| Artifact | Verification |
| --- | --- |
| `lifeos-private-candidate2-1024.apk` | 336715791 bytes; SHA256 `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f` |
| `candidate-2-source-sha256.json` | Exact19-file manifest |
| `candidate-source-files.tar.gz` | Only those19 source/test/generated files; archived bytes rehashed against manifest |
| `screened-evidence-logs.tar.gz` | 18 test/analyzer/build/ASR log files; SHA256 `876515a235fdfcd73e4c504660eec6f7f91934158373d94d6dd4ab2d007e2f44` |
| `logs/gama/transcripts*.log` | Both independent raw ASR logs |
| `SHA256SUMS.json` | Backup artifact checksums |

Raw defines, key.properties, keystore and environment files were **not archived**. A private child screened candidate textual logs against owned private values and encodings without printing them; no selected log matched. The APK retains its normal baked configuration and is a private backup, not a publication. Full original device evidence remains under `odd/reports/english-pixel-audit/`.

## Removed only verified owned resources

- Devbox `/home/hectormr/work/lifeos-english-pixel-audit/`: isolated clone, build outputs, fixtures, scratch and owned signing/defines copies. Before removal, exact root contents, clone HEAD and19source hashes were checked; source/log backups verified. Original dirty checkout exists outside this root and was not modified; original signing inputs, SDK and global caches untouched.
- Gama normalized-ASR directory: eight WAVs and two logs verified; logs preserved, then scratch and empty parent directories removed.
- ASUS: four exact staged APK/tar paths. LXC212:22 exact paths comprising two APKs,16 duplicate capture FLACs, fixture tar/directory and portable capture tar/directory. APK hashes, retained-original FLAC hashes, all five fixture contents and official portable archive/extracted files were checked before removal. No broad `/tmp/lifeos*` deletion.
- Gama staged candidate2 APK removed only after the private backup was verified.
- TESTPixel: all five fixture hashes matched local originals, including `qa-transcript.txt` SHA256 `c3f15654a59feef9857e72f7bcaf91e7c7cabb98f105ed96bc181c5db7b6bfa6`. Deleted exactly their five MediaStore rows using both ID and canonical path predicates, then removed the empty owned folder. Final scoped MediaStore query returned `No result found.`.

No original model, Piper derivative, private app storage, imported learning record, card, placement, conversation or recording was deleted. Unknown/unrelated helpers were not removed merely by filename.

## Final checks

- Installed `base.apk` still hashes to `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f`.
- App0.20.1/1024; PID14936 alive; stay-awake0, media5, microphone still granted.
- Work, Daniela and reminder absence were last verified in phase G. Cleanup did not operate those controls or create another reminder; no fresh UI claim is substituted for the phase-G evidence.
- Main Gama HEAD remains `ab5d67465be7857e97f0f44063a8d8b9d582ec85`; exactly the same19source/test/generated paths and hashes, clean `git diff --check`. Changes remain uncommitted.
- Owned remote scratch-prefix inventories empty; isolated devbox workspace absent; no matching capture/build process observed.
- Native AlarmManager absence was not queried. Ordinary file removal is not a secure-erasure guarantee.

## Maintenance observations and receipts

Initial log export succeeded remotely but local receipt writing failed because `cleanup/` did not exist; the directory-creating write tool saved the receipt afterward, without replaying export. The first Android `content delete` succeeded with empty stdout; an overly specific success-text assertion stopped the script. Fresh readback proved the text row/file already absent; it was **not replayed**. Subsequent deletions were verified by exact postcondition queries rather than expected stdout wording.

Receipts in `cleanup/`: `log-archive-inventory.json`, `phone-fixtures-before.json`, `phone-fixtures-removed.json`, host-specific inspected/removed inventories, `devbox-workspace-removed.json`, `gama-asr-removed.json`, `final-phone-readback.json`, `final-backup-source-proof.json`. These distinguish observed completion from the original blocked worker handoff.
