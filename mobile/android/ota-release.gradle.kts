// Standalone task-graph gate: Flutter passes comma-separated Base64(name=value)
// entries via -Pdart-defines. This runs before any release task action, including
// direct Flutter compilation and aggregate builds. Like the existing app graph
// checks, whenReady is not compatible with Gradle's configuration cache.
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64

fun validUpdateUrl(value: String): Boolean {
    if (value.any { it.code !in 0x21..0x7e } ||
        Regex("placeholder|change.?me|replace.?me|your.?url|[<>]", RegexOption.IGNORE_CASE)
            .containsMatchIn(value)) return false
    val uri = runCatching { URI(value) }.getOrNull() ?: return false
    val host = uri.host ?: return false
    return uri.scheme == "https" && uri.rawUserInfo == null &&
        uri.rawQuery == null && uri.rawFragment == null &&
        '?' !in value && '#' !in value &&
        (uri.port == -1 || uri.port in 1..65535) && host.length <= 253 &&
        host.split('.').all {
            it.matches(Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"))
        }
}

fun validUpdateKey(value: String): Boolean = value.isNotEmpty() &&
    value.all { it.code in 0x21..0x7e } &&
    !Regex("placeholder|change.?me|replace.?me|your.?access|dummy|[<>]",
           RegexOption.IGNORE_CASE).containsMatchIn(value)

fun validDartDefines(raw: String?): Boolean {
    if (raw.isNullOrEmpty()) return false
    val values = mutableMapOf<String, String>()
    for (token in raw.split(',')) {
        val decoded = runCatching {
            val bytes = Base64.getDecoder().decode(token)
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        }.getOrNull() ?: return false
        val separator = decoded.indexOf('=')
        if (separator <= 0) return false
        val name = decoded.substring(0, separator)
        if (values.putIfAbsent(name, decoded.substring(separator + 1)) != null) return false
    }
    return validUpdateUrl(values["UPDATE_BASE_URL"] ?: "") &&
        validUpdateKey(values["UPDATE_ACCESS_KEY"] ?: "")
}

gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release") }) {
        check(validDartDefines(project.findProperty("dart-defines")?.toString())) {
            "Production release requires valid UPDATE_BASE_URL and UPDATE_ACCESS_KEY Dart defines."
        }
    }
}
