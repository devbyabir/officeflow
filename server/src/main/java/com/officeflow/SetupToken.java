package com.officeflow;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;

/**
 * The one-time secret that authorizes creating the first administrator from the browser. It
 * expires after a short time, is used up by one successful setup, and locks after repeated wrong
 * guesses. OfficeFlow.exe chooses it and opens the browser with it in the URL fragment, which
 * browsers never send to the server or write into request logs.
 */
final class SetupToken {
  static final Duration LIFETIME = Duration.ofMinutes(15);
  static final int MAXIMUM_FAILURES = 5;

  enum Status {
    READY,
    EXPIRED,
    USED,
    LOCKED
  }

  private final byte[] secret;
  private final Instant expires;
  private int failures;
  private boolean used;

  private SetupToken(String secret, Instant expires) {
    this.secret = secret.getBytes(StandardCharsets.US_ASCII);
    this.expires = expires;
  }

  /** Uses {@code supplied} when it is a strong token (at least 32 URL-safe characters). */
  static SetupToken create(String supplied, Instant now) {
    String secret = valid(supplied) ? supplied : generate();
    return new SetupToken(secret, now.plus(LIFETIME));
  }

  static boolean valid(String token) {
    return token != null && token.matches("[A-Za-z0-9_-]{32,128}");
  }

  static String generate() {
    byte[] bytes = new byte[32];
    new SecureRandom().nextBytes(bytes);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  String value() {
    return new String(secret, StandardCharsets.US_ASCII);
  }

  synchronized Status status(Instant now) {
    if (used) return Status.USED;
    if (failures >= MAXIMUM_FAILURES) return Status.LOCKED;
    if (!now.isBefore(expires)) return Status.EXPIRED;
    return Status.READY;
  }

  /**
   * True exactly once, for the correct token while it is still valid. Every wrong guess counts
   * towards the lock. The comparison takes the same time wherever the first difference is.
   */
  synchronized boolean redeem(String candidate, Instant now) {
    if (status(now) != Status.READY) return false;
    byte[] given = (candidate == null ? "" : candidate).getBytes(StandardCharsets.US_ASCII);
    if (!MessageDigest.isEqual(secret, given)) {
      failures++;
      return false;
    }
    used = true;
    return true;
  }
}
