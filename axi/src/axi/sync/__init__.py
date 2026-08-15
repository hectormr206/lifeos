"""Device-to-device sync: the crypto core, shared by every LifeOS install.

Everything in here has an exact Dart counterpart in `mobile/lib/core/sync/`.
The two are held together by `shared/sync-test-vectors/vectors.json`, which
this package generates and both test suites assert against. Change a domain
string, a KDF parameter or the wordlist here and you have changed the format
for every device — regenerate the vectors and expect the Dart suite to go red
until it is updated to match.
"""
