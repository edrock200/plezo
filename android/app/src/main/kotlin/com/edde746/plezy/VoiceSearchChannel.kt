package com.edde746.plezy

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
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
 *
 * Android 11 Google TV (Silo Android #860): the TV search app's recognition
 * activity fails its own permission check there, so on that release with that
 * recogniser Plezilo calls the recognition service itself (SpeechRecognizer),
 * asks for RECORD_AUDIO first, and shows a small listening dialog.
 */
internal class VoiceSearchChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/voice_search"
    private const val TAG = "VoiceSearchChannel"
    const val REQUEST_CODE = 7462
    const val MIC_REQUEST_CODE = 7463
    private const val GOOGLE_TV_RECOGNIZER = "com.google.android.katniss"
    private const val STARTUP_TIMEOUT_MS = 10_000L
  }

  private var pendingResult: MethodChannel.Result? = null

  // Android 11 Google TV path: the service recogniser, its dialog and the
  // prompt waiting for the microphone permission answer.
  private var recognizer: SpeechRecognizer? = null
  private var listeningDialog: AlertDialog? = null
  private var pendingPrompt: String? = null
  private val handler = Handler(Looper.getMainLooper())
  private var startupTimeout: Runnable? = null

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
    if (usesServiceRecognizer()) {
      pendingResult = result
      if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
        startServiceRecognition(prompt)
      } else {
        pendingPrompt = prompt
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST_CODE)
      }
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

  fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
    if (requestCode != MIC_REQUEST_CODE) return false
    val prompt = pendingPrompt
    pendingPrompt = null
    if (pendingResult == null) return true
    if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
      startServiceRecognition(prompt)
    } else {
      showMessageThenCancel("Allow microphone access for Plezilo in Settings to use voice search.")
    }
    return true
  }

  fun dispose() {
    stopServiceRecognition()
    pendingResult?.success(mapOf("status" to "cancelled"))
    pendingResult = null
  }

  /** Android 11 with the Google TV search app as the recogniser (Silo Android #860). */
  private fun usesServiceRecognizer(): Boolean {
    if (Build.VERSION.SDK_INT != Build.VERSION_CODES.R) return false
    val pkg = preferredRecognizerPackage(activity)
      ?: Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).resolveActivity(activity.packageManager)?.packageName
    return pkg == GOOGLE_TV_RECOGNIZER && SpeechRecognizer.isRecognitionAvailable(activity)
  }

  private fun finish(status: Map<String, Any>) {
    val result = pendingResult ?: return
    pendingResult = null
    result.success(status)
  }

  private fun cancelStartupTimeout() {
    startupTimeout?.let(handler::removeCallbacks)
    startupTimeout = null
  }

  private fun releaseRecognizer() {
    cancelStartupTimeout()
    val speech = recognizer
    recognizer = null
    try {
      speech?.destroy()
    } catch (e: IllegalArgumentException) {
      // A failed bind may leave no registered connection to unbind.
      Log.w(TAG, "Recognition service was not bound", e)
    }
  }

  private fun stopServiceRecognition() {
    releaseRecognizer()
    val dialog = listeningDialog
    listeningDialog = null
    dialog?.setOnDismissListener(null)
    dialog?.dismiss()
  }

  /** A message the viewer closes; the search then counts as cancelled. */
  private fun showMessageThenCancel(message: String) {
    stopServiceRecognition()
    listeningDialog = AlertDialog.Builder(activity)
      .setTitle("Voice search")
      .setMessage(message)
      .setPositiveButton(android.R.string.ok, null)
      .create()
      .also { dialog ->
        dialog.setOnDismissListener {
          listeningDialog = null
          finish(mapOf("status" to "cancelled"))
        }
        dialog.show()
      }
  }

  private fun startServiceRecognition(prompt: String?) {
    stopServiceRecognition()
    val speech = try {
      SpeechRecognizer.createSpeechRecognizer(activity)
    } catch (e: RuntimeException) {
      Log.w(TAG, "Could not create a speech recogniser", e)
      finish(mapOf("status" to "unavailable"))
      return
    }
    recognizer = speech
    val dialog = AlertDialog.Builder(activity)
      .setTitle("Voice search")
      .setMessage(if (prompt.isNullOrBlank()) "Listening…" else prompt)
      .setNegativeButton(android.R.string.cancel, null)
      .create()
    dialog.setOnDismissListener {
      if (listeningDialog === dialog) listeningDialog = null
      releaseRecognizer()
      finish(mapOf("status" to "cancelled"))
    }
    listeningDialog = dialog
    speech.setRecognitionListener(object : RecognitionListener {
      override fun onReadyForSpeech(params: Bundle?) {
        if (recognizer === speech) cancelStartupTimeout()
      }
      override fun onBeginningOfSpeech() {
        if (recognizer === speech) cancelStartupTimeout()
      }
      override fun onRmsChanged(rmsdB: Float) = Unit
      override fun onBufferReceived(buffer: ByteArray?) = Unit
      override fun onEndOfSpeech() = Unit
      override fun onEvent(eventType: Int, params: Bundle?) = Unit
      override fun onPartialResults(partialResults: Bundle?) {
        if (recognizer !== speech) return
        cancelStartupTimeout()
        partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
          ?.firstOrNull()?.takeIf { it.isNotBlank() }?.let(dialog::setMessage)
      }
      override fun onResults(results: Bundle?) {
        if (recognizer !== speech) return
        val spoken = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
          ?.firstOrNull()?.trim().orEmpty()
        val status = if (spoken.isEmpty()) mapOf("status" to "cancelled") else mapOf("status" to "ok", "text" to spoken)
        finish(status)
        stopServiceRecognition()
      }
      override fun onError(error: Int) {
        if (recognizer !== speech) return
        Log.w(TAG, "Recognition failed: $error")
        releaseRecognizer()
        // The dialog stays with the reason until the viewer closes it.
        dialog.setMessage(
          when (error) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
              "Didn't hear a title. Close and try again."
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
              "Couldn't connect to voice search. Check your connection and try again."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
              "The voice service couldn't use the microphone. Check microphone access in Settings and try again."
            else -> "Voice search couldn't start. Close and try again."
          }
        )
      }
    })
    dialog.show()
    // Android 11 can drop binding errors before the listener is installed.
    val timeout = Runnable {
      if (recognizer === speech) {
        finish(mapOf("status" to "unavailable"))
        stopServiceRecognition()
      }
    }
    startupTimeout = timeout
    handler.postDelayed(timeout, STARTUP_TIMEOUT_MS)
    try {
      speech.startListening(
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
          putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
          putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        }
      )
    } catch (e: SecurityException) {
      Log.w(TAG, "Recognition service access denied", e)
      finish(mapOf("status" to "unavailable"))
      stopServiceRecognition()
    }
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
