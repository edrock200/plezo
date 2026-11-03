package com.edde746.plezy.silopairing

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.security.SecureRandom
import java.util.Vector
import org.bouncycastle.tls.BasicTlsPSKExternal
import org.bouncycastle.tls.CipherSuite
import org.bouncycastle.tls.PRFAlgorithm
import org.bouncycastle.tls.PSKTlsServer
import org.bouncycastle.tls.ProtocolVersion
import org.bouncycastle.tls.TlsPSKExternal
import org.bouncycastle.tls.TlsPSKIdentityManager
import org.bouncycastle.tls.TlsServerProtocol
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto

/**
 * The TLS-PSK server side of Silo's companion pairing, as Silo's Android TV app runs it
 * (silo-android `android-shared/.../common/pairing/TlsPskPairingTransport.kt`, itself
 * byte-compatible with silo-apple's `PairingSession.tlsParameters`).
 *
 * The key and identity are fixed and public, compiled into every Silo app: this is
 * opportunistic encryption, not authentication. Trust comes from the person allowing the
 * setup on the TV and comparing the code; no token ever crosses this channel.
 *
 * BouncyCastle's blocking accept waits for the peer's first application record before it
 * returns with TLS 1.3 PSK, while the phone waits for the TV's `hello`; so, like Silo, the
 * handshake runs in non-blocking mode and returns as soon as it is connected.
 */
internal object SiloPairingTls {
  // Fresh arrays on every use: BouncyCastle zeroes the PSK buffer once a TLS 1.2 handshake
  // derived its keys (Silo found a shared array failing every later handshake).
  private fun key(): ByteArray = "silo-companion-pairing-v1".toByteArray(Charsets.UTF_8)
  private fun identity(): ByteArray = "silo-pairing".toByteArray(Charsets.UTF_8)

  private const val TLS12_SUITE = CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256
  private const val TLS13_SUITE = CipherSuite.TLS_AES_128_GCM_SHA256
  private const val HANDSHAKE_TIMEOUT_MS = 10_000

  /** Server handshake over an accepted [socket]. Blocking; closes the socket on failure. */
  fun accept(socket: Socket): SiloPairingTlsSession {
    val rawIn = socket.getInputStream()
    val rawOut = socket.getOutputStream()
    val protocol = TlsServerProtocol()
    try {
      socket.soTimeout = HANDSHAKE_TIMEOUT_MS
      protocol.accept(PairingPskTlsServer(BcTlsCrypto(SecureRandom())))
      drain(protocol, rawOut)
      val chunk = ByteArray(16 * 1024)
      while (!protocol.isConnected) {
        val read = rawIn.read(chunk)
        if (read < 0) throw EOFException("Pairing TLS handshake closed before completion")
        if (read == 0) continue
        protocol.offerInput(chunk, 0, read)
        drain(protocol, rawOut)
      }
      drain(protocol, rawOut)
      // The session's own idle rule lives in Dart; reads may wait as long as it allows.
      socket.soTimeout = 0
    } catch (t: Throwable) {
      // A LAN listener takes arbitrary connections: never leak a descriptor.
      runCatching { protocol.close() }
      runCatching { socket.close() }
      throw t
    }
    return SiloPairingTlsSession(socket, protocol, rawIn, rawOut)
  }

  internal fun drain(protocol: TlsServerProtocol, rawOut: OutputStream) {
    val out = ByteArray(16 * 1024)
    while (protocol.availableOutputBytes > 0) {
      val read = protocol.readOutput(out, 0, out.size)
      if (read <= 0) break
      rawOut.write(out, 0, read)
    }
    rawOut.flush()
  }

  /** Pinned to the fixed PSK and the AES-128-GCM PSK suites Apple's and Silo's stacks offer. */
  private class PairingPskTlsServer(
    private val bcCrypto: BcTlsCrypto
  ) : PSKTlsServer(
    bcCrypto,
    object : TlsPSKIdentityManager {
      override fun getHint(): ByteArray? = null

      override fun getPSK(identity: ByteArray?): ByteArray = key()
    }
  ) {
    override fun getCipherSuites(): IntArray = intArrayOf(TLS13_SUITE, TLS12_SUITE)

    override fun getSupportedVersions(): Array<ProtocolVersion> = arrayOf(ProtocolVersion.TLSv13, ProtocolVersion.TLSv12)

    override fun allowCertificateStatus(): Boolean = false

    /** TLS 1.3 external PSK: the fixed key for whatever identity is offered (it is public). */
    override fun getExternalPSK(identities: Vector<*>?): TlsPSKExternal = BasicTlsPSKExternal(identity(), bcCrypto.createSecret(key()), PRFAlgorithm.tls13_hkdf_sha256)
  }
}

/**
 * Application-data streams over the non-blocking server protocol. Reads and writes run on
 * different threads (the two relay directions); each touches the engine under its monitor.
 */
internal class SiloPairingTlsSession(
  private val socket: Socket,
  private val protocol: TlsServerProtocol,
  private val rawIn: InputStream,
  private val rawOut: OutputStream
) {
  val input: InputStream = object : InputStream() {
    private val chunk = ByteArray(16 * 1024)

    override fun read(): Int {
      val one = ByteArray(1)
      val n = read(one, 0, 1)
      return if (n <= 0) -1 else one[0].toInt() and 0xff
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
      while (true) {
        synchronized(protocol) {
          if (protocol.availableInputBytes > 0) return protocol.readInput(b, off, len)
          if (protocol.isClosed) return -1
        }
        val read = rawIn.read(chunk)
        if (read < 0) return -1
        if (read == 0) continue
        synchronized(protocol) {
          protocol.offerInput(chunk, 0, read)
          SiloPairingTls.drain(protocol, rawOut)
        }
      }
    }
  }

  val output: OutputStream = object : OutputStream() {
    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
      synchronized(protocol) {
        protocol.writeApplicationData(b, off, len)
        SiloPairingTls.drain(protocol, rawOut)
      }
    }
  }

  fun close() {
    // The socket first: a write blocked on a peer that stopped reading holds the monitor,
    // and closing the socket is what frees it (Silo's SiloCastTlsSession does the same).
    runCatching { socket.close() }
    synchronized(protocol) { runCatching { protocol.close() } }
  }
}
