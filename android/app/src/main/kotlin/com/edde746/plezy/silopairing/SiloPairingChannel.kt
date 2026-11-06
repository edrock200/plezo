package com.edde746.plezy.silopairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * "Sign in from your phone" for Silo: while Plezilo's Silo sign-in screen is up, this
 * advertises `_silopair._tcp` with NsdManager (the service type, TXT keys and TLS-PSK that
 * Silo's Android TV app uses, silo-android `TvPairingAdvertiser.kt`), so Silo's phone app
 * on the same network lists this device as a TV.
 *
 * Only the network edge lives here: the service registration, the LAN listener and the
 * TLS-PSK handshake (Dart has no PSK). Each accepted phone's plaintext is relayed to a
 * loopback socket the Dart side listens on (`SiloPairingHost`), opened by a one-time
 * secret, and the protocol itself (frames, messages, the state machine) runs in Dart.
 * One phone at a time: a second connection is closed while one is relayed.
 */
internal class SiloPairingChannel(context: Context) {
  companion object {
    private const val TAG = "SiloPairing"
    private const val CHANNEL = "com.plezy/silo_pairing"
    private const val BRIDGE_CONNECT_TIMEOUT_MS = 3_000
  }

  private val appContext = context.applicationContext
  private val nsdManager: NsdManager? = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
  private val mainThread = Handler(Looper.getMainLooper())

  /** start/stop run here, one at a time, so a stop can never interleave a start. */
  private val control = Executors.newSingleThreadExecutor { r -> Thread(r, "silo-pairing-control").apply { isDaemon = true } }

  private var serverSocket: ServerSocket? = null
  private var registration: NsdManager.RegistrationListener? = null
  private val busy = AtomicBoolean(false)

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  fun dispose() {
    control.execute { stopNow() }
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> {
        val serviceName = call.argument<String>("serviceName")
        val serviceType = call.argument<String>("serviceType")
        val txt = call.argument<Map<String, String>>("txt").orEmpty()
        val bridgePort = call.argument<Int>("bridgePort")
        val secret = call.argument<ByteArray>("bridgeSecret")
        if (serviceName.isNullOrEmpty() || serviceType.isNullOrEmpty() || bridgePort == null || secret == null) {
          result.error("bad_args", "start needs serviceName, serviceType, bridgePort and bridgeSecret", null)
          return
        }
        control.execute {
          val port = runCatching { startNow(serviceName, serviceType, txt, bridgePort, secret) }
            .onFailure { Log.w(TAG, "could not start the pairing listener", it) }
            .getOrNull()
          mainThread.post {
            if (port != null) result.success(port) else result.error("start_failed", "pairing listener did not start", null)
          }
        }
      }
      "stop" -> control.execute {
        stopNow()
        mainThread.post { result.success(null) }
      }
      else -> result.notImplemented()
    }
  }

  /** Caller is the control thread. Returns the LAN port. */
  private fun startNow(serviceName: String, serviceType: String, txt: Map<String, String>, bridgePort: Int, secret: ByteArray): Int {
    stopNow()
    val socket = ServerSocket(0)
    serverSocket = socket
    val info = NsdServiceInfo().apply {
      this.serviceName = serviceName
      this.serviceType = serviceType
      port = socket.localPort
      for ((key, value) in txt) {
        runCatching { setAttribute(key, value) }.onFailure { Log.w(TAG, "TXT $key not set", it) }
      }
    }
    val listener = object : NsdManager.RegistrationListener {
      override fun onServiceRegistered(info: NsdServiceInfo) {
        Log.i(TAG, "pairing service registered as ${info.serviceName}")
      }

      override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
        Log.w(TAG, "pairing service registration failed: $errorCode")
      }

      override fun onServiceUnregistered(info: NsdServiceInfo) {
        Log.i(TAG, "pairing service unregistered")
      }

      override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
        Log.w(TAG, "pairing service unregistration failed: $errorCode")
      }
    }
    try {
      nsdManager?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
      registration = listener
      thread(isDaemon = true, name = "silo-pairing-accept") { acceptLoop(socket, bridgePort, secret.copyOf()) }
    } catch (t: Throwable) {
      // Nothing listens without the advertisement: close the socket (which
      // also ends an accept loop that did start) rather than keep it open
      // until the next start or stop.
      stopNow()
      throw t
    }
    Log.i(TAG, "pairing listener on port ${socket.localPort}")
    return socket.localPort
  }

  /** Caller is the control thread. Relayed sessions are left to end on their own. */
  private fun stopNow() {
    registration?.let { listener -> runCatching { nsdManager?.unregisterService(listener) } }
    registration = null
    runCatching { serverSocket?.close() }
    serverSocket = null
  }

  private fun acceptLoop(socket: ServerSocket, bridgePort: Int, secret: ByteArray) {
    while (true) {
      val client = try {
        socket.accept()
      } catch (_: Throwable) {
        return // closed by stop
      }
      if (!busy.compareAndSet(false, true)) {
        Log.i(TAG, "pairing connection refused: busy")
        runCatching { client.close() }
        continue
      }
      thread(isDaemon = true, name = "silo-pairing-session") {
        try {
          relay(client, bridgePort, secret)
        } catch (t: Throwable) {
          Log.i(TAG, "pairing connection ended: ${t.javaClass.simpleName}")
          runCatching { client.close() }
        } finally {
          busy.set(false)
        }
      }
    }
  }

  /** TLS-PSK with the phone, then pump plaintext both ways until either side ends. */
  private fun relay(client: Socket, bridgePort: Int, secret: ByteArray) {
    client.tcpNoDelay = true
    val tls = SiloPairingTls.accept(client)
    Log.i(TAG, "pairing TLS connected")
    val bridge = Socket()
    try {
      bridge.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), bridgePort), BRIDGE_CONNECT_TIMEOUT_MS)
      bridge.tcpNoDelay = true
      bridge.getOutputStream().apply {
        write(secret)
        flush()
      }
    } catch (t: Throwable) {
      tls.close()
      runCatching { bridge.close() }
      throw t
    }
    val closeBoth = {
      tls.close()
      runCatching { bridge.close() }
    }
    val toDart = thread(isDaemon = true, name = "silo-pairing-in") {
      pump(tls.input, bridge.getOutputStream())
      closeBoth()
    }
    pump(bridge.getInputStream(), tls.output)
    closeBoth()
    toDart.join()
  }

  private fun pump(from: InputStream, to: OutputStream) {
    val buffer = ByteArray(16 * 1024)
    try {
      while (true) {
        val read = from.read(buffer)
        if (read < 0) return
        if (read == 0) continue
        to.write(buffer, 0, read)
        to.flush()
      }
    } catch (_: Throwable) {
      // Either side went away; the caller closes both.
    }
  }
}
