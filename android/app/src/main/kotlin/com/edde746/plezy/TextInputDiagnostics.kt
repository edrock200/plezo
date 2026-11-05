package com.edde746.plezy

import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.TextAttribute
import androidx.annotation.RequiresApi

/**
 * Text-input diagnostics that a release build can switch on from adb, so a user's
 * TV can show where IME edits (typed or dictated) go:
 *
 *   adb shell setprop log.tag.PlezyTextInput DEBUG
 *   adb shell am force-stop com.edrock200.plezilo
 *   adb logcat -s PlezyTextInput:V flutter:V
 *
 * `adb shell setprop log.tag.PlezyTextInput ""` (and a restart) turns it off.
 * Only lengths, offsets and flags are logged, never the text itself.
 */
object TextInputDiagnostics {
  const val TAG = "PlezyTextInput"

  @Volatile var enabled: Boolean = false
    private set

  /** Re-reads the `log.tag.PlezyTextInput` property; called when the activity is created. */
  fun refresh(): Boolean {
    enabled = try {
      Log.isLoggable(TAG, Log.DEBUG)
    } catch (_: IllegalArgumentException) {
      false
    }
    return enabled
  }

  inline fun log(message: () -> String) {
    if (enabled) Log.i(TAG, message())
  }

  fun describeEditorInfo(info: EditorInfo): String = "inputType=0x${Integer.toHexString(info.inputType)} " +
    "imeOptions=0x${Integer.toHexString(info.imeOptions)} privateImeOptions=${info.privateImeOptions} " +
    "initialSel=${info.initialSelStart}-${info.initialSelEnd}"
}

/**
 * Logs every call an IME makes that edits the field, with the editable's length and
 * caret right after it and again [FRAMEWORK_SETTLE_MS] later — by then the Flutter
 * framework has answered, so a length that falls back shows the framework rejected the
 * edit (a read-only field, a formatter, a controller listener), while a call that never
 * appears shows the IME delivered the words somewhere else.
 */
class LoggingInputConnection(target: InputConnection, private val connectionId: Int) : InputConnectionWrapper(target, false) {
  companion object {
    private const val FRAMEWORK_SETTLE_MS = 500L
    private val mainHandler = Handler(Looper.getMainLooper())
  }

  // getExtractedText would reset the IME's text-monitor request on Flutter's
  // InputConnectionAdaptor, so read the text around the caret instead.
  private fun state(): String {
    val before = try {
      getTextBeforeCursor(100_000, 0)?.length
    } catch (_: RuntimeException) {
      null
    }
    val after = try {
      getTextAfterCursor(100_000, 0)?.length
    } catch (_: RuntimeException) {
      null
    }
    val selected = try {
      getSelectedText(0)?.length ?: 0
    } catch (_: RuntimeException) {
      null
    }
    if (before == null || after == null || selected == null) return "editable=unavailable"
    return "editableLen=${before + selected + after} caret=$before selectedLen=$selected"
  }

  private fun <T> traced(call: String, edits: Boolean, block: () -> T): T {
    val result = block()
    if (TextInputDiagnostics.enabled) {
      TextInputDiagnostics.log { "ic#$connectionId $call -> $result ${state()}" }
      if (edits) {
        mainHandler.postDelayed({
          TextInputDiagnostics.log { "ic#$connectionId $call after framework: ${state()}" }
        }, FRAMEWORK_SETTLE_MS)
      }
    }
    return result
  }

  private fun len(text: CharSequence?): String = "len=${text?.length ?: -1}"

  override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean = traced("setComposingText(${len(text)}, cursor=$newCursorPosition)", true) {
    super.setComposingText(text, newCursorPosition)
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  override fun setComposingText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean = traced("setComposingText+attr(${len(text)}, cursor=$newCursorPosition)", true) {
    super.setComposingText(text, newCursorPosition, textAttribute)
  }

  override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean = traced("commitText(${len(text)}, cursor=$newCursorPosition)", true) {
    super.commitText(text, newCursorPosition)
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  override fun commitText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean = traced("commitText+attr(${len(text)}, cursor=$newCursorPosition)", true) {
    super.commitText(text, newCursorPosition, textAttribute)
  }

  override fun finishComposingText(): Boolean = traced("finishComposingText", true) { super.finishComposingText() }

  override fun setComposingRegion(start: Int, end: Int): Boolean = traced("setComposingRegion($start-$end)", true) {
    super.setComposingRegion(start, end)
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  override fun setComposingRegion(start: Int, end: Int, textAttribute: TextAttribute?): Boolean = traced("setComposingRegion+attr($start-$end)", true) {
    super.setComposingRegion(start, end, textAttribute)
  }

  override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean = traced("deleteSurroundingText($beforeLength, $afterLength)", true) {
    super.deleteSurroundingText(beforeLength, afterLength)
  }

  override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean = traced("deleteSurroundingTextInCodePoints($beforeLength, $afterLength)", true) {
    super.deleteSurroundingTextInCodePoints(beforeLength, afterLength)
  }

  override fun setSelection(start: Int, end: Int): Boolean = traced("setSelection($start-$end)", true) {
    super.setSelection(start, end)
  }

  override fun sendKeyEvent(event: KeyEvent?): Boolean = traced(
    "sendKeyEvent(action=${event?.action} key=${event?.keyCode?.let { KeyEvent.keyCodeToString(it) }})",
    true
  ) { super.sendKeyEvent(event) }

  override fun performEditorAction(editorAction: Int): Boolean = traced("performEditorAction($editorAction)", false) {
    super.performEditorAction(editorAction)
  }

  override fun performPrivateCommand(action: String?, data: Bundle?): Boolean = traced("performPrivateCommand($action)", false) {
    super.performPrivateCommand(action, data)
  }

  override fun beginBatchEdit(): Boolean = traced("beginBatchEdit", false) { super.beginBatchEdit() }

  override fun endBatchEdit(): Boolean = traced("endBatchEdit", true) { super.endBatchEdit() }

  override fun closeConnection() {
    TextInputDiagnostics.log { "ic#$connectionId closeConnection" }
    super.closeConnection()
  }
}
