package com.edde746.plezy.iptv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.edde746.plezy.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.text.DateFormat
import java.util.Date

/**
 * Keeps Plezilo's process alive while an IPTV recording runs (or one is due soon) and the app
 * is in the background: a foreground service of type dataSync with an ongoing notification.
 *
 * The recording itself runs in Dart (IptvRecorder); the service only stops Android from
 * suspending or killing the process. Dart reports its state over `com.plezy/iptv_recording`
 * ([IptvRecordingChannel]). The service is started while the app is visible (a recording
 * starting in front of the user, or the activity pausing with one due) because Android 12+
 * refuses to start a foreground service from the background. When the activity is destroyed
 * (the app swiped away) the Flutter engine stops with it, so the service stops too.
 */
class IptvRecordingService : Service() {
  companion object {
    private const val TAG = "PlezyIptvRecording"
    private const val CHANNEL_ID = "iptv_recording"
    private const val NOTIFICATION_ID = 7341

    /** Titles recording now, in Dart's order. */
    @Volatile var activeTitles: List<String> = emptyList()

    /** The next scheduled recording (epoch ms) and its title, or null. */
    @Volatile var nextAtMs: Long? = null
    @Volatile var nextTitle: String? = null
    @Volatile var running = false

    /** How far ahead a scheduled recording keeps the service up when the app leaves. */
    private const val ARM_WINDOW_MS = 12L * 60 * 60 * 1000

    fun isArmed(nowMs: Long = System.currentTimeMillis()): Boolean {
      val next = nextAtMs
      return activeTitles.isNotEmpty() || (next != null && next - nowMs in 0..ARM_WINDOW_MS)
    }

    fun start(context: Context) {
      if (!isArmed()) return
      try {
        val intent = Intent(context, IptvRecordingService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
      } catch (e: Exception) {
        // ForegroundServiceStartNotAllowedException when the app is no longer visible.
        Log.w(TAG, "recording service not started: ${e.javaClass.simpleName}")
      }
    }

    fun stop(context: Context) {
      if (!running) return
      context.stopService(Intent(context, IptvRecordingService::class.java))
    }
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val notification = buildNotification()
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }
      running = true
    } catch (e: Exception) {
      Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName}")
      stopSelf()
      return START_NOT_STICKY
    }
    // Nothing to resume if Android restarts us without the app: Dart owns the recording.
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    running = false
    super.onDestroy()
  }

  private fun buildNotification(): Notification {
    val manager = getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager?.getNotificationChannel(CHANNEL_ID) == null) {
      manager?.createNotificationChannel(
        NotificationChannel(CHANNEL_ID, getString(R.string.iptv_recording_channel), NotificationManager.IMPORTANCE_LOW),
      )
    }
    val titles = activeTitles
    val text = if (titles.isNotEmpty()) {
      titles.joinToString(", ")
    } else {
      val at = nextAtMs?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it)) } ?: ""
      listOfNotNull(nextTitle, at.ifEmpty { null }).joinToString(" · ")
    }
    val title = getString(if (titles.isNotEmpty()) R.string.iptv_recording_now else R.string.iptv_recording_waiting)
    val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
      PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else @Suppress("DEPRECATION") Notification.Builder(this)
    return builder
      .setSmallIcon(R.drawable.ic_stat_notification)
      .setContentTitle(title)
      .setContentText(text)
      .setOngoing(true)
      .setContentIntent(launch)
      .build()
  }
}

/**
 * `com.plezy/iptv_recording`: Dart reports which recordings run and which is next
 * (`setState`), and the activity starts or stops [IptvRecordingService] around it.
 */
class IptvRecordingChannel(private val context: Context) {
  companion object {
    const val CHANNEL = "com.plezy/iptv_recording"
  }

  /** Whether the activity is in front (a service started now is allowed). */
  var visible = true

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "setState" -> {
          @Suppress("UNCHECKED_CAST")
          val titles = (call.argument<List<Any?>>("active") ?: emptyList()).mapNotNull { it as? String }
          IptvRecordingService.activeTitles = titles
          IptvRecordingService.nextAtMs = (call.argument<Any?>("nextAtMs") as? Number)?.toLong()
          IptvRecordingService.nextTitle = call.argument<String>("nextTitle")
          update()
          result.success(IptvRecordingService.running)
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun update() {
    when {
      IptvRecordingService.activeTitles.isNotEmpty() -> IptvRecordingService.start(context)
      // Restarting a running service only refreshes its notification.
      (!visible || IptvRecordingService.running) && IptvRecordingService.isArmed() -> IptvRecordingService.start(context)
      else -> IptvRecordingService.stop(context)
    }
  }

  /** The activity is pausing (still visible): keep the process alive for a due recording. */
  fun onPause() {
    visible = false
    if (IptvRecordingService.isArmed()) IptvRecordingService.start(context)
  }

  /** Back in front: the service is only needed while something records. */
  fun onResume() {
    visible = true
    if (IptvRecordingService.activeTitles.isEmpty()) IptvRecordingService.stop(context)
  }

  /** The engine stops with the activity; nothing can record any more. */
  fun onDestroy() {
    IptvRecordingService.activeTitles = emptyList()
    IptvRecordingService.nextAtMs = null
    IptvRecordingService.stop(context)
  }
}
