package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.speech.RecognizerIntent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice search for the TV search screen (port of Silo Android #830's
 * `TvVoiceSearch.kt`). Listening is handed to the system speech recogniser
 * (RecognizerIntent.ACTION_RECOGNIZE_SPEECH): on a TV it listens through the
 * remote's microphone in its own app, so this needs no RECORD_AUDIO. The
 * remote's own mic button goes to the system assistant before any app sees
 * it, so an on-screen button is the only way in.
 *
 * Methods: `isAvailable` (an activity can take the intent; needs the
 * manifest's `<queries>` entry on Android 11+) and `recognize` {prompt},
 * answering {status: "ok", text} with the recogniser's top result,
 * {status: "cancelled"} or {status: "unavailable"}.
 */
internal class VoiceSearchChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/voice_search"
    private const val TAG = "VoiceSearchChannel"
    const val REQUEST_CODE = 7462
  }

  private var pendingResult: MethodChannel.Result? = null

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isAvailable" -> result.success(isRecognitionAvailable(activity))
      "recognize" -> recognize(call.argument<String>("prompt"), result)
      else -> result.notImplemented()
    }
  }

  private fun recognize(prompt: String?, result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "Voice search is already listening", null)
      return
    }
    // Availability was read earlier and may be stale (the recogniser can be
    // disabled since): the caller says so instead of doing nothing.
    if (!isRecognitionAvailable(activity)) {
      result.success(mapOf("status" to "unavailable"))
      return
    }
    try {
      pendingResult = result
      activity.startActivityForResult(recognizerIntent(prompt, preferredRecognizerPackage(activity)), REQUEST_CODE)
    } catch (e: ActivityNotFoundException) {
      pendingResult = null
      Log.w(TAG, "No activity accepted the speech recognition intent", e)
      result.success(mapOf("status" to "unavailable"))
    }
  }

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE) return false
    val result = pendingResult ?: return true
    pendingResult = null
    // Ordered by confidence: the first entry is the recogniser's best guess.
    val spoken = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.trim().orEmpty()
    if (resultCode != Activity.RESULT_OK || spoken.isEmpty()) {
      result.success(mapOf("status" to "cancelled"))
    } else {
      result.success(mapOf("status" to "ok", "text" to spoken))
    }
    return true
  }

  fun dispose() {
    pendingResult?.success(mapOf("status" to "cancelled"))
    pendingResult = null
  }

  /**
   * resolveActivity, not queryIntentActivities(intent, 0): the latter also
   * lists handlers without CATEGORY_DEFAULT, which startActivityForResult
   * will not launch. SpeechRecognizer.isRecognitionAvailable reports a
   * recognition service, not the activity this needs.
   */
  private fun isRecognitionAvailable(context: Context): Boolean =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).resolveActivity(context.packageManager) != null

  /**
   * Which package should take the request, or null to leave it to the system.
   * With several handlers and no default the launch becomes a chooser (a
   * Google TV Streamer offers the TV search app and the text-to-speech
   * package). The voice-interaction/assistant package is the TV's spoken
   * front end, so it is asked first, the recognition service after it.
   */
  private fun preferredRecognizerPackage(context: Context): String? {
    val candidates = context.packageManager.queryIntentActivities(
      Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
      PackageManager.MATCH_DEFAULT_ONLY
    )
    if (candidates.size <= 1) return candidates.firstOrNull()?.activityInfo?.packageName
    val resolver = context.contentResolver
    // Read by key: the constants are not all public API.
    return listOf("voice_interaction_service", "assistant", "voice_recognition_service")
      .mapNotNull { key -> Settings.Secure.getString(resolver, key)?.substringBefore('/')?.takeIf { it.isNotBlank() } }
      .firstOrNull { pkg -> candidates.any { it.activityInfo?.packageName == pkg } }
  }

  /**
   * Free-form, not web search: these are titles, and the web-search model
   * rewrites them toward a web query. No EXTRA_MAX_RESULTS (only the first is
   * used) and no EXTRA_LANGUAGE: the device's own speech locale is what the
   * household set up.
   */
  private fun recognizerIntent(prompt: String?, recognizerPackage: String?): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      recognizerPackage?.let(::setPackage)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      if (!prompt.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
    }
}
